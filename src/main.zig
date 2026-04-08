/// mm — entry point and CLI dispatch.
///
/// This file is intentionally thin: it parses arguments, calls core functions,
/// and formats results for the user. No business logic lives here.
///
/// stdout: ONLY the eval-able command string (execute path).
/// stderr: ALL human-readable output (lists, errors, confirmations).
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const core = @import("core/mod.zig");

/// On non-POSIX targets (Windows) the TUI is not available.
/// A stub namespace provides the same function signatures and always returns null.
const tui = if (builtin.os.tag == .windows) struct {
    pub fn openCommands(
        io: std.Io,
        gpa: std.mem.Allocator,
        db: *core.Db,
        env: *const std.process.Environ.Map,
    ) !?[]u8 {
        _ = io; _ = gpa; _ = db; _ = env;
        return null;
    }
    pub fn openHistory(
        io: std.Io,
        gpa: std.mem.Allocator,
        db: *core.Db,
        env: *const std.process.Environ.Map,
    ) !?[]u8 {
        _ = io; _ = gpa; _ = db; _ = env;
        return null;
    }
} else @import("tui/mod.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| switch (err) {
        error.UserError => return 1,
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error: unknown\n";
            std.Io.File.stderr().writeStreamingAll(init.io, msg) catch {};
            return 1;
        },
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 0) argv[1..] else argv;
    const args_plain = @as([]const []const u8, @ptrCast(args));

    const parsed = cli.parse(gpa, args_plain) catch |err| {
        return printErr(io, "parse error: {s}\n", .{@errorName(err)});
    };

    const db_path = try resolveDbPath(gpa, init.environ_map);
    defer gpa.free(db_path);

    var db = core.Db.open(io, gpa, db_path) catch |err| {
        return printErr(io, "error: could not open database: {s}\n", .{@errorName(err)});
    };
    defer db.close();

    switch (parsed) {
        .add => |a| {
            defer if (a.command) |cmd| gpa.free(cmd);
            try handleAdd(io, gpa, &db, init.environ_map, a);
        },
        .list => |l| try handleList(io, gpa, &db, init.environ_map, l),
        .execute => |e| {
            defer gpa.free(e.extra_args);
            try handleExecute(io, gpa, &db, init.environ_map, e);
        },
        .edit => |e| try handleEdit(io, gpa, &db, init.environ_map, e),
        .delete => |d| {
            defer gpa.free(d.labels);
            try handleDelete(io, gpa, &db, init, d);
        },
        .history => |h| try handleHistory(io, gpa, &db, init, h),
        .init => |i| try handleInit(io, gpa, init.environ_map, i),
        .help => {
            // Only open the TUI when invoked with no arguments on a TTY.
            // Explicit --help / -h always prints the help text.
            if (args_plain.len == 0 and (std.Io.File.stderr().isTty(io) catch false)) {
                if (try tui.openCommands(io, gpa, &db, init.environ_map)) |cmd| {
                    defer gpa.free(cmd);
                    try std.Io.File.stdout().writeStreamingAll(io, cmd);
                }
            } else {
                printHelp(io);
            }
        },
        .version => printVersion(io),
    }
}

// ── Database path ─────────────────────────────────────────────────────────────

const build_options = @import("build_options");

fn resolveDbPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    // MM_DB lets developers point at an isolated database without touching the
    // production store.  The check is compiled out entirely in release builds.
    if (comptime build_options.enable_mm_db_override) {
        if (env.get("MM_DB")) |p| return gpa.dupe(u8, p);
    }
    if (builtin.os.tag == .windows) {
        if (env.get("APPDATA")) |appdata| {
            return std.fs.path.join(gpa, &.{ appdata, "memento", "db.sqlite" });
        }
        if (env.get("USERPROFILE")) |profile| {
            return std.fs.path.join(gpa, &.{ profile, "AppData", "Roaming", "memento", "db.sqlite" });
        }
    } else {
        if (env.get("XDG_DATA_HOME")) |xdg| {
            return std.fs.path.join(gpa, &.{ xdg, "memento", "db.sqlite" });
        }
        if (env.get("HOME")) |home| {
            return std.fs.path.join(gpa, &.{ home, ".local", "share", "memento", "db.sqlite" });
        }
    }
    return gpa.dupe(u8, "mm.db.sqlite");
}

// ── add ───────────────────────────────────────────────────────────────────────

