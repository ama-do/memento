Feature: Shell History Integration
  As a developer
  I want to browse my shell history and save a command directly into memento
  So that I can bookmark commands I have already run without retyping them

  Background:
    Given the mm shell wrapper is installed
    And the current shell history contains the following entries:
      | index | command                                    |
      | 1     | cargo build --release                      |
      | 2     | kubectl get pods --namespace production    |
      | 3     | git log --oneline --graph --all            |
      | 4     | docker compose up -d                       |
      | 5     | ssh admin@10.0.0.1 -p 22                   |

  # --- Happy Paths ---

  Scenario: View recent shell history entries (short flag)
    When I run "mm -H"
    Then the output lists recent shell history entries with an index number
    And each entry shows its index and command string

  Scenario: View recent shell history entries (long flag)
    When I run "mm --history"
    Then the output lists recent shell history entries with an index number
    And each entry shows its index and command string

  Scenario: View a limited number of history entries
    When I run "mm -H --last 3"
    Then only the 3 most recent history entries are shown

  Scenario: Save a history entry into memento by index
    When I run "mm -H --save 3"
    Then I am prompted "Label for 'git log --oneline --graph --all': "
    And I enter "gitlog"
    Then the command is saved with label "gitlog"
    And the output confirms "Added: gitlog → git log --oneline --graph --all"

  Scenario: Save a history entry with a label provided inline
    When I run "mm -H --save 3 --label gitlog"
    Then the command "git log --oneline --graph --all" is saved with label "gitlog"
    And no label prompt is shown

  Scenario: Save the most recent history entry
    When I run "mm -H --save --last"
    Then I am prompted for a label for "ssh admin@10.0.0.1 -p 22"
    And I enter "sshprod"
    Then the command is saved with label "sshprod"

  Scenario: Save a history entry and convert it to a template
    When I run "mm -H --save 5 --label sship --template"
    Then the $EDITOR opens with "ssh admin@10.0.0.1 -p 22" pre-filled
    And I change it to "ssh {user}@{host} -p {port}"
    And I save and close the editor
    Then the stored command is "ssh {user}@{host} -p {port}" with label "sship"
    And the command is detected as a template with placeholders: user, host, port

  Scenario: Search shell history before saving
    When I run "mm -H kubectl"
    Then only history entries containing "kubectl" are shown
    And the entry "kubectl get pods --namespace production" appears

  Scenario: Save a history search result into memento
    When I run "mm -H kubectl --save 1 --label kgp"
    Then the first "kubectl" result "kubectl get pods --namespace production" is saved with label "kgp"

  Scenario: Edit a history command before saving it
    When I run "mm -H --save 5 --label sship --edit"
    Then the $EDITOR opens with "ssh admin@10.0.0.1 -p 22" pre-filled
    And I change it to "ssh {user}@{host} -p {port}"
    And I save and close the editor
    Then the modified command "ssh {user}@{host} -p {port}" is saved with label "sship"

  # --- Shell-Specific History Sources ---

  Scenario: History is read from fish history when shell is fish
    Given the current shell is "fish"
    When I run "mm -H"
    Then the history entries are sourced from fish's history (~/.local/share/fish/fish_history)

  Scenario: History is read from bash history when shell is bash
    Given the current shell is "bash"
    When I run "mm -H"
    Then the history entries are sourced from "$HISTFILE" or "~/.bash_history"

  Scenario: History is read from zsh history when shell is zsh
    Given the current shell is "zsh"
    When I run "mm -H"
    Then the history entries are sourced from "$HISTFILE" or "~/.zsh_history"

  Scenario: History is read from PSReadLine history when shell is PowerShell
    Given the current shell is "powershell"
    When I run "mm -H"
    Then the history entries are sourced from the PSReadLine history file

  # --- Edge Cases ---

  Scenario: Attempt to save a history entry with an out-of-range index
    When I run "mm -H --save 999 --label test"
    Then the exit code is non-zero
    And the error output contains "No history entry at index 999"

  Scenario: Shell history is empty
    Given the current shell history is empty
    When I run "mm -H"
    Then the output contains "No shell history found"

  Scenario: History search returns no results
    When I run "mm -H xyznonexistent"
    Then the output contains "No history entries match 'xyznonexistent'"

  Scenario: History save with a label that already exists in memento
    Given a command with label "gitlog" already exists in the store
    When I run "mm -H --save 3 --label gitlog"
    Then the exit code is non-zero
    And the error output contains "Label 'gitlog' already exists"
    And the error output suggests using "--force" to overwrite

  Scenario: History save with a label that already exists, forced
    Given a command with label "gitlog" already exists in the store
    When I run "mm -H --save 3 --label gitlog --force"
    Then the existing "gitlog" command is replaced
    And the output confirms "Updated: gitlog → git log --oneline --graph --all"
