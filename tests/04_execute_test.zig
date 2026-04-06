/// Feature 04: Execute a Saved Command
///
/// The mm binary does NOT run commands itself — it prints the resolved command
/// to stdout so the shell wrapper can eval it. These tests verify that the
/// binary outputs the right command string (and nothing else on stdout), that
/// human-readable output goes to stderr, and that error paths behave correctly.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Happy paths: stdout contains the command to eval ─────────────────────────

test "executing a universal command prints the command to stdout" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});

    const r = try ctx.runAs(&.{"build"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    // The shell wrapper evals stdout, so it must contain exactly the command.
    try r.expectStdoutEq("cargo build --release");
}

test "executing a command by numeric label works" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("1", "git status", &.{"--universal"});

    const r = try ctx.runAs(&.{"1"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("git status");
}

test "executing a fish-specific command in fish succeeds" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});

    const r = try ctx.runAs(&.{"fishfn"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("funcsave my_func");
}

test "executing a universal command works from any shell" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});

    // Run from zsh even though we added under default (fish) scope via --universal.
    const r = try ctx.runAs(&.{"build"}, "zsh");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("cargo build --release");
}

test "--dry-run prints the command to stderr without producing eval output" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});

    const r = try ctx.runAs(&.{ "build", "--dry-run" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    // Nothing must go to stdout (the shell would eval it).
    try std.testing.expectEqualStrings("", r.stdout);
    try r.expectStderr("Would run: cargo build --release");
}

// ── stderr cleanliness ────────────────────────────────────────────────────────

test "list output goes to stderr so eval path stays clean" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});

    const r = try ctx.run(&.{"-l"});
    defer r.deinit(gpa);

    try r.ok();
    try std.testing.expectEqualStrings("", r.stdout);
    try r.expectStderr("build");
}

// ── Error paths ───────────────────────────────────────────────────────────────

test "executing a non-existent label fails with a clear error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{"nonexistent"});
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("No command found with label 'nonexistent'");
    // stdout must be empty so the shell wrapper does not eval anything.
    try std.testing.expectEqualStrings("", r.stdout);
}

test "executing a fish command in zsh fails with a scope error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});

    const r = try ctx.runAs(&.{"fishfn"}, "zsh");
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("not available in zsh");
    try r.expectStderr("-l"); // suggest listing available commands
    try std.testing.expectEqualStrings("", r.stdout);
}

test "executing a fish command in bash fails with a scope error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});

    const r = try ctx.runAs(&.{"fishfn"}, "bash");
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("not available in bash");
}

test "executing a shell-incompatible command with --force succeeds and warns" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});

    const r = try ctx.runAs(&.{ "fishfn", "--force" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("funcsave my_func");
    try r.expectStderr("Warning");
    try r.expectStderr("fish");
}

test "template command without arguments fails with usage hint" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});

    const r = try ctx.run(&.{"kgp"});
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("ns");
    try std.testing.expectEqualStrings("", r.stdout);
}