fn handleAdd(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    a: cli.AddArgs,
) !void {
    const label = a.label orelse return printErr(io, "error: label required\nUsage: mm -a <label> <command>\n", .{});
    const command = a.command orelse return printErr(io, "error: command required\nUsage: mm -a <label> <command>\n", .{});

    // Determine scope from flags / detected shell.
    const scope: core.Scope = blk: {
        if (a.universal) break :blk .universal;
        if (a.shell) |s| break :blk core.Scope.fromStr(s) orelse {
            return printErr(io, "error: unknown shell '{s}'\n", .{s});
        };
        const sh = core.shell.detectShell(env);
        break :blk if (sh) |s| core.Scope.fromStr(s.toStr()).? else .universal;
    };

    const result = core.add(gpa, db, .{
        .label = label,
        .command = command,
        .scope = scope,
        .description = a.description,
        .force = a.force,
    }) catch |err| switch (err) {
        error.LabelEmpty => return printErr(io, "error: Label must not be empty\n", .{}),
        error.LabelHasSpaces => return printErr(io, "error: Label must not contain spaces\n", .{}),
        error.CommandEmpty => return printErr(io, "error: Command must not be empty\n", .{}),
        error.LabelExists => return printErr(io, "error: Label '{s}' already exists. Use 'mm -e {s}' or --force\n", .{ label, label }),
        else => return err,
    };
    defer {
        for (result.placeholder_names) |n| gpa.free(n);
        gpa.free(result.placeholder_names);
    }

    const verb: []const u8 = if (result.was_updated) "Updated" else "Added";

    if (result.placeholder_names.len > 0) {
        var csv_str: []u8 = try gpa.alloc(u8, 0);
        defer gpa.free(csv_str);
        for (result.placeholder_names, 0..) |ph, i| {
            const sep: []const u8 = if (i > 0) ", " else "";
            const new = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ csv_str, sep, ph });
            gpa.free(csv_str);
            csv_str = new;
        }
        printInfo(io, "{s}: {s} → {s} [{s}] (template with {d} placeholder(s): {s})\n", .{
            verb, label, command, scope.toStr(), result.placeholder_names.len, csv_str,
        });
    } else {
        printInfo(io, "{s}: {s} → {s} [{s}]\n", .{ verb, label, command, scope.toStr() });
    }
}

// ── list ──────────────────────────────────────────────────────────────────────

fn handleList(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    l: cli.ListArgs,
) !void {
    const current_shell = core.shell.detectShell(env);
    const filter = core.ListFilter{
        .current_shell = if (current_shell) |s| core.Scope.fromStr(s.toStr()) else null,
        .show_all = l.show_all,
        .scope = if (l.scope) |s| core.Scope.fromStr(s) else null,
        .templates_only = l.templates_only,
        .search = l.search,
    };

    const commands = try db.listCommands(filter);
    defer {
        for (commands) |cmd| cmd.deinit(gpa);
        gpa.free(commands);
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);

    if (commands.len == 0) {
        if (l.search != null) {
            try w.interface.print("No commands match\n", .{});
        } else {
            try w.interface.print("No commands saved yet. Use mm -a to get started.\n", .{});
        }
        try w.flush();
        return;
    }

    // Single exact-label lookup: show detailed view.
    if (l.search != null and commands.len == 1 and
        std.mem.eql(u8, commands[0].label, l.search.?))
    {
        const cmd = commands[0];
        try w.interface.print("Label:   {s}\n", .{cmd.label});
        try w.interface.print("Command: {s}\n", .{cmd.command});
        try w.interface.print("Scope:   {s}\n", .{cmd.scope.toStr()});
        if (cmd.description) |d| try w.interface.print("Desc:    {s}\n", .{d});
        if (cmd.placeholders) |p| try w.interface.print("Placeholders: {s}\n", .{p});
        try w.flush();
        return;
    }

    // Tabular list.
    const truncate_len: usize = if (l.no_truncate) std.math.maxInt(usize) else 60;
    for (commands) |cmd| {
        const marker: []const u8 = if (cmd.is_template) " {}" else "   ";
        const display_cmd = if (cmd.command.len > truncate_len)
            cmd.command[0..truncate_len]
        else
            cmd.command;
        const ellipsis: []const u8 = if (cmd.command.len > truncate_len) "…" else "";
        try w.interface.print("{s:<16}{s}{s}{s}  [{s}]\n", .{
            cmd.label, marker, display_cmd, ellipsis, cmd.scope.toStr(),
        });
    }
    try w.flush();
}

