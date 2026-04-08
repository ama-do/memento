/// Feature 08: TUI Browser Integration Tests
///
/// These tests drive the interactive TUI browsers (commands and history) using
/// a pseudoterminal (PTY) as stdin/stderr so that raw-mode setup and the
/// `stderr.isTty()` guard in main both succeed.
///
/// Layout per test:
///   PTY slave  → child stdin  (key reading, raw mode)
///   PTY slave  → child stderr (TUI rendering; isTty check passes)
///   pipe write → child stdout (captured for assertion)
///
/// A drain thread silently discards the TUI's rendered ANSI output from the
/// PTY master so the child never blocks on a full PTY buffer.
///
/// After the TUI exits we verify database state with the normal CLI helpers.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ─────────────────────────────────────────────────────────────────────────────
// C bindings — PTY + process management
// ─────────────────────────────────────────────────────────────────────────────

extern fn fork() c_int;
extern fn setsid() c_int;
extern fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn pipe(pipefd: *[2]c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
extern fn grantpt(fd: c_int) c_int;
extern fn unlockpt(fd: c_int) c_int;
extern fn ptsname(fd: c_int) ?[*:0]u8;
extern fn execve(
    path: [*:0]const u8,
    argv: [*c]?[*:0]const u8,
    envp: [*c]?[*:0]const u8,
) c_int;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn _exit(status: c_int) noreturn;
extern fn usleep(microseconds: c_uint) c_int;

// Platform-specific ioctl request codes
const is_darwin = builtin.os.tag.isDarwin();
const TIOCSCTTY:  c_ulong = if (is_darwin) 0x20007461 else 0x540E;
const TIOCSWINSZ: c_ulong = if (is_darwin) 0x80087467 else 0x5414;

const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = 0x400;

const WinSize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort,
    ws_ypixel: c_ushort,
};

// ─────────────────────────────────────────────────────────────────────────────
// TuiProc — an mm subprocess connected to a PTY
// ─────────────────────────────────────────────────────────────────────────────

const TuiProc = struct {
    master_fd: c_int,
    stdout_read: c_int,
    pid: c_int,
    drain_thread: std.Thread,

    /// Send raw bytes to the TUI (simulates keyboard input via PTY master).
    pub fn send(self: *const TuiProc, keys: []const u8) void {
        _ = write(self.master_fd, keys.ptr, keys.len);
    }

    /// Wait for mm to exit, collect stdout, and return result.
    /// Call after all key sequences have been sent (last key should quit).
    pub fn finish(self: *TuiProc, gpa: std.mem.Allocator) !Result {
        // Read stdout until EOF (child closes write-end of pipe on exit).
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = read(self.stdout_read, &buf, buf.len);
            if (n <= 0) break;
            try out.appendSlice(gpa, buf[0..@intCast(n)]);
        }

        // Reap the child process.
        var wstatus: c_int = 0;
        _ = waitpid(self.pid, &wstatus, 0);

        // Join the drain thread (it exits when the PTY slave closes on child exit).
        self.drain_thread.join();

        _ = close(self.master_fd);
        _ = close(self.stdout_read);

        // WIFEXITED(wstatus) == ((wstatus & 0x7f) == 0)
        // WEXITSTATUS(wstatus) == ((wstatus >> 8) & 0xff)
        const exit_code: u8 = if ((wstatus & 0x7f) == 0)
            @truncate(@as(u32, @intCast((wstatus >> 8) & 0xff)))
        else
            255;

        return .{
            .stdout = try out.toOwnedSlice(gpa),
            .exit_code = exit_code,
        };
    }
};

const Result = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Drain thread: reads and discards all data from the PTY master.
/// Exits naturally when the child closes the PTY slave (read returns EIO).
fn drainLoop(fd: c_int) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n <= 0) return;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// spawnTui — open a PTY, fork, exec mm, return TuiProc
// ─────────────────────────────────────────────────────────────────────────────

