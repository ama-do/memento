/// Interactive history browser TUI.
///
/// Layout (example 80×24 terminal):
///
///   ┌ header bar (reverse) ──────────────────────────────────────────────────┐
///   │  memento — history   150 entries   [D]dedup  [/]filter  [?]help       │
///   ├ list rows ─────────────────────────────────────────────────────────────┤
///   │   150  cargo build --release                                            │
///   │>  149  kubectl get pods --namespace production                          │
///   │   148  git diff --stat HEAD~1                                           │
///   ├ status bar ─────────────────────────────────────────────────────────────┤
///   │  [j/k]nav  [Enter]run  [w]write to memento  [/]filter  [q]quit        │
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

    // ── History data ──────────────────────────────────────────────────────────
    hist: core.History,
    /// Visible entries (slice into hist.entries, dedup_entries, or search_results).
    entries: []core.Entry,
    /// Allocated by dedupEntries; freed at the start of each applyEntries call.
    dedup_entries: ?[]core.Entry,
    /// Allocated by history.search; freed at the start of each applyEntries call.
    search_results: ?[]core.Entry,

    // ── View state ────────────────────────────────────────────────────────────
    selected: usize,
    offset: usize,
    dedup: bool, // deduplicate consecutive identical entries

    // ── Filter state ──────────────────────────────────────────────────────────
    filter: [128]u8,
    filter_len: usize,
    filter_active: bool,
    in_filter: bool,
    // Snapshot saved when entering filter mode; restored on Escape to cancel.
    pre_filter_len: usize,
    pre_filter_active: bool,

    // ── Key sequence state ─────────────────────────────────────────────────────
    pending_g: bool,
    should_quit: bool,
    switch_view: bool,

    // ─────────────────────────────────────────────────────────────────────────

    pub fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        db: *core.Db,
        env: *const std.process.Environ.Map,
        out_switch_view: *bool,
    ) !?[]u8 {
        const sh = core.shell.detectShell(env) orelse return null;
        const home = env.get("HOME") orelse return null;

        const raw = try term.RawMode.enable(STDIN);
        var self = Browser{
            .gpa = gpa,
            .db = db,
            .env = env,
            .raw = raw,
            .frame = term.Frame.init(STDERR),
            .hist = try core.history.read(io, gpa, sh, env, home),
            .entries = &.{},
            .dedup_entries = null,
            .search_results = null,
            .selected = 0,
            .offset = 0,
            .dedup = true,
            .filter = undefined,
            .filter_len = 0,
            .filter_active = false,
            .in_filter = false,
            .pre_filter_len = 0,
            .pre_filter_active = false,
            .pending_g = false,
            .should_quit = false,
            .switch_view = false,
        };
        defer self.raw.disable();
        defer self.hist.deinit();
        defer if (self.dedup_entries) |de| gpa.free(de);
        defer if (self.search_results) |sr| gpa.free(sr);

        // Enter the alternate screen so the main screen is preserved and
        // restored when the TUI exits.
        self.frame.enterAltScreen();
        self.frame.hideCursor();
        self.frame.flush();
        defer {
            self.frame.clear();
            self.frame.leaveAltScreen();
            self.frame.showCursor();
            self.frame.flush();
        }

        self.applyEntries();
        // Start at newest (first entry in the reversed view = last in the array).
        if (self.entries.len > 0) {
            self.selected = self.entries.len - 1;
        }
        self.clampScroll();

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

    // ── Normal mode ───────────────────────────────────────────────────────────

    fn handleNormalKey(self: *Browser, key: term.Key) !?[]u8 {
        if (self.pending_g) {
            self.pending_g = false;
            const is_g = switch (key) {
                .char => |c| c == 'g',
                else => false,
            };
            if (is_g) {
                // gg: jump to newest (visually the bottom since we show newest-last).
                if (self.entries.len > 0) self.selected = self.entries.len - 1;
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
                    // G: jump to oldest (visually the top).
                    self.selected = 0;
                    self.clampScroll();
                },
                'D' => {
                    self.dedup = !self.dedup;
                    self.applyEntries();
                    self.selected = 0;
                    self.offset = 0;
                },
                '/' => {
                    self.pre_filter_len = self.filter_len;
                    self.pre_filter_active = self.filter_active;
                    self.in_filter = true;
                },
                'h' => {
                    if (self.filter_active) {
                        self.filter_len = 0;
                        self.filter_active = false;
                        self.applyEntries();
                        self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                        self.clampScroll();
                    }
                },
                'a' => try self.doAdd(),
                'e' => try self.doEditAndAdd(),
                '?' => self.doHelp(),
                else => {},
            },
            .up => self.moveUp(),
            .down => self.moveDown(),
            .escape => {
                if (self.filter_active) {
                    self.filter_len = 0;
                    self.filter_active = false;
                    self.applyEntries();
                    self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                    self.clampScroll();
                }
                // Escape does nothing when no filter is active.
            },
            else => {},
        }
        return null;
    }

    // ── Filter mode ───────────────────────────────────────────────────────────

    fn handleFilterKey(self: *Browser, key: term.Key) !?[]u8 {
        switch (key) {
            .enter => {
                self.in_filter = false;
                self.filter_active = self.filter_len > 0;
                self.applyEntries();
                self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                self.clampScroll();
            },
            .escape => {
                // Cancel: restore the filter state that was active before entering
                // filter mode, so a previously committed filter is preserved.
                self.in_filter = false;
                self.filter_len = self.pre_filter_len;
                self.filter_active = self.pre_filter_active;
                self.applyEntries();
                self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                self.clampScroll();
            },
            .char => |ch| switch (ch) {
                'l' => {
                    self.in_filter = false;
                    self.filter_active = self.filter_len > 0;
                    self.applyEntries();
                    self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                    self.clampScroll();
                },
                else => {
                    if (ch >= 0x20 and self.filter_len < self.filter.len) {
                        self.filter[self.filter_len] = ch;
                        self.filter_len += 1;
                        self.applyEntries();
                        self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                        self.clampScroll();
                    }
                },
            },
            .backspace => {
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.applyEntries();
                    self.selected = if (self.entries.len > 0) self.entries.len - 1 else 0;
                    self.clampScroll();
                }
            },
            .ctrl_c, .ctrl_d => { self.should_quit = true; return null; },
            else => {},
        }
        return null;
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    /// Add the selected entry to the db: prompts for label and description.
    fn doAdd(self: *Browser) !void {
        if (self.entries.len == 0) return;
        const entry = self.entries[self.selected];
        try self.saveCommand(entry.command);
    }

    /// Edit the selected entry's command inline, then save to the db.
    /// Useful for turning a raw command into a template before bookmarking.
    fn doEditAndAdd(self: *Browser) !void {
        if (self.entries.len == 0) return;
        const entry = self.entries[self.selected];

        const ts = term.getTermSize(STDERR);
        const edited = try self.readLine(ts.rows, strings.hist_prompt_command, entry.command, false) orelse return;
        defer self.gpa.free(edited);
        if (edited.len == 0) return;

        try self.saveCommand(edited);
    }

    /// Prompt for label + description and write `command` to the db.
    fn saveCommand(self: *Browser, command: []const u8) !void {
        const ts = term.getTermSize(STDERR);

        var suggest_buf: [64]u8 = undefined;
        const suggested = suggestLabel(&suggest_buf, command);

        const label = try self.readLine(ts.rows, strings.hist_prompt_label, suggested, true) orelse return;
        defer self.gpa.free(label);
        if (label.len == 0) return;

        const desc_raw = try self.readLine(ts.rows, strings.hist_prompt_desc, "", false) orelse return;
        defer self.gpa.free(desc_raw);
        const description: ?[]const u8 = if (desc_raw.len > 0) desc_raw else null;

        const result = core.historySave(self.gpa, self.db, .{
            .command = command,
            .label = label,
            .description = description,
        }) catch |err| switch (err) {
            error.LabelExists => {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&err_buf, strings.hist_msg_exists_fmt, .{label}) catch strings.hist_msg_exists_fallback;
                try self.showMessage(ts.rows, msg);
                return;
            },
            else => return err,
        };
        _ = result;

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, strings.hist_msg_saved_fmt, .{label}) catch strings.hist_msg_saved_fallback;
        try self.showMessage(ts.rows, msg);
    }

    /// Derive a suggested label from a command string.
    /// Takes the first 1-2 non-flag words and joins them with "-".
    fn suggestLabel(buf: []u8, command: []const u8) []const u8 {
        var words: [2][]const u8 = undefined;
        var word_count: usize = 0;
        var iter = std.mem.splitAny(u8, command, " \t");
        while (iter.next()) |word| {
            if (word.len == 0) continue;
            if (std.mem.startsWith(u8, word, "-")) continue;
            words[word_count] = word;
            word_count += 1;
            if (word_count >= 2) break;
        }
        if (word_count == 0) return "my-command";

        var out_len: usize = 0;
        for (words[0..word_count], 0..) |w, i| {
            if (i > 0 and out_len < buf.len) {
                buf[out_len] = '-';
                out_len += 1;
            }
            const n = @min(w.len, buf.len - out_len);
            @memcpy(buf[out_len..][0..n], w[0..n]);
            out_len += n;
        }
        return buf[0..out_len];
    }

    fn doHelp(self: *Browser) void {
        const ts = term.getTermSize(STDERR);
        self.frame.clear();
        self.frame.hideCursor();
        self.frame.clearScreen();

        self.frame.moveTo(1, 1);
        self.frame.w(th.header);
        self.frame.wPad(strings.hist_help_title, ts.cols);
        self.frame.w(th.reset);

        const lines = [_][]const u8{
            "",
            "  Navigation",
            "    j / ↓       move down (toward older entries)",
            "    k / ↑       move up (toward newer entries)",
            "    G           jump to oldest entry",
            "    gg          jump to newest entry",
            "",
            "  Actions",
            "    a           save entry to memento store",
            "    e           edit command, then save to memento store",
            "    Tab         switch to commands view",
            "",
            "  View",
            "    /           start filter",
            "    l / Enter   confirm filter",
            "    h / Esc     clear filter",
            "    D           toggle deduplication",
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

    // ── Inline line reader ────────────────────────────────────────────────────

    fn readLine(self: *Browser, row: usize, prompt: []const u8, initial: []const u8, replace_on_type: bool) !?[]u8 {
        var buf: [256]u8 = undefined;
        const init_n = @min(initial.len, buf.len);
        @memcpy(buf[0..init_n], initial[0..init_n]);
        var n = init_n;
        // Cursor starts at the end of the pre-fill.
        var cursor: usize = n;
        // When true the pre-fill is "selected": the first character typed
        // replaces it entirely. Left/right arrows exit this mode instead,
        // positioning the cursor at the start or end respectively.
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
            // Place the terminal cursor at the correct insert position.
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
                        // Accept text, move cursor to start.
                        cursor = 0;
                        pending_replace = false;
                    } else if (cursor > 0) {
                        cursor -= 1;
                    }
                },
                .right => {
                    if (pending_replace) {
                        // Accept text, cursor stays at end.
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
                        // Delete the character before the cursor.
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
                    // Insert character at cursor, shifting the rest right.
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

    fn showMessage(self: *Browser, row: usize, msg: []const u8) !void {
        const ts = term.getTermSize(STDERR);
        self.frame.clear();
        self.frame.hideCursor();
        self.renderContent();
        self.frame.moveTo(row, 1);
        self.frame.w(th.prompt);
        self.frame.wPad(msg, ts.cols);
        self.frame.w(th.reset);
        self.frame.showCursor();
        self.frame.flush();
        _ = term.readKey(STDIN) catch {};
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

        const dedup_tag: []const u8 = if (!self.dedup) strings.hist_tag_dedup_off else "";
        const filter_tag: []const u8 = if (self.filter_active) strings.hist_tag_filtered else "";
        var hdr: [128]u8 = undefined;
        const hdr_text = std.fmt.bufPrint(&hdr, strings.hist_header_fmt, .{
            self.entries.len, dedup_tag, filter_tag,
        }) catch strings.hist_header_fallback;
        self.frame.wPad(hdr_text, ts.cols);
        self.frame.w(th.reset);

        // ── Entry rows ────────────────────────────────────────────────────────
        // idx column: 6 chars + space, cursor: 2, command: rest
        const idx_w: usize = 6;
        const cmd_w: usize = if (ts.cols > idx_w + 3) ts.cols - idx_w - 3 else 10;

        for (0..list_rows) |row_i| {
            const entry_i = self.offset + row_i;
            const row = row_i + 2;
            self.frame.moveTo(row, 1);

            if (entry_i >= self.entries.len) {
                self.frame.clearEol();
                continue;
            }

            const entry = self.entries[entry_i];
            const is_selected = entry_i == self.selected;

            if (is_selected) self.frame.w(th.selected);

            self.frame.w(if (is_selected) "> " else "  ");
            var idx_buf: [8]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{entry.index}) catch "?";
            self.frame.wPad(idx_str, idx_w);
            self.frame.w(" ");
            self.frame.wPad(entry.command, cmd_w);

            if (is_selected) self.frame.w(th.reset);
            self.frame.clearEol();
        }

        // ── Status bar ────────────────────────────────────────────────────────
        self.frame.moveTo(ts.rows, 1);
        self.frame.w(th.prompt);

        if (self.in_filter) {
            var status: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&status, strings.hist_filter_prefix, .{self.filter[0..self.filter_len]}) catch strings.hist_filter_fallback;
            self.frame.wPad(s, ts.cols);
        } else {
            self.frame.wPad(strings.hist_hint, ts.cols);
        }

        self.frame.w(th.reset);
    }

    // ── Navigation ────────────────────────────────────────────────────────────

    fn moveDown(self: *Browser) void {
        if (self.entries.len == 0) return;
        self.selected = (self.selected + 1) % self.entries.len;
        self.clampScroll();
    }

    fn moveUp(self: *Browser) void {
        if (self.entries.len == 0) return;
        if (self.selected == 0) {
            self.selected = self.entries.len - 1;
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
        // and empty rows would appear at the bottom despite entries being above.
        const max_offset = if (self.entries.len > list_rows) self.entries.len - list_rows else 0;
        if (self.offset > max_offset) self.offset = max_offset;
    }

    // ── Data helpers ──────────────────────────────────────────────────────────

    fn applyEntries(self: *Browser) void {
        // Free previous allocations before building new ones.
        if (self.search_results) |sr| {
            self.gpa.free(sr);
            self.search_results = null;
        }
        if (self.dedup_entries) |de| {
            self.gpa.free(de);
            self.dedup_entries = null;
        }

        var source = self.hist.entries;

        if (self.dedup) {
            if (self.dedupEntries(source)) |deduped| {
                self.dedup_entries = deduped;
                source = deduped;
            } else |_| {}
        }

        if (self.filter_active or self.in_filter) {
            const term_str = self.filter[0..self.filter_len];
            if (term_str.len > 0) {
                const results = core.history.search(self.gpa, &self.hist, term_str) catch {
                    self.entries = source;
                    return;
                };
                self.search_results = results;
                self.entries = results;
                return;
            }
        }

        self.entries = source;
    }

    fn dedupEntries(self: *Browser, source: []core.Entry) ![]core.Entry {
        // Walk newest-to-oldest, skip duplicates of already-seen commands.
        var seen = std.StringHashMap(void).init(self.gpa);
        defer seen.deinit();

        var out = std.ArrayList(core.Entry).empty;
        errdefer out.deinit(self.gpa);

        // Iterate in reverse (newest first) to keep the most recent occurrence.
        var i: usize = source.len;
        while (i > 0) {
            i -= 1;
            const entry = source[i];
            const result = try seen.getOrPut(entry.command);
            if (!result.found_existing) {
                try out.append(self.gpa, entry);
            }
        }

        // Reverse so oldest is first (index 0) for consistent navigation.
        const slice = try out.toOwnedSlice(self.gpa);
        std.mem.reverse(core.Entry, slice);
        return slice;
    }
};
