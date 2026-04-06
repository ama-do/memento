Feature: TUI Commands Browser
  As a user with saved commands
  I want an interactive command browser
  So I can browse, view, add, edit, and delete commands without leaving the terminal

  # Invocation: `mm` with no arguments when stderr is a TTY opens the commands TUI.
  # `mm --help` and `mm -h` always print help text regardless of TTY state.
  # All rendering and input happen on stderr / /dev/tty.
  # The TUI is a pure browser — commands cannot be executed from within it.
  # To execute a command use the shell wrapper installed by `mm --init`.
  #
  # ── Layout ─────────────────────────────────────────────────────────────────
  #
  #   ┌─ memento  3/12 ──────────────────────────────────────────────────────┐
  #   │   deploy    {} helm upgrade {release} {chart} -n {ns}  [universal]  │
  #   │ > kgp          kubectl get pods --namespace {ns}        [universal]  │
  #   │   build…       cargo build --release                    [universal]  │
  #   └─ [j/k]nav  [i]info  [Enter]desc  [e]edit  [d]del  [a]add  ...      ─┘
  #
  # Labels and commands longer than their column width are elided with …
  # A ¶ marker replaces the {} marker when a row is showing its description.

  Background:
    Given the memento database has been initialized
    And the following commands exist:
      | label  | command                                 | description          | scope     |
      | deploy | helm upgrade {release} {chart} -n {ns} | Deploy a Helm chart  | universal |
      | kgp    | kubectl get pods --namespace {ns}       |                      | universal |
      | build  | cargo build --release                   | Release build        | universal |
      | test   | cargo test                              |                      | universal |

  # ── Opening ──────────────────────────────────────────────────────────────────

  Scenario: TUI opens when mm is invoked with no arguments on a TTY
    When the user runs "mm" on a TTY
    Then the TUI is displayed
    And the command list shows all saved commands
    And the first command is highlighted

  Scenario: mm --help always prints help text, never opens the TUI
    When the user runs "mm --help" on a TTY
    Then the help text is printed to stderr
    And no TUI is rendered

  Scenario: mm -h always prints help text, never opens the TUI
    When the user runs "mm -h" on a TTY
    Then the help text is printed to stderr
    And no TUI is rendered

  Scenario: TUI does not open when stderr is not a TTY
    When the user runs "mm" with stderr piped
    Then the help text is printed
    And no TUI is rendered

  # ── Closing ──────────────────────────────────────────────────────────────────

  Scenario: Pressing q quits the TUI
    When the user opens the TUI
    And presses "q"
    Then the TUI closes
    And the exit code is 0
    And nothing is written to stdout

  # ── Navigation ───────────────────────────────────────────────────────────────

  Scenario: Pressing j moves the selection down one row
    When the user opens the TUI
    And presses "j"
    Then the second command is highlighted

  Scenario: Pressing k moves the selection up one row
    When the user opens the TUI
    And the second command is highlighted
    And presses "k"
    Then the first command is highlighted

  Scenario: Arrow keys move the selection
    When the user opens the TUI
    And presses the down arrow key
    Then the second command is highlighted

  Scenario: Selection wraps from last to first
    When the user opens the TUI
    And the last command is highlighted
    And presses "j"
    Then the first command is highlighted

  Scenario: G jumps to the last command
    When the user opens the TUI
    And presses "G"
    Then the last command is highlighted

  Scenario: gg jumps to the first command
    When the user opens the TUI
    And the last command is highlighted
    And presses "g" then "g"
    Then the first command is highlighted

  # ── Description toggle (Enter) ───────────────────────────────────────────────
  #
  # Enter swaps the command text on the selected row for its description.
  # Pressing Enter again collapses it back.
  # If the command has no description, Enter does nothing.

  Scenario: Pressing Enter on a command with a description toggles the description
    When the user opens the TUI
    And "deploy" is highlighted
    And presses "Enter"
    Then the "deploy" row shows "Deploy a Helm chart" instead of the command text
    And a ¶ marker appears where the {} marker was

  Scenario: Pressing Enter again on an expanded row collapses it
    When the "deploy" row is showing its description
    And the user presses "Enter"
    Then the "deploy" row shows the command text again

  Scenario: Pressing Enter on a command with no description does nothing
    When the user opens the TUI
    And "kgp" is highlighted
    And presses "Enter"
    Then the "kgp" row still shows its command text

  # ── Info popup (i) ───────────────────────────────────────────────────────────
  #
  # i shows a centered reverse-video popup with all fields of the selected record.
  # Long values are word-wrapped inside the popup — no truncation.

  Scenario: Pressing i shows a full-record popup for the selected command
    When the user opens the TUI
    And "deploy" is highlighted
    And presses "i"
    Then a centered popup appears showing:
      | field        | value                                   |
      | Label        | deploy                                  |
      | Command      | helm upgrade {release} {chart} -n {ns} |
      | Description  | Deploy a Helm chart                     |
      | Scope        | universal                               |
      | Placeholders | release, chart, ns                      |
    And "Press any key to close." is shown at the bottom of the popup

  Scenario: Pressing any key closes the info popup
    When the info popup is displayed
    And the user presses any key
    Then the popup closes
    And the command list is shown again

  Scenario: Info popup wraps long command values across multiple lines
    Given a command with a very long command string
    When the user presses "i"
    Then the full command text is visible in the popup, wrapped to fit

  # ── Long text elision ────────────────────────────────────────────────────────

  Scenario: Labels longer than the column width are elided with …
    Given a command with label "my-very-long-label-that-exceeds-column"
    When the user opens the TUI
    Then the label column shows "my-very-long-label…" (or similar truncation)

  Scenario: Commands longer than the column width are elided with …
    Given a command whose text is wider than the available column
    When the user opens the TUI
    Then the command column shows the text ending with …

  # ── Filter ───────────────────────────────────────────────────────────────────

  Scenario: Pressing / enters filter mode
    When the user opens the TUI
    And presses "/"
    Then a filter input bar appears at the bottom of the screen
    And the cursor is placed in the input

  Scenario: Typing in filter mode narrows the visible commands
    When the user is in filter mode
    And types "cargo"
    Then only commands containing "cargo" are shown

  Scenario: After filtering the list fills the screen from the bottom up
    When the user is scrolled far down in a long list
    And enters a filter that matches a smaller set of entries
    Then the visible rows fill the screen rather than showing empty rows at the bottom

  Scenario: Pressing l confirms the filter and returns focus to the list
    When the user is in filter mode
    And presses "l"
    Then filter mode exits
    And the filtered list remains visible

  Scenario: Pressing Enter confirms the filter and returns focus to the list
    When the user is in filter mode
    And presses "Enter"
    Then filter mode exits
    And the filtered list remains visible

  Scenario: Pressing h clears the active filter
    When the user has an active filter
    And presses "h"
    Then the filter is cleared
    And all commands are shown

  Scenario: Pressing Escape in filter mode restores the previously committed filter
    When the user has an active filter "cargo"
    And the user presses "/" to enter filter mode and types "git"
    And presses "Escape"
    Then filter mode exits
    And the list shows the previously committed "cargo" filter result

  # ── Scope toggle ─────────────────────────────────────────────────────────────

  Scenario: TUI shows only current-shell commands plus universal ones by default
    When the user opens the TUI in fish shell
    Then fish-scoped commands appear alongside universal commands
    And bash-scoped commands do not appear

  Scenario: Pressing A toggles showing all commands regardless of scope
    When the user opens the TUI
    And presses "A"
    Then commands from all scopes are shown
    And a "[all scopes]" indicator appears in the header

  # ── Add (a) ──────────────────────────────────────────────────────────────────
  #
  # Three sequential inline prompts: Label → Command → Description (optional).
  # Pressing Escape at any prompt cancels the entire operation.

  Scenario: Pressing a opens the add form
    When the user opens the TUI
    And presses "a"
    Then an inline prompt appears asking for "New label:"

  Scenario: Completing the add form saves the command and refreshes the list
    When the user fills in label "greet", command "echo hello", and no description
    And submits the form
    Then "greet" appears in the list with command "echo hello"

  Scenario: A description entered during add is saved with the command
    When the user fills in label "greet", command "echo hello", and description "Greet the world"
    Then the saved command has description "Greet the world"

  Scenario: Pressing Escape during add cancels without saving
    When the label prompt is shown
    And the user presses "Escape"
    Then the add form closes
    And no new command is written to the database

  # ── Edit (e) ──────────────────────────────────────────────────────────────────
  #
  # Three sequential inline prompts: Label → Command → Description.
  # All fields are pre-filled with the current values; the cursor starts at the
  # end of each field and typing inserts rather than replacing.
  # Submitting an empty field keeps the original value (clears description if
  # description field was previously set and is now cleared).
  # Pressing Escape at any prompt cancels the entire operation.

  Scenario: Pressing e opens the edit form pre-filled with current values
    When the user opens the TUI
    And "build" is highlighted
    And presses "e"
    Then a "Label:" prompt appears pre-filled with "build"
    And a "Command:" prompt appears pre-filled with "cargo build --release"
    And a "Description:" prompt appears pre-filled with "Release build"

  Scenario: Typing in an edit prompt inserts rather than replacing the value
    When the "Command:" edit prompt is shown with "cargo build --release"
    And the user presses a character key
    Then the character is inserted at the cursor position
    And the existing text is not cleared

  Scenario: Changing the label renames the command
    When the user edits "build" and submits a new label "release-build"
    Then the command previously named "build" is now accessible as "release-build"

  Scenario: Changing the command updates the stored value
    When the user edits "build" and submits a new command "cargo build --release --target x86_64"
    Then "build" now runs "cargo build --release --target x86_64"

  Scenario: Clearing the description field removes the description
    When the user edits "deploy", clears the description field, and submits
    Then the "deploy" command has no description

  Scenario: Pressing Escape during edit cancels without saving
    When the "Label:" edit prompt is shown
    And the user presses "Escape"
    Then the edit form closes
    And the command is unchanged in the database

  Scenario: Submitting unchanged values produces no database write
    When the user opens the edit form for "build"
    And presses "Enter" on all three prompts without changing anything
    Then the command is unchanged in the database

  # ── Delete (d) ───────────────────────────────────────────────────────────────

  Scenario: Pressing d prompts for delete confirmation
    When the user opens the TUI
    And "build" is highlighted
    And presses "d"
    Then a confirmation prompt appears

  Scenario: Confirming delete with y removes the command
    When the delete confirmation prompt is shown for "build"
    And the user types "y" and presses "Enter"
    Then "build" is removed from the database
    And the list refreshes without "build"

  Scenario: Pressing n at the delete prompt cancels
    When the delete confirmation prompt is shown for "build"
    And the user types "n"
    Then "build" remains in the database

  # ── View switching (Tab) ─────────────────────────────────────────────────────

  Scenario: Pressing Tab switches to the history TUI
    When the user opens the commands TUI
    And presses "Tab"
    Then the history TUI is displayed

  Scenario: Pressing Tab in the history TUI switches back to the commands TUI
    When the user is in the history TUI
    And presses "Tab"
    Then the commands TUI is displayed

  # ── Help overlay ─────────────────────────────────────────────────────────────

  Scenario: Pressing ? shows the keybinding help overlay
    When the user opens the TUI
    And presses "?"
    Then a help overlay is displayed listing all keybindings including:
      | key        | action                                   |
      | j / ↓      | move down                                |
      | k / ↑      | move up                                  |
      | G          | jump to last                             |
      | gg         | jump to first                            |
      | i          | show full record popup                   |
      | Enter      | toggle description inline                |
      | e          | edit label / command / description       |
      | d          | delete with confirmation                 |
      | a          | add new command                          |
      | /          | start filter                             |
      | l / Enter  | confirm filter                           |
      | h / Esc    | clear filter                             |
      | A          | toggle all scopes                        |
      | Tab        | switch to history view                   |
      | ?          | toggle this help                         |
      | q          | quit                                     |

  Scenario: Pressing any key closes the help overlay
    When the help overlay is shown
    And the user presses any key
    Then the help overlay closes
    And the command list is shown again
