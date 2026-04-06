Feature: Template Commands with Variable Placeholders
  As a developer
  I want to save parameterized commands with placeholders
  So that I can quickly run variations without retyping the whole command

  Background:
    Given the mm shell wrapper is installed
    And the memento database contains the following template commands:
      | label | command                                    | placeholders     |
      | kgp   | kubectl get pods --namespace {ns}          | ns               |
      | kgd   | kubectl get deployment {dep} -n {ns}       | dep, ns          |
      | sship | ssh {user}@{host} -p {port}                | user, host, port |
      | img   | docker build -t {name}:{tag} .             | name, tag        |

  # --- Single Placeholder ---

  Scenario: Execute a single-placeholder template with a positional argument
    Given the current shell is "bash"
    When I run "mm kgp my-namespace"
    Then the placeholder "{ns}" is replaced with "my-namespace"
    And the shell wrapper evals "kubectl get pods --namespace my-namespace"

  Scenario: Execute a single-placeholder template with a named argument
    When I run "mm kgp --ns my-namespace"
    Then the placeholder "{ns}" is replaced with "my-namespace"
    And the shell wrapper evals "kubectl get pods --namespace my-namespace"

  # --- Multiple Placeholders ---

  Scenario: Execute a multi-placeholder template with positional arguments in order
    When I run "mm kgd frontend production"
    Then "{dep}" is replaced with "frontend"
    And "{ns}" is replaced with "production"
    And the shell wrapper evals "kubectl get deployment frontend -n production"

  Scenario: Execute a multi-placeholder template with named arguments
    When I run "mm kgd --dep frontend --ns production"
    Then "{dep}" is replaced with "frontend"
    And "{ns}" is replaced with "production"
    And the shell wrapper evals "kubectl get deployment frontend -n production"

  Scenario: Execute a multi-placeholder template with named arguments in any order
    When I run "mm kgd --ns staging --dep api"
    Then the command evals "kubectl get deployment api -n staging"

  Scenario: Execute a three-placeholder template
    When I run "mm sship admin 10.0.0.1 22"
    Then the shell wrapper evals "ssh admin@10.0.0.1 -p 22"

  Scenario: Execute a two-placeholder docker image template
    When I run "mm img myapp latest"
    Then the shell wrapper evals "docker build -t myapp:latest ."

  # --- Dry Run ---

  Scenario: Preview a template substitution without executing
    When I run "mm kgp my-namespace --dry-run"
    Then the output shows "Would run: kubectl get pods --namespace my-namespace"
    And no command is executed

  # --- Adding Templates ---

  Scenario: Add a template command and detect placeholders automatically
    When I run "mm -a deploy 'helm upgrade {release} {chart} -n {ns}'"
    Then the command is stored with label "deploy"
    And the placeholders "release", "chart", "ns" are recorded automatically
    And the output confirms "Template command added with 3 placeholder(s): release, chart, ns"

  # --- Edge Cases ---

  Scenario: Reject execution when too few positional arguments are provided
    When I run "mm kgd frontend"
    Then the exit code is non-zero
    And the error output contains "Missing argument for placeholder: ns"
    And the error output shows usage: "mm kgd <dep> <ns>"

  Scenario: Reject execution when a named argument is missing
    When I run "mm kgd --dep frontend"
    Then the exit code is non-zero
    And the error output contains "Missing argument for placeholder: ns"

  Scenario: Warn when too many positional arguments are provided
    When I run "mm kgp ns1 extra-arg"
    Then the exit code is non-zero
    And the error output contains "Too many arguments: expected 1, got 2"

  Scenario: Placeholder names are case-sensitive
    Given a template command "upper" with command "echo {Name}"
    When I run "mm upper --name hello"
    Then the exit code is non-zero
    And the error output contains "Unknown placeholder: name (did you mean: Name?)"

  Scenario: A placeholder appearing multiple times is filled once
    Given a template command "dup" with command "echo {word} {word}"
    When I run "mm dup hello"
    Then the shell wrapper evals "echo hello hello"

  Scenario: Placeholder value containing spaces is quoted correctly
    When I run "mm kgp 'my namespace'"
    Then the shell wrapper evals "kubectl get pods --namespace 'my namespace'"

  Scenario: List template entry shows placeholder names
    When I run "mm -l kgd"
    Then the output shows placeholders: "dep, ns"
    And the output shows an example usage line

  Scenario: Edit a template to add a new placeholder
    Given a template command "kgp" exists with placeholder "{ns}"
    When I run "mm -e kgp"
    And I change the command to "kubectl get pods --namespace {ns} --context {ctx}"
    Then the updated placeholders "ns", "ctx" are recorded
    And executing "mm kgp staging prod-cluster" evals the fully substituted command
