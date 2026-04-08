# memento

A shell command bookmarking tool. Save commands with short labels and run them
instantly from any directory.

```sh
mm build              # runs: cargo build --release
mm kgp staging        # runs: kubectl get pods --namespace staging
mm deploy             # runs: helm upgrade ...
```

For the full feature specification and architectural rationale, see
[`docs/README.md`](docs/README.md).

---

## Prerequisites

| Dependency | Version | Notes |
|------------|---------|-------|
| [Zig](https://ziglang.org/download/) | `0.16.0-dev` | See `build.zig.zon` for minimum version |

SQLite is bundled as an amalgamation in `vendor/sqlite3/` — no system library
required.

### Installing Zig

The project tracks the nightly (`master`) Zig toolchain. The recommended way to
manage Zig versions is [zvm](https://github.com/tristanisham/zvm):

```sh
zvm install master
zvm use master
zig version   # should print 0.16.0-dev.*
```

Alternatively, download a pre-built binary from
<https://ziglang.org/download/> and put it on your `PATH`.

---

## Building

```sh
# Debug build (fast compile, assertions enabled)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseSafe

# Cross-compile for a specific target (example: musl static binary)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
```

The binary is placed at `zig-out/bin/memento`.

---

## Installing for personal use

Copy the binary to a directory on your `PATH`:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/memento ~/.local/bin/memento
```

Then install the shell wrapper. By default this creates a function named `mm`,
which is the recommended short alias:

```sh
memento --init           # installs shell function named "mm"
memento --init mm        # same, explicit
memento --init mymemo    # custom name if "mm" conflicts with something
```

Target a specific shell, or point at a custom config file:

```sh
memento --init --shell fish
memento --init --shell bash --config-file ~/.bash_profile
```

Restart your shell or source the relevant config file (`~/.bashrc`,
`~/.zshrc`, `~/.config/fish/config.fish`) to activate the wrapper.

Verify the installation:

```sh
memento --init --verify
```

---

## Shell wrapper architecture

`memento` prints the resolved command to **stdout** and all human-readable
output to **stderr**. A thin shell function captures stdout and passes it to
`eval`:

```fish
# Fish  (~/.config/fish/functions/mm.fish)
function mm
    eval (command memento $argv)
end
```

```bash
# Bash / Zsh  (~/.bashrc or ~/.zshrc)
function mm() { eval "$(command memento "$@")"; }
```

This is what allows commands like `cd ~/project` and `export TOKEN=...` to
affect the current shell session. See [`docs/README.md`](docs/README.md) for
the full architectural rationale.

### Choosing a function name

`memento --init [name]` installs the wrapper under whatever name you choose.
The binary is always `memento`; the name is just what you type at the prompt.

| Scenario | Command |
|----------|---------|
| Default (`mm`) | `memento --init` |
| Avoid conflict with an existing `mm` | `memento --init memo` |
| Match your muscle memory | `memento --init m` |

---

## Development workflow

There are two modes depending on what you are testing.

### Mode 1 — testing the binary directly

`zig build dev` runs the binary with `MM_DB` pointing at
`.zig-cache/mm-dev.sqlite`, completely isolated from your production store.
Use this for everything that does not require the shell wrapper:

```sh
zig build dev -- -a build 'cargo build --release'
zig build dev -- -l
zig build dev -- -H
```

The dev database persists between invocations. Delete it to start fresh:

```sh
rm .zig-cache/mm-dev.sqlite
```

**Limitation:** because this calls the binary directly (no `eval`), stateful
commands such as `cd ~/project` or `export TOKEN=...` will not affect your
current shell. For those, use Mode 2.

### Mode 2 — testing the full shell wrapper

Source the activation script for your shell to override the `mm` function in
the current session so it calls the local dev binary with the isolated
database:

```sh
# bash / zsh — source from the project root
source dev/activate.sh

# fish
source dev/activate.fish
```

After activating, `mm` behaves exactly as it will for end users — commands are
`eval`-ed in the current shell — but everything reads from and writes to the
dev database, not your production store.

To deactivate and restore your production `mm`, source your shell config:

```sh
source ~/.bashrc          # bash
source ~/.zshrc           # zsh
source ~/.config/fish/config.fish  # fish
```

### MM_DB in release builds

`MM_DB` is compiled in only for `Debug` builds. In any release mode
(`-Doptimize=ReleaseSafe`, `ReleaseSmall`, `ReleaseFast`) the check is a
`comptime false` branch and is eliminated entirely — a release binary ignores
the variable completely. This means the activation scripts also only work with
a debug binary (`zig build` default, no `-Doptimize` flag).

> **Note:** The shell wrapper (`memento --init`) is not required for
> development. Running the binary directly works fine. The wrapper is only
> needed when you want `cd`, `export`, and other stateful commands to affect
> your current shell session.

---

## Testing

Integration tests spawn `memento` as a subprocess against a temporary database
and assert its exit codes and output.

```sh
# Run all integration tests
zig build test

# Run a single test file
zig test tests/02_add_test.zig \
    --mod helper::tests/helper.zig \
    -Dbuild_options.mm_exe=zig-out/bin/memento
```

Tests live in `tests/` and correspond to the Gherkin feature files in
`docs/features/`.

---

## Project layout

```
memento/
├── src/
│   ├── main.zig          # CLI entry point and argument dispatch
│   ├── cli.zig           # Argument parsing
│   ├── strings.zig       # All user-facing strings (easy to localise)
│   ├── core/             # Business logic (no I/O except DB)
│   │   ├── mod.zig       # Public re-exports
│   │   ├── db.zig        # SQLite CRUD
│   │   ├── template.zig  # {placeholder} substitution
│   │   ├── shell.zig     # Shell detection and wrapper generation
│   │   ├── history.zig   # Shell history reading
│   │   └── init.zig      # Shell wrapper installation
│   └── tui/              # Interactive terminal UI
│       ├── mod.zig       # Public entry points and view-toggle loop
│       ├── term.zig      # Raw mode, key reading, frame buffer
│       ├── theme.zig     # Colour theme (all ANSI sequences in one place)
│       ├── commands.zig  # Commands browser
│       └── history.zig   # History viewer
├── vendor/
│   └── sqlite3/          # SQLite amalgamation (bundled, no system dep)
│       ├── sqlite3.c
│       └── sqlite3.h
├── tests/                # Integration test suite
├── docs/
│   ├── README.md         # Architecture and feature specification
│   └── features/         # Gherkin BDD specs (01–09)
├── dev/                  # Dev-mode shell activation scripts
├── build.zig
└── build.zig.zon
```

---

## Deployment

Distribution works through GitHub Releases: CI builds a binary for each
platform on every version tag, uploads the archives, and users fetch the right
one.

### Releasing a new version

```sh
git tag v0.2.0
git push --tags
```

The `.github/workflows/release.yml` workflow fires automatically. It builds
`ReleaseSafe` binaries for four targets, packages each as a `.tar.gz`, and
creates a GitHub Release with generated release notes.

| Archive | Runner |
|---------|--------|
| `memento-linux-x86_64.tar.gz` | `ubuntu-latest` |
| `memento-linux-aarch64.tar.gz` | `ubuntu-24.04-arm` |
| `memento-macos-x86_64.tar.gz` | `macos-13` (Intel) |
| `memento-macos-aarch64.tar.gz` | `macos-latest` (Apple Silicon) |

> **Before your first release** update the `REPO` placeholder in `install.sh`
> to match your GitHub `owner/repo` slug.

### System-wide install via `--prefix`

```sh
# Install to /usr/local/bin/memento
sudo zig build -Doptimize=ReleaseSafe --prefix /usr/local

# Install to ~/.local (no sudo)
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

`memento --init` must still be run separately after copying the binary.

### One-line install script

End users can install from a published release with:

```sh
sh <(curl -fsSL https://raw.githubusercontent.com/OWNER/memento/main/install.sh)
```

The script detects OS and architecture, downloads the matching archive from
the latest GitHub Release, installs the binary to `~/.local/bin`, and runs
`memento --init mm` to set up the `mm` shell function.
