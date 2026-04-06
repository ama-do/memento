/// SQLite-backed storage layer.
///
/// All SQL lives here. Nothing outside this file touches C pointers.
/// Every function that returns heap memory documents who owns it.
const std = @import("std");
const c = @import("../sqlite3.zig");

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Scope = enum {
    universal,
    bash,
    zsh,
    fish,
    powershell,

    pub fn fromStr(s: []const u8) ?Scope {
        if (std.mem.eql(u8, s, "universal")) return .universal;
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "powershell")) return .powershell;
        return null;
    }

    pub fn toStr(scope: Scope) []const u8 {
        return switch (scope) {
            .universal => "universal",
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .powershell => "powershell",
        };
    }
};

/// A command record. All string fields are owned by the caller and must be freed.
pub const Command = struct {
    id: i64,
    label: []u8,
    command: []u8,
    scope: Scope,
    description: ?[]u8,
    is_template: bool,
    /// Comma-separated placeholder names, e.g. "ns,dep". Null if not a template.
    placeholders: ?[]u8,

    pub fn deinit(self: Command, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        gpa.free(self.command);
        if (self.description) |d| gpa.free(d);
        if (self.placeholders) |p| gpa.free(p);
    }
};

pub const ListFilter = struct {
    /// Show only the current shell + universal (null = no shell filter, show all).
    current_shell: ?Scope = null,
    /// Override: show every scope regardless.
    show_all: bool = false,
    /// Filter to a specific scope (--scope X).
    scope: ?Scope = null,
    /// Show only template commands.
    templates_only: bool = false,
    /// Substring filter on label or command.
    search: ?[]const u8 = null,
};

// ── Database handle ───────────────────────────────────────────────────────────

