/// Feature 03: List Saved Commands
///
/// Tests that `mm -l` / `mm --list` shows the right subset of commands for
/// the current shell, supports filtering, and displays helpful empty-state
/// messages.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Seed the database used by most list tests.
fn seedDatabase(ctx: *helper.TestCtx) !void {
    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});
    try ctx.addCommand("1", "git status", &.{"--universal"});
    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});
    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});
    try ctx.addCommand("zshcomp", "autoload -Uz compinit", &.{"--shell", "zsh"});
    try ctx.addCommand("psdep", "Deploy-Module", &.{"--shell", "powershell"});
}

// ── Happy paths ───────────────────────────────────────────────────────────────

test "mm -l shows universal and current-shell commands (fish)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{"-l"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("build");
    try r.expectStderr("1");
    try r.expectStderr("kgp");
    try r.expectStderr("fishfn");
    // Other shell commands must NOT appear.
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "zshcomp"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "psdep"));
}

test "mm --list long flag works the same as -l" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{"--list"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("build");
}

test "mm -l shows universal and current-shell commands (zsh)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{"-l"}, "zsh");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("zshcomp");
    try r.expectStderr("build");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "fishfn"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "psdep"));
}

test "mm -l --all shows every command regardless of shell" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{ "-l", "--all" }, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("fishfn");
    try r.expectStderr("zshcomp");
    try r.expectStderr("psdep");
    try r.expectStderr("build");
}

test "mm -l <term> filters by label or command substring" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{ "-l", "kubectl" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("kgp");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "build"));
}

test "mm -l <label> shows full details of a single command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.runAs(&.{ "-l", "kgp" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("kubectl get pods --namespace {ns}");
    try r.expectStderr("ns"); // placeholder should be shown
}

test "mm -l --scope fish shows only fish-scoped commands" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-l", "--scope", "fish" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("fishfn");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "build")); // universal not shown
}

test "mm -l --scope universal shows only universal commands" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-l", "--scope", "universal" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("build");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "fishfn"));
}

test "mm -l --templates shows only template commands" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-l", "--templates" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("kgp");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "build")); // not a template
}

test "mm -l output is written to stderr (stdout is clean for eval)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{"-l"});
    defer r.deinit(gpa);

    try r.ok();
    // stdout must be empty — it is reserved for eval-able command output.
    try std.testing.expectEqualStrings("", r.stdout);
}

// ── Empty states ──────────────────────────────────────────────────────────────

test "mm -l shows helpful message when no commands are saved" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{"-l"});
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("No commands saved yet");
    try r.expectStderr("-a"); // should suggest how to add
}

test "mm -l <term> shows 'no match' when search has no results" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-l", "xyznonexistent" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("No commands match");
}
