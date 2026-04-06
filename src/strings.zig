/// User-facing strings for the mm CLI and TUI.
///
/// Centralising strings here makes it easy to change wording or adapt the
/// tool for a different locale.  Format strings (containing `{s}`, `{d}`, …)
/// are compatible with `std.fmt.bufPrint` because `pub const` values are
/// comptime-known.

// ── Commands TUI ──────────────────────────────────────────────────────────────

pub const cmd_help_title = "  memento — keyboard shortcuts";
pub const cmd_hint       = "  [j/k]nav  [i]info  [Enter]desc  [e]edit  [d]del  [a]add  [/]filter  [A]all  [Tab]history  [?]help  [q]quit";

pub const cmd_header_fmt      = "  memento  {d}/{d}{s}{s}";
pub const cmd_header_fallback = "  memento";
pub const cmd_tag_all_scopes  = " [all scopes]";
pub const cmd_tag_filtered    = " [filtered]";

pub const cmd_prompt_new_label = "  New label: ";
pub const cmd_prompt_label     = "  Label: ";
pub const cmd_prompt_command   = "  Command: ";
pub const cmd_prompt_desc      = "  Description (optional): ";
pub const cmd_prompt_delete_fmt      = "  Delete '{s}'? [y/N] ";
pub const cmd_prompt_delete_fallback = "  Delete? [y/N] ";

pub const cmd_info_title_fmt      = "  {s}";
pub const cmd_info_title_fallback = "  Record";
pub const cmd_info_close          = "  Press any key to close.";
pub const cmd_filter_prefix       = "  /{s}";
pub const cmd_filter_fallback     = "  /";

// ── History TUI ───────────────────────────────────────────────────────────────

pub const hist_help_title = "  memento — history keyboard shortcuts";
pub const hist_hint       = "  [j/k]nav  [a]add  [e]edit+add  [/]filter  [D]dedup  [Tab]commands  [?]help  [q]quit";

pub const hist_header_fmt      = "  memento — history  {d} entries{s}{s}";
pub const hist_header_fallback = "  memento — history";
pub const hist_tag_dedup_off   = " [dedup off]";
pub const hist_tag_filtered    = " [filtered]";

pub const hist_prompt_command = "  Command: ";
pub const hist_prompt_label   = "  Label: ";
pub const hist_prompt_desc    = "  Description (optional): ";

pub const hist_msg_saved_fmt          = "  Saved as '{s}'";
pub const hist_msg_saved_fallback     = "  Saved.";
pub const hist_msg_exists_fmt         = "  Label '{s}' already exists. Use mm -e to overwrite.";
pub const hist_msg_exists_fallback    = "  Label already exists.";

pub const hist_filter_prefix  = "  /{s}";
pub const hist_filter_fallback = "  /";

// ── Help / version ────────────────────────────────────────────────────────────

pub const help_any_key_return = "  Press any key to return.";
