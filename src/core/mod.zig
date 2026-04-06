/// Public API of the memento core library.
///
/// CLI and TUI layers import this module. No human-readable I/O is performed
/// here. All functions take typed inputs and return typed results; the caller
/// is responsible for presenting those results to the user.
///
/// std.Io is accepted only where genuine filesystem I/O is required (DB open,
/// history file reads). It is never used to print human-readable output.
const std = @import("std");

// ── Re-exported submodules ────────────────────────────────────────────────────
//
// Callers can reach the low-level APIs as core.db, core.shell, etc., or use
// the convenience aliases below.

pub const db = @import("db.zig");
pub const template = @import("template.zig");
pub const shell = @import("shell.zig");
pub const history = @import("history.zig");
pub const init_mod = @import("init.zig");

// ── Type aliases ──────────────────────────────────────────────────────────────

pub const Db = db.Db;
pub const Scope = db.Scope;
pub const Command = db.Command;
pub const ListFilter = db.ListFilter;
pub const Shell = shell.Shell;
pub const History = history.History;
pub const Entry = history.Entry;

// ── add ───────────────────────────────────────────────────────────────────────

pub const AddInput = struct {
    label: []const u8,
    command: []const u8,
    scope: Scope,
    description: ?[]const u8 = null,
    force: bool = false,
};

pub const AddResult = struct {
    was_updated: bool,
    /// Placeholder names extracted from the command.
    /// Caller owns: `for (r.placeholder_names) |n| gpa.free(n); gpa.free(r.placeholder_names);`
    placeholder_names: [][]u8,
};

/// Add (or force-update) a command in the database.
///
/// Errors:
///   error.LabelEmpty         — label is the empty string
///   error.LabelHasSpaces     — label contains a space
///   error.CommandEmpty       — command is the empty string
///   error.LabelExists        — label already taken and force=false
pub fn add(gpa: std.mem.Allocator, d: *Db, input: AddInput) !AddResult {
    if (input.label.len == 0) return error.LabelEmpty;
    if (std.mem.indexOfScalar(u8, input.label, ' ') != null) return error.LabelHasSpaces;
    if (input.command.len == 0) return error.CommandEmpty;

    const phs = try template.extractPlaceholders(gpa, input.command);
    errdefer {
        for (phs) |ph| gpa.free(ph);
        gpa.free(phs);
    }
    const phs_const = @as([]const []const u8, phs);
    const phs_csv = try template.encodeCsv(gpa, phs_const);
    defer if (phs_csv) |csv| gpa.free(csv);

    if (input.force and try d.labelExists(input.label)) {
        _ = try d.updateCommand(input.label, .{
            .command = input.command,
            .scope = input.scope,
            .description = input.description,
            .placeholders_csv = phs_csv,
            .update_template_flag = true,
        });
        return .{ .was_updated = true, .placeholder_names = phs };
    }

    _ = try d.addCommand(input.label, input.command, input.scope, input.description, phs_csv);
    return .{ .was_updated = false, .placeholder_names = phs };
}

// ── execute ───────────────────────────────────────────────────────────────────

pub const ExecuteInput = struct {
    label: []const u8,
    extra_args: []const []const u8,
    current_shell: ?Shell,
    force: bool = false,
};

pub const ScopeWarning = struct {
    command_scope: []const u8, // comptime constant from Scope.toStr()
    current_shell: []const u8, // comptime constant from Shell.toStr()
};

pub const ExecuteResult = struct {
    /// The final substituted command string. Caller owns; free with gpa.free().
    command: []u8,
    /// Non-null when --force overrode a scope mismatch.
    scope_warning: ?ScopeWarning = null,
};

/// Extra context populated on error; free with ExecuteDiag.deinit(gpa).
pub const ExecuteDiag = struct {
    /// Set on error.MissingPlaceholder. Gpa-owned copy.
    missing_placeholder: ?[]u8 = null,
    /// Set on error.TooManyArguments when an unknown --flag was given.
    /// Points into input.extra_args (not owned by this struct).
    unknown_flag: ?[]const u8 = null,
    /// Set alongside unknown_flag when a case-insensitive match was found.
    /// Gpa-owned copy.
    unknown_flag_suggestion: ?[]u8 = null,

    pub fn deinit(self: *ExecuteDiag, gpa: std.mem.Allocator) void {
        if (self.missing_placeholder) |p| gpa.free(p);
        if (self.unknown_flag_suggestion) |p| gpa.free(p);
        self.* = .{};
    }
};

