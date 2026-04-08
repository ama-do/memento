/// Low-level terminal utilities: raw mode, key input, ANSI frame buffer.
///
/// All rendering is done by building a Frame (a fixed-size byte buffer) and
/// flushing it to the terminal in a single write(2) call to avoid flicker.
/// Raw mode and key reading use the C termios API via libc (already linked).
const std = @import("std");
const builtin = @import("builtin");

// ── C bindings ────────────────────────────────────────────────────────────────

extern fn tcgetattr(fd: c_int, t: *Termios) c_int;
extern fn tcsetattr(fd: c_int, action: c_int, t: *const Termios) c_int;
extern fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

// ── Platform-specific termios layout ─────────────────────────────────────────
//
// macOS (Darwin): tcflag_t = unsigned long (8 bytes on 64-bit), NCCS = 20,
//   no c_line field.  Speed fields are also unsigned long.
//
// Linux:          tcflag_t = unsigned int  (4 bytes), NCCS = 19 (kernel ABI),
//   has c_line field.  Speed fields are unsigned int.

const is_darwin = builtin.os.tag.isDarwin();

/// The type of each flag field in the termios struct (platform-specific).
const TermiosFlag = if (is_darwin) c_ulong else c_uint;

const Termios = if (is_darwin) extern struct {
    c_iflag: c_ulong,
    c_oflag: c_ulong,
    c_cflag: c_ulong,
    c_lflag: c_ulong,
    c_cc: [20]u8, // NCCS = 20 on macOS
    // extern struct applies C ABI alignment: 4 bytes of implicit padding here
    // before the 8-byte-aligned speed fields.
    c_ispeed: c_ulong,
    c_ospeed: c_ulong,
} else extern struct {
    c_iflag: c_uint,
    c_oflag: c_uint,
    c_cflag: c_uint,
    c_lflag: c_uint,
    c_line: u8,
    c_cc: [19]u8, // NCCS = 19 on Linux (kernel ABI)
    c_ispeed: c_uint,
    c_ospeed: c_uint,
};

// ── Terminal control constants ────────────────────────────────────────────────

const VTIME: usize = if (is_darwin) 17 else 5;
const VMIN: usize  = if (is_darwin) 16 else 6;
const TCSANOW:  c_int = 0;
const TCSAFLUSH: c_int = 2;

// Input flags (c_iflag)
const IXON:   TermiosFlag = if (is_darwin) 0x0200 else 0x0400;
const ICRNL:  TermiosFlag = 0x0100; // same on both
const BRKINT: TermiosFlag = 0x0002; // same on both
const INPCK:  TermiosFlag = 0x0010; // same on both
const ISTRIP: TermiosFlag = 0x0020; // same on both

// Output flags (c_oflag)
const OPOST: TermiosFlag = 0x0001; // same on both

// Control flags (c_cflag)
const CS8: TermiosFlag = if (is_darwin) 0x0300 else 0x0030;

// Local flags (c_lflag)
const ECHO:   TermiosFlag = 0x0008; // same on both
const ECHONL: TermiosFlag = if (is_darwin) 0x0010 else 0x0040;
const ICANON: TermiosFlag = if (is_darwin) 0x0100 else 0x0002;
const ISIG:   TermiosFlag = if (is_darwin) 0x0080 else 0x0001;
const IEXTEN: TermiosFlag = if (is_darwin) 0x0400 else 0x8000;

// ioctl request codes
const TIOCGWINSZ: c_ulong = if (is_darwin) 0x40087468 else 0x5413;

const WinSize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    tab,
    ctrl_c,
    ctrl_d,
};

pub const TermSize = struct { rows: usize, cols: usize };

// ── Raw mode ──────────────────────────────────────────────────────────────────

pub const RawMode = struct {
    fd: c_int,
    orig: Termios,

    /// Enable raw mode on `fd`. Call disable() before exit to restore.
    pub fn enable(fd: c_int) !RawMode {
        var orig: Termios = undefined;
        if (tcgetattr(fd, &orig) != 0) return error.TcGetAttrFailed;

        var raw = orig;
        raw.c_iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
        raw.c_oflag &= ~OPOST;
        raw.c_cflag |= CS8;
        raw.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;

        if (tcsetattr(fd, TCSAFLUSH, &raw) != 0) return error.TcSetAttrFailed;
        return .{ .fd = fd, .orig = orig };
    }

    pub fn disable(self: *const RawMode) void {
        _ = tcsetattr(self.fd, TCSAFLUSH, &self.orig);
    }
};

// ── Key reading ───────────────────────────────────────────────────────────────