pub const Db = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,

    const schema =
        \\CREATE TABLE IF NOT EXISTS commands (
        \\    id           INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    label        TEXT    NOT NULL UNIQUE,
        \\    command      TEXT    NOT NULL,
        \\    scope        TEXT    NOT NULL DEFAULT 'universal',
        \\    description  TEXT,
        \\    is_template  INTEGER NOT NULL DEFAULT 0,
        \\    placeholders TEXT,
        \\    created_at   INTEGER NOT NULL,
        \\    updated_at   INTEGER NOT NULL
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_commands_scope  ON commands(scope);
        \\CREATE INDEX IF NOT EXISTS idx_commands_label  ON commands(label);
    ;

    /// Open (or create) the database at `path`. Creates parent dirs as needed.
    /// Returns an initialised database with the schema applied.
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Db {
        // Ensure parent directory exists.
        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(io, parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }

        // SQLite requires a null-terminated path.
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);

        var db_ptr: *c.sqlite3 = undefined;
        const rc = c.sqlite3_open_v2(
            path_z,
            &db_ptr,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK) return error.DbOpenFailed;

        var self = Db{ .db = db_ptr, .gpa = gpa };
        try self.exec(schema);
        return self;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.db);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    fn exec(self: *Db, sql: [*:0]const u8) !void {
        const rc = c.sqlite3_exec(self.db, sql, null, null, null);
        if (rc != c.SQLITE_OK) return error.DbExecFailed;
    }

    fn prepare(self: *Db, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: *c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.DbPrepareFailed;
        return stmt;
    }

    fn bindText(stmt: *c.sqlite3_stmt, col: c_int, text: []const u8) !void {
        const rc = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.DbBindFailed;
    }

    fn bindTextZ(stmt: *c.sqlite3_stmt, col: c_int, text: ?[]const u8) !void {
        if (text) |t| {
            try bindText(stmt, col, t);
        } else {
            if (c.sqlite3_bind_null(stmt, col) != c.SQLITE_OK) return error.DbBindFailed;
        }
    }

    fn colText(self: *Db, stmt: *c.sqlite3_stmt, col: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(stmt, col) orelse return error.DbNullColumn;
        const s = std.mem.span(ptr);
        return self.gpa.dupe(u8, s);
    }

    fn colTextOpt(self: *Db, stmt: *c.sqlite3_stmt, col: c_int) !?[]u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        return @as(?[]u8, try self.colText(stmt, col));
    }

    extern fn time(t: ?*i64) i64;
    fn now() i64 {
        return time(null);
    }

    fn rowToCommand(self: *Db, stmt: *c.sqlite3_stmt) !Command {
        const scope_str = c.sqlite3_column_text(stmt, 3) orelse return error.DbNullColumn;
        const scope = Scope.fromStr(std.mem.span(scope_str)) orelse .universal;
        return Command{
            .id = c.sqlite3_column_int64(stmt, 0),
            .label = try self.colText(stmt, 1),
            .command = try self.colText(stmt, 2),
            .scope = scope,
            .description = try self.colTextOpt(stmt, 4),
            .is_template = c.sqlite3_column_int64(stmt, 5) != 0,
            .placeholders = try self.colTextOpt(stmt, 6),
        };
    }

    // ── CRUD ──────────────────────────────────────────────────────────────────

    /// Add a new command. Returns error.LabelExists if the label is already taken.
    /// `placeholders_csv` is a comma-separated list like "ns,dep", or null.
    pub fn addCommand(
        self: *Db,
        label: []const u8,
        command: []const u8,
        scope: Scope,
        description: ?[]const u8,
        placeholders_csv: ?[]const u8,
    ) !i64 {
        const is_template: i64 = if (placeholders_csv != null and placeholders_csv.?.len > 0) 1 else 0;
        const t = now();

        const stmt = try self.prepare(
            "INSERT INTO commands(label,command,scope,description,is_template,placeholders,created_at,updated_at)" ++
                " VALUES(?,?,?,?,?,?,?,?)",
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, label);
        try bindText(stmt, 2, command);
        try bindText(stmt, 3, scope.toStr());
        try bindTextZ(stmt, 4, description);
        if (c.sqlite3_bind_int64(stmt, 5, is_template) != c.SQLITE_OK) return error.DbBindFailed;
        try bindTextZ(stmt, 6, placeholders_csv);
        if (c.sqlite3_bind_int64(stmt, 7, t) != c.SQLITE_OK) return error.DbBindFailed;
        if (c.sqlite3_bind_int64(stmt, 8, t) != c.SQLITE_OK) return error.DbBindFailed;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return c.sqlite3_last_insert_rowid(self.db);
        // SQLITE_CONSTRAINT (19) means UNIQUE violation → label exists
        if (rc == 19) return error.LabelExists;
        return error.DbStepFailed;
    }

    /// Fetch a single command by label. Returns null if not found.
    /// Caller owns the returned Command (call cmd.deinit(gpa)).
    pub fn getCommand(self: *Db, label: []const u8) !?Command {
        const stmt = try self.prepare(
            "SELECT id,label,command,scope,description,is_template,placeholders FROM commands WHERE label=?",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, label);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.DbStepFailed;
        return try self.rowToCommand(stmt);
    }

    /// List commands matching the filter. Caller owns the returned slice and
    /// each Command in it (call cmd.deinit(gpa) for each, then gpa.free(slice)).
    pub fn listCommands(self: *Db, filter: ListFilter) ![]Command {
        var results = std.ArrayList(Command).empty;
        errdefer {
            for (results.items) |cmd| cmd.deinit(self.gpa);
            results.deinit(self.gpa);
        }

        const stmt = try self.prepare(
            "SELECT id,label,command,scope,description,is_template,placeholders FROM commands ORDER BY label ASC",
        );
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const cmd = try self.rowToCommand(stmt);
            errdefer cmd.deinit(self.gpa);

            if (!matchesFilter(cmd, filter)) {
                cmd.deinit(self.gpa);
                continue;
            }
            try results.append(self.gpa, cmd);
        }

        return results.toOwnedSlice(self.gpa);
    }

    fn matchesFilter(cmd: Command, filter: ListFilter) bool {
        if (!filter.show_all) {
            if (filter.scope) |s| {
                if (cmd.scope != s) return false;
            } else if (filter.current_shell) |sh| {
                if (cmd.scope != .universal and cmd.scope != sh) return false;
            }
        }
        if (filter.templates_only and !cmd.is_template) return false;
        if (filter.search) |term| {
            if (term.len == 0) return true;
            const in_label = std.mem.containsAtLeast(u8, cmd.label, 1, term);
            const in_cmd = std.mem.containsAtLeast(u8, cmd.command, 1, term);
            if (!in_label and !in_cmd) return false;
        }
        return true;
    }

    pub const UpdateFields = struct {
        command: ?[]const u8 = null,
        label: ?[]const u8 = null,
        scope: ?Scope = null,
        description: ?[]const u8 = null,
        clear_description: bool = false,
        placeholders_csv: ?[]const u8 = null,
        update_template_flag: bool = false,
    };

    /// Update a command by its current label. Returns false if label not found.
    pub fn updateCommand(self: *Db, current_label: []const u8, fields: UpdateFields) !bool {
        const existing = try self.getCommand(current_label) orelse return false;
        defer existing.deinit(self.gpa);

        const new_cmd = fields.command orelse existing.command;
        const new_label = fields.label orelse existing.label;
        const new_scope = fields.scope orelse existing.scope;
        const new_desc: ?[]const u8 = if (fields.clear_description) null else (fields.description orelse existing.description);
        const new_ph: ?[]const u8 = if (fields.update_template_flag) fields.placeholders_csv else existing.placeholders;
        const is_template: i64 = if (new_ph != null and new_ph.?.len > 0) 1 else 0;

        const stmt = try self.prepare(
            "UPDATE commands SET label=?,command=?,scope=?,description=?,is_template=?,placeholders=?,updated_at=? WHERE label=?",
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, new_label);
        try bindText(stmt, 2, new_cmd);
        try bindText(stmt, 3, new_scope.toStr());
        try bindTextZ(stmt, 4, new_desc);
        if (c.sqlite3_bind_int64(stmt, 5, is_template) != c.SQLITE_OK) return error.DbBindFailed;
        try bindTextZ(stmt, 6, new_ph);
        if (c.sqlite3_bind_int64(stmt, 7, now()) != c.SQLITE_OK) return error.DbBindFailed;
        try bindText(stmt, 8, current_label);

        const rc = c.sqlite3_step(stmt);
        if (rc == 19) return error.LabelExists;
        if (rc != c.SQLITE_DONE) return error.DbStepFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    /// Delete a command by label. Returns false if not found.
    pub fn deleteCommand(self: *Db, label: []const u8) !bool {
        const stmt = try self.prepare("DELETE FROM commands WHERE label=?");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, label);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStepFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    /// Delete all commands.
    pub fn deleteAll(self: *Db) !void {
        try self.exec("DELETE FROM commands");
    }

    /// Returns true if a command with the given label exists.
    pub fn labelExists(self: *Db, label: []const u8) !bool {
        const stmt = try self.prepare("SELECT 1 FROM commands WHERE label=? LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, label);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }
};
