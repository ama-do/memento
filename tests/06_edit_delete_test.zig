/// Feature 06: Edit and Delete Saved Commands
///
/// Tests non-interactive edits (--command, --label, --scope, --description)
/// and deletes with and without confirmation, using both short and long flags.
///
/// Interactive editor tests (mm -e <label> with $EDITOR) are integration-level
/// and require a pseudo-TTY; those are noted as skipped stubs here.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Fixtures ──────────────────────────────────────────────────────────────────

fn seedDatabase(ctx: *helper.TestCtx) !void {
    try ctx.addCommand("build", "cargo build --release", &.{"--universal"});
    try ctx.addCommand("deploy", "kubectl apply -f k8s/", &.{"--universal"});
    try ctx.addCommand("fishfn", "funcsave my_func", &.{"--shell", "fish"});
    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});
}

// ── Edit: non-interactive ─────────────────────────────────────────────────────

test "mm -e --command replaces a command non-interactively (short flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-e", "build", "--command", "cargo build" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Updated: build → cargo build");

    // Verify the stored command changed.
    const exec = try ctx.runAs(&.{"build"}, "bash");
    defer exec.deinit(gpa);
    try exec.ok();
    try exec.expectStdoutEq("cargo build");
}

test "mm --edit --command replaces a command non-interactively (long flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "--edit", "build", "--command", "cargo build" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Updated: build → cargo build");
}

test "mm -e --label renames a command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-e", "build", "--label", "release-build" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Renamed: build → release-build");

    // Old label must no longer exist.
    const old = try ctx.runAs(&.{"build"}, "bash");
    defer old.deinit(gpa);
    try old.err();

    // New label must work.
    const new_r = try ctx.runAs(&.{"release-build"}, "bash");
    defer new_r.deinit(gpa);
    try new_r.ok();
    try new_r.expectStdoutEq("cargo build --release");
}

test "mm -e --scope changes the scope of a command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    // Make the fish-scoped command universal.
    const r = try ctx.run(&.{ "-e", "fishfn", "--scope", "universal" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("universal");

    // Should now be accessible from zsh.
    const exec = try ctx.runAs(&.{"fishfn"}, "zsh");
    defer exec.deinit(gpa);
    try exec.ok();
}

test "mm -e --description updates the description" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-e", "deploy", "--description", "Deploy all Kubernetes manifests" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Updated: deploy");
}

// ── Edit: error cases ─────────────────────────────────────────────────────────

test "mm -e fails for a non-existent label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-e", "nonexistent", "--command", "echo hi" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("No command found with label 'nonexistent'");
}

test "mm -e --label fails when target label already exists" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-e", "build", "--label", "deploy" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Label 'deploy' already exists");
    try r.expectStderr("--force");
}

test "mm -e --label --force overwrites the target label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-e", "build", "--label", "deploy", "--force" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Replaced: deploy");
}

// ── Delete ────────────────────────────────────────────────────────────────────

test "mm -d --yes deletes a command without prompting (short flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-d", "build", "--yes" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Deleted: build");

    // Label must no longer be accessible.
    const exec = try ctx.runAs(&.{"build"}, "bash");
    defer exec.deinit(gpa);
    try exec.err();
}

test "mm --delete --yes deletes a command (long flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "--delete", "build", "--yes" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Deleted: build");
}

test "mm -d deletes multiple labels at once" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-d", "build", "deploy", "--yes" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Deleted: build, deploy");
}

test "mm -d --all removes every command" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedDatabase(&ctx);

    const r = try ctx.run(&.{ "-d", "--all", "--yes" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Deleted all commands");

    // List should now report empty.
    const list = try ctx.run(&.{"-l"});
    defer list.deinit(gpa);
    try list.ok();
    try list.expectStderr("No commands saved yet");
}

// ── Delete: error cases ───────────────────────────────────────────────────────

test "mm -d fails for a non-existent label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-d", "nonexistent" });
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("No command found with label 'nonexistent'");
}

test "mm -d with no label given fails with usage hint" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{"-d"});
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Please provide a label to delete");
}
