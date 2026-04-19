#!/usr/bin/env bash
#
# Install pr-babysitter
#
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

mkdir -p "$BIN_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cp "$SCRIPT_DIR/bin/babysitter" "$BIN_DIR/babysitter"
cp "$SCRIPT_DIR/bin/pr-babysitter.sh" "$BIN_DIR/pr-babysitter.sh"
chmod +x "$BIN_DIR/babysitter" "$BIN_DIR/pr-babysitter.sh"

echo "Installed to $BIN_DIR"
echo ""
echo "Next steps:"
echo "  1. cd into your repo"
echo "  2. babysitter init"
echo "  3. Edit .babysitterrc"
echo "  4. babysitter start"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "Note: $BIN_DIR is not in your PATH. Add it:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
