#!/bin/bash
# Install respawn: the script on your PATH, and its hooks in every supported agent installed here.
#
#   ./install.sh               install, or update in place (safe to run again)
#   ./install.sh --uninstall   remove the script, its hooks and its records
#
# Run it from a clone, or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/lorenzobalzani/respawn/main/install.sh | bash
#
# BIN_DIR=/somewhere ./install.sh puts the script somewhere other than ~/.local/bin.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/lorenzobalzani/respawn/main"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/respawn"

fail() {
  printf 'respawn: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null || fail "needs jq (it ships with macOS 15 and later; otherwise: brew install jq, or apt install jq)"

install() {
  local here=""
  mkdir -p "$BIN_DIR"
  if [ -n "${BASH_SOURCE[0]:-}" ]; then # empty when piped from curl: there is no clone to copy from
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || here=""
  fi
  if [ -n "$here" ] && [ -f "$here/respawn" ]; then
    cp "$here/respawn" "$BIN.tmp"
  else
    curl -fsSL "$REPO_RAW/respawn" -o "$BIN.tmp" || fail "could not download respawn"
  fi
  chmod +x "$BIN.tmp"
  mv "$BIN.tmp" "$BIN"
  echo "Installed $("$BIN" --version) to $BIN"
  echo "Hooks:"
  "$BIN" setup

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH. Add it, or run $BIN directly." ;;
  esac
  echo
  echo "Done. Every session you start from now on is recorded, and Claude Code's open ones already are."
  echo "Other agents' open sessions are recorded on their next prompt."
  echo "After your terminal quits or the machine restarts, run: respawn"
}

uninstall() {
  if [ -x "$BIN" ]; then
    "$BIN" uninstall
    rm -f "$BIN"
  fi
  echo "respawn is uninstalled."
}

case "${1:-}" in
  '') install ;;
  --uninstall) uninstall ;;
  *) fail "unknown option: $1 (use --uninstall to remove)" ;;
esac
