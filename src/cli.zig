/// Argument parsing. Produces a tagged-union ParsedArgs from the raw arg slice.
///
/// Design: all flags can appear anywhere in the command line. The parser does
/// a two-pass scan — first to identify the mode flag, then to collect the
/// mode-specific flags and positionals. Unknown flags cause an error.
const std = @import("std");

// ── Result types ──────────────────────────────────────────────────────────────

pub const ParsedArgs = union(enum) {
    execute: ExecuteArgs,
    add: AddArgs,
    list: ListArgs,
    edit: EditArgs,
    delete: DeleteArgs,
    history: HistoryArgs,
    init: InitArgs,
    help,
    version,
};

pub const ExecuteArgs = struct {
    label: []const u8,
    /// Raw tokens after the label (template positional + named args).
    extra_args: []const []const u8,
    dry_run: bool = false,
    force: bool = false,
};

pub const AddArgs = struct {
    label: ?[]const u8 = null,
    command: ?[]const u8 = null,
    universal: bool = false,
    shell: ?[]const u8 = null,
    description: ?[]const u8 = null,
    force: bool = false,
};

pub const ListArgs = struct {
    search: ?[]const u8 = null,
    show_all: bool = false,
    scope: ?[]const u8 = null,
    templates_only: bool = false,
    no_truncate: bool = false,
};

pub const EditArgs = struct {
    label: []const u8,
    new_command: ?[]const u8 = null,
    new_label: ?[]const u8 = null,
    new_scope: ?[]const u8 = null,
    new_description: ?[]const u8 = null,
    force: bool = false,
};

pub const DeleteArgs = struct {
    labels: []const []const u8,
    yes: bool = false,
    all: bool = false,
};

pub const HistoryArgs = struct {
    search: ?[]const u8 = null,
    last_n: ?u32 = null,
    save_index: ?u32 = null,
    save_last: bool = false,
    label: ?[]const u8 = null,
    as_template: bool = false,
    force: bool = false,
    edit: bool = false,
};

pub const InitArgs = struct {
    shell: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    force: bool = false,
    verify: bool = false,
    explain: bool = false,
};

// ── Parser ────────────────────────────────────────────────────────────────────

pub fn parse(gpa: std.mem.Allocator, raw: []const []const u8) !ParsedArgs {
    if (raw.len == 0) return .help;

    // ── 1. Identify mode flag ────────────────────────────────────────────────
    var mode: enum { execute, add, list, edit, delete, history, init, help, version } = .execute;
    var mode_idx: ?usize = null;

    for (raw, 0..) |arg, i| {
        if (eql(arg, "-a") or eql(arg, "--add")) {
            mode = .add;
            mode_idx = i;
            break;
        }
        if (eql(arg, "-l") or eql(arg, "--list")) {
            mode = .list;
            mode_idx = i;
            break;
        }
        if (eql(arg, "-e") or eql(arg, "--edit")) {
            mode = .edit;
            mode_idx = i;
            break;
        }
        if (eql(arg, "-d") or eql(arg, "--delete")) {
            mode = .delete;
            mode_idx = i;
            break;
        }
        if (eql(arg, "-H") or eql(arg, "--history")) {
            mode = .history;
            mode_idx = i;
            break;
        }
        if (eql(arg, "-i") or eql(arg, "--init")) {
            mode = .init;
            mode_idx = i;
            break;
        }
        if (eql(arg, "--help") or eql(arg, "-h")) {
            mode = .help;
            mode_idx = i;
            break;
        }
        if (eql(arg, "--version") or eql(arg, "-v")) {
            mode = .version;
            mode_idx = i;
            break;
        }
    }

    // ── 2. Build the remaining args list (skip the mode flag token) ──────────
    var rest = std.ArrayList([]const u8).empty;
    defer rest.deinit(gpa);
    for (raw, 0..) |arg, i| {
        if (i == mode_idx) continue;
        try rest.append(gpa, arg);
    }
    const args = rest.items;

    // ── 3. Dispatch to mode-specific parsers ─────────────────────────────────
    return switch (mode) {
        .add => .{ .add = try parseAdd(gpa, args) },
        .list => .{ .list = parseList(args) },
        .edit => .{ .edit = try parseEdit(gpa, args) },
        .delete => .{ .delete = try parseDelete(gpa, args) },
        .history => .{ .history = try parseHistory(gpa, args) },
        .init => .{ .init = parseInit(args) },
        .help => .help,
        .version => .version,
        .execute => try parseExecute(gpa, args),
    };
}

// ── Mode parsers ──────────────────────────────────────────────────────────────

