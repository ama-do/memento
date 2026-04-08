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
    /// Title / header bar.
    header: []const u8,
    /// Column header row (label / command / scope names + sort indicator).
    col_header: []const u8,
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

/// Tokyo Night theme (256-colour approximation).
///
/// Colour mapping used:
///   60  ≈ #3d59a1  dark blue      (header / prompt background)
///   111 ≈ #7aa2f7  blue           (selected row foreground)
///   146 ≈ #a9b1d6  fg_dark        (popup body foreground)
///   189 ≈ #c0caf5  fg             (header / popup title foreground)
///   234 ≈ #1a1b26  bg             (popup body background)
///   235 ≈ #1e1f2e  slightly lighter bg
///   236 ≈ #292e42  bg_highlight   (selected / col-header background)
///   61  ≈ #565f89  comment        (col-header foreground)
pub const default = Theme{
    .header      = "\x1b[48;5;60m\x1b[38;5;189m\x1b[1m",  // dark-blue bg, light fg, bold
    .col_header  = "\x1b[48;5;236m\x1b[38;5;61m\x1b[1m",   // highlight bg, comment fg, bold
    .selected    = "\x1b[48;5;236m\x1b[38;5;111m\x1b[1m",  // highlight bg, blue fg, bold
    .prompt      = "\x1b[48;5;60m\x1b[38;5;189m",           // dark-blue bg, light fg
    .popup_title = "\x1b[48;5;60m\x1b[38;5;189m\x1b[1m",   // dark-blue bg, light fg, bold
    .popup_body  = "\x1b[48;5;235m\x1b[38;5;146m",          // bg, fg_dark
    .reset       = "\x1b[0m",                                // all attrs off
};
