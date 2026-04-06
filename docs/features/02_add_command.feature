Feature: Add a Command to the Memento Store
  As a developer
  I want to save shell commands with a label
  So that I can recall and execute them instantly later

  Background:
    Given the mm shell wrapper is installed
    And the memento database is initialized

  # --- Happy Paths ---

  Scenario: Add a simple command with a label (short flag)
    When I run "mm -a build 'cargo build --release'"
    Then the command "cargo build --release" is stored with label "build"
    And the output confirms "Added: build → cargo build --release"

  Scenario: Add a simple command with a label (long flag)
    When I run "mm --add build 'cargo build --release'"
    Then the command "cargo build --release" is stored with label "build"
    And the output confirms "Added: build → cargo build --release"

  Scenario: Add a command with a numeric label
    When I run "mm -a 1 'git status'"
    Then the command "git status" is stored with label "1"
    And the output confirms "Added: 1 → git status"

  Scenario: Add a command and mark it as universal (flag at end)
    When I run "mm -a greet 'echo hello world' --universal"
    Then the command is stored with label "greet" and scope "universal"
    And the output confirms the command is marked as universal

  Scenario: Add a command and mark it as universal (flag at beginning)
    When I run "mm --universal -a greet 'echo hello world'"
    Then the command is stored with label "greet" and scope "universal"
    And the output confirms the command is marked as universal

  Scenario: Add a command and mark it as universal (flag in the middle)
    When I run "mm -a greet --universal 'echo hello world'"
    Then the command is stored with label "greet" and scope "universal"
    And the output confirms the command is marked as universal

  Scenario: Add a command and mark it as shell-specific
    Given the current shell is "fish"
    When I run "mm -a fishfuncs 'funcsave my_func' --shell fish"
    Then the command is stored with label "fishfuncs" and scope "fish"

  Scenario: Add a command with the current shell inferred automatically
    Given the current shell is "zsh"
    When I run "mm -a zshtest 'autoload -Uz compinit'"
    Then the command is stored with label "zshtest" and scope "zsh"

  Scenario: Add a template command with placeholders
    When I run "mm -a kgp 'kubectl get pods --namespace {ns}'"
    Then the command "kubectl get pods --namespace {ns}" is stored with label "kgp"
    And the command is marked as a template
    And the placeholder "ns" is recorded

  Scenario: Add a command interactively via prompt
    When I run "mm -a"
    Then I am prompted for a label
    And I enter "deploy"
    And I am prompted for the command
    And I enter "kubectl apply -f k8s/"
    Then the command is stored with label "deploy"
    And the output confirms "Added: deploy → kubectl apply -f k8s/"

  Scenario: Add a command with an optional description
    When I run "mm -a test 'npm test' --description 'Run the full test suite'"
    Then the command is stored with label "test"
    And the description "Run the full test suite" is saved alongside it

  Scenario: Add a multi-word command without quoting (shell passes args)
    When I run "mm -a ls ls -la"
    Then the command "ls -la" is stored with label "ls"

  Scenario: Add a command with special shell characters
    When I run "mm -a pipecmd 'ps aux | grep nginx'"
    Then the command "ps aux | grep nginx" is stored with label "pipecmd"

  # --- Edge Cases ---

  Scenario: Reject adding a command when the label already exists
    Given a command with label "build" already exists in the store
    When I run "mm -a build 'make all'"
    Then the exit code is non-zero
    And the error output contains "Label 'build' already exists"
    And the error output suggests using "mm -e build" or "--force"

  Scenario: Overwrite an existing command using --force
    Given a command with label "build" already exists
    When I run "mm -a build 'make all' --force"
    Then the old command for label "build" is replaced with "make all"
    And the output confirms "Updated: build → make all"

  Scenario: Reject a label containing spaces
    When I run "mm -a 'my label' 'echo hi'"
    Then the exit code is non-zero
    And the error output contains "Label must not contain spaces"

  Scenario: Reject an empty command string
    When I run "mm -a emptycmd ''"
    Then the exit code is non-zero
    And the error output contains "Command must not be empty"

  Scenario: Reject an empty label
    When I run "mm -a '' 'echo hi'"
    Then the exit code is non-zero
    And the error output contains "Label must not be empty"

  Scenario: No labels are reserved — any string is a valid label
    When I run "mm -a init 'echo something'"
    Then the command "echo something" is stored with label "init"
    And the output confirms "Added: init → echo something"
