Feature: List Saved Commands
  As a developer
  I want to view all my saved commands
  So that I can find the label I need to execute

  Background:
    Given the mm shell wrapper is installed
    And the memento database contains the following commands:
      | label   | command                             | scope      |
      | build   | cargo build --release               | universal  |
      | 1       | git status                          | universal  |
      | kgp     | kubectl get pods --namespace {ns}   | universal  |
      | fishfn  | funcsave my_func                    | fish       |
      | zshcomp | autoload -Uz compinit               | zsh        |
      | psdep   | Deploy-Module                       | powershell |

  # --- Happy Paths ---

  Scenario: List all commands when shell is fish (short flag)
    Given the current shell is "fish"
    When I run "mm -l"
    Then the output contains the "build" entry
    And the output contains the "1" entry
    And the output contains the "kgp" entry
    And the output contains the "fishfn" entry
    And the output does not contain the "zshcomp" entry
    And the output does not contain the "psdep" entry

  Scenario: List all commands when shell is fish (long flag)
    Given the current shell is "fish"
    When I run "mm --list"
    Then the output contains the "build" entry
    And the output contains the "fishfn" entry
    And the output does not contain the "zshcomp" entry

  Scenario: List all commands when shell is zsh
    Given the current shell is "zsh"
    When I run "mm -l"
    Then the output contains the "build" entry
    And the output contains the "zshcomp" entry
    And the output does not contain the "fishfn" entry
    And the output does not contain the "psdep" entry

  Scenario: List all commands regardless of shell using --all
    Given the current shell is "fish"
    When I run "mm -l --all"
    Then the output contains the "fishfn" entry
    And the output contains the "zshcomp" entry
    And the output contains the "psdep" entry
    And the output contains the "build" entry

  Scenario: List output includes label, command, and scope columns
    Given the current shell is "bash"
    When I run "mm -l"
    Then each row shows the label, the command string, and the scope
    And template commands are visually marked (e.g., with a "{}" indicator)

  Scenario: List commands filtered by a search term
    Given the current shell is "bash"
    When I run "mm -l kubectl"
    Then only entries whose label or command contain "kubectl" are shown
    And the "kgp" entry is included in the output

  Scenario: List commands filtered by scope flag
    When I run "mm -l --scope fish"
    Then only fish-scoped commands are shown

  Scenario: List commands filtered to universal only
    When I run "mm -l --scope universal"
    Then only universal commands are shown
    And no shell-specific commands appear in the output

  Scenario: List commands showing only templates
    When I run "mm -l --templates"
    Then only template commands (those with placeholders) are shown
    And the "kgp" entry appears in the output

  Scenario: Show a single command's details by label
    When I run "mm -l kgp"
    And exactly one result matches the label "kgp"
    Then the full command is shown without truncation
    And the scope, description, and placeholder list are shown

  # --- Empty States ---

  Scenario: Empty list when no commands are saved
    Given the memento database is empty
    When I run "mm -l"
    Then the output contains "No commands saved yet"
    And the output suggests running "mm -a" to get started

  Scenario: Empty list after filtering with a term that matches nothing
    When I run "mm -l xyznonexistent"
    Then the output contains "No commands match"

  # --- Display Formatting ---

  Scenario: Long commands are truncated in the list view
    Given a command with a very long string (over 80 characters) is stored
    When I run "mm -l"
    Then the command is truncated with a trailing ellipsis in the list output

  Scenario: Full command is shown with --no-truncate flag
    Given a command with a very long string is stored
    When I run "mm -l --no-truncate"
    Then the full command string is displayed without truncation
