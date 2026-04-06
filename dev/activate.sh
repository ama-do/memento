#!/usr/bin/env sh
# Activate the mm dev environment in the current bash or zsh session.
#
#   source dev/activate.sh
#
# This overrides the `mm` shell function so that all invocations use the
# locally-built debug binary and an isolated database, leaving your production
# store untouched.
#
# To deactivate, source your normal shell config:
#   source ~/.bashrc   # bash
#   source ~/.zshrc    # zsh

# Resolve the project root regardless of where the shell is when this is sourced.
# BASH_SOURCE is set by bash; $0 is used as a fallback for other POSIX shells.
_MM_DEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_MM_DEV_BIN="$_MM_DEV_ROOT/zig-out/bin/mm"
_MM_DEV_DB="$_MM_DEV_ROOT/.zig-cache/mm-dev.sqlite"

if [ ! -f "$_MM_DEV_BIN" ]; then
    echo "mm dev: binary not found. Run 'zig build' first." >&2
    return 1
fi

mm() {
    eval "$(MM_DB="$_MM_DEV_DB" "$_MM_DEV_BIN" "$@")"
}

echo "mm dev environment active"
echo "  binary:   $_MM_DEV_BIN"
echo "  database: $_MM_DEV_DB"
echo "  deactivate: source ~/.bashrc  (or ~/.zshrc)"