fn parseAdd(gpa: std.mem.Allocator, args: []const []const u8) !AddArgs {
    var result: AddArgs = .{};
    var positionals = std.ArrayList([]const u8).empty;
    defer positionals.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--universal") or eql(arg, "-u")) {
            result.universal = true;
        } else if (eql(arg, "--force") or eql(arg, "-f")) {
            result.force = true;
        } else if (eql(arg, "--shell")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.shell = args[i];
        } else if (eql(arg, "--description")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.description = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            try positionals.append(gpa, arg);
        }
    }

    if (positionals.items.len > 0) result.label = positionals.items[0];
    if (positionals.items.len > 1) {
        // Always heap-allocate so the caller can unconditionally free.
        result.command = try std.mem.join(gpa, " ", positionals.items[1..]);
    }
    return result;
}

fn parseList(args: []const []const u8) ListArgs {
    var result: ListArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--all") or eql(arg, "-A")) {
            result.show_all = true;
        } else if (eql(arg, "--templates") or eql(arg, "-t")) {
            result.templates_only = true;
        } else if (eql(arg, "--no-truncate")) {
            result.no_truncate = true;
        } else if (eql(arg, "--scope")) {
            i += 1;
            if (i < args.len) result.scope = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.search = arg;
        }
    }
    return result;
}

fn parseEdit(gpa: std.mem.Allocator, args: []const []const u8) !EditArgs {
    var label: ?[]const u8 = null;
    var result: EditArgs = .{ .label = "" };
    _ = gpa;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--command")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.new_command = args[i];
        } else if (eql(arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.new_label = args[i];
        } else if (eql(arg, "--scope")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.new_scope = args[i];
        } else if (eql(arg, "--description")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.new_description = args[i];
        } else if (eql(arg, "--force") or eql(arg, "-f")) {
            result.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (label == null) label = arg;
        }
    }

    result.label = label orelse return error.MissingLabel;
    return result;
}

fn parseDelete(gpa: std.mem.Allocator, args: []const []const u8) !DeleteArgs {
    var result: DeleteArgs = .{ .labels = &.{} };
    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--yes") or eql(arg, "-y")) {
            result.yes = true;
        } else if (eql(arg, "--all") or eql(arg, "-A")) {
            result.all = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try labels.append(gpa, arg);
        }
    }

    result.labels = try labels.toOwnedSlice(gpa);
    return result;
}

fn parseHistory(gpa: std.mem.Allocator, args: []const []const u8) !HistoryArgs {
    var result: HistoryArgs = .{};
    _ = gpa;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--save")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const next = args[i];
            if (eql(next, "--last")) {
                result.save_last = true;
            } else {
                result.save_index = std.fmt.parseInt(u32, next, 10) catch return error.InvalidIndex;
            }
        } else if (eql(arg, "--last")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.last_n = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidIndex;
        } else if (eql(arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            result.label = args[i];
        } else if (eql(arg, "--template")) {
            result.as_template = true;
        } else if (eql(arg, "--force") or eql(arg, "-f")) {
            result.force = true;
        } else if (eql(arg, "--edit") or eql(arg, "-e")) {
            result.edit = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.search = arg;
        }
    }

    return result;
}

fn parseInit(args: []const []const u8) InitArgs {
    var result: InitArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--force") or eql(arg, "-f")) {
            result.force = true;
        } else if (eql(arg, "--verify")) {
            result.verify = true;
        } else if (eql(arg, "--explain")) {
            result.explain = true;
        } else if (eql(arg, "--shell")) {
            i += 1;
            if (i < args.len) result.shell = args[i];
        } else if (eql(arg, "--config-file")) {
            i += 1;
            if (i < args.len) result.config_file = args[i];
        }
    }
    return result;
}

fn parseExecute(gpa: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return .help;

    // First non-flag arg is the label; everything after it goes to extra_args.
    // Global flags (--dry-run, --force) are extracted here; the rest are
    // passed raw to the template substitution layer.
    var dry_run = false;
    var force = false;
    var label: ?[]const u8 = null;
    var extra = std.ArrayList([]const u8).empty;
    defer extra.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--dry-run")) {
            dry_run = true;
        } else if (eql(arg, "--force") or eql(arg, "-f")) {
            force = true;
        } else if (label == null and !std.mem.startsWith(u8, arg, "-")) {
            label = arg;
        } else if (label != null) {
            try extra.append(gpa, arg);
        }
    }

    const lbl = label orelse return .help;
    return .{ .execute = .{
        .label = lbl,
        .extra_args = try extra.toOwnedSlice(gpa),
        .dry_run = dry_run,
        .force = force,
    } };
}

// ── Utilities ─────────────────────────────────────────────────────────────────

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
