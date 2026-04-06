/// Interactive commands browser TUI.
///
/// Layout (example 80×24 terminal):
///
///   ┌ header bar (reverse) ──────────────────────────────────────────────────┐
///   │  memento   5/12   [A]all  [/]filter  [?]help  [q]quit                 │
///   ├ list rows ─────────────────────────────────────────────────────────────┤
///   │  deploy    {} helm upgrade {release} {chart} -n {ns}   [universal]     │
///   │> kgp       {} kubectl get pods --namespace {ns}         [universal]     │
///   │  build        cargo build --release                     [universal]     │
///   ├ status bar ─────────────────────────────────────────────────────────────┤
///   │  [j/k]nav  [Enter]run  [e]edit  [d]del  [a]add                        │
///   └─────────────────────────────────────────────────────────────────────────┘
const std = @import("std");
const core = @import("../core/mod.zig");
const term = @import("term.zig");
const theme = @import("theme.zig");
const strings = @import("../strings.zig");

const th = theme.default;

const STDIN = std.posix.STDIN_FILENO;
const STDERR = std.posix.STDERR_FILENO;
const STDOUT = std.posix.STDOUT_FILENO;

pub const Browser = struct {
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    raw: term.RawMode,
    frame: term.Frame,

    // ── View state ────────────────────────────────────────────────────────────
    commands: []core.Command,
    selected: usize, // index into commands[]
    offset: usize, // top-visible row index into commands[]
    show_all: bool,
    current_shell: ?core.Shell,

    // ── Filter state ──────────────────────────────────────────────────────────
    filter: [128]u8,
    filter_len: usize,
    filter_active: bool, // filter has been committed (not just being typed)
    in_filter: bool, // currently in filter input mode
    // Snapshot saved when entering filter mode; restored on Escape to cancel.
    pre_filter_len: usize,
    pre_filter_active: bool,

    // ── Key sequence state ─────────────────────────────────────────────────────
    pending_g: bool,
    should_quit: bool,
    switch_view: bool,

    // ── Description toggle ────────────────────────────────────────────────────
    /// Index of the command currently showing its description instead of command
    /// text. Null means all rows show the command.
    expanded: ?usize,

    // ─────────────────────────────────────────────────────────────────────────

    pub fn run(
        gpa: std.mem.Allocator,
        db: *core.Db,
        env: *const std.process.Environ.Map,
        out_switch_view: *bool,
    ) !?[]u8 {
        const raw = try term.RawMode.enable(STDIN);
        var self = Browser{
            .gpa = gpa,
            .db = db,
            .env = env,
            .raw = raw,
            .frame = term.Frame.init(STDERR),
            .commands = &.{},
            .selected = 0,
            .offset = 0,
            .show_all = false,
            .current_shell = core.shell.detectShell(env),
            .filter = undefined,
            .filter_len = 0,
            .filter_active = false,
            .in_filter = false,
            .pre_filter_len = 0,
            .pre_filter_active = false,
            .pending_g = false,
            .should_quit = false,
            .switch_view = false,
            .expanded = null,
        };
        defer self.raw.disable();
        defer self.freeCommands();

        // Enter the alternate screen so the main screen (shell history, previous
        // output) is fully preserved and restored when the TUI exits.
        self.frame.enterAltScreen();
        self.frame.hideCursor();
        self.frame.flush();
        defer {
            self.frame.clear();
            self.frame.leaveAltScreen();
            self.frame.showCursor();
            self.frame.flush();
        }

        try self.refresh();
        const result = try self.eventLoop();
        if (self.switch_view) out_switch_view.* = true;
        return result;
    }

    // ── Event loop ────────────────────────────────────────────────────────────

    fn eventLoop(self: *Browser) !?[]u8 {
        while (true) {
            self.render();

            const key = term.readKey(STDIN) catch |err| switch (err) {
                error.EndOfFile => return null,
                else => return err,
            };

            if (self.in_filter) {
                if (try self.handleFilterKey(key)) |result| return result;
            } else {
                if (try self.handleNormalKey(key)) |result| return result;
            }
            if (self.should_quit) return null;
        }
    }

    // ── Normal mode key handling ──────────────────────────────────────────────

    fn handleNormalKey(self: *Browser, key: term.Key) !?[]u8 {
        // Handle 'gg' sequence.
        if (self.pending_g) {
            self.pending_g = false;
            const is_g = switch (key) {
                .char => |c| c == 'g',
                else => false,
            };
            if (is_g) {
                self.selected = 0;
                self.clampScroll();
                return null;
            }
        }

        switch (key) {
            .ctrl_c, .ctrl_d => { self.should_quit = true; return null; },
            .tab => { self.switch_view = true; self.should_quit = true; return null; },
            .char => |ch| switch (ch) {
                'q' => { self.should_quit = true; return null; },
                'j' => self.moveDown(),
                'k' => self.moveUp(),
                'g' => self.pending_g = true,
                'G' => {
                    if (self.commands.len > 0) self.selected = self.commands.len - 1;
                    self.clampScroll();
                },
                'A' => {
                    self.show_all = !self.show_all;
                    self.selected = 0;
                    self.offset = 0;
                    try self.refresh();
                },
                '/' => {
                    self.pre_filter_len = self.filter_len;
                    self.pre_filter_active = self.filter_active;
                    self.in_filter = true;
                },
                'h' => {
                    // Clear active filter.
                    if (self.filter_active) {
                        self.filter_len = 0;
                        self.filter_active = false;
                        self.selected = 0;
                        self.offset = 0;
                        try self.refresh();
                    }
                },
                'i' => self.doInfo(),
                'e' => try self.doEdit(),
                'd' => try self.doDelete(),
                'a' => try self.doAdd(),
                '?' => self.doHelp(),
                else => {},
            },
            .up => self.moveUp(),
            .down => self.moveDown(),
            .enter => {
                if (self.commands.len > 0 and self.commands[self.selected].description != null) {
                    self.expanded = if (self.expanded == self.selected) null else self.selected;
                }
            },
            .escape => {
                if (self.filter_active) {
                    self.filter_len = 0;
                    self.filter_active = false;
                    self.selected = 0;
                    self.offset = 0;
                    try self.refresh();
                }
                // Escape does nothing when no filter is active.
            },
            else => {},
        }
        return null;
    }

    // ── Filter mode key handling ──────────────────────────────────────────────

    fn handleFilterKey(self: *Browser, key: term.Key) !?[]u8 {
        switch (key) {
            .enter, .right => {
                // 'l' / Enter: confirm filter, return to normal mode.
                self.in_filter = false;
                self.filter_active = self.filter_len > 0;
                self.selected = 0;
                self.offset = 0;
                try self.refresh();
            },
            .escape => {
                // Cancel: restore the filter state that was active before entering
                // filter mode, so a previously committed filter is preserved.
                self.in_filter = false;
                self.filter_len = self.pre_filter_len;
                self.filter_active = self.pre_filter_active;
                self.selected = 0;
                self.offset = 0;
                try self.refresh();
            },
            .char => |ch| switch (ch) {
                'l' => {
                    self.in_filter = false;
                    self.filter_active = self.filter_len > 0;
                    self.selected = 0;
                    self.offset = 0;
                    try self.refresh();
                },
                else => {
                    if (ch >= 0x20 and self.filter_len < self.filter.len) {
                        self.filter[self.filter_len] = ch;
                        self.filter_len += 1;
                        self.selected = 0;
                        self.offset = 0;
                        try self.refresh();
                    }
                },
            },
            .backspace => {
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.selected = 0;
                    self.offset = 0;
                    try self.refresh();
                }
            },
            .ctrl_c, .ctrl_d => { self.should_quit = true; return null; },
            else => {},
        }
        return null;
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    fn doDelete(self: *Browser) !void {
        if (self.commands.len == 0) return;
        const cmd = self.commands[self.selected];

        var confirm_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&confirm_buf, strings.cmd_prompt_delete_fmt, .{cmd.label}) catch strings.cmd_prompt_delete_fallback;
        const ts = term.getTermSize(STDERR);
        const answer = try self.readLine(ts.rows, prompt, "", false) orelse return;
        defer self.gpa.free(answer);

        if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y")) {
            var diag = core.DeleteDiag{};
            const labels = [_][]const u8{cmd.label};
            core.delete(self.gpa, self.db, .{ .labels = &labels }, &diag) catch {};
            if (self.selected > 0 and self.selected >= self.commands.len -| 1) {
                self.selected -= 1;
            }
            try self.refresh();
        }
    }

    fn doEdit(self: *Browser) !void {
        if (self.commands.len == 0) return;
        const cmd = self.commands[self.selected];

        const ts = term.getTermSize(STDERR);

        // Prompt for new label (pre-filled, cursor at end, no clear-on-type).
        const new_label_raw = try self.readLine(ts.rows, strings.cmd_prompt_label, cmd.label, false) orelse return;
        defer self.gpa.free(new_label_raw);

        // Prompt for new command (pre-filled, cursor at end, no clear-on-type).
        const new_cmd_raw = try self.readLine(ts.rows, strings.cmd_prompt_command, cmd.command, false) orelse return;
        defer self.gpa.free(new_cmd_raw);

        // Prompt for description (pre-filled with existing or blank).
        const current_desc = cmd.description orelse "";
        const new_desc_raw = try self.readLine(ts.rows, strings.cmd_prompt_desc, current_desc, false) orelse return;
        defer self.gpa.free(new_desc_raw);

        // Empty string means the user cleared the field — treat as no change.
        const new_label: ?[]const u8 = if (new_label_raw.len > 0 and
            !std.mem.eql(u8, new_label_raw, cmd.label)) new_label_raw else null;
        const new_cmd: ?[]const u8 = if (new_cmd_raw.len > 0 and
            !std.mem.eql(u8, new_cmd_raw, cmd.command)) new_cmd_raw else null;
        const new_desc: ?[]const u8 = if (!std.mem.eql(u8, new_desc_raw, current_desc))
            (if (new_desc_raw.len > 0) new_desc_raw else null)
        else
            null;

        if (new_label == null and new_cmd == null and new_desc == null) return;

        _ = core.edit(self.gpa, self.db, .{
            .label = cmd.label,
            .new_label = new_label,
            .new_command = new_cmd,
            .new_description = new_desc,
        }) catch {};
        try self.refresh();
    }

    fn doAdd(self: *Browser) !void {
        const ts = term.getTermSize(STDERR);

        const label = try self.readLine(ts.rows, strings.cmd_prompt_new_label, "", false) orelse return;
        defer self.gpa.free(label);
        if (label.len == 0) return;

        const command = try self.readLine(ts.rows, strings.cmd_prompt_command, "", false) orelse return;
        defer self.gpa.free(command);
        if (command.len == 0) return;

        const desc = try self.readLine(ts.rows, strings.cmd_prompt_desc, "", false) orelse return;
        defer self.gpa.free(desc);

        const result = core.add(self.gpa, self.db, .{
            .label = label,
            .command = command,
            .description = if (desc.len > 0) desc else null,
            .scope = if (self.current_shell) |sh| core.Scope.fromStr(sh.toStr()) orelse .universal else .universal,
        }) catch return;
        for (result.placeholder_names) |n| self.gpa.free(n);
        self.gpa.free(result.placeholder_names);

        try self.refresh();
        // Select the newly added command.
        for (self.commands, 0..) |c, i| {
            if (std.mem.eql(u8, c.label, label)) {
                self.selected = i;
                self.clampScroll();
                break;
            }
        }
    }

    fn doHelp(self: *Browser) void {
        const ts = term.getTermSize(STDERR);
        self.frame.clear();
        self.frame.hideCursor();
        self.frame.clearScreen();

        self.frame.moveTo(1, 1);
        self.frame.w(th.header);
        self.frame.wPad(strings.cmd_help_title, ts.cols);
        self.frame.w(th.reset);

        const lines = [_][]const u8{
            "",
            "  Navigation",
            "    j / ↓       move down",
            "    k / ↑       move up",
            "    G           jump to last",
            "    gg          jump to first",
            "",
            "  Actions",
            "    i           show full record popup",
            "    Enter       toggle description inline (if one exists)",
            "    e           edit label / command / description",
            "    d           delete with confirmation",
            "    a           add new command",
            "    Tab         switch to history view",
            "",
            "  View",
            "    /           start filter",
            "    l / Enter   confirm filter",
            "    h / Esc     clear filter",
            "    A           toggle all scopes",
            "",
            "  Other",
            "    ?           toggle this help",
            "    q           quit",
            "",
            strings.help_any_key_return,
        };

        for (lines, 0..) |line, i| {
            const row = i + 2;
            if (row >= ts.rows) break;
            self.frame.moveTo(row, 1);
            self.frame.clearEol();
            self.frame.w(line);
        }

        self.frame.showCursor();
        self.frame.flush();

        _ = term.readKey(STDIN) catch {};
    }

    // ── Info popup ────────────────────────────────────────────────────────────

    fn doInfo(self: *Browser) void {
        if (self.commands.len == 0) return;
        const cmd = self.commands[self.selected];
        const ts = term.getTermSize(STDERR);

        // ── geometry ──────────────────────────────────────────────────────────
        const pop_w: usize = @max(44, @min(74, ts.cols -| 4));
        const pop_col: usize = if (ts.cols > pop_w) (ts.cols - pop_w) / 2 + 1 else 1;
        // Field name column: wide enough for "Placeholders:" (13 chars).
        const key_w: usize = 13;
        // Value column fills the rest: 1 (margin) + key_w + 1 (sep) + val_w = pop_w.
        const val_w: usize = pop_w -| (1 + key_w + 1);

        // ── count rows needed so we can vertically centre ─────────────────────
        var height: usize = 0;
        height += 1; // header
        height += 1; // label (always 1 line — labels are short)
        height += wrappedLines(cmd.command, val_w);
        if (cmd.description) |d| height += wrappedLines(d, val_w);
        height += 1; // scope
        if (cmd.placeholders) |p| height += wrappedLines(p, val_w);
        height += 1; // blank separator
        height += 1; // close hint

        const pop_row: usize = if (ts.rows > height + 2) (ts.rows - height) / 2 + 1 else 2;

        // ── render background then draw the popup on top ──────────────────────
        self.frame.clear();
        self.frame.hideCursor();
        self.renderContent();

        var row = pop_row;

        // Header row (bold, uses the label as title).
        {
            var hbuf: [80]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hbuf, strings.cmd_info_title_fmt, .{cmd.label}) catch strings.cmd_info_title_fallback;
            self.frame.moveTo(row, pop_col);
            self.frame.w(th.popup_title);
            self.frame.wPad(hdr, pop_w);
            self.frame.w(th.reset);
            row += 1;
        }

        // Content fields.
        self.popField(&row, pop_col, key_w, val_w, "Label:", cmd.label);
        self.popField(&row, pop_col, key_w, val_w, "Command:", cmd.command);
        if (cmd.description) |d|
            self.popField(&row, pop_col, key_w, val_w, "Description:", d);
        self.popField(&row, pop_col, key_w, val_w, "Scope:", cmd.scope.toStr());
        if (cmd.placeholders) |p|
            self.popField(&row, pop_col, key_w, val_w, "Placeholders:", p);

        // Blank separator.
        self.frame.moveTo(row, pop_col);
        self.frame.w(th.popup_body);
        self.frame.wPad("", pop_w);
        self.frame.w(th.reset);
        row += 1;

        // Close hint.
        self.frame.moveTo(row, pop_col);
        self.frame.w(th.popup_body);
        self.frame.wPad(strings.cmd_info_close, pop_w);
        self.frame.w(th.reset);

        self.frame.showCursor();
        self.frame.flush();
        _ = term.readKey(STDIN) catch {};
    }

    /// Render one popup field, wrapping the value across multiple rows if needed.
    /// Layout per row:  " " key(key_w) " " value(val_w)  total = pop_w.
    fn popField(
        self: *Browser,
        row: *usize,
        col: usize,
        key_w: usize,
        val_w: usize,
        key: []const u8,
        val: []const u8,
    ) void {
        if (val_w == 0) return;
        var pos: usize = 0;
        var first = true;
        while (true) {
            const end = @min(pos + val_w, val.len);
            self.frame.moveTo(row.*, col);
            self.frame.w(th.popup_body);
            self.frame.w(" ");
            if (first) self.frame.wPad(key, key_w) else self.frame.wPad("", key_w);
            self.frame.w(" ");
            self.frame.wPad(val[pos..end], val_w);
            self.frame.w(th.reset);
            row.* += 1;
            if (end >= val.len) break;
            pos = end;
            first = false;
        }
    }

    // ── Inline line reader ────────────────────────────────────────────────────

    /// Render a prompt on `row`, read a line, return gpa-owned string or null on Esc.
    /// `replace_on_type`: when true, the first keypress clears the pre-filled text
    /// (useful for suggested labels); when false, the cursor is placed at the end
    /// and typing inserts normally (useful for editing existing values).
    fn readLine(self: *Browser, row: usize, prompt: []const u8, initial: []const u8, replace_on_type: bool) !?[]u8 {
        var buf: [256]u8 = undefined;
        const init_n = @min(initial.len, buf.len);
        @memcpy(buf[0..init_n], initial[0..init_n]);
        var n = init_n;
        var cursor: usize = n;
        var pending_replace = replace_on_type and n > 0;

        while (true) {
            self.frame.clear();
            self.frame.hideCursor();
            self.renderContent();
            const ts_row = term.getTermSize(STDERR);
            self.frame.moveTo(row, 1);
            self.frame.w(th.prompt);
            self.frame.w(prompt);
            const total_avail: usize = if (ts_row.cols > prompt.len) ts_row.cols - prompt.len else 0;
            var rem = total_avail;
            // Text before cursor.
            const before_n = @min(cursor, rem);
            self.frame.w(buf[0..before_n]);
            rem -= before_n;
            // Cursor character: normal video so it stands out against the white row.
            if (rem > 0) {
                self.frame.w(th.reset);
                self.frame.w(if (cursor < n) buf[cursor .. cursor + 1] else " ");
                rem -= 1;
                self.frame.w(th.prompt);
            }
            // Text after cursor, then padding to fill the row.
            if (cursor < n and rem > 0) {
                const tail_n = @min(n - cursor - 1, rem);
                self.frame.w(buf[cursor + 1 .. cursor + 1 + tail_n]);
                rem -= tail_n;
            }
            self.frame.wPad("", rem);
            self.frame.w(th.reset);
            self.frame.moveTo(row, prompt.len + cursor + 1);
            self.frame.showCursor();
            self.frame.flush();

            const key = term.readKey(STDIN) catch return null;
            switch (key) {
                .enter => return try self.gpa.dupe(u8, buf[0..n]),
                .escape => return null,
                .ctrl_c, .ctrl_d => return null,
                .left => {
                    if (pending_replace) {
                        cursor = 0;
                        pending_replace = false;
                    } else if (cursor > 0) {
                        cursor -= 1;
                    }
                },
                .right => {
                    if (pending_replace) {
                        pending_replace = false;
                    } else if (cursor < n) {
                        cursor += 1;
                    }
                },
                .backspace => {
                    if (pending_replace) {
                        n = 0;
                        cursor = 0;
                        pending_replace = false;
                    } else if (cursor > 0) {
                        var k = cursor - 1;
                        while (k < n - 1) : (k += 1) buf[k] = buf[k + 1];
                        n -= 1;
                        cursor -= 1;
                    }
                },
                .char => |ch| if (ch >= 0x20 and n < buf.len) {
                    if (pending_replace) {
                        n = 0;
                        cursor = 0;
                        pending_replace = false;
                    }
                    var k = n;
                    while (k > cursor) : (k -= 1) buf[k] = buf[k - 1];
                    buf[cursor] = ch;
                    n += 1;
                    cursor += 1;
                },
                else => {},
            }
        }
    }

    // ── Rendering ─────────────────────────────────────────────────────────────

    fn render(self: *Browser) void {
        self.frame.clear();
        self.frame.hideCursor();
        self.renderContent();
        self.frame.showCursor();
        self.frame.flush();
    }

    fn renderContent(self: *Browser) void {
        const ts = term.getTermSize(STDERR);
        const list_rows = if (ts.rows > 2) ts.rows - 2 else 1;

        self.clampScroll();

        // ── Header ────────────────────────────────────────────────────────────
        self.frame.moveTo(1, 1);
        self.frame.w(th.header);

        var hdr: [256]u8 = undefined;
        const scope_tag: []const u8 = if (self.show_all) strings.cmd_tag_all_scopes else "";
        const filter_tag: []const u8 = if (self.filter_active) strings.cmd_tag_filtered else "";
        const hdr_text = std.fmt.bufPrint(&hdr, strings.cmd_header_fmt, .{
            self.commands.len, self.totalCount(),
            scope_tag, filter_tag,
        }) catch strings.cmd_header_fallback;
        self.frame.wPad(hdr_text, ts.cols);
        self.frame.w(th.reset);

        // ── Command rows ──────────────────────────────────────────────────────
        const label_w: usize = 16;
        const scope_w: usize = 13; // " [universal]" = 13 chars
        const cmd_prefix_w: usize = 2 + 1 + label_w + 1 + 3 + 1; // "> " + " " + label + " " + "{}" + " "
        const cmd_w: usize = if (ts.cols > cmd_prefix_w + scope_w + 1)
            ts.cols - cmd_prefix_w - scope_w - 1
        else
            10;

        for (0..list_rows) |row_i| {
            const cmd_i = self.offset + row_i;
            const row = row_i + 2;
            self.frame.moveTo(row, 1);

            if (cmd_i >= self.commands.len) {
                self.frame.clearEol();
                continue;
            }

            const cmd = self.commands[cmd_i];
            const is_selected = cmd_i == self.selected;

            if (is_selected) self.frame.w(th.selected);

            // Cursor indicator.
            self.frame.w(if (is_selected) "> " else "  ");
            // Label (elide with … if too long).
            self.frame.wPadElide(cmd.label, label_w);
            self.frame.w(" ");
            // Template / description marker.
            const showing_desc = if (self.expanded) |exp| exp == cmd_i else false;
            if (showing_desc) {
                self.frame.w("¶  ");
            } else {
                self.frame.w(if (cmd.is_template) "{} " else "   ");
            }
            // Body: description when expanded, command otherwise (elide if too long).
            const body: []const u8 = if (showing_desc) cmd.description.? else cmd.command;
            self.frame.wPadElide(body, cmd_w);
            // Scope.
            var scope_buf: [16]u8 = undefined;
            const scope_str = std.fmt.bufPrint(&scope_buf, " [{s}]", .{cmd.scope.toStr()}) catch " [?]";
            self.frame.wPad(scope_str, scope_w);

            if (is_selected) self.frame.w(th.reset);
            self.frame.clearEol();
        }

        // ── Status bar ────────────────────────────────────────────────────────
        self.frame.moveTo(ts.rows, 1);
        self.frame.w(th.prompt);

        if (self.in_filter) {
            var status: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&status, strings.cmd_filter_prefix, .{self.filter[0..self.filter_len]}) catch strings.cmd_filter_fallback;
            self.frame.wPad(s, ts.cols);
        } else {
            self.frame.wPad(strings.cmd_hint, ts.cols);
        }

        self.frame.w(th.reset);
    }

    // ── Navigation helpers ────────────────────────────────────────────────────

    fn moveDown(self: *Browser) void {
        if (self.commands.len == 0) return;
        self.selected = (self.selected + 1) % self.commands.len;
        self.clampScroll();
    }

    fn moveUp(self: *Browser) void {
        if (self.commands.len == 0) return;
        if (self.selected == 0) {
            self.selected = self.commands.len - 1;
        } else {
            self.selected -= 1;
        }
        self.clampScroll();
    }

    fn clampScroll(self: *Browser) void {
        const ts = term.getTermSize(STDERR);
        const list_rows = if (ts.rows > 2) ts.rows - 2 else 1;
        if (self.selected < self.offset) self.offset = self.selected;
        if (self.selected >= self.offset + list_rows) {
            self.offset = self.selected - list_rows + 1;
        }
        // Fill screen: pull offset back when the list shrank (e.g. after filtering)
        // so empty rows never appear at the bottom while entries exist above.
        const max_offset = if (self.commands.len > list_rows) self.commands.len - list_rows else 0;
        if (self.offset > max_offset) self.offset = max_offset;
    }

    // ── Data helpers ──────────────────────────────────────────────────────────

    fn totalCount(self: *Browser) usize {
        const filter = core.ListFilter{
            .current_shell = if (self.current_shell) |s| core.Scope.fromStr(s.toStr()) else null,
            .show_all = self.show_all,
        };
        const all = self.db.listCommands(filter) catch return 0;
        defer {
            for (all) |c| c.deinit(self.gpa);
            self.gpa.free(all);
        }
        return all.len;
    }

    fn refresh(self: *Browser) !void {
        self.freeCommands();
        self.expanded = null;

        const search: ?[]const u8 = if ((self.filter_active or self.in_filter) and self.filter_len > 0)
            self.filter[0..self.filter_len]
        else
            null;

        const filter = core.ListFilter{
            .current_shell = if (self.current_shell) |s| core.Scope.fromStr(s.toStr()) else null,
            .show_all = self.show_all,
            .search = search,
        };
        self.commands = try self.db.listCommands(filter);

        if (self.selected >= self.commands.len and self.commands.len > 0) {
            self.selected = self.commands.len - 1;
        } else if (self.commands.len == 0) {
            self.selected = 0;
        }
        self.clampScroll();
    }

    fn freeCommands(self: *Browser) void {
        for (self.commands) |cmd| cmd.deinit(self.gpa);
        self.gpa.free(self.commands);
        self.commands = &.{};
    }
};

/// Number of wrapped lines needed to display `text` in a column of `width` chars.
fn wrappedLines(text: []const u8, width: usize) usize {
    if (width == 0 or text.len == 0) return 1;
    return (text.len + width - 1) / width;
}
