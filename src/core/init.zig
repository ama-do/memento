/// mm --init: install the shell wrapper and initialise the database.
const std = @import("std");
const shell_mod = @import("shell.zig");
const Shell = shell_mod.Shell;

pub const InitResult = enum { installed, already_installed, reinstalled };

pub const Options = struct {
    shell: ?Shell,
    config_file: ?[]const u8,
    force: bool,
    verify: bool,
    explain: bool,
};

/// Install the shell wrapper for the detected (or forced) shell.
/// Returns what action was taken.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    opts: Options,
) !InitResult {
    const sh = opts.shell orelse shell_mod.detectShell(environ_map) orelse {
        return error.ShellNotDetected;
    };

    const home = environ_map.get("HOME") orelse return error.HomeNotSet;

    if (opts.verify) {
        try runVerify(io, gpa, sh, home);
        return .already_installed;
    }

    if (opts.explain) {
        runExplain(io, sh);
        return .already_installed;
    }

    if (sh == .fish) {
        return installFish(io, gpa, home, opts);
    } else {
        return installRcShell(io, gpa, sh, home, opts);
    }
}

// ── Fish ──────────────────────────────────────────────────────────────────────

fn installFish(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    opts: Options,
) !InitResult {
    const wrapper_path = if (opts.config_file) |cf|
        try gpa.dupe(u8, cf)
    else
        try std.fs.path.join(gpa, &.{ home, shell_mod.fish_wrapper_rel });
    defer gpa.free(wrapper_path);

    const cwd = std.Io.Dir.cwd();

    const exists = fileExists(io, cwd, wrapper_path);
    if (exists and !opts.force) {
        return .already_installed;
    }

    const parent = std.fs.path.dirname(wrapper_path) orelse return error.InvalidPath;
    cwd.createDirPath(io, parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const content = shell_mod.wrapperSnippet(.fish);
    try cwd.writeFile(io, .{ .sub_path = wrapper_path, .data = content });

    return if (exists) .reinstalled else .installed;
}

// ── bash / zsh / PowerShell ───────────────────────────────────────────────────

fn installRcShell(
    io: std.Io,
    gpa: std.mem.Allocator,
    sh: Shell,
    home: []const u8,
    opts: Options,
) !InitResult {
    const rc_path: []u8 = if (opts.config_file) |cf|
        try gpa.dupe(u8, cf)
    else
        try std.fs.path.join(gpa, &.{ home, shell_mod.rcFileRel(sh) });
    defer gpa.free(rc_path);

    const cwd = std.Io.Dir.cwd();

    const current = cwd.readFileAlloc(io, rc_path, gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
    defer gpa.free(current);

    const has_marker = std.mem.containsAtLeast(u8, current, 1, shell_mod.MARKER_BEGIN);
    if (has_marker and !opts.force) return .already_installed;

    var new_content: []u8 = undefined;
    if (has_marker) {
        new_content = try removeMarkerBlock(gpa, current);
        defer gpa.free(new_content);
        const appended = try appendSnippet(gpa, new_content, sh);
        defer gpa.free(appended);
        try cwd.writeFile(io, .{ .sub_path = rc_path, .data = appended });
    } else {
        const appended = try appendSnippet(gpa, current, sh);
        defer gpa.free(appended);
        try cwd.writeFile(io, .{ .sub_path = rc_path, .data = appended });
    }

    return if (has_marker) .reinstalled else .installed;
}

fn appendSnippet(gpa: std.mem.Allocator, base: []const u8, sh: Shell) ![]u8 {
    const snippet = shell_mod.wrapperSnippet(sh);
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, base);
    try buf.appendSlice(gpa, snippet);
    return buf.toOwnedSlice(gpa);
}

/// Remove the `# mm-memento-begin` … `# mm-memento-end` block from `content`.
fn removeMarkerBlock(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var skip = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, shell_mod.MARKER_BEGIN)) {
            skip = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, shell_mod.MARKER_END)) {
            skip = false;
            continue;
        }
        if (!skip) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── Verify / Explain ──────────────────────────────────────────────────────────

fn runVerify(io: std.Io, gpa: std.mem.Allocator, sh: Shell, home: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    if (sh == .fish) {
        const wrapper_path = try std.fs.path.join(gpa, &.{ home, shell_mod.fish_wrapper_rel });
        defer gpa.free(wrapper_path);
        const exists = fileExists(io, cwd, wrapper_path);
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        if (exists) {
            try w.interface.print("Shell wrapper is correctly initialized\n", .{});
            try w.interface.print("File: {s}\n", .{wrapper_path});
        } else {
            try w.interface.print("Shell wrapper not found at: {s}\n", .{wrapper_path});
            try w.interface.print("Run: mm --init\n", .{});
        }
        try w.flush();
        return;
    }

    const rc_rel = shell_mod.rcFileRel(sh);
    const rc_path = try std.fs.path.join(gpa, &.{ home, rc_rel });
    defer gpa.free(rc_path);

    const content = cwd.readFileAlloc(io, rc_path, gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Config file not found: {s}\n", .{rc_path}) catch "Config file not found\n";
            try std.Io.File.stderr().writeStreamingAll(io, msg);
            return;
        },
        else => return e,
    };
    defer gpa.free(content);

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    if (std.mem.containsAtLeast(u8, content, 1, shell_mod.MARKER_BEGIN)) {
        try w.interface.print("Shell wrapper is correctly initialized\n", .{});
        try w.interface.print("File: {s}\n", .{rc_path});
    } else {
        try w.interface.print("Wrapper found in {s} but not yet active\n", .{rc_path});
        try w.interface.print("Run: source {s}\n", .{rc_path});
    }
    try w.flush();
}

fn runExplain(io: std.Io, sh: Shell) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(
        \\mm uses a shell wrapper because a subprocess cannot modify its parent shell.
        \\The wrapper captures mm's stdout and passes it to eval, allowing cd, export,
        \\and other stateful commands to work correctly.
        \\
        \\Example wrapper for {s}:
        \\{s}
    , .{ sh.toStr(), shell_mod.wrapperSnippet(sh) }) catch {};
    w.flush() catch {};
}

// ── Utilities ─────────────────────────────────────────────────────────────────

fn fileExists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const f = dir.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}