// ── execute ───────────────────────────────────────────────────────────────────

fn handleExecute(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    e: cli.ExecuteArgs,
) !void {
    const current_shell = core.shell.detectShell(env);

    var diag = core.ExecuteDiag{};
    defer diag.deinit(gpa);

    const result = core.execute(gpa, db, .{
        .label = e.label,
        .extra_args = e.extra_args,
        .current_shell = current_shell,
        .force = e.force,
    }, &diag) catch |err| switch (err) {
        error.CommandNotFound => return printErr(io, "error: No command found with label '{s}'\n", .{e.label}),
        error.ScopeMismatch => return printErr(io, "error: Command '{s}' is not available in {s}. Use mm -l to see available commands.\n", .{
            e.label, if (current_shell) |sh| sh.toStr() else "current shell",
        }),
        error.NotATemplate => return printErr(io, "error: '{s}' is not a template command\n", .{e.label}),
        error.TooManyArguments => {
            if (diag.unknown_flag) |flag| {
                if (diag.unknown_flag_suggestion) |sug| {
                    return printErr(io, "error: Unknown argument '--{s}'; placeholder is '{{{s}}}' (argument names are case-sensitive)\n", .{ flag, sug });
                }
                return printErr(io, "error: Unknown argument '--{s}'\n", .{flag});
            }
            return printErr(io, "error: Too many arguments\n", .{});
        },
        error.MissingPlaceholder => {
            const missing = diag.missing_placeholder orelse "";
            return printErr(io, "error: Missing argument for placeholder: {s}\nUsage: mm {s} <{s}>\n", .{ missing, e.label, missing });
        },
        else => return err,
    };
    defer gpa.free(result.command);

    if (result.scope_warning) |sw| {
        printInfo(io, "Warning: running a {s}-scoped command in {s}\n", .{ sw.command_scope, sw.current_shell });
    }

    if (e.dry_run) {
        printInfo(io, "Would run: {s}\n", .{result.command});
        return;
    }

    try std.Io.File.stdout().writeStreamingAll(io, result.command);
}

// ── edit ──────────────────────────────────────────────────────────────────────

fn handleEdit(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    e: cli.EditArgs,
) !void {
    // No modification flags → interactive editor mode.
    const has_flags = e.new_command != null or e.new_label != null or
        e.new_scope != null or e.new_description != null;
    if (!has_flags) {
        const existing = (try db.getCommand(e.label)) orelse
            return printErr(io, "error: No command found with label '{s}'\n", .{e.label});
        defer existing.deinit(gpa);
        try spawnEditorEdit(io, gpa, db, env, e.label, existing.command);
        return;
    }

    // Validate new scope string before calling core (core takes ?Scope, not ?[]const u8).
    var new_scope: ?core.Scope = null;
    if (e.new_scope) |s| {
        new_scope = core.Scope.fromStr(s) orelse {
            return printErr(io, "error: unknown scope '{s}'\n", .{s});
        };
    }

    const outcome = core.edit(gpa, db, .{
        .label = e.label,
        .new_command = e.new_command,
        .new_label = e.new_label,
        .new_scope = new_scope,
        .new_description = e.new_description,
        .force = e.force,
    }) catch |err| switch (err) {
        error.CommandNotFound => return printErr(io, "error: No command found with label '{s}'\n", .{e.label}),
        error.NoChanges => return printErr(io, "error: no changes specified. Use --command, --label, --scope, or --description\n", .{}),
        error.LabelExists => return printErr(io, "error: Label '{s}' already exists. Use --force to overwrite\n", .{e.new_label.?}),
        else => return err,
    };

    switch (outcome) {
        .renamed => printInfo(io, "Renamed: {s} → {s}\n", .{ e.label, e.new_label.? }),
        .replaced => printInfo(io, "Replaced: {s}\n", .{e.new_label.?}),
        .updated => {
            const updated = try db.getCommand(e.new_label orelse e.label) orelse return;
            defer updated.deinit(gpa);
            printInfo(io, "Updated: {s} → {s} [{s}]\n", .{ e.label, updated.command, updated.scope.toStr() });
        },
    }
}

