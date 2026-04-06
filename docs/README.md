# Memento (`mm`) — BDD Specification

This directory contains the Behavior-Driven Development (BDD) specification for
the `mm` (memento) CLI tool, written in Gherkin syntax.

## What is Memento?

`mm` is a CLI tool for bookmarking and executing shell commands. It solves the
problem of finding previously-run commands across multiple projects and sessions
without scrolling through shell history. Commands are saved with short labels
and can be executed instantly.

```sh
mm build         # runs: cargo build --release
mm 1             # runs: git status
mm kgp staging   # runs: kubectl get pods --namespace staging
```

## Feature Files

| File | Feature Area |
|------|-------------|
| `features/01_setup.feature` | Installation and shell wrapper setup |
| `features/02_add_command.feature` | Adding commands to the store |
| `features/03_list_commands.feature` | Listing and filtering saved commands |
| `features/04_execute_command.feature` | Executing commands by label |
| `features/05_template_commands.feature` | Parameterized template commands |
| `features/06_edit_delete_commands.feature` | Editing and deleting commands |
| `features/07_history_integration.feature` | Shell history browsing and import |
| `features/08_tui_commands.feature` | Interactive commands browser TUI |
| `features/09_tui_history.feature` | Interactive history viewer TUI |

## Command Reference

All operations use flags. No labels are reserved — any string is valid.

| Operation | Short | Long |
|-----------|-------|------|
| Execute label | `mm <label>` | — |
| Add | `mm -a <label> <cmd>` | `mm --add <label> <cmd>` |
| List | `mm -l [term]` | `mm --list [term]` |
| Edit | `mm -e <label>` | `mm --edit <label>` |
| Delete | `mm -d <label>` | `mm --delete <label>` |
| History | `mm -H [term]` | `mm --history [term]` |
| Init (one-time) | `mm -i` | `mm --init` |
| Help | `mm -h` | `mm --help` |

### Why flags instead of subcommands?

The primary use case is `mm <label>`, which runs the saved command. Any
subcommand name becomes a label users cannot use. With a pure flag-based
design, the entire label namespace is free — users can save labels named
`add`, `list`, `init`, `deploy`, `build`, etc. without conflict.

## Key Architectural Decision: Shell Eval Wrapper

A subprocess (the `mm` binary) cannot modify the state of its parent shell. To
allow `cd`, `export`, and other stateful commands to work correctly — and to
execute commands in the user's actual shell environment — `mm` uses a shell
wrapper function.

The wrapper is installed via `mm init` and works as follows:

1. The shell wrapper function intercepts calls to `mm`.
2. The real `mm` binary is invoked as a subprocess.
3. The binary resolves the label, substitutes any template placeholders, and
   prints the final command string to **stdout**.
4. The shell wrapper captures stdout and passes it to `eval`.
5. All human-readable output (errors, lists, prompts) is written to **stderr**
   so the `eval` path is never polluted.

**Fish:**
```fish
function mm
    eval (command mm $argv)
end
```

**Bash / Zsh:**
```bash
function mm() {
    eval "$(command mm "$@")"
}
```

**PowerShell:**
```powershell
function mm {
    Invoke-Expression (& (Get-Command mm -CommandType Application).Source @args)
}
```

### Wrapper detection

When `mm init` writes the wrapper it wraps it in marker comments:

```bash
# mm-memento-begin
function mm() { eval "$(command mm "$@")"; }
# mm-memento-end
```

Re-running `mm init` greps for `# mm-memento-begin` in the relevant config
file to detect an existing installation without shell-specific logic.

`mm init --verify` checks whether `mm` is currently defined as a shell
function in the active session (using `type mm` or the shell equivalent),
which confirms both that the wrapper is present in config *and* has been
sourced.

## Storage

Commands are stored in a SQLite database. The default location follows OS
conventions:

| Platform | Default Path |
|----------|-------------|
| Linux / macOS | `$XDG_DATA_HOME/memento/db.sqlite` (fallback: `~/.local/share/memento/db.sqlite`) |
| Windows | `%APPDATA%\memento\db.sqlite` |

## Shell Support

| Shell | Scope Name | History File |
|-------|-----------|-------------|
| bash | `bash` | `$HISTFILE` / `~/.bash_history` |
| zsh | `zsh` | `$HISTFILE` / `~/.zsh_history` |
| fish | `fish` | `~/.local/share/fish/fish_history` |
| PowerShell | `powershell` | PSReadLine history file |
| (any) | `universal` | — |

