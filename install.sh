#!/bin/bash
# Install claude-restore: the script on your PATH, and its three hooks in ~/.claude/settings.json.
#
#   ./install.sh               install, or update in place (safe to run again)
#   ./install.sh --uninstall   remove the script, its hooks and its records
#
# Run it from a clone, or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/lorenzobalzani/claude-restore/main/install.sh | bash
#
# BIN_DIR=/somewhere ./install.sh puts the script somewhere other than ~/.local/bin.
# shellcheck disable=SC2016 # the jq programs are single-quoted on purpose

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/lorenzobalzani/claude-restore/main"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/claude-restore"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.claude/session-restore"
HOOK_PATTERN='claude-restore (record|record-once|forget)$'

say() { printf '%s\n' "$*"; }
fail() {
  printf 'claude-restore: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null || fail "needs jq (it ships with macOS 15 and later; otherwise: brew install jq)"

# Rewrite settings.json through jq, keeping a backup and refusing to write anything that is not JSON.
edit_settings() {
  local filter=$1 tmp
  shift
  mkdir -p "$(dirname "$SETTINGS")"
  [ -s "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  jq -e . "$SETTINGS" >/dev/null || fail "$SETTINGS is not valid JSON; fix it first"
  tmp=$(mktemp "$SETTINGS.XXXXXX")
  if ! jq "$@" "$filter" "$SETTINGS" >"$tmp" || ! jq -e . "$tmp" >/dev/null; then
    rm -f "$tmp"
    fail "could not update $SETTINGS"
  fi
  if cmp -s "$tmp" "$SETTINGS"; then
    rm -f "$tmp"
    return 1 # nothing changed
  fi
  cp "$SETTINGS" "$SETTINGS.bak-claude-restore"
  mv "$tmp" "$SETTINGS"
}

uninstall() {
  if edit_settings '
    if .hooks == null then . else
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | test($pattern) | not)))
                                         | map(select(.hooks | length > 0))))
                 | with_entries(select(.value | length > 0)))
      | if .hooks == {} then del(.hooks) else . end
    end' --arg pattern "$HOOK_PATTERN"; then
    say "Removed the hooks from $SETTINGS (backup: $SETTINGS.bak-claude-restore)"
  fi
  rm -f "$BIN" "$HOME/.warp/launch_configurations/claude-restore.yaml"
  rm -rf "$STATE_DIR"
  say "claude-restore is uninstalled."
}

install() {
  local here
  mkdir -p "$BIN_DIR"
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  if [ -n "$here" ] && [ -f "$here/claude-restore" ]; then
    cp "$here/claude-restore" "$BIN.tmp"
  else
    curl -fsSL "$REPO_RAW/claude-restore" -o "$BIN.tmp" || fail "could not download claude-restore"
  fi
  chmod +x "$BIN.tmp"
  mv "$BIN.tmp" "$BIN"
  say "Installed $("$BIN" --version) to $BIN"

  if edit_settings '
    def ensure($event; $command; $extra):
      .hooks[$event] = ((.hooks[$event] // []) as $groups
        | if [$groups[].hooks[]?.command] | any(. == $command) then $groups
          else $groups + [{hooks: [{type: "command", command: $command} + $extra]}] end);
    .hooks = (.hooks // {})
    | ensure("SessionStart"; $bin + " record"; {timeout: 10})
    | ensure("UserPromptSubmit"; $bin + " record-once"; {timeout: 10})
    | ensure("SessionEnd"; $bin + " forget"; {})' --arg bin "$BIN"; then
    say "Added the hooks to $SETTINGS (backup: $SETTINGS.bak-claude-restore)"
  else
    say "The hooks were already in $SETTINGS"
  fi

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "Note: $BIN_DIR is not on your PATH. Add it, or run $BIN directly." ;;
  esac
  say ""
  say "Done. Sessions you start from now on are recorded; ones already open are recorded on their next prompt."
  say "After Warp quits or the Mac restarts, run: claude-restore"
}

case "${1:-}" in
  '') install ;;
  --uninstall) uninstall ;;
  *) fail "unknown option: $1 (use --uninstall to remove)" ;;
esac
