#!/bin/bash
# Tests for claude-restore and install.sh, each against a throwaway HOME.
# Needs bash, jq, python3 and a C compiler. Run: tests/test.sh
# shellcheck disable=SC2016 # jq programs and the hook's command line are single-quoted on purpose

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/claude-restore"
PASSED=0
FAILED=0

# A stand-in for claude. Not a copied shell: macOS kills a copy of a system binary run from another path.
FAKE_CLAUDE_DIR=$(mktemp -d)
FAKE_CLAUDE="$FAKE_CLAUDE_DIR/claude"
cc -o "$FAKE_CLAUDE" "$ROOT/tests/fake_claude.c" || {
  echo "could not compile tests/fake_claude.c" >&2
  exit 1
}

check() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    printf '  ok    %s\n' "$what"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$what"
  fi
}

fresh_home() {
  WORK=$(mktemp -d)
  export HOME="$WORK/home"
  mkdir -p "$HOME/.claude/projects/p"
  STATE="$HOME/.claude/session-restore/open"
}

# Runs a hook mode the way Claude Code does: as a child of a claude process that owns a terminal.
hook() {
  HOOK_INPUT=$2 BIN=$BIN MODE=$1 python3 "$ROOT/tests/in_terminal.py" "$FAKE_CLAUDE" \
    'printf %s "$HOOK_INPUT" | "$BIN" "$MODE"' </dev/null
}

# A record of a session as the hook writes it; $3 is the pid, $4 its start time.
fake_record() {
  local id=$1 cwd=$2 pid=${3:-99999} started=${4:-Thu Jan  1 00:00:00 1970}
  mkdir -p "$STATE"
  jq -n --arg id "$id" --arg cwd "$cwd" --arg t "$HOME/.claude/projects/p/$id.jsonl" --argjson pid "$pid" --arg s "$started" \
    '{session_id: $id, cwd: $cwd, transcript_path: $t, pid: $pid, process_started: $s, tty: "ttys001"}' >"$STATE/$id.json"
}

transcript() { echo '{}' >"$HOME/.claude/projects/p/$1.jsonl"; }

prompt_history() { jq -nc --arg id "$1" --arg d "$2" '{display: $d, pastedContents: {}, timestamp: 0, project: "/x", sessionId: $id}' >>"$HOME/.claude/history.jsonl"; }

has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
exists() { [ -e "$1" ]; }
missing() { [ ! -e "$1" ]; }

echo "hooks"
fresh_home
hook record '{"session_id":"s-1","cwd":"/work/api","transcript_path":"/t/s-1.jsonl","source":"startup"}'
check "record writes the session, its folder and its claude process" \
  jq -e '.session_id == "s-1" and .cwd == "/work/api" and (.pid | type) == "number" and .process_started != "" and .tty != ""' "$STATE/s-1.json"
hook record-once '{"session_id":"s-1","cwd":"/work/elsewhere"}'
check "record-once leaves an existing record alone" jq -e '.cwd == "/work/api"' "$STATE/s-1.json"
hook record-once '{"session_id":"s-2","cwd":"/work/web"}'
check "record-once records a session it has not seen" exists "$STATE/s-2.json"
hook record '{"session_id":"s-agent","cwd":"/work","agent_id":"a1"}'
check "a subagent or teammate is not recorded" missing "$STATE/s-agent.json"
hook record '{"session_id":"../../escape","cwd":"/work"}'
check "an id that is not a session id is refused" missing "$HOME/.claude/escape.json"
hook forget '{"session_id":"s-1","reason":"other"}'
check "forget keeps a session that ended for another reason (the terminal went away)" exists "$STATE/s-1.json"
for reason in prompt_input_exit clear resume logout; do
  id="left-${reason//_/-}"
  fake_record "$id" /work
  hook forget "{\"session_id\":\"$id\",\"reason\":\"$reason\"}"
  check "forget drops a session left on purpose: $reason" missing "$STATE/$id.json"
done

