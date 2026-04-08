#!/usr/bin/env sh
# install.sh — download the latest mm release and install it.
#
# Usage:
#   sh install.sh                   # installs to ~/.local/bin
#   sh install.sh --prefix /usr/local
#   GITHUB_REPO=you/memento sh install.sh
#
# After installing the binary, the script runs `mm --init` to install the
# shell wrapper for the current shell.
set -e

REPO="${GITHUB_REPO:-OWNER/memento}"   # replace OWNER before publishing
PREFIX="${1:-}"
if [ "$1" = "--prefix" ]; then
    PREFIX="$2"
fi
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

# ── Detect OS and architecture ────────────────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)  OS_TAG="linux" ;;
    Darwin) OS_TAG="macos" ;;
    *)
        echo "error: unsupported OS '$OS'" >&2
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64 | amd64)  ARCH_TAG="x86_64" ;;
    aarch64 | arm64) ARCH_TAG="aarch64" ;;
    *)
        echo "error: unsupported architecture '$ARCH'" >&2
        exit 1
        ;;
esac

ARCHIVE="memento-${OS_TAG}-${ARCH_TAG}.tar.gz"

# ── Resolve latest release tag ────────────────────────────────────────────────

echo "Fetching latest release from github.com/$REPO ..."
LATEST_URL="https://api.github.com/repos/$REPO/releases/latest"

if command -v curl >/dev/null 2>&1; then
    TAG="$(curl -fsSL "$LATEST_URL" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
elif command -v wget >/dev/null 2>&1; then
    TAG="$(wget -qO- "$LATEST_URL" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
else
    echo "error: curl or wget is required" >&2
    exit 1
fi

if [ -z "$TAG" ]; then
    echo "error: could not determine latest release tag" >&2
    exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ARCHIVE"
echo "Downloading $ARCHIVE ($TAG) ..."

# ── Download and extract ──────────────────────────────────────────────────────

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DOWNLOAD_URL" -o "$TMP/$ARCHIVE"
else
    wget -qO "$TMP/$ARCHIVE" "$DOWNLOAD_URL"
fi

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"

# ── Install binary ────────────────────────────────────────────────────────────

mkdir -p "$BIN_DIR"
install -m 755 "$TMP/memento" "$BIN_DIR/memento"
echo "Installed memento to $BIN_DIR/memento"

# ── Check PATH ────────────────────────────────────────────────────────────────

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "  Note: $BIN_DIR is not on your PATH."
        echo "  Add this to your shell config (~/.bashrc, ~/.zshrc, etc.):"
        echo ""
        echo "    export PATH=\"\$PATH:$BIN_DIR\""
        echo ""
        echo ""
        ;;
esac

# ── Install shell wrapper ─────────────────────────────────────────────────────

echo "Installing shell wrapper (function name: mm) ..."
"$BIN_DIR/memento" --init mm

echo ""
echo "Done. Restart your shell or source your shell config, then run: mm --help"
