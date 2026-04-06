/// TUI colour theme — all ANSI escape sequences in one place.
///
/// To change the look of the entire TUI, edit the `default` constant below.
/// Swap escape sequences or add new ones; the rest of the code uses these
/// semantic names instead of raw ANSI strings.
///
/// Each field is an ANSI SGR sequence string.  The rendering code writes these
/// directly into the frame buffer with `frame.w(theme.X)`.

/// Semantic roles used throughout the TUI.
pub const Theme = struct {
    /// Title / header bar (typically reverse-video + bold).
    header: []const u8,
    /// Currently-selected list row.
    selected: []const u8,
    /// Inline prompt rows (readLine, showMessage, status bar).
    prompt: []const u8,
    /// Popup title row.
    popup_title: []const u8,
    /// Popup body rows (fields, blank separator, close hint).
    popup_body: []const u8,
    /// Reset — all attributes off.
    reset: []const u8,
};

/// Default theme: reverse video for interactive elements, bold for titles.
pub const default = Theme{
    .header      = "\x1b[7m\x1b[1m", // reverse + bold
    .selected    = "\x1b[7m",         // reverse
    .prompt      = "\x1b[7m",         // reverse
    .popup_title = "\x1b[7m\x1b[1m", // reverse + bold
    .popup_body  = "\x1b[7m",         // reverse
    .reset       = "\x1b[0m",         // all attrs off
};
