/// Fuzz tests for every user-input parsing surface.
///
/// Seed / regression run (fast, finishes):
///   zig build fuzz
///
/// Continuous fuzzing (runs until you Ctrl-C or a crash is found):
///   zig build fuzz -- --fuzz
///
/// Each test calls std.testing.fuzz which, in normal mode, runs the
/// function once per corpus entry and exits.  In fuzz mode it runs
/// indefinitely, mutating inputs to maximise coverage.
///
/// The fuzzer reports a failure only when the test function returns an
/// unexpected error or panics (safety check, out-of-bounds, etc.).
/// Expected parse errors (bad flag, missing label, etc.) are caught and
/// swallowed so they don't register as failures.
const std = @import("std");
const Smith = std.testing.Smith;

// Modules registered in build.zig so we can import source files that live
// outside this module's root directory (tests/).
const cli      = @import("cli");
const template = @import("template");
const hist_mod = @import("history");

// page_allocator keeps per-iteration overhead low; ASAN / Zig's safety
// checks catch out-of-bounds accesses without the GPA bookkeeping noise.
const alloc = std.heap.page_allocator;

// ── 1. CLI argument parser ────────────────────────────────────────────────────
//
// The fuzz bytes are split on NUL to form argument tokens, mirroring how a
// shell delivers argv.  Every mode flag and positional combination is reachable.

test "fuzz: cli.parse" {
    try std.testing.fuzz({}, fuzzCliParse, .{
        .corpus = &.{
            // seed: common invocations
            "-a\x00build\x00cargo build --release",
            "-l",
            "-l\x00build",
            "-e\x00build\x00--command\x00make",
            "-d\x00build\x00--yes",
            "--init",
            "--init\x00--shell\x00bash",
            "-H\x00--save\x001",
        },
    });
}

fn fuzzCliParse(_: void, smith: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    var it = std.mem.splitScalar(u8, input, 0);
    while (it.next()) |seg| try args.append(alloc, seg);

    const parsed = cli.parse(alloc, args.items) catch return;
    switch (parsed) {
        .execute => |e| alloc.free(e.extra_args),
        .add     => |a| if (a.command) |cmd| alloc.free(cmd),
        .delete  => |d| alloc.free(d.labels),
        else     => {},
    }
}

// ── 2. Template placeholder extraction ───────────────────────────────────────
//
// Arbitrary bytes used as a command string.  Invariant: every returned name
// is non-empty.

test "fuzz: template.extractPlaceholders" {
    try std.testing.fuzz({}, fuzzExtractPlaceholders, .{
        .corpus = &.{
            "kubectl get pods --namespace {ns}",
            "docker run -p {port}:{port} {image}",
            "{{unclosed",
            "{}",
            "{} {a} {a}",
            "",
        },
    });
}

fn fuzzExtractPlaceholders(_: void, smith: *Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    const names = template.extractPlaceholders(alloc, input) catch return;
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    for (names) |n| std.debug.assert(n.len > 0);
}

// ── 3. Template substitution ──────────────────────────────────────────────────
//
// Two independent fuzz regions: one for the template string, one for a
// user-supplied value (exercises the shell-quoting path).

test "fuzz: template.substitute" {
    try std.testing.fuzz({}, fuzzSubstitute, .{
        .corpus = &.{
            // template \x00 value_for_host \x00 value_for_port \x00 value_for_msg
            "ssh {host} -p {port}\x00localhost\x00 22 \x00hello",
            "echo {msg}\x00it's done",
            "{host}\x00a b c",
            "\x00\x00\x00",
        },
    });
}

fn fuzzSubstitute(_: void, smith: *Smith) anyerror!void {
    // Region 1: template string
    var tmpl_buf: [1024]u8 = undefined;
    const tmpl_len = smith.slice(&tmpl_buf);
    const tmpl = tmpl_buf[0..tmpl_len];

    // Region 2: value for "msg" (exercises shell-quoting with special chars)
    var val_buf: [256]u8 = undefined;
    const val_len = smith.slice(&val_buf);
    const val = val_buf[0..val_len];

    const placeholders: []const []const u8 = &.{ "host", "port", "msg" };
    const values:       []const []const u8 = &.{ "localhost", "8080", val };

    const out = template.substitute(alloc, tmpl, placeholders, values) catch return;
    defer alloc.free(out);
}