echo "listing"
fresh_home
mkdir -p "$HOME/work/api"
fake_record cut-off "$HOME/work/api"
transcript cut-off
prompt_history cut-off "/model opus"
prompt_history cut-off "migrate the billing tables to the new schema"
prompt_history cut-off "go on"
sleep 300 &
running_pid=$!
fake_record still-running "$HOME/work/web" "$running_pid" "$(LC_ALL=C ps -o lstart= -p "$running_pid" | sed 's/^ *//; s/ *$//')"
transcript still-running
fake_record never-written "$HOME/work"
fake_record too-old "$HOME/work"
transcript too-old
touch -t 202001010000 "$HOME/.claude/projects/p/too-old.jsonl"
list=$("$BIN" --list)
check "a session whose process is gone is listed" has "$list" "work/api"
check "it is described by its first prompt that is not a slash command" has "$list" "migrate the billing tables"
check "a session whose process still runs is not listed" lacks "$list" "work/web"
check "a session that never wrote a transcript is dropped" missing "$STATE/never-written.json"
check "a session cut off more than a week ago is dropped" missing "$STATE/too-old.json"
check "the count matches" has "$list" "1 Claude session(s) were cut off"

echo "restoring"
fake_record folder-gone "$HOME/no/such/folder"
transcript folder-gone
yaml=$("$BIN" --dry-run)
check "the launch configuration resumes each session by id" has "$yaml" '"claude --resume cut-off"'
check "each tab opens in the session's folder" has "$yaml" "\"$HOME/work/api\""
check "a session whose folder is gone opens in HOME" has "$yaml" "cwd: \"$HOME\""
check "the configuration is named so warp://launch/claude-restore finds it" has "$yaml" "name: claude-restore"
check "a dry run keeps the records" exists "$STATE/cut-off.json"
check "picking a session that is not listed fails" bash -c "echo 9 | '$BIN'; [ \$? -eq 2 ]"
check "answering no reopens nothing and keeps the records" bash -c "echo n | '$BIN' && [ -e '$STATE/cut-off.json' ]"
"$BIN" --clear >/dev/null
check "--clear forgets the cut-off sessions" missing "$STATE/cut-off.json"
check "--clear keeps the ones still running" exists "$STATE/still-running.json"
kill "$running_pid" 2>/dev/null
wait "$running_pid" 2>/dev/null

echo "installer"
fresh_home
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ] }
}
EOF
BIN_DIR="$HOME/.local/bin" bash "$ROOT/install.sh" >/dev/null
settings="$HOME/.claude/settings.json"
check "the script is installed and runs" "$HOME/.local/bin/claude-restore" --version
check "the three hooks are added" jq -e '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.SessionEnd] | map(length) == [1, 1, 1]' "$settings"
check "the hooks point at the installed script" jq -e --arg bin "$HOME/.local/bin/claude-restore" '.hooks.SessionEnd[0].hooks[0].command == ($bin + " forget")' "$settings"
check "existing settings and hooks are kept" jq -e '.model == "opus" and .hooks.Stop[0].hooks[0].command == "say done"' "$settings"
BIN_DIR="$HOME/.local/bin" bash "$ROOT/install.sh" >/dev/null
check "installing again adds nothing" jq -e '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.SessionEnd] | map(length) == [1, 1, 1]' "$settings"
BIN_DIR="$HOME/.local/bin" bash "$ROOT/install.sh" --uninstall >/dev/null
check "uninstalling removes the three hooks" jq -e '.hooks | keys == ["Stop"]' "$settings"
check "uninstalling keeps everything else" jq -e '.model == "opus" and .hooks.Stop[0].hooks[0].command == "say done"' "$settings"
check "uninstalling removes the script" missing "$HOME/.local/bin/claude-restore"
echo '{ not json' >"$settings"
check "a settings file that is not JSON is refused" bash -c "! BIN_DIR='$HOME/.local/bin' bash '$ROOT/install.sh'"
check "and left as it was" bash -c "[ \"\$(cat '$settings')\" = '{ not json' ]"

rm -rf "$FAKE_CLAUDE_DIR"
echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
