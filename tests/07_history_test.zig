/// Feature 07: Shell History Integration
///
/// Tests that `mm -H` / `mm --history` reads and searches shell history,
/// and that `mm -H --save` imports commands into the store.
///
/// History files are synthetic — written into the temp HOME dir — so no real
/// shell history is touched during testing.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// Write a fake bash_history file with five known entries.
fn seedBashHistory(ctx: *helper.TestCtx) !void {
    const content =
        "cargo build --release\n" ++
        "kubectl get pods --namespace production\n" ++
        "git log --oneline --graph --all\n" ++
        "docker compose up -d\n" ++
        "ssh admin@10.0.0.1 -p 22\n";
    try ctx.writeHomeFile(".bash_history", content);
}

/// Write a fake fish history file (fish uses a YAML-like format).
fn seedFishHistory(ctx: *helper.TestCtx) !void {
    const content =
        "- cmd: cargo build --release\n  when: 1700000001\n" ++
        "- cmd: kubectl get pods --namespace production\n  when: 1700000002\n" ++
        "- cmd: git log --oneline --graph --all\n  when: 1700000003\n" ++
        "- cmd: docker compose up -d\n  when: 1700000004\n" ++
        "- cmd: ssh admin@10.0.0.1 -p 22\n  when: 1700000005\n";
    try ctx.writeHomeFile(".local/share/fish/fish_history", content);
}

// ── Browsing history ──────────────────────────────────────────────────────────

test "mm -H lists bash history entries with indices (short flag)" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{"-H"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("cargo build --release");
    try r.expectStderr("git log --oneline --graph --all");
    try r.expectStderr("ssh admin@10.0.0.1 -p 22");
}

test "mm --history long flag works the same as -H" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{"--history"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("cargo build --release");
}

test "mm -H reads fish history when shell is fish" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedFishHistory(&ctx);

    const r = try ctx.runAs(&.{"-H"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("cargo build --release");
}

test "mm -H --last 3 shows only the 3 most recent entries" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "--last", "3" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    // Only the last 3 should appear.
    try r.expectStderr("ssh admin@10.0.0.1 -p 22");
    try r.expectStderr("docker compose up -d");
    try r.expectStderr("git log --oneline --graph --all");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "cargo build --release"));
}

// ── Searching history ─────────────────────────────────────────────────────────

test "mm -H <term> filters history entries by substring" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "kubectl" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("kubectl get pods --namespace production");
    try std.testing.expect(!std.mem.containsAtLeast(u8, r.stderr, 1, "cargo build"));
}

test "mm -H <term> reports no-match message for unknown search" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "xyznonexistent" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("No history entries match");
}

// ── Saving history entries ────────────────────────────────────────────────────

test "mm -H --save <index> --label saves a history entry to the store" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    // Entry 3 is "git log --oneline --graph --all".
    const r = try ctx.runAs(&.{ "-H", "--save", "3", "--label", "gitlog" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: gitlog → git log --oneline --graph --all");

    // It should now be executable.
    const exec = try ctx.runAs(&.{"gitlog"}, "bash");
    defer exec.deinit(gpa);
    try exec.ok();
    try exec.expectStdoutEq("git log --oneline --graph --all");
}

test "mm -H --save --last --label saves the most recent history entry" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "--save", "--last", "--label", "sshprod" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Added: sshprod → ssh admin@10.0.0.1 -p 22");
}

test "mm -H kubectl --save 1 --label imports first search result" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "kubectl", "--save", "1", "--label", "kgp" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("kgp → kubectl get pods --namespace production");
}

test "mm -H --save --force overwrites existing label" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    try ctx.addCommand("gitlog", "git status", &.{"--universal"});

    const r = try ctx.runAs(&.{ "-H", "--save", "3", "--label", "gitlog", "--force" }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Updated: gitlog → git log --oneline --graph --all");
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "mm -H --save out-of-range index fails with clear error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    const r = try ctx.runAs(&.{ "-H", "--save", "999", "--label", "test" }, "bash");
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("No history entry at index 999");
}

test "mm -H --save fails when label already exists without --force" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedBashHistory(&ctx);

    try ctx.addCommand("gitlog", "git status", &.{"--universal"});

    const r = try ctx.runAs(&.{ "-H", "--save", "3", "--label", "gitlog" }, "bash");
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Label 'gitlog' already exists");
    try r.expectStderr("--force");
}

test "mm -H on an empty history file reports no entries" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.writeHomeFile(".bash_history", "");

    const r = try ctx.runAs(&.{"-H"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("No shell history found");
}
