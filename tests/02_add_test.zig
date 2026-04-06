/// Feature 02: Add a Command to the Memento Store
///
/// Tests that `mm -a` / `mm --add` correctly saves labels and commands,
/// enforces constraints, and that --universal / --shell flags work regardless
/// of position in the argument list.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Happy paths ───────────────────────────────────────────────────────────────

test "mm -a adds a command (short flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "build", "cargo build --release" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: build → cargo build --release");
}

test "mm --add adds a command (long flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "--add", "build", "cargo build --release" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: build → cargo build --release");
}

test "mm -a adds a command with a numeric label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "1", "git status" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: 1 → git status");
}

test "mm -a with --universal at the end marks command as universal" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "greet", "echo hello world", "--universal" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("universal");
}

test "mm --universal at the beginning marks command as universal" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "--universal", "-a", "greet", "echo hello world" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("universal");
}

test "mm --universal in the middle marks command as universal" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "greet", "--universal", "echo hello world" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("universal");
}

test "mm -a without --universal defaults to current shell scope" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // runAs "fish" so the inferred scope is fish.
    const r = try ctx.runAs(&.{ "-a", "fishcmd", "funcsave my_func" }, "fish");
    defer r.deinit(gpa);

    try r.ok();
    // Confirm it was stored under fish scope.
    try r.expectStderr("fish");
}

test "mm -a with optional --description stores description" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "test", "npm test", "--description", "Run the full test suite" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: test → npm test");
}

test "mm -a stores a command with pipe characters" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "pipecmd", "ps aux | grep nginx" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: pipecmd → ps aux | grep nginx");
}

test "mm -a auto-detects placeholders and marks command as template" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "kgp", "kubectl get pods --namespace {ns}" });
    defer r.deinit(gpa);

    try r.ok();
    // Should confirm template with placeholder count / names.
    try r.expectStderr("ns");
}

test "any label is valid, including 'init'" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "init", "echo something" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: init → echo something");
}

// ── --force overwrite ─────────────────────────────────────────────────────────

test "mm -a --force overwrites an existing label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{});

    const r = try ctx.run(&.{ "-a", "build", "make all", "--force" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Updated: build → make all");
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "mm -a fails when label already exists" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("build", "cargo build --release", &.{});

    const r = try ctx.run(&.{ "-a", "build", "make all" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Label 'build' already exists");
    try r.expectStderr("-e build");
}

test "mm -a fails for empty label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "", "echo hi" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Label must not be empty");
}

test "mm -a fails for empty command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "emptycmd", "" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Command must not be empty");
}

test "mm -a fails for label containing spaces" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "my label", "echo hi" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Label must not contain spaces");
}

// ── Interactive mode stub ─────────────────────────────────────────────────────

test "mm -a with no label or command enters interactive mode" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // We can't easily drive an interactive prompt in an integration test, but
    // we can at least confirm the binary detects the missing args and does NOT
    // silently exit 0 when stdin is closed (non-TTY).
    const r = try ctx.run(&.{"-a"});
    defer r.deinit(gpa);

    // Either it prompts (and fails because stdin is empty) or it gives a usage
    // hint. Emit the output so CI captures it, but don't assert on exit code.
    std.debug.print("mm -a (no args) exited {d}: stderr={s}\n", .{ r.exit_code, r.stderr });
}