/// Return a temp file path unique to this process.  Caller owns the result.
fn tmpFilePath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, stem: []const u8) ![]u8 {
    const pid: u32 = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.c.getpid());
    const tmp_dir = if (builtin.os.tag == .windows)
        env.get("TEMP") orelse env.get("TMP") orelse "C:\\Windows\\Temp"
    else
        "/tmp";
    return std.fmt.allocPrint(gpa, "{s}" ++ std.fs.path.sep_str ++ "mm_{s}_{d}", .{ tmp_dir, stem, pid });
}

/// Open $EDITOR (fallback: vi) with the command in a temp file, then save if changed.
fn spawnEditorEdit(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    label: []const u8,
    current_cmd: []const u8,
) !void {
    const editor = env.get("EDITOR") orelse "vi";

    const tmp_path = try tmpFilePath(gpa, env, "edit");
    defer gpa.free(tmp_path);

    // Write current command to temp file.
    {
        const f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, current_cmd);
        try f.writeStreamingAll(io, "\n");
    }
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Spawn editor and wait.
    var child = try std.process.spawn(io, .{ .argv = &.{ editor, tmp_path } });
    _ = try child.wait(io);

    // Read back.
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, tmp_path, gpa, .unlimited) catch {
        printInfo(io, "No changes made\n", .{});
        return;
    };
    defer gpa.free(content);

    const new_cmd = std.mem.trimEnd(u8, content, "\n\r \t");
    if (new_cmd.len == 0 or std.mem.eql(u8, new_cmd, current_cmd)) {
        printInfo(io, "No changes made\n", .{});
        return;
    }

    _ = core.edit(gpa, db, .{
        .label = label,
        .new_command = new_cmd,
    }) catch |err| switch (err) {
        error.CommandNotFound => return printErr(io, "error: No command found with label '{s}'\n", .{label}),
        error.NoChanges => { printInfo(io, "No changes made\n", .{}); return; },
        else => return err,
    };
    printInfo(io, "Updated: {s}\n", .{label});
}

// ── delete ────────────────────────────────────────────────────────────────────

fn handleDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    init: std.process.Init,
    d: cli.DeleteArgs,
) !void {
    if (d.all) {
        if (!d.yes) {
            const ans = try prompt(io, init, "Delete ALL commands? This cannot be undone. [y/N] ");
            if (!isYes(ans)) return printErr(io, "Cancelled\n", .{});
        }
        var del_diag = core.DeleteDiag{};
        try core.delete(gpa, db, .{ .all = true, .labels = &.{} }, &del_diag);
        printInfo(io, "Deleted all commands\n", .{});
        return;
    }

    if (d.labels.len == 0) {
        return printErr(io, "error: Please provide a label to delete\nUsage: mm -d <label> [--yes]\n", .{});
    }

    // Validate existence first (before any prompt or deletion).
    for (d.labels) |label| {
        if (!try db.labelExists(label)) {
            return printErr(io, "error: No command found with label '{s}'\n", .{label});
        }
    }

    // Prompt for confirmation.
    if (!d.yes) {
        if (d.labels.len == 1) {
            const cmd = (try db.getCommand(d.labels[0])).?;
            defer cmd.deinit(gpa);
            var msg_buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "Delete '{s}: {s}'? [y/N] ", .{ cmd.label, cmd.command });
            const ans = try prompt(io, init, msg);
            if (!isYes(ans)) return printErr(io, "Cancelled\n", .{});
        } else {
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Delete {d} commands? [y/N] ", .{d.labels.len}) catch "Delete? [y/N] ";
            const ans = try prompt(io, init, msg);
            if (!isYes(ans)) return printErr(io, "Cancelled\n", .{});
        }
    }

    // Perform deletion.
    var del_diag = core.DeleteDiag{};
    core.delete(gpa, db, .{ .labels = d.labels }, &del_diag) catch |err| switch (err) {
        error.CommandNotFound => return printErr(io, "error: No command found with label '{s}'\n", .{del_diag.missing_label orelse "?"}),
        else => return err,
    };

    if (d.labels.len == 1) {
        printInfo(io, "Deleted: {s}\n", .{d.labels[0]});
    } else {
        var buf: [512]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("Deleted: ", .{});
        for (d.labels, 0..) |l, i| {
            if (i > 0) try w.interface.print(", ", .{});
            try w.interface.print("{s}", .{l});
        }
        try w.interface.print("\n", .{});
        try w.flush();
    }
}

// ── history ───────────────────────────────────────────────────────────────────

