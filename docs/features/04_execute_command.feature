Feature: Execute a Saved Command
  As a developer
  I want to run a saved command by its label
  So that I can avoid retyping or searching through shell history

  Background:
    Given the mm shell wrapper is installed and active in the current shell
    And the memento database contains the following commands:
      | label   | command                 | scope      |
      | build   | cargo build --release   | universal  |
      | 1       | git status              | universal  |
      | fishfn  | funcsave my_func        | fish       |
      | psdep   | Deploy-Module           | powershell |

  # --- Happy Paths ---

  Scenario: Execute a command by string label
    Given the current shell is "bash"
    When I run "mm build"
    Then the shell wrapper calls the mm binary
    And the binary outputs the command "cargo build --release" to stdout
    And the shell wrapper evals "cargo build --release"
    And "cargo build --release" runs in the current shell session

  Scenario: Execute a command by numeric label
    Given the current shell is "bash"
    When I run "mm 1"
    Then the shell wrapper evals "git status"
    And "git status" runs in the current shell session

  Scenario: Execute a universal command from any shell
    Given the current shell is "zsh"
    When I run "mm build"
    Then "cargo build --release" runs in the current shell session

  Scenario: Execute a fish-specific command in fish shell
    Given the current shell is "fish"
    When I run "mm fishfn"
    Then "funcsave my_func" runs in the current shell session

  Scenario: Execute a command and observe its exit code is forwarded
    Given the current shell is "bash"
    And the command stored under "build" exits with code 2
    When I run "mm build"
    Then the shell session's exit code is 2

  Scenario: Dry-run execution to preview the command without running it
    Given the current shell is "bash"
    When I run "mm build --dry-run"
    Then the output shows "Would run: cargo build --release"
    And the command is not actually executed

  # --- Shell Eval Architecture ---

  Scenario: The mm binary alone does not execute the command
    Given the shell wrapper is NOT active
    When the mm binary is called directly with "mm build"
    Then the binary prints the command string to stdout
    And the command is not executed in the parent shell
    And the output is intended to be consumed by the shell wrapper via eval

  Scenario: All human-readable output goes to stderr, not stdout
    When I run "mm -l"
    Then the list output is written to stderr
    And stdout contains only executable output (empty for a list command)

  Scenario: The shell wrapper intercepts mm calls and evals the result
    Given the mm fish wrapper function is defined as:
      """
      function mm
        eval (command mm $argv)
      end
      """
    When I invoke "mm build" through the fish wrapper
    Then "command mm build" is run as a subprocess returning "cargo build --release"
    And the fish wrapper evals "cargo build --release"

  Scenario: The bash/zsh wrapper intercepts mm calls and evals the result
    Given the mm bash wrapper function is defined as:
      """
      function mm() {
        eval "$(command mm "$@")"
      }
      """
    When I invoke "mm build" through the bash wrapper
    Then "command mm build" is run as a subprocess returning "cargo build --release"
    And the bash wrapper evals "cargo build --release"

  # --- Error Cases ---

  Scenario: Attempt to execute a non-existent label
    When I run "mm nonexistent"
    Then the exit code is non-zero
    And the error output contains "No command found with label 'nonexistent'"
    And the shell wrapper does not eval anything

  Scenario: Attempt to execute a fish-specific command in zsh
    Given the current shell is "zsh"
    When I run "mm fishfn"
    Then the exit code is non-zero
    And the error output contains "Command 'fishfn' is not available in zsh"
    And the error output suggests using "mm -l" to see available commands

  Scenario: Attempt to execute a PowerShell command in bash
    Given the current shell is "bash"
    When I run "mm psdep"
    Then the exit code is non-zero
    And the error output contains "Command 'psdep' is not available in bash"

  Scenario: Execute a shell-incompatible command using --force
    Given the current shell is "bash"
    When I run "mm fishfn --force"
    Then "funcsave my_func" is eval'd in the current shell session regardless of scope
    And a warning is printed to stderr: "Warning: running a fish-scoped command in bash"

  Scenario: Template command is rejected when run without arguments
    Given a template command "kgp" with placeholder "{ns}" exists
    When I run "mm kgp"
    Then the exit code is non-zero
    And the error output contains "Template requires argument for placeholder: ns"
    And the error output shows usage: "mm kgp <ns>"