/// Resolve a command label to a runnable string, substituting template
/// placeholders.
///
/// Errors:
///   error.CommandNotFound   — no command with that label
///   error.ScopeMismatch     — command scope incompatible with current shell and force=false
///   error.NotATemplate      — extra_args given but command has no placeholders
///   error.MissingPlaceholder — too few arguments; diag.missing_placeholder is set
///   error.TooManyArguments  — too many arguments; diag.unknown_flag may be set
pub fn execute(
    gpa: std.mem.Allocator,
    d: *Db,
    input: ExecuteInput,
    diag: *ExecuteDiag,
) !ExecuteResult {
    const cmd = try d.getCommand(input.label) orelse return error.CommandNotFound;
    defer cmd.deinit(gpa);

    var scope_warning: ?ScopeWarning = null;
    if (input.current_shell) |sh| {
        if (!shell.isCompatible(cmd.scope.toStr(), sh)) {
            if (!input.force) return error.ScopeMismatch;
            scope_warning = .{
                .command_scope = cmd.scope.toStr(),
                .current_shell = sh.toStr(),
            };
        }
    }

    if (!cmd.is_template) {
        if (input.extra_args.len > 0) return error.NotATemplate;
        return .{
            .command = try gpa.dupe(u8, cmd.command),
            .scope_warning = scope_warning,
        };
    }

    const phs_csv = cmd.placeholders orelse "";
    const placeholders = try template.decodeCsv(gpa, phs_csv);
    defer gpa.free(placeholders);

    if (input.extra_args.len == 0 and placeholders.len > 0) {
        diag.missing_placeholder = try gpa.dupe(u8, placeholders[0]);
        return error.MissingPlaceholder;
    }

    // parseArgs may set pd fields pointing into `placeholders`; we dupe them
    // before `placeholders` is freed by the deferred gpa.free above.
    var pd = template.ParseDiag{};
    const values = template.parseArgs(gpa, placeholders, input.extra_args, &pd) catch |err| {
        if (pd.missing_placeholder) |mp| diag.missing_placeholder = gpa.dupe(u8, mp) catch null;
        if (pd.unknown_flag_suggestion) |ufs| diag.unknown_flag_suggestion = gpa.dupe(u8, ufs) catch null;
        diag.unknown_flag = pd.unknown_flag; // points into extra_args — caller-owned, safe
        return err;
    };
    defer gpa.free(values);

    const final = try template.substitute(gpa, cmd.command, placeholders, values);
    return .{ .command = final, .scope_warning = scope_warning };
}

// ── edit ─────────────────────────────────────────────────────────────────────

pub const EditInput = struct {
    label: []const u8,
    new_command: ?[]const u8 = null,
    new_label: ?[]const u8 = null,
    new_scope: ?Scope = null,
    new_description: ?[]const u8 = null,
    force: bool = false,
};

pub const EditOutcome = enum {
    updated, // field(s) other than label were changed
    renamed, // label was renamed (no conflict)
    replaced, // label was force-renamed, overwriting an existing label
};

/// Edit a command's fields.
///
/// Errors:
///   error.CommandNotFound — no command with input.label
///   error.NoChanges       — no fields were specified
///   error.LabelExists     — new_label conflicts with an existing label and force=false
pub fn edit(gpa: std.mem.Allocator, d: *Db, input: EditInput) !EditOutcome {
    const existing = try d.getCommand(input.label) orelse return error.CommandNotFound;
    defer existing.deinit(gpa);

    const has_changes = input.new_command != null or input.new_label != null or
        input.new_scope != null or input.new_description != null;
    if (!has_changes) return error.NoChanges;

    if (input.new_label) |nl| {
        if (try d.labelExists(nl)) {
            if (!input.force) return error.LabelExists;
            _ = try d.deleteCommand(nl);
        }
    }

    var update = db.Db.UpdateFields{
        .command = input.new_command,
        .label = input.new_label,
        .scope = input.new_scope,
        .description = input.new_description,
    };

    if (input.new_command) |new_cmd| {
        const phs = try template.extractPlaceholders(gpa, new_cmd);
        defer {
            for (phs) |ph| gpa.free(ph);
            gpa.free(phs);
        }
        const phs_const = @as([]const []const u8, phs);
        update.placeholders_csv = try template.encodeCsv(gpa, phs_const);
        update.update_template_flag = true;
    }
    defer if (update.placeholders_csv) |p| gpa.free(p);

    _ = try d.updateCommand(input.label, update);

    if (input.new_label != null) {
        return if (input.force) .replaced else .renamed;
    }
    return .updated;
}

// ── delete ────────────────────────────────────────────────────────────────────

pub const DeleteInput = struct {
    labels: []const []const u8,
    all: bool = false,
};

pub const DeleteDiag = struct {
    /// Set on error.CommandNotFound: the first label that was not found.
    missing_label: ?[]const u8 = null,
};

/// Delete commands. Validates that all labels exist before deleting any.
///
/// Errors:
///   error.CommandNotFound — a label was not found; diag.missing_label is set
pub fn delete(gpa: std.mem.Allocator, d: *Db, input: DeleteInput, diag: *DeleteDiag) !void {
    _ = gpa;
    if (input.all) {
        try d.deleteAll();
        return;
    }
    for (input.labels) |label| {
        if (!try d.labelExists(label)) {
            diag.missing_label = label;
            return error.CommandNotFound;
        }
    }
    for (input.labels) |label| {
        _ = try d.deleteCommand(label);
    }
}

// ── history save ──────────────────────────────────────────────────────────────

pub const HistorySaveInput = struct {
    command: []const u8,
    label: []const u8,
    force: bool = false,
    description: ?[]const u8 = null,
};

pub const HistorySaveResult = enum { added, updated };

/// Save a history entry as a memento command (always universal scope,
/// non-template).
///
/// Errors:
///   error.LabelExists — label already taken and force=false
pub fn historySave(gpa: std.mem.Allocator, d: *Db, input: HistorySaveInput) !HistorySaveResult {
    _ = gpa;
    if (input.force and try d.labelExists(input.label)) {
        _ = try d.updateCommand(input.label, .{
            .command = input.command,
            .description = input.description,
        });
        return .updated;
    }
    _ = d.addCommand(input.label, input.command, .universal, input.description, null) catch |err| switch (err) {
        error.LabelExists => return error.LabelExists,
        else => return err,
    };
    return .added;
}