// ── 4. Template argument parsing ─────────────────────────────────────────────
//
// The extra_args slice that the execute path feeds into parseArgs.  Exercises
// both positional and --named argument paths.

test "fuzz: template.parseArgs" {
    try std.testing.fuzz({}, fuzzParseArgs, .{
        .corpus = &.{
            "staging",                        // positional
            "--ns\x00staging",               // named
            "--ns\x00staging\x00my-deploy",  // named + extra
            "a\x00b\x00c",                   // too many positionals
        },
    });
}

fn fuzzParseArgs(_: void, smith: *Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    const placeholders: []const []const u8 = &.{ "ns", "dep" };

    var extra = std.ArrayList([]const u8).empty;
    defer extra.deinit(alloc);
    var it = std.mem.splitScalar(u8, input, 0);
    while (it.next()) |seg| try extra.append(alloc, seg);

    var diag = template.ParseDiag{};
    const vals = template.parseArgs(alloc, placeholders, extra.items, &diag) catch return;
    defer alloc.free(vals);
}

// ── 5. CSV encode / decode roundtrip ─────────────────────────────────────────
//
// Invariant: decode produces no empty parts, and decode(encode(parts)) == parts.

test "fuzz: template CSV roundtrip" {
    try std.testing.fuzz({}, fuzzCsvRoundtrip, .{
        .corpus = &.{
            "ns,dep,image",
            "a",
            ",",
            ",,",
            "",
            "a,b,,c",
        },
    });
}

fn fuzzCsvRoundtrip(_: void, smith: *Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    const parts = template.decodeCsv(alloc, input) catch return;
    defer alloc.free(parts);
    for (parts) |p| std.debug.assert(p.len > 0);

    if (parts.len == 0) return;

    const encoded = (try template.encodeCsv(alloc, parts)) orelse return;
    defer alloc.free(encoded);

    const parts2 = template.decodeCsv(alloc, encoded) catch return;
    defer alloc.free(parts2);

    // Roundtrip invariant.
    std.debug.assert(parts.len == parts2.len);
    for (parts, parts2) |a, b| std.debug.assert(std.mem.eql(u8, a, b));
}

// ── 6. Shell history: plain format ───────────────────────────────────────────
//
// One command per line (bash / zsh / PowerShell).  Invariants: indices start
// at 1 and are strictly sequential; every entry has a non-empty command.

test "fuzz: history.parsePlain" {
    try std.testing.fuzz({}, fuzzParsePlain, .{
        .corpus = &.{
            "git log --oneline\ngit status\ngit diff\n",
            "cargo build --release\n",
            "\n\n\n",
            "",
            "a\r\nb\r\n",
        },
    });
}

fn fuzzParsePlain(_: void, smith: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);

    // parsePlain takes ownership; give it a heap copy.
    const owned = alloc.dupe(u8, buf[0..len]) catch return;
    var h = hist_mod.parsePlain(alloc, owned) catch {
        alloc.free(owned);
        return;
    };
    defer h.deinit();

    var expected: u32 = 1;
    for (h.entries) |e| {
        std.debug.assert(e.index == expected);
        std.debug.assert(e.command.len > 0);
        expected += 1;
    }
}

// ── 7. Shell history: fish YAML-ish format ───────────────────────────────────
//
// Entries look like "- cmd: <command>\n  when: <timestamp>\n".  We verify that
// every parsed entry has a non-empty command string.

test "fuzz: history.parseFish" {
    try std.testing.fuzz({}, fuzzParseFish, .{
        .corpus = &.{
            "- cmd: git log\n  when: 1700000001\n",
            "- cmd: cargo build --release\n  when: 1700000002\n- cmd: kubectl get pods\n  when: 1700000003\n",
            "not a fish history file",
            "",
            "- cmd: \n",
            "- cmd: a b c\n  when: 0\n",
        },
    });
}

fn fuzzParseFish(_: void, smith: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);

    const owned = alloc.dupe(u8, buf[0..len]) catch return;
    var h = hist_mod.parseFish(alloc, owned) catch {
        alloc.free(owned);
        return;
    };
    defer h.deinit();

    for (h.entries) |e| std.debug.assert(e.command.len > 0);
}