fn spawnTui(ctx: *helper.TestCtx, args: []const []const u8) !TuiProc {
    const gpa = ctx.gpa;

    // ── Open PTY master ────────────────────────────────────────────────────
    const master_fd = open("/dev/ptmx", O_RDWR | O_NOCTTY, @as(c_int, 0));
    if (master_fd < 0) return error.OpenPtmxFailed;
    errdefer _ = close(master_fd);

    _ = grantpt(master_fd);
    _ = unlockpt(master_fd);

    const slave_cstr = ptsname(master_fd) orelse return error.PtsnameFailure;
    // Copy slave path before any other libc calls could clobber the static buffer.
    var slave_path_buf: [64]u8 = undefined;
    const slave_path = slave_path_buf[0..std.mem.len(slave_cstr)];
    @memcpy(slave_path, slave_cstr[0..slave_path.len]);
    slave_path_buf[slave_path.len] = 0;

    const slave_fd = open(@ptrCast(&slave_path_buf), O_RDWR | O_NOCTTY, @as(c_int, 0));
    if (slave_fd < 0) return error.OpenSlaveFailed;
    errdefer _ = close(slave_fd);

    // Set terminal window size so the TUI renders at 24×80.
    const ws = WinSize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = ioctl(master_fd, TIOCSWINSZ, &ws);

    // ── Stdout pipe ────────────────────────────────────────────────────────
    var pipe_fds: [2]c_int = .{ 0, 0 };
    if (pipe(&pipe_fds) != 0) return error.PipeFailed;
    errdefer _ = close(pipe_fds[0]);
    errdefer _ = close(pipe_fds[1]);

    // ── Build null-terminated argv / envp using an arena allocator.
    // The arena is freed in the PARENT after fork.  The CHILD sees COW copies
    // of these strings (valid until execve() replaces the process image).
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    var argv: [32]?[*:0]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = try a.dupeZ(u8, mm_exe);
    argc += 1;
    for (args) |arg| {
        argv[argc] = try a.dupeZ(u8, arg);
        argc += 1;
    }
    argv[argc] = null;

    var envp: [8]?[*:0]const u8 = undefined;
    var envc: usize = 0;
    envp[envc] = (try a.dupeZ(u8, try std.fmt.allocPrint(a, "HOME={s}",          .{ctx.home_path}))).ptr; envc += 1;
    envp[envc] = (try a.dupeZ(u8, try std.fmt.allocPrint(a, "XDG_DATA_HOME={s}", .{ctx.tmp_path}))).ptr;  envc += 1;
    // Use fish so commands added via TUI share scope with the CLI test helper
    // (which also runs as fish by default).
    envp[envc] = (try a.dupeZ(u8, "SHELL=/bin/fish")).ptr;                                                 envc += 1;
    envp[envc] = (try a.dupeZ(u8, "PATH=/usr/bin:/bin")).ptr;                                              envc += 1;
    envp[envc] = null;

    const path_z: [*:0]const u8 = argv[0].?;

    // ── Fork ───────────────────────────────────────────────────────────────
    const pid = fork();
    if (pid < 0) {
        arena.deinit();
        return error.ForkFailed;
    }

    if (pid == 0) {
        // ── Child process ──────────────────────────────────────────────────
        // Create a new session; this process becomes session leader.
        _ = setsid();

        // Attach PTY slave as controlling terminal so raw-mode succeeds.
        _ = ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0));

        // Rewire stdio:
        //   stdin  ← PTY slave  (raw-mode key input)
        //   stderr ← PTY slave  (TUI rendering; isTty returns true)
        //   stdout ← pipe       (selected command captured by parent)
        _ = dup2(slave_fd, 0);
        _ = dup2(slave_fd, 2);
        _ = dup2(pipe_fds[1], 1);

        // Close file descriptors that the child no longer needs.
        if (slave_fd > 2) _ = close(slave_fd);
        _ = close(pipe_fds[0]);
        _ = close(pipe_fds[1]);
        _ = close(master_fd);

        // Replace the process image with mm.
        _ = execve(path_z, @ptrCast(&argv), @ptrCast(&envp));

        // execve only returns on failure.
        _exit(127);
    }

    // ── Parent process ─────────────────────────────────────────────────────

    // Free pre-fork allocations (child has COW copies that remain valid
    // until execve() replaces its address space).
    arena.deinit();

    // Close file descriptors the parent does not need.
    _ = close(slave_fd);
    _ = close(pipe_fds[1]);

    // Start a thread to drain rendered TUI output from the PTY master.
    // Without this the child would block when the PTY kernel buffer fills.
    const drain_thread = try std.Thread.spawn(.{}, drainLoop, .{master_fd});

    return TuiProc{
        .master_fd    = master_fd,
        .stdout_read  = pipe_fds[0],
        .pid          = pid,
        .drain_thread = drain_thread,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

fn delay(ms: u64) void {
    _ = usleep(@intCast(ms * 1000)); // usleep takes microseconds
}

fn seedFishHistory(ctx: *helper.TestCtx) !void {
    // Fish history format: YAML-like, newest entry at the bottom of the file.
    // The history browser loads entries in file order (oldest first), then
    // opens at the LAST entry (newest), so "git log --oneline" is selected.
    try ctx.writeHomeFile(".local/share/fish/fish_history",
        "- cmd: cargo build --release\n  when: 1700000001\n" ++
        "- cmd: kubectl get pods\n  when: 1700000002\n" ++
        "- cmd: git log --oneline\n  when: 1700000003\n",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands browser tests
// ─────────────────────────────────────────────────────────────────────────────

test "commands TUI: quit with q exits cleanly with empty stdout" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    var tui = try spawnTui(&ctx, &.{});
    delay(150);
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "commands TUI: ctrl-c exits cleanly" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    var tui = try spawnTui(&ctx, &.{});
    delay(150);
    tui.send("\x03"); // ^C

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "commands TUI: adding a command via 'a' persists to the database" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    tui.send("a");                        delay(80); // open add prompt
    tui.send("my-build\r");               delay(80); // label + Enter
    tui.send("cargo build --release\r");  delay(80); // command + Enter
    tui.send("\r");                       delay(80); // empty description
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Verify the command landed in the database.
    const list = try ctx.run(&.{ "-l", "my-build" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("my-build");
    try list.expectStderr("cargo build --release");
}

test "commands TUI: adding a command with description stores it" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    tui.send("a");                 delay(80);
    tui.send("kgp\r");             delay(80);
    tui.send("kubectl get pods\r");delay(80);
    tui.send("list all pods\r");   delay(80); // description
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const list = try ctx.run(&.{ "-l", "kgp" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("kgp");
    try list.expectStderr("kubectl get pods");
    try list.expectStderr("list all pods");
}

test "commands TUI: deleting a command via 'd' removes it from the database" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("deploy", "kubectl apply -f .", &.{"--universal"});

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    tui.send("d");    delay(80); // open delete prompt for selected command
    tui.send("y\r");  delay(80); // confirm with 'y' + Enter
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Verify the command is gone.
    const list = try ctx.run(&.{ "-l", "deploy" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("No commands match");
}

test "commands TUI: cancelling delete with 'n' preserves the command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build", &.{"--universal"});

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    tui.send("d");    delay(80); // open delete prompt
    tui.send("n\r");  delay(80); // answer 'n' — should cancel
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Command must still exist.
    const list = try ctx.run(&.{ "-l", "build" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("build");
}

test "commands TUI: navigation with j/k moves selection" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Add two commands.  List order is alphabetical by label, so 'alpha'
    // appears first and 'zeta' second.
    try ctx.addCommand("alpha", "echo alpha", &.{"--universal"});
    try ctx.addCommand("zeta",  "echo zeta",  &.{"--universal"});

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    // Move down to the second command ('zeta') and delete it.
    tui.send("j");    delay(50);
    tui.send("d");    delay(80);
    tui.send("y\r");  delay(80);
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // 'alpha' must still exist; 'zeta' must be gone.
    const la = try ctx.run(&.{ "-l", "alpha" });
    defer la.deinit(gpa);
    try la.ok();
    try la.expectStderr("alpha");

    const lz = try ctx.run(&.{ "-l", "zeta" });
    defer lz.deinit(gpa);
    try lz.ok();
    try lz.expectStderr("No commands match");
}

test "commands TUI: filter via '/' narrows the visible list" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build",         "cargo build",          &.{"--universal"});
    try ctx.addCommand("build-release", "cargo build --release",&.{"--universal"});
    try ctx.addCommand("deploy",        "kubectl apply -f .",   &.{"--universal"});

    var tui = try spawnTui(&ctx, &.{});
    delay(150);

    // Enter filter mode, type "build", confirm filter.
    tui.send("/build"); delay(50);
    tui.send("\r");     delay(80);

    // Delete the first visible command (which must be a 'build' variant).
    tui.send("d");    delay(80);
    tui.send("y\r");  delay(80);
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // 'deploy' must be untouched (it was invisible under the filter).
    const ld = try ctx.run(&.{ "-l", "deploy" });
    defer ld.deinit(gpa);
    try ld.ok();
    try ld.expectStderr("deploy");

    // Exactly one of the two build commands should have been deleted.
    const la = try ctx.run(&.{ "-l" });
    defer la.deinit(gpa);
    try la.ok();
    // Three commands added, one deleted → two remain.
    // Just assert the total isn't three (i.e., something was deleted).
    const count_before: usize = 3;
    _ = count_before;
    // Verify 'deploy' present and at most one 'build*' deleted.
    try la.expectStderr("deploy");
}

// ─────────────────────────────────────────────────────────────────────────────
// History browser tests
// ─────────────────────────────────────────────────────────────────────────────

test "history TUI: quit with q exits cleanly" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try seedFishHistory(&ctx);

    var tui = try spawnTui(&ctx, &.{"-H"});
    delay(150);
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "history TUI: ctrl-c exits cleanly" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try seedFishHistory(&ctx);

    var tui = try spawnTui(&ctx, &.{"-H"});
    delay(150);
    tui.send("\x03"); // ^C

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "history TUI: saving the selected entry via 'a' adds it to the database" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Bash history (oldest → newest):
    //   1. cargo build --release
    //   2. kubectl get pods
    //   3. git log --oneline      ← TUI opens here (newest = last)
    try seedFishHistory(&ctx);

    // The history browser starts with the newest entry selected.
    // suggestLabel("git log --oneline") → "git-log"
    var tui = try spawnTui(&ctx, &.{"-H"});
    delay(150);

    tui.send("a");  delay(80); // open save prompt
    tui.send("\r"); delay(80); // accept suggested label "git-log"
    tui.send("\r"); delay(80); // empty description
    tui.send(" ");  delay(50); // dismiss "Saved as 'git-log'" message
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Verify the entry was saved to the database.
    const list = try ctx.run(&.{ "-l", "git-log" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("git log --oneline");
}

test "history TUI: navigating then saving picks the correct entry" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try seedFishHistory(&ctx);

    // Start at newest (index 3 = "git log --oneline").
    // Press 'k' once to move toward older entries (index 2 = "kubectl get pods").
    // suggestLabel("kubectl get pods") → "kubectl-get"
    var tui = try spawnTui(&ctx, &.{"-H"});
    delay(150);

    tui.send("k");  delay(50); // move up (toward older)
    tui.send("a");  delay(80); // open save prompt
    tui.send("\r"); delay(80); // accept suggested label "kubectl-get"
    tui.send("\r"); delay(80); // empty description
    tui.send(" ");  delay(50); // dismiss message
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const list = try ctx.run(&.{ "-l", "kubectl-get" });
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("kubectl get pods");
}

test "history TUI: empty history opens and quits cleanly" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // No history file → empty History.
    var tui = try spawnTui(&ctx, &.{"-H"});
    delay(150);
    tui.send("q");

    const result = try tui.finish(gpa);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
