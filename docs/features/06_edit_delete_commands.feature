Feature: Edit and Delete Saved Commands
  As a developer
  I want to update or remove commands from my memento store
  So that I can keep my bookmarks accurate and uncluttered

  Background:
    Given the mm shell wrapper is installed
    And the memento database contains the following commands:
      | label   | command                           | scope      | description          |
      | build   | cargo build --release             | universal  | Build release binary |
      | deploy  | kubectl apply -f k8s/             | universal  |                      |
      | fishfn  | funcsave my_func                  | fish       |                      |
      | kgp     | kubectl get pods --namespace {ns} | universal  |                      |

  # --- Edit Happy Paths ---

  Scenario: Edit a command interactively (short flag)
    When I run "mm -e build"
    Then the $EDITOR (or "vi" if unset) opens with the current command "cargo build --release" pre-filled
    And I change the command to "cargo build --release --target x86_64-unknown-linux-musl"
    And I save and close the editor
    Then the stored command for "build" is updated
    And the output confirms "Updated: build"

  Scenario: Edit a command interactively (long flag)
    When I run "mm --edit build"
    Then the $EDITOR opens with the current command "cargo build --release" pre-filled
    And I change the command to "cargo build --release --target x86_64-unknown-linux-musl"
    And I save and close the editor
    Then the stored command for "build" is updated
    And the output confirms "Updated: build"

  Scenario: Edit a command non-interactively with --command flag
    When I run "mm -e build --command 'cargo build'"
    Then the stored command for "build" is updated to "cargo build"
    And the output confirms "Updated: build → cargo build"

  Scenario: Edit the label of a command
    When I run "mm -e build --label release-build"
    Then the label is renamed from "build" to "release-build"
    And the command text remains unchanged
    And the output confirms "Renamed: build → release-build"

  Scenario: Edit the scope of a command to make it universal
    When I run "mm -e fishfn --scope universal"
    Then the scope of "fishfn" is changed to "universal"
    And the output confirms "Updated: fishfn"

  Scenario: Edit the scope of a command to make it shell-specific
    When I run "mm -e build --scope fish"
    Then the scope of "build" is changed to "fish"

  Scenario: Edit the description of a command
    When I run "mm -e deploy --description 'Deploy all Kubernetes manifests'"
    Then the description for "deploy" is updated
    And the output confirms "Updated: deploy"

  Scenario: Edit a command using the $EDITOR environment variable
    Given the EDITOR environment variable is set to "nano"
    When I run "mm -e build"
    Then "nano" is opened with the command text in a temporary file

  Scenario: Edit falls back to "vi" when EDITOR is not set
    Given the EDITOR environment variable is not set
    When I run "mm -e build"
    Then "vi" is opened with the command text

  # --- Edit Edge Cases ---

  Scenario: Attempt to edit a non-existent label
    When I run "mm -e nonexistent"
    Then the exit code is non-zero
    And the error output contains "No command found with label 'nonexistent'"

  Scenario: Attempt to rename a label to one that already exists
    When I run "mm -e build --label deploy"
    Then the exit code is non-zero
    And the error output contains "Label 'deploy' already exists"
    And the error output suggests using "--force" to overwrite

  Scenario: Rename a label to one that exists using --force
    When I run "mm -e build --label deploy --force"
    Then the existing "deploy" command is overwritten by the renamed "build" command
    And the output confirms "Replaced: deploy"

  Scenario: Edit leaves command unchanged when editor is closed without saving
    When I run "mm -e build"
    And I close the editor without making changes
    Then the stored command for "build" is unchanged
    And the output says "No changes made"

  # --- Delete Happy Paths ---

  Scenario: Delete a command by label (short flag)
    When I run "mm -d build"
    Then I am prompted "Delete 'build: cargo build --release'? [y/N]"
    And I enter "y"
    Then the "build" entry is removed from the database
    And the output confirms "Deleted: build"

  Scenario: Delete a command by label (long flag)
    When I run "mm --delete build"
    Then I am prompted "Delete 'build: cargo build --release'? [y/N]"
    And I enter "y"
    Then the "build" entry is removed from the database
    And the output confirms "Deleted: build"

  Scenario: Delete multiple commands at once
    When I run "mm -d build deploy"
    Then I am prompted to confirm deletion of both entries
    And I enter "y"
    Then both "build" and "deploy" are removed from the database
    And the output confirms "Deleted: build, deploy"

  Scenario: Cancel deletion at the confirmation prompt
    When I run "mm -d build"
    Then I am prompted to confirm
    And I enter "n"
    Then the "build" command remains in the database
    And the output says "Cancelled"

  Scenario: Delete without confirmation prompt using --yes flag
    When I run "mm -d build --yes"
    Then the command is deleted immediately without a prompt
    And the output confirms "Deleted: build"

  Scenario: Delete all commands using --all flag
    When I run "mm -d --all"
    Then I am prompted "Delete ALL commands? This cannot be undone. [y/N]"
    And I enter "y"
    Then all commands are removed from the database
    And the output confirms "Deleted all commands"

  # --- Delete Edge Cases ---

  Scenario: Attempt to delete a non-existent label
    When I run "mm -d nonexistent"
    Then the exit code is non-zero
    And the error output contains "No command found with label 'nonexistent'"

  Scenario: Attempt to delete with no label provided
    When I run "mm -d"
    Then the exit code is non-zero
    And the error output contains "Please provide a label to delete"
    And the error output shows usage for the delete flag