/// Read one logical key event. Blocks until a byte arrives.
/// Escape sequences (arrow keys) are detected with a 0.1 s timeout.
pub fn readKey(fd: c_int) !Key {
    var b: [1]u8 = undefined;
    const n = try std.posix.read(@intCast(fd), &b);
    if (n == 0) return error.EndOfFile;

    if (b[0] == '\x1b') {
        // Temporarily set VMIN=0, VTIME=1 (0.1 s) to detect escape sequences.
        var cur: Termios = undefined;
        _ = tcgetattr(fd, &cur);
        var nb = cur;
        nb.c_cc[VMIN] = 0;
        nb.c_cc[VTIME] = 1;
        _ = tcsetattr(fd, TCSANOW, &nb);
        defer _ = tcsetattr(fd, TCSANOW, &cur);

        var seq: [2]u8 = undefined;
        const sn = std.posix.read(@intCast(fd), &seq) catch return .escape;
        if (sn == 0) return .escape;
        if (seq[0] == '[' and sn >= 2) {
            return switch (seq[1]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .escape,
            };
        }
        return .escape;
    }

    return switch (b[0]) {
        '\r', '\n' => .enter,
        127, 8 => .backspace,
        '\t' => .tab,
        3 => .ctrl_c,
        4 => .ctrl_d,
        else => .{ .char = b[0] },
    };
}

// ── Terminal size ─────────────────────────────────────────────────────────────

pub fn getTermSize(fd: c_int) TermSize {
    var ws: WinSize = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

// ── Frame buffer ──────────────────────────────────────────────────────────────

/// Fixed-size render buffer. Accumulate ANSI + text, then flush() once per
/// frame to the terminal fd to avoid visible tearing.
pub const Frame = struct {
    buf: [32768]u8 = undefined,
    len: usize = 0,
    fd: c_int,

    pub fn init(fd: c_int) Frame {
        return .{ .fd = fd, .len = 0 };
    }

    /// Reset the buffer for the next frame.
    pub fn clear(self: *Frame) void {
        self.len = 0;
    }

    pub fn w(self: *Frame, data: []const u8) void {
        const n = @min(data.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], data[0..n]);
        self.len += n;
    }

    pub fn wfmt(self: *Frame, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }

    /// Write `text` padded/truncated to exactly `width` visible columns,
    /// replacing the last character with `…` when the text is too long.
    pub fn wPadElide(self: *Frame, text: []const u8, width: usize) void {
        if (width == 0) return;
        if (text.len <= width) {
            self.wPad(text, width);
            return;
        }
        // Truncate: show width-1 chars then a single-column ellipsis.
        if (width == 1) { self.w("…"); return; }
        self.w(text[0 .. width - 1]);
        self.w("…");
    }

    /// Write `text` padded/truncated to exactly `width` visible columns.
    pub fn wPad(self: *Frame, text: []const u8, width: usize) void {
        const n = @min(text.len, width);
        self.w(text[0..n]);
        var pad = width - n;
        const spaces = "                                                                ";
        while (pad > 0) {
            const chunk = @min(pad, spaces.len);
            self.w(spaces[0..chunk]);
            pad -= chunk;
        }
    }

    // ── ANSI helpers ──────────────────────────────────────────────────────────

    /// Switch to the terminal alternate screen buffer.
    /// The main screen (shell history, previous output) is preserved and
    /// restored automatically when leaveAltScreen is called.
    pub fn enterAltScreen(self: *Frame) void {
        self.w("\x1b[?1049h");
    }

    /// Return to the main screen buffer, restoring previous terminal content.
    pub fn leaveAltScreen(self: *Frame) void {
        self.w("\x1b[?1049l");
    }

    pub fn clearScreen(self: *Frame) void {
        self.w("\x1b[2J\x1b[H");
    }

    pub fn moveTo(self: *Frame, row: usize, col: usize) void {
        self.wfmt("\x1b[{d};{d}H", .{ row, col });
    }

    pub fn clearEol(self: *Frame) void {
        self.w("\x1b[K");
    }

    pub fn reverseVideo(self: *Frame) void {
        self.w("\x1b[7m");
    }

    pub fn bold(self: *Frame) void {
        self.w("\x1b[1m");
    }

    pub fn attrsOff(self: *Frame) void {
        self.w("\x1b[0m");
    }

    pub fn hideCursor(self: *Frame) void {
        self.w("\x1b[?25l");
    }

    pub fn showCursor(self: *Frame) void {
        self.w("\x1b[?25h");
    }

    pub fn flush(self: *const Frame) void {
        _ = write(self.fd, self.buf[0..self.len].ptr, self.len);
    }
};
