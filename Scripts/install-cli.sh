#!/bin/zsh
# Install the `spacebar` command into a directory already on PATH.
#
#   ./Scripts/install-cli.sh                 -> ~/.local/bin/spacebar
#   ./Scripts/install-cli.sh /usr/local/bin
#
# The command is read-only: it measures the filesystem and the APFS container with
# unprivileged calls and never deletes, uploads or escalates.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
INSTALL_DIR="${1:-$HOME/.local/bin}"
BIN="$INSTALL_DIR/spacebar"

[[ -d "$INSTALL_DIR" ]] || { echo "No such directory: $INSTALL_DIR" >&2; exit 1; }
[[ -w "$INSTALL_DIR" ]] || { echo "$INSTALL_DIR is not writable by you. Choose another directory." >&2; exit 1; }

CANDIDATES=(
    "$PROJECT_DIR/dist/SpaceBar.app/Contents/Helpers/spacebar"
    "$HOME/Applications/SpaceBar.app/Contents/Helpers/spacebar"
    "/Applications/SpaceBar.app/Contents/Helpers/spacebar"
    "$PROJECT_DIR/.build/release/spacebar-cli"
    "$PROJECT_DIR/.build/debug/spacebar-cli"
)

SOURCE=""
for candidate in "${CANDIDATES[@]}"; do
    if [[ -x "$candidate" ]]; then SOURCE="$candidate"; break; fi
done

if [[ -z "$SOURCE" ]]; then
    echo "Building the command-line tool…"
    "$SCRIPT_DIR/swift-package.sh" build -c release --product spacebar-cli
    SOURCE="$("$SCRIPT_DIR/swift-package.sh" build -c release --show-bin-path)/spacebar-cli"
fi

/bin/mkdir -p "$INSTALL_DIR"
/usr/bin/install -m755 "$SOURCE" "$BIN"
"$BIN" schema > /dev/null
echo "Installed $BIN"
echo "Try: spacebar volume | spacebar reclaim ~ --json | spacebar explain"
