Feature: TUI History Viewer
  As a user who runs many commands
  I want an interactive history browser
  So I can find past commands and save them to memento without leaving the terminal

  # Invocation: `mm -H` / `mm --history` with no arguments on a TTY opens the
  # history TUI. All rendering happens on stderr / /dev/tty.
  # The TUI is a pure browser — history entries cannot be executed from within it.
  # Use the shell wrapper installed by `mm --init` to run commands.
  #
  # History is read from the shell history file (HISTFILE or shell default).
  # Entries are displayed oldest-at-top, newest-at-bottom.
  # The selection starts at the newest entry.
  #
  # ── Layout ─────────────────────────────────────────────────────────────────
  #
  #   ┌─ memento — history  150 entries ────────────────────────────────────┐
  #   │     148  git diff --stat HEAD~1                                     │
  #   │     149  kubectl get pods --namespace production                    │
  #   │  >  150  cargo build --release                                      │
  #   └─ [j/k]nav  [a]add  [e]edit+add  [/]filter  [D]dedup  [Tab]cmds  ──┘

  Background:
    Given the memento database has been initialized
    And the shell history contains:
      | entry                                     |
      | cargo build --release                     |
      | kubectl get pods --namespace production   |
      | git diff --stat HEAD~1                    |
      | docker ps -a                              |
      | grep -r "TODO" src/                       |

  # ── Opening ──────────────────────────────────────────────────────────────────

  Scenario: History TUI opens when mm -H is invoked with no arguments on a TTY
    When the user runs "mm -H" on a TTY
    Then the history TUI is displayed
    And the history list shows entries with oldest at top, newest at bottom
    And the newest entry is highlighted

  Scenario: History TUI does not open when stderr is not a TTY
    When the user runs "mm -H" with stderr piped
    Then the non-interactive history output is printed
    And no TUI is rendered

  # ── Closing ──────────────────────────────────────────────────────────────────

  Scenario: Pressing q quits the TUI
    When the user opens the history TUI
    And presses "q"
    Then the TUI closes
    And the exit code is 0
    And nothing is written to stdout

  # ── Navigation ───────────────────────────────────────────────────────────────
  #
  # j / ↓ moves toward older entries (down the screen toward lower indices).
  # k / ↑ moves toward newer entries (up the screen toward higher indices).

  Scenario: Pressing j moves the selection toward older entries
    When the user opens the history TUI
    And the newest entry is highlighted
    And presses "j"
    Then the next-older entry is highlighted

  Scenario: Pressing k moves the selection toward newer entries
    When the user opens the history TUI
    And the second-newest entry is highlighted
    And presses "k"
    Then the newest entry is highlighted

  Scenario: Arrow keys move the selection
    When the user opens the history TUI
    And presses the down arrow key
    Then the next entry is highlighted

  Scenario: G jumps to the oldest entry (top of list)
    When the user opens the history TUI
    And presses "G"
    Then the oldest history entry is highlighted

  Scenario: gg jumps to the newest entry (bottom of list)
    When the user opens the history TUI
    And the oldest entry is highlighted
    And presses "g" then "g"
    Then the newest history entry is highlighted

  # ── Add to memento store (a) ─────────────────────────────────────────────────
  #
  # Pressing a on any entry opens a two-prompt inline form:
  #   1. Label  — pre-filled with a suggestion derived from the command.
  #               The pre-filled text is replaced on the first keypress (replace-on-type).
  #   2. Description (optional) — starts empty; pressing Enter skips it.
  # Pressing Escape at either prompt cancels without saving.

  Scenario: Pressing a on an entry opens the label prompt
    When the user opens the history TUI
    And "cargo build --release" is highlighted
    And presses "a"
    Then an inline "Label:" prompt appears
    And the field is pre-filled with a suggestion such as "cargo-build"

  Scenario: The suggested label is replaced on the first keypress
    When the label prompt is shown with suggestion "cargo-build"
    And the user presses any printable key
    Then the suggestion is cleared and the typed character appears

  Scenario: Completing the add form saves the command to the memento store
    When the add form is shown for "cargo build --release"
    And the user accepts the suggested label "cargo-build" and presses "Enter"
    And presses "Enter" to skip the description
    Then the command is saved to memento with label "cargo-build"
    And a confirmation message "Saved as 'cargo-build'" is shown briefly
    And focus returns to the history list

  Scenario: A description entered during add is saved with the command
    When the add form is shown
    And the user enters label "build-release" and presses "Enter"
    And types "Release build via cargo" in the description field and presses "Enter"
    Then the saved command has description "Release build via cargo"

  Scenario: Pressing Escape in the label prompt cancels without saving
    When the add form is shown
    And the user presses "Escape" in the label prompt
    Then the add form closes
    And no command is written to the database

  Scenario: Attempting to add with an already-used label shows an error
    Given the memento store already has a command with label "cargo-build"
    When the user submits the add form with label "cargo-build"
    Then an error message appears: "Label 'cargo-build' already exists. Use mm -e to overwrite."
    And focus returns to the history list

  # ── Edit then add (e) ────────────────────────────────────────────────────────
  #
  # Pressing e opens a "Command:" edit prompt pre-filled with the selected entry.
  # The cursor is placed at the end; typing inserts rather than replacing.
  # After editing, the normal add form (label + description) follows.

  Scenario: Pressing e opens an inline command editor
    When the user opens the history TUI
    And "ssh admin@10.0.0.1 -p 22" is highlighted
    And presses "e"
    Then an inline "Command:" prompt appears pre-filled with "ssh admin@10.0.0.1 -p 22"

  Scenario: Typing in the command editor inserts rather than replacing
    When the command editor is shown with "ssh admin@10.0.0.1 -p 22"
    And the user presses a character key
    Then the character is inserted at the cursor position
    And the existing text is not cleared

  Scenario: Editing the command and adding saves the modified version
    When the command editor is shown for "ssh admin@10.0.0.1 -p 22"
    And the user changes it to "ssh {user}@{host} -p {port}" and presses "Enter"
    And enters label "sship" and presses "Enter"
    And presses "Enter" to skip description
    Then the command "ssh {user}@{host} -p {port}" is saved as a template with label "sship"

  Scenario: Pressing Escape in the command editor cancels without saving
    When the command editor is shown
    And the user presses "Escape"
    Then the command editor closes
    And no command is written to the database

  # ── Filter ───────────────────────────────────────────────────────────────────

  Scenario: Pressing / enters filter mode
    When the user opens the history TUI
    And presses "/"
    Then a filter input bar appears at the bottom
    And the cursor is in the input

  Scenario: Typing in filter mode narrows the history list
    When the user is in history filter mode
    And types "cargo"
    Then only history entries containing "cargo" are shown

  Scenario: After filtering the list fills the screen from the bottom up
    When the user is scrolled far into the history
    And enters a filter that matches a smaller set of entries
    Then the visible rows fill the screen rather than showing empty rows at the bottom

  Scenario: Pressing l confirms the filter and returns focus to the list
    When the user is in history filter mode with "cargo" typed
    And presses "l"
    Then filter mode exits
    And the filtered list remains visible
    And the selection moves to the newest matching entry

  Scenario: Pressing Enter confirms the filter
    When the user is in history filter mode
    And presses "Enter"
    Then filter mode exits
    And the filtered list remains visible

  Scenario: Pressing h clears the active filter
    When the user has an active history filter
    And presses "h"
    Then the filter is cleared
    And all history entries are shown

  Scenario: Pressing Escape in filter mode restores the previously committed filter
    When the user has an active filter "cargo"
    And the user presses "/" to enter filter mode and types "git"
    And presses "Escape"
    Then filter mode exits
    And the list shows the previously committed "cargo" filter result

  # ── Deduplication ────────────────────────────────────────────────────────────

  Scenario: Duplicate entries are collapsed by default
    Given the history contains "cargo build --release" three times
    When the user opens the history TUI
    Then "cargo build --release" appears only once in the list
    And the most recent occurrence is shown

  Scenario: Pressing D toggles deduplication off
    When the user opens the history TUI
    And presses "D"
    Then all occurrences of duplicate commands are shown
    And a "[dedup off]" indicator is visible in the header

  Scenario: Pressing D again re-enables deduplication
    When dedup is off
    And the user presses "D"
    Then duplicates are collapsed again
    And the "[dedup off]" indicator is no longer shown

  # ── View switching (Tab) ─────────────────────────────────────────────────────

  Scenario: Pressing Tab switches to the commands TUI
    When the user opens the history TUI
    And presses "Tab"
    Then the commands TUI is displayed

  Scenario: Pressing Tab in the commands TUI switches back to the history TUI
    When the user is in the commands TUI
    And presses "Tab"
    Then the history TUI is displayed

  # ── Help overlay ─────────────────────────────────────────────────────────────

  Scenario: Pressing ? shows the keybinding help overlay
    When the user opens the history TUI
    And presses "?"
    Then a help overlay is displayed listing all keybindings including:
      | key        | action                                   |
      | j / ↓      | move down (toward older entries)         |
      | k / ↑      | move up (toward newer entries)           |
      | G          | jump to oldest entry                     |
      | gg         | jump to newest entry                     |
      | a          | save entry to memento store              |
      | e          | edit command, then save to memento store |
      | /          | start filter                             |
      | l / Enter  | confirm filter                           |
      | h / Esc    | clear filter                             |
      | D          | toggle deduplication                     |
      | Tab        | switch to commands view                  |
      | ?          | toggle this help                         |
      | q          | quit                                     |

  Scenario: Pressing any key closes the help overlay
    When the help overlay is shown
    And the user presses any key
    Then the help overlay closes
    And the history list is shown again