fn handleHistory(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    init: std.process.Init,
    h: cli.HistoryArgs,
) !void {
    const env = init.environ_map;

    // No action flags + TTY → open the history TUI.
    const no_action = h.save_index == null and !h.save_last and h.search == null and h.last_n == null;
    if (no_action and (std.Io.File.stderr().isTty(io) catch false)) {
        if (try tui.openHistory(io, gpa, db, env)) |cmd| {
            defer gpa.free(cmd);
            try std.Io.File.stdout().writeStreamingAll(io, cmd);
        }
        return;
    }

    const sh = core.shell.detectShell(env) orelse {
        return printErr(io, "error: Could not detect current shell\n", .{});
    };
    const home = env.get("HOME")
        orelse env.get("USERPROFILE") // Windows fallback
        orelse return printErr(io, "error: HOME not set\n", .{});

    var hist = try core.history.read(io, gpa, sh, env, home);
    defer hist.deinit();

    // ── save path ─────────────────────────────────────────────────────────────
    if (h.save_index != null or h.save_last) {
        const entry_cmd: []const u8 = blk: {
            if (h.save_last) {
                break :blk hist.last() orelse return printErr(io, "error: No shell history found\n", .{});
            }
            const idx = h.save_index.?;
            break :blk hist.get(idx) orelse return printErr(io, "error: No history entry at index {d}\n", .{idx});
        };

        // When search is active, index refers to result position.
        var search_results_buf: ?[]core.Entry = null;
        defer if (search_results_buf) |sr| gpa.free(sr);
        const base_cmd: []const u8 = if (h.search != null) blk: {
            search_results_buf = try core.history.search(gpa, &hist, h.search.?);
            const results = search_results_buf.?;
            const idx = (h.save_index orelse 1);
            if (idx == 0 or idx > results.len)
                return printErr(io, "error: No history entry at index {d}\n", .{idx});
            break :blk results[idx - 1].command;
        } else entry_cmd;

        // --edit or --template: open $EDITOR so user can modify / add {} placeholders.
        var edited_buf: ?[]u8 = null;
        defer if (edited_buf) |b| gpa.free(b);
        const final_cmd: []const u8 = if (h.edit or h.as_template) blk: {
            const editor = env.get("EDITOR") orelse "vi";
            const tmp_path = try tmpFilePath(gpa, env, "hist");
            defer gpa.free(tmp_path);
            {
                const f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, base_cmd);
                try f.writeStreamingAll(io, "\n");
            }
            defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
            var child = try std.process.spawn(io, .{ .argv = &.{ editor, tmp_path } });
            _ = try child.wait(io);
            const content = std.Io.Dir.readFileAlloc(.cwd(), io, tmp_path, gpa, .unlimited) catch break :blk base_cmd;
            const trimmed = std.mem.trimEnd(u8, content, "\n\r \t");
            if (trimmed.len == 0) {
                gpa.free(content);
                break :blk base_cmd;
            }
            // Keep the trimmed version, free the rest.
            const trimmed_owned = try gpa.dupe(u8, trimmed);
            gpa.free(content);
            edited_buf = trimmed_owned;
            break :blk trimmed_owned;
        } else base_cmd;

        // Prompt for label if not given.
        var prompted_label_buf: ?[]u8 = null;
        defer if (prompted_label_buf) |b| gpa.free(b);
        const label: []const u8 = if (h.label) |l| l else blk: {
            var msg_buf: [128]u8 = undefined;
            const display = final_cmd[0..@min(final_cmd.len, 40)];
            const msg = std.fmt.bufPrint(&msg_buf, "Label for '{s}': ", .{display}) catch "Label: ";
            const input = try prompt(io, init, msg);
            if (input.len == 0) return printErr(io, "error: Label required\n", .{});
            const owned = try gpa.dupe(u8, input);
            prompted_label_buf = owned;
            break :blk owned;
        };

        const save_result = core.historySave(gpa, db, .{
            .command = final_cmd,
            .label = label,
            .force = h.force,
        }) catch |err| switch (err) {
            error.LabelExists => return printErr(io, "error: Label '{s}' already exists. Use --force to overwrite.\n", .{label}),
            else => return err,
        };

        switch (save_result) {
            .added => printInfo(io, "Added: {s} → {s}\n", .{ label, final_cmd }),
            .updated => printInfo(io, "Updated: {s} → {s}\n", .{ label, final_cmd }),
        }
        return;
    }

    // ── browse / search path ──────────────────────────────────────────────────
    var entries_to_show: []core.Entry = undefined;
    var search_results: ?[]core.Entry = null;
    defer if (search_results) |sr| gpa.free(sr);

    if (h.search) |term| {
        search_results = try core.history.search(gpa, &hist, term);
        entries_to_show = search_results.?;
        if (entries_to_show.len == 0) {
            printInfo(io, "No history entries match '{s}'\n", .{term});
            return;
        }
    } else {
        entries_to_show = hist.entries;
    }

    if (entries_to_show.len == 0) {
        printInfo(io, "No shell history found\n", .{});
        return;
    }

    if (h.last_n) |n| {
        const start = if (entries_to_show.len > n) entries_to_show.len - n else 0;
        entries_to_show = entries_to_show[start..];
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    for (entries_to_show) |entry| {
        try w.interface.print("{d:>4}  {s}\n", .{ entry.index, entry.command });
    }
    try w.flush();
}

