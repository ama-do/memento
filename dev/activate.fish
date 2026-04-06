# Activate the mm dev environment in the current fish session.
#
#   source dev/activate.fish
#
# This overrides the `mm` function so that all invocations use the
# locally-built debug binary and an isolated database, leaving your production
# store untouched.
#
# To deactivate, source your fish config:
#   source ~/.config/fish/config.fish

set -l _mm_dev_root (realpath (dirname (status filename))/..)
set -l _mm_dev_bin  $_mm_dev_root/zig-out/bin/mm
set -l _mm_dev_db   $_mm_dev_root/.zig-cache/mm-dev.sqlite

if not test -f $_mm_dev_bin
    echo "mm dev: binary not found. Run 'zig build' first." >&2
    return 1
end

# Store paths in global vars so the function closure can read them.
set -gx _MM_DEV_BIN $_mm_dev_bin
set -gx _MM_DEV_DB  $_mm_dev_db

function mm
    eval (env MM_DB="$_MM_DEV_DB" "$_MM_DEV_BIN" $argv)
end

echo "mm dev environment active"
echo "  binary:   $_mm_dev_bin"
echo "  database: $_mm_dev_db"
echo "  deactivate: source ~/.config/fish/config.fish"