Commands marked `universal` appear in all shells. Shell-specific commands only
appear when that shell is active. Use `mm -l --all` to see every command
regardless of current shell.

## Command Scope Rules

- When **adding** a command, the current shell is used as the default scope.
  Pass `--universal` to make it available in all shells (the flag can appear
  anywhere in the argument list), or `--shell <name>` to target a different
  shell explicitly.
- When **listing**, `mm -l` shows universal commands plus commands for the
  current shell. `mm -l --all` shows everything.
- When **executing**, running a shell-specific command in the wrong shell
  produces an error. Use `--force` to override.

## Template Commands

Commands can contain `{placeholder}` tokens:

```sh
mm -a kgp 'kubectl get pods --namespace {ns}'
mm kgp production          # positional: fills {ns} = production
mm kgp --ns production     # named argument form
```

Placeholders are detected automatically when a command is added. Multiple
placeholders are filled in left-to-right order for positional arguments, or by
name when using `--name value` flags.

## Interactive TUI

`mm` ships two interactive terminal UIs. Both open on a TTY and render entirely
on stderr so the shell wrapper's stdout path is never polluted. Neither TUI
executes commands — selection always goes through the shell wrapper (`eval`).

### Commands browser (`mm`)

Opened by invoking `mm` with no arguments on a TTY. `mm --help` / `mm -h`
always prints help text and never opens the TUI.

| Key | Action |
|-----|--------|
| `j` / `↓` | Move selection down |
| `k` / `↑` | Move selection up |
| `G` | Jump to last command |
| `gg` | Jump to first command |
| `Enter` | Toggle description inline (only if a description exists; `¶` marker shown) |
| `i` | Show full-record popup (label, command, description, scope, placeholders — long values word-wrapped) |
| `e` | Edit: three sequential prompts pre-filled with current label → command → description; cursor at end, typing inserts |
| `d` | Delete with `[y/N]` confirmation |
| `a` | Add: three sequential prompts for label → command → description |
| `/` | Enter filter mode (live narrow-as-you-type) |
| `l` / `Enter` | Confirm filter |
| `h` / `Esc` | Clear filter |
| `A` | Toggle showing all scopes vs. current shell only |
| `Tab` | Switch to the history TUI |
| `?` | Help overlay |
| `q` / `Esc` | Quit |

Labels and command text that are wider than their column are elided with `…`.

### History viewer (`mm -H`)

Opened by `mm -H` / `mm --history` with no arguments on a TTY. Reads the
shell history file for the detected shell. Entries are displayed
oldest-at-top, newest-at-bottom; the selection starts at the newest entry.

| Key | Action |
|-----|--------|
| `j` / `↓` | Move toward older entries |
| `k` / `↑` | Move toward newer entries |
| `G` | Jump to oldest entry |
| `gg` | Jump to newest entry |
| `a` | Save selected entry to memento: prompts for label (replace-on-type suggestion) then optional description |
| `e` | Edit then save: opens command editor pre-filled (cursor at end, no replace-on-type), then label + description prompts |
| `/` | Enter filter mode |
| `l` / `Enter` | Confirm filter; selection moves to the newest matching entry |
| `h` / `Esc` | Clear filter |
| `D` | Toggle deduplication (default on: only the most recent occurrence of each command is shown) |
| `Tab` | Switch to the commands TUI |
| `?` | Help overlay |
| `q` | Quit |

After filtering, the list always fills the screen from the bottom up — no
empty rows at the bottom when there are entries above the viewport.

### View toggling

`Tab` switches between the two TUIs without returning to the shell. The
toggle loop is managed in `src/tui/mod.zig`; both `mm` and `mm -H` entry
points support toggling.

### Input line behaviour

All inline prompts (edit, add, filter, delete confirmation) use a shared
line-reader rendered in the status bar row. The cursor position is shown by
inverting the character under it (normal video against the reverse-video row).
The full row is always filled to the terminal width so the white background
extends edge-to-edge.

Two modes control how pre-filled text behaves:

- **Replace-on-type** (`replace_on_type = true`): the first printable keypress
  clears the pre-fill entirely. Used for suggested labels where the suggestion
  is usually discarded.
- **Insert** (`replace_on_type = false`): the cursor starts at the end of the
  pre-filled text and typing inserts normally. Used for editing existing values
  so the user can make incremental changes.
