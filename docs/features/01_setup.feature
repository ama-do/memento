Feature: Installation and Shell Integration Setup
  As a developer using multiple shells and projects
  I want to initialize the mm shell wrapper into my shell configuration
  So that commands executed by mm run in my current shell session

  Background:
    Given the "mm" binary is installed and available on PATH

  # --- Happy Paths ---

  Scenario: Initialize the shell wrapper for fish (short flag)
    Given the current shell is "fish"
    And the fish function directory is "~/.config/fish/functions"
    When I run "mm -i"
    Then a file "~/.config/fish/functions/mm.fish" is created
    And the file contains a fish function named "mm"
    And the function calls the "mm" binary and evals its output
    And the output confirms "Shell wrapper initialized for fish"

  Scenario: Initialize the shell wrapper for fish (long flag)
    Given the current shell is "fish"
    And the fish function directory is "~/.config/fish/functions"
    When I run "mm --init"
    Then a file "~/.config/fish/functions/mm.fish" is created
    And the output confirms "Shell wrapper initialized for fish"

  Scenario: Initialize the shell wrapper for bash
    Given the current shell is "bash"
    And "~/.bashrc" exists
    When I run "mm --init"
    Then a shell function definition is appended to "~/.bashrc"
    And the function is wrapped with a "# mm-memento-begin" / "# mm-memento-end" marker
    And the function calls the "mm" binary and evals its output
    And the output confirms "Shell wrapper initialized for bash"
    And the output advises the user to run "source ~/.bashrc"

  Scenario: Initialize the shell wrapper for zsh
    Given the current shell is "zsh"
    And "~/.zshrc" exists
    When I run "mm --init"
    Then a shell function definition is appended to "~/.zshrc"
    And the function is wrapped with a "# mm-memento-begin" / "# mm-memento-end" marker
    And the function calls the "mm" binary and evals its output
    And the output confirms "Shell wrapper initialized for zsh"
    And the output advises the user to run "source ~/.zshrc"

  Scenario: Initialize the shell wrapper for PowerShell
    Given the current shell is "powershell"
    And the PowerShell profile path exists
    When I run "mm --init"
    Then a PowerShell function named "mm" is added to the profile
    And the function is wrapped with a "# mm-memento-begin" / "# mm-memento-end" marker
    And the function calls the "mm" binary and evals its output
    And the output confirms "Shell wrapper initialized for PowerShell"

  Scenario: Detect already-initialized wrapper for fish and skip re-installation
    Given the current shell is "fish"
    And the fish wrapper "~/.config/fish/functions/mm.fish" already exists
    When I run "mm --init"
    Then the output confirms "Shell wrapper already initialized for fish"
    And the existing file is not modified

  Scenario: Detect already-initialized wrapper for bash and skip re-installation
    Given the current shell is "bash"
    And "~/.bashrc" already contains the "# mm-memento-begin" marker
    When I run "mm --init"
    Then the output confirms "Shell wrapper already initialized for bash"
    And "~/.bashrc" is not modified

  Scenario: Detect already-initialized wrapper for zsh and skip re-installation
    Given the current shell is "zsh"
    And "~/.zshrc" already contains the "# mm-memento-begin" marker
    When I run "mm --init"
    Then the output confirms "Shell wrapper already initialized for zsh"
    And "~/.zshrc" is not modified

  Scenario: Force re-initialize the wrapper when already installed
    Given the current shell is "fish"
    And the fish wrapper "~/.config/fish/functions/mm.fish" already exists
    When I run "mm --init --force"
    Then the existing wrapper file is overwritten
    And the output confirms "Shell wrapper reinitialized for fish"

  Scenario: Verify setup is working correctly using shell function detection
    Given the mm shell wrapper has been sourced in the current shell session
    When I run "mm --init --verify"
    Then the binary checks whether "mm" is defined as a shell function in the current shell
    And the output confirms "Shell wrapper is correctly initialized"
    And the output shows the wrapper file or config location

  Scenario: Verify detects that the wrapper is present in config but not yet sourced
    Given the current shell is "bash"
    And "~/.bashrc" contains the "# mm-memento-begin" marker
    But "mm" is not yet defined as a function in the current shell session
    When I run "mm --init --verify"
    Then the output confirms "Wrapper found in ~/.bashrc but not yet active"
    And the output advises the user to run "source ~/.bashrc"

  # --- Edge Cases ---

  Scenario: Attempt init when shell cannot be detected
    Given the SHELL environment variable is not set
    And the current process name does not indicate a known shell
    When I run "mm --init"
    Then the exit code is non-zero
    And the error output contains "Could not detect current shell"
    And the error output suggests running "mm --init --shell <name>"

  Scenario: Specify the shell explicitly during init
    Given the current shell cannot be detected automatically
    When I run "mm --init --shell zsh"
    Then a shell function definition is appended to "~/.zshrc"
    And the output confirms "Shell wrapper initialized for zsh"

  Scenario: Init with a custom config file path for bash
    Given the current shell is "bash"
    When I run "mm --init --config-file ~/.bash_profile"
    Then a shell function definition is appended to "~/.bash_profile"
    And the output confirms "Shell wrapper initialized for bash"

  Scenario: Init with a custom config file path for zsh
    Given the current shell is "zsh"
    When I run "mm --init --config-file ~/.zshenv"
    Then a shell function definition is appended to "~/.zshenv"
    And the output confirms "Shell wrapper initialized for zsh"

  Scenario: Init with a custom config file path for fish
    Given the current shell is "fish"
    When I run "mm --init --config-file ~/.config/fish/config.fish"
    Then the wrapper function definition is appended to "~/.config/fish/config.fish"
    And the output confirms "Shell wrapper initialized for fish"

  Scenario: Init with a custom config file path for PowerShell
    Given the current shell is "powershell"
    When I run "mm --init --config-file ~/Documents/PowerShell/profile.ps1"
    Then the wrapper function is appended to "~/Documents/PowerShell/profile.ps1"
    And the output confirms "Shell wrapper initialized for PowerShell"

  Scenario: Init initializes the SQLite database on first run
    Given no memento database file exists
    When I run "mm --init"
    Then the SQLite database file is created at the default location
    And the output mentions "Database initialized"

  Scenario: Display the correct eval wrapper explanation
    When I run "mm --init --explain"
    Then the output explains that child processes cannot modify parent shell state
    And the output explains that the wrapper function captures mm binary output and evals it
    And the output shows an example of the wrapper function for the detected shell
