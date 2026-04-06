/// Shared test utilities for mm integration tests.
///
/// Each test file creates a TestCtx for each test case. The context gives you
/// an isolated temp directory, a fake HOME, and convenience methods for
/// running mm and inspecting the file system.
const std = @import("std");

const io = std.testing.io;

// ── Public types ─────────────────────────────────────────────────────────────

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    /// Fails the test if the exit code does not match.
    pub fn expectExitCode(self: RunResult, expected: u8) !void {
        if (self.exit_code != expected) {
            std.debug.print(
                "\nexpected exit code {d}, got {d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ expected, self.exit_code, self.stdout, self.stderr },
            );
            return error.WrongExitCode;
        }
    }

    /// Fails the test if stderr does not contain the needle.
    pub fn expectStderr(self: RunResult, needle: []const u8) !void {
        if (!std.mem.containsAtLeast(u8, self.stderr, 1, needle)) {
            std.debug.print(
                "\nexpected stderr to contain: {s}\nactual stderr:\n{s}\n",
                .{ needle, self.stderr },
            );
            return error.StderrMismatch;
        }
    }

    /// Fails the test if stdout does not contain the needle.
    pub fn expectStdout(self: RunResult, needle: []const u8) !void {
        if (!std.mem.containsAtLeast(u8, self.stdout, 1, needle)) {
            std.debug.print(
                "\nexpected stdout to contain: {s}\nactual stdout:\n{s}\n",
                .{ needle, self.stdout },
            );
            return error.StdoutMismatch;
        }
    }

    /// Fails the test if stdout does not exactly equal expected.
    pub fn expectStdoutEq(self: RunResult, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, self.stdout);
    }

    pub fn ok(self: RunResult) !void {
        try self.expectExitCode(0);
    }

    pub fn err(self: RunResult) !void {
        if (self.exit_code == 0) {
            std.debug.print(
                "\nexpected non-zero exit code\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ self.stdout, self.stderr },
            );
            return error.ExpectedFailure;
        }
    }
};

/// An isolated test environment with its own temp directory, HOME, and database.
pub const TestCtx = struct {
    gpa: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    tmp_path: []u8, // absolute path to the temp dir root
    home_path: []u8, // absolute path to tmp/home  (used as HOME)
    mm_exe: []const u8, // path to the mm binary

    pub fn init(gpa: std.mem.Allocator, mm_exe: []const u8) !TestCtx {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        // Resolve the absolute path of the temp dir.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const tmp_path = try gpa.dupe(u8, buf[0..n]);
        errdefer gpa.free(tmp_path);

        // Create a subdirectory to use as HOME so we don't pollute the root.
        try tmp.dir.createDirPath(io, "home");
        const home_path = try std.fs.path.join(gpa, &.{ tmp_path, "home" });
        errdefer gpa.free(home_path);

        return .{
            .gpa = gpa,
            .tmp = tmp,
            .tmp_path = tmp_path,
            .home_path = home_path,
            .mm_exe = mm_exe,
        };
    }

    pub fn deinit(ctx: *TestCtx) void {
        ctx.gpa.free(ctx.tmp_path);
        ctx.gpa.free(ctx.home_path);
        ctx.tmp.cleanup();
    }

    // ── Running mm ────────────────────────────────────────────────────────

    /// Run mm with the given args, using fish as the detected shell.
    pub fn run(ctx: *TestCtx, args: []const []const u8) !RunResult {
        return ctx.runAs(args, "fish");
    }

    /// Run mm with the given args, using a specific shell name for SHELL env.
    pub fn runAs(ctx: *TestCtx, args: []const []const u8, shell_name: []const u8) !RunResult {
        const shell_path = try std.fmt.allocPrint(ctx.gpa, "/bin/{s}", .{shell_name});
        defer ctx.gpa.free(shell_path);

        var env = std.process.Environ.Map.init(ctx.gpa);
        defer env.deinit();
        try env.put("HOME", ctx.home_path);
        try env.put("XDG_DATA_HOME", ctx.tmp_path);
        try env.put("SHELL", shell_path);
        // Prevent any test from accidentally touching the real system.
        try env.put("PATH", "/usr/bin:/bin");

        var argv = try std.ArrayList([]const u8).initCapacity(ctx.gpa, args.len + 1);
        defer argv.deinit(ctx.gpa);
        try argv.append(ctx.gpa, ctx.mm_exe);
        try argv.appendSlice(ctx.gpa, args);

        const result = try std.process.run(ctx.gpa, io, .{
            .argv = argv.items,
            .environ_map = &env,
        });

        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            },
        };
    }

    // ── File system helpers ───────────────────────────────────────────────

    /// Write content to a path relative to HOME.
    pub fn writeHomeFile(ctx: *TestCtx, rel_path: []const u8, content: []const u8) !void {
        const full = try std.fs.path.join(ctx.gpa, &.{ "home", rel_path });
        defer ctx.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            ctx.tmp.dir.createDirPath(io, parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        try ctx.tmp.dir.writeFile(io, .{ .sub_path = full, .data = content });
    }

    /// Returns true if a path relative to HOME exists.
    pub fn homeFileExists(ctx: *TestCtx, rel_path: []const u8) !bool {
        const full = try std.fs.path.join(ctx.gpa, &.{ "home", rel_path });
        defer ctx.gpa.free(full);
        const f = ctx.tmp.dir.openFile(io, full, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        f.close(io);
        return true;
    }

    /// Read the contents of a file relative to HOME. Caller owns the result.
    pub fn readHomeFile(ctx: *TestCtx, rel_path: []const u8) ![]u8 {
        const full = try std.fs.path.join(ctx.gpa, &.{ "home", rel_path });
        defer ctx.gpa.free(full);
        return ctx.tmp.dir.readFileAlloc(io, full, ctx.gpa, .unlimited);
    }

    /// Seed the database by running `mm -a <label> <command> [extra_args...]`.
    /// Convenience wrapper so individual tests don't repeat add calls.
    pub fn addCommand(ctx: *TestCtx, label: []const u8, command: []const u8, extra: []const []const u8) !void {
        var args = try std.ArrayList([]const u8).initCapacity(ctx.gpa, 3 + extra.len);
        defer args.deinit(ctx.gpa);
        try args.appendSlice(ctx.gpa, &.{ "-a", label, command });
        try args.appendSlice(ctx.gpa, extra);
        const r = try ctx.run(args.items);
        defer r.deinit(ctx.gpa);
        try r.ok();
    }
};