// ── init ──────────────────────────────────────────────────────────────────────

fn handleInit(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    i: cli.InitArgs,
) !void {
    const sh: ?core.Shell = if (i.shell) |s|
        core.Shell.fromStr(s) orelse {
            return printErr(io, "error: unknown shell '{s}'\n", .{s});
        }
    else
        null;

    const opts = core.init_mod.Options{
        .fn_name = i.fn_name,
        .shell = sh,
        .config_file = i.config_file,
        .force = i.force,
        .verify = i.verify,
        .explain = i.explain,
    };

    const result = core.init_mod.run(io, gpa, env, opts) catch |err| switch (err) {
        error.ShellNotDetected => return printErr(io, "error: Could not detect current shell. Use mm --init --shell <name>\n", .{}),
        error.HomeNotSet => return printErr(io, "error: HOME environment variable is not set\n", .{}),
        else => return err,
    };

    if (i.verify or i.explain) return;

    const actual_sh = sh orelse core.shell.detectShell(env) orelse return;
    const shell_name = actual_sh.toStr();

    switch (result) {
        .installed => {
            printInfo(io, "Shell wrapper initialized for {s}\n", .{shell_name});
            printInfo(io, "Database initialized\n", .{});
            if (actual_sh != .fish) {
                const rc = core.shell.rcFileRel(actual_sh);
                printInfo(io, "Run: source ~/{s}\n", .{rc});
            }
        },
        .already_installed => printInfo(io, "Shell wrapper already initialized for {s}\n", .{shell_name}),
        .reinstalled => printInfo(io, "Shell wrapper reinitialized for {s}\n", .{shell_name}),
    }
}

// ── help / version ────────────────────────────────────────────────────────────

fn printHelp(io: std.Io) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(
        \\memento — command bookmarks
        \\
        \\  mm <label>              Execute saved command  (via shell function)
        \\  mm -a <label> <cmd>     Add command  (--add)
        \\  mm -l [term]            List commands  (--list)
        \\  mm -e <label>           Edit command  (--edit)
        \\  mm -d <label>           Delete command  (--delete)
        \\  mm -H [term]            Browse shell history  (--history)
        \\  memento --init [name]   Install shell wrapper  (-i)  default name: mm
        \\
        \\  --description <text>    Set a description for the command  (-a, -e)
        \\  --universal             Mark command as available in all shells
        \\  --shell <name>          Target a specific shell scope
        \\  --force                 Overwrite / skip scope check
        \\  --dry-run               Preview without executing
        \\
    , .{}) catch {};
    w.flush() catch {};
}

fn printVersion(io: std.Io) void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("memento 0.1.0\n", .{}) catch {};
    w.flush() catch {};
}

// ── Utilities ─────────────────────────────────────────────────────────────────

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) error{UserError} {
    printInfo(io, fmt, args);
    return error.UserError;
}

fn printInfo(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn prompt(io: std.Io, init: std.process.Init, msg: []const u8) ![]const u8 {
    const stdin_file = std.Io.File.stdin();
    const is_tty = stdin_file.isTty(io) catch false;
    if (!is_tty) return "";
    if (msg.len > 0) try std.Io.File.stderr().writeStreamingAll(io, msg);
    var read_buf: [256]u8 = undefined;
    var r = stdin_file.reader(io, &read_buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return "";
    _ = init;
    return std.mem.trimEnd(u8, line, "\r");
}

fn isYes(s: []const u8) bool {
    return std.mem.eql(u8, s, "y") or std.mem.eql(u8, s, "Y");
}
