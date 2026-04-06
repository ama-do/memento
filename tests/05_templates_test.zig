/// Feature 05: Template Commands with Variable Placeholders
///
/// Tests that placeholder substitution works for positional and named
/// arguments, in single- and multi-placeholder commands, and that error cases
/// produce helpful messages.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;

// ── Fixtures ──────────────────────────────────────────────────────────────────

fn seedTemplates(ctx: *helper.TestCtx) !void {
    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});
    try ctx.addCommand("kgd", "kubectl get deployment {dep} -n {ns}", &.{"--universal"});
    try ctx.addCommand("sship", "ssh {user}@{host} -p {port}", &.{"--universal"});
    try ctx.addCommand("img", "docker build -t {name}:{tag} .", &.{"--universal"});
}

// ── Single placeholder ────────────────────────────────────────────────────────

test "single positional arg fills the placeholder" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgp", "my-namespace" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get pods --namespace my-namespace");
}

test "single named arg fills the placeholder" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgp", "--ns", "my-namespace" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get pods --namespace my-namespace");
}

// ── Multiple placeholders ─────────────────────────────────────────────────────

test "multiple positional args fill placeholders in order" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgd", "frontend", "production" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get deployment frontend -n production");
}

test "multiple named args fill placeholders by name" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgd", "--dep", "frontend", "--ns", "production" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get deployment frontend -n production");
}

test "named args can be provided in any order" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgd", "--ns", "staging", "--dep", "api" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get deployment api -n staging");
}

test "three positional args fill three placeholders in order" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "sship", "admin", "10.0.0.1", "22" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("ssh admin@10.0.0.1 -p 22");
}

test "two-placeholder template with positional args" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "img", "myapp", "latest" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("docker build -t myapp:latest .");
}

// ── Dry run ───────────────────────────────────────────────────────────────────

test "--dry-run shows the substituted command without producing eval output" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgp", "my-namespace", "--dry-run" });
    defer r.deinit(gpa);

    try r.ok();
    try std.testing.expectEqualStrings("", r.stdout);
    try r.expectStderr("Would run: kubectl get pods --namespace my-namespace");
}

// ── Adding templates ──────────────────────────────────────────────────────────

test "mm -a detects placeholders and reports them on add" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const r = try ctx.run(&.{ "-a", "deploy", "helm upgrade {release} {chart} -n {ns}" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("3"); // 3 placeholders detected
    try r.expectStderr("release");
    try r.expectStderr("chart");
    try r.expectStderr("ns");
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "too few positional args produces a missing-placeholder error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgd", "frontend" }); // kgd needs 2 args
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Missing argument for placeholder: ns");
    try r.expectStderr("kgd"); // usage hint
}

test "missing named arg produces a missing-placeholder error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgd", "--dep", "frontend" }); // --ns missing
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Missing argument for placeholder: ns");
}

test "too many positional args produces an error" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();
    try seedTemplates(&ctx);

    const r = try ctx.run(&.{ "kgp", "ns1", "extra-arg" }); // kgp only needs 1
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("Too many arguments");
}

test "placeholder names are case-sensitive" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("upper", "echo {Name}", &.{"--universal"});

    const r = try ctx.run(&.{ "upper", "--name", "hello" }); // wrong case
    defer r.deinit(gpa);

    try r.err();
    try r.expectStderr("name"); // should mention the wrong key
    try r.expectStderr("Name"); // and suggest the correct one
}

test "duplicate placeholder in template is filled once for all occurrences" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("dup", "echo {word} {word}", &.{"--universal"});

    const r = try ctx.run(&.{ "dup", "hello" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("echo hello hello");
}

test "placeholder value containing spaces is single-quoted in output" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});

    const r = try ctx.run(&.{ "kgp", "my namespace" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get pods --namespace 'my namespace'");
}

test "plain placeholder value without special chars is not quoted" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.addCommand("kgp", "kubectl get pods --namespace {ns}", &.{"--universal"});

    const r = try ctx.run(&.{ "kgp", "my-namespace" });
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStdoutEq("kubectl get pods --namespace my-namespace");
}
