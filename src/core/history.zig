/// Shell history file parsing.
///
/// Entries are numbered 1 (oldest) … N (newest), matching the file order.
/// The display and --save index both use this 1-based numbering.
const std = @import("std");
const shell_mod = @import("shell.zig");

pub const Entry = struct {
    index: u32,
    command: []const u8, // slice into the History.buf
};

pub const History = struct {
    entries: []Entry,
    buf: []u8, // backing buffer that Entry.command slices point into
    gpa: std.mem.Allocator,

    pub fn deinit(self: *History) void {
        self.gpa.free(self.entries);
        self.gpa.free(self.buf);
    }

    pub fn get(self: *const History, index: u32) ?[]const u8 {
        if (index == 0 or index > self.entries.len) return null;
        return self.entries[index - 1].command;
    }

    pub fn last(self: *const History) ?[]const u8 {
        if (self.entries.len == 0) return null;
        return self.entries[self.entries.len - 1].command;
    }
};

/// Read shell history for `sh` from the HOME-relative history file.
/// Returns an empty History if the file does not exist.
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    sh: shell_mod.Shell,
    environ_map: *const std.process.Environ.Map,
    home: []const u8,
) !History {
    const path = try shell_mod.historyFilePath(gpa, sh, environ_map, home) orelse {
        return emptyHistory(gpa);
    };
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return emptyHistory(gpa),
        else => return e,
    };

    return switch (sh) {
        .bash, .zsh => parsePlain(gpa, content),
        .fish => parseFish(gpa, content),
        .powershell => parsePlain(gpa, content),
    };
}

fn emptyHistory(gpa: std.mem.Allocator) !History {
    return History{
        .entries = try gpa.alloc(Entry, 0),
        .buf = try gpa.dupe(u8, ""),
        .gpa = gpa,
    };
}

/// Parse a plain one-command-per-line history file (bash/zsh/powershell).
/// Takes ownership of `buf`; call History.deinit to release.
pub fn parsePlain(gpa: std.mem.Allocator, buf: []u8) !History {
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(gpa);

    var idx: u32 = 1;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try entries.append(gpa, .{ .index = idx, .command = trimmed });
        idx += 1;
    }

    return History{
        .entries = try entries.toOwnedSlice(gpa),
        .buf = buf,
        .gpa = gpa,
    };
}

/// Parse fish's YAML-ish history format:
///   - cmd: <command>
///     when: <timestamp>
/// Takes ownership of `buf`; call History.deinit to release.
pub fn parseFish(gpa: std.mem.Allocator, buf: []u8) !History {
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(gpa);

    var idx: u32 = 1;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "- cmd: ";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const cmd = trimmed[prefix.len..];
            if (cmd.len > 0) {
                try entries.append(gpa, .{ .index = idx, .command = cmd });
                idx += 1;
            }
        }
    }

    return History{
        .entries = try entries.toOwnedSlice(gpa),
        .buf = buf,
        .gpa = gpa,
    };
}

/// Filter entries whose command contains `term` (case-sensitive substring).
/// Returns a slice into `history.entries` — do not free it separately.
pub fn search(
    gpa: std.mem.Allocator,
    hist: *const History,
    term: []const u8,
) ![]Entry {
    var results = std.ArrayList(Entry).empty;
    errdefer results.deinit(gpa);
    for (hist.entries) |entry| {
        if (std.mem.containsAtLeast(u8, entry.command, 1, term)) {
            try results.append(gpa, entry);
        }
    }
    return results.toOwnedSlice(gpa);
}
