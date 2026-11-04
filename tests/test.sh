#!/bin/bash
# Tests for respawn and install.sh, each against a throwaway HOME.
# Needs bash, jq, python3, perl and a C compiler; tmux and node for a few tests (skipped without them).
# Run: tests/test.sh
# shellcheck disable=SC2016 # jq programs and the hook's command line are single-quoted on purpose

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/respawn"
PASSED=0
FAILED=0
SKIPPED=0

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

skip() {
  SKIPPED=$((SKIPPED + 1))
  printf '  skip  %s\n' "$1"
}

# Stand-ins for the agents. Not copied shells: macOS kills a copy of a system binary run from another path.
FAKES=$(mktemp -d)
cc -o "$FAKES/claude" "$ROOT/tests/fake_agent.c" || {
  echo "could not compile tests/fake_agent.c" >&2
  exit 1
}
for name in codex copilot droid kiro-cli opencode node; do # Gemini CLI, Qwen Code and Cursor CLI run as node
  cp "$FAKES/claude" "$FAKES/$name"
done

# Stand-ins for the terminals' commands: each records how respawn called it, and opens nothing.
STUBS=$(mktemp -d)
for command in osascript open xdg-open kitty wezterm alacritty ghostty gnome-terminal ptyxis konsole x-terminal-emulator zellij; do
  cat >"$STUBS/$command" <<'EOF'
#!/bin/bash
{
  echo "=== ${0##*/}"
  for arg in "$@"; do echo "arg: $arg"; done
  if [ ! -t 0 ]; then sed 's/^/stdin: /'; fi
} >>"$STUB_LOG"
if [ -n "${STUB_RUN:-}" ]; then eval "$STUB_RUN"; fi # what happens while the terminal opens its tabs
if [ "${0##*/}" = wezterm ] && [ "${2:-}" = spawn ]; then # wezterm cli spawn prints the new pane's id
  n=$(($(cat "$STUB_LOG.panes" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$STUB_LOG.panes"
  echo "$n"
fi
exit "${STUB_EXIT:-0}" # a terminal that fails: no display, not set up
EOF
  chmod +x "$STUBS/$command"
done

fresh_home() {
  WORK=$(mktemp -d)
  export HOME="$WORK/home" XDG_STATE_HOME="$WORK/state" XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share"
  unset CODEX_HOME
  export RESPAWN_TERMINAL=print # a test that opens tabs names its terminal, and gets a stub
  mkdir -p "$HOME/.claude/projects/p"
  export STATE="$XDG_STATE_HOME/respawn/sessions"
}

quote() {
  local quote="'" escaped="'\\''"
  printf "'%s'" "${1//$quote/$escaped}"
}

# The shell line that runs one of respawn's hooks with this payload, as the agent would.
hook_line() { printf 'printf %%s %s | %s hook %s %s' "$(quote "$3")" "$(quote "$BIN")" "$1" "$2"; }

# A session's life: a terminal, a shell in it, the agent under the shell, and the agent's hooks.
# session [--close-after N] agent-command-line... where the last word is the hooks' script.
session() {
  local close=()
  if [ "$1" = --close-after ]; then
    close=(--close-after "$2")
    shift 2
  fi
  local words=("$@") line=""
  for word in "${words[@]}"; do line+=" $(quote "$word")"; done
  # A second command stops the shell from exec'ing the agent, so the agent stays the shell's child. With
  # LINGER, the shell outlives the agent for a moment, as an interactive one would until you close the tab.
  python3 "$ROOT/tests/in_terminal.py" "${close[@]+"${close[@]}"}" /bin/sh -c "$line; ${LINGER:-true}" </dev/null
}

# How long a shell stays after its agent quits, in the tests that quit one: longer than respawn waits for a
# shell that is still closing.
QUIT_LINGER="sleep 4"

eventually() { # the check passes within a few seconds: it waits on what respawn does in the background
  local _
  for _ in $(seq 1 60); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# One hook, run by an agent that lives just for it.
hook() { session "$FAKES/$1" "$(hook_line "$@")"; }

# A record of a session as a hook writes it. Its agent and the agent's shell are gone, unless a pid and a
# start time are given for either.
fake_record() { # agent id cwd [pid started [shell-pid shell-started]]
  local agent=$1 id=$2 cwd=$3 pid=${4:-99999} started=${5:-Thu Jan  1 00:00:00 1970}
  local parent=${6:-99998} parent_started=${7:-Thu Jan  1 00:00:00 1970}
  mkdir -p "$STATE"
  jq -n --arg a "$agent" --arg id "$id" --arg cwd "$cwd" --arg t "$HOME/.claude/projects/p/$id.jsonl" \
    --argjson pid "$pid" --arg s "$started" --argjson parent "$parent" --arg ps "$parent_started" --argjson now "$(date +%s)" \
    '{agent: $a, session_id: $id, cwd: $cwd, transcript: $t, pid: $pid, process_started: $s, tty: "ttys001",
      parent_pid: $parent, parent_started: $ps, first_prompt: "", terminal: "warp", recorded_at: $now}' >"$STATE/$agent.$id.json"
}

transcript() { echo '{}' >"$HOME/.claude/projects/p/$1.jsonl"; }

claude_history() { jq -nc --arg id "$1" --arg d "$2" '{display: $d, pastedContents: {}, timestamp: 0, project: "/x", sessionId: $id}' >>"$HOME/.claude/history.jsonl"; }

is() { [ "$1" = "$2" ]; }
json_quote() { jq -rn --arg value "$1" '$value | @json'; }
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
exists() { [ -e "$1" ]; }
missing() { [ ! -e "$1" ]; }
process_started() { LC_ALL=C ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//'; }
backdate() { perl -e 'utime(time - $ARGV[1], time - $ARGV[1], $ARGV[0])' "$1" "$2"; }
real_ps=$(command -v ps)

echo "hooks: Claude Code"
fresh_home
hook claude start '{"session_id":"s-1","cwd":"/work/api","transcript_path":"/t/s-1.jsonl","source":"startup"}'
record="$STATE/claude.s-1.json"
check "start records the session, its folder, its agent process and that process's shell" \
  jq -e '.agent == "claude" and .session_id == "s-1" and .cwd == "/work/api" and (.pid | type) == "number" and .process_started != ""
         and .tty != "" and .shell_pid > 1 and .shell_started != ""' "$record"
session "$FAKES/claude" "$(hook_line claude prompt '{"session_id":"s-1","prompt":"/model opus"}');
  $(hook_line claude prompt '{"session_id":"s-1","prompt":"migrate the billing\ntables"}');
  $(hook_line claude prompt '{"session_id":"s-1","cwd":"/work/elsewhere","prompt":"go on"}')"
check "its first prompt that is not a slash command describes it" jq -e '.first_prompt == "migrate the billing tables"' "$record"
check "later prompts leave the record alone" jq -e '.cwd == "/work/api"' "$record"
hook claude prompt '{"session_id":"s-2","cwd":"/work/web","prompt":"fix the flaky test"}'
check "a prompt records a session that was open before respawn was installed" jq -e '.first_prompt == "fix the flaky test"' "$STATE/claude.s-2.json"
hook claude start '{"session_id":"s-agent","cwd":"/work","agent_id":"a1"}'
check "a subagent or teammate is not recorded" missing "$STATE/claude.s-agent.json"
hook claude start '{"session_id":"../../escape","cwd":"/work"}'
check "an id that is not a session id is refused" missing "$XDG_STATE_HOME/escape.json"
session "$FAKES/claude" "$(hook_line unknown-agent start '{"session_id":"s-3","cwd":"/work"}')"
check "an agent respawn does not know is ignored" missing "$STATE/unknown-agent.s-3.json"
# Starts a session and ends it in the same agent process, noting whether it was recorded in between.
start_then_end() { # agent id end-payload [agent-command-line...]
  local agent=$1 id=$2 end=$3
  shift 3
  local start="{\"session_id\":\"$id\",\"cwd\":\"/work\"}" # built here: bash 3.2 garbles \" inside "$(...)"
  LINGER=${LINGER:-$QUIT_LINGER} session "$@" "$(hook_line "$agent" start "$start"); cp $(quote "$STATE/$agent.$id.json") $(quote "$WORK/seen.$id");
    $(hook_line "$agent" end "$end")"
}
recorded_then_gone() { [ -e "$WORK/seen.$1" ] && [ ! -e "$STATE/$2.$1.json" ]; }
for reason in prompt_input_exit clear resume logout; do
  id="left-${reason//_/-}"
  LINGER=true start_then_end claude "$id" "{\"session_id\":\"$id\",\"reason\":\"$reason\"}" "$FAKES/claude"
  check "an end the agent calls deliberate forgets the session: $reason" recorded_then_gone "$id" claude
done
start_then_end claude s-quit '{"session_id":"s-quit","reason":"other"}' "$FAKES/claude"
check "any other end, while the agent is still its shell's child, forgets it: you quit, the tab stays" eventually recorded_then_gone s-quit claude
# A closing terminal hangs up its shell, and the shell, going, its agent, which runs its end hook then.
FAKE_AGENT_ON_HUP="$(hook_line claude end '{"session_id":"s-closed","reason":"other"}'); touch $(quote "$WORK/ended.s-closed")" \
  session --close-after 0.5 "$FAKES/claude" "$(hook_line claude start '{"session_id":"s-closed","cwd":"/work"}'); sleep 5"
sleep 2
check "an end after the terminal closed (the agent lost its shell) keeps the session" \
  bash -c "[ -e '$WORK/ended.s-closed' ] && [ -e '$STATE/claude.s-closed.json' ]"
# zsh, hung up, hangs up its job, then saves its history and exits: it outlives its agent for a moment.
zsh_like='trap "kill -HUP \$agent; sleep 1; exit 129" HUP; "$@" & agent=$!; wait $agent; sleep 5'
FAKE_AGENT_ON_HUP="$(hook_line claude end '{"session_id":"s-slow-shell","reason":"other"}'); touch $(quote "$WORK/ended.s-slow-shell")" \
  python3 "$ROOT/tests/in_terminal.py" --close-after 0.5 /bin/sh -c "$zsh_like" sh "$FAKES/claude" \
  "$(hook_line claude start '{"session_id":"s-slow-shell","cwd":"/work"}'); sleep 5" </dev/null
sleep 4
check "  and when the shell takes a moment to go, after its agent" \
  bash -c "[ -e '$WORK/ended.s-slow-shell' ] && [ -e '$STATE/claude.s-slow-shell.json' ]"
session --close-after 0.3 "$FAKES/claude" "sleep 2; touch $(quote "$WORK/outlived")"
sleep 2.5
check "the stand-in's children get the HUP of a closing terminal, as an agent's do" missing "$WORK/outlived"
LINGER=$QUIT_LINGER session "$FAKES/claude" "$(hook_line claude start '{"session_id":"s-slow-exit","cwd":"/work"}');
  $(hook_line claude end '{"session_id":"s-slow-exit","reason":"other"}'); sleep 4"
check "an agent that takes seconds to exit after its end hook (MCP servers stopping) has still quit" \
  eventually missing "$STATE/claude.s-slow-exit.json"
# Codex kills the process group of a hook that timed out: here the end hook gets a group of its own, killed whole.
in_own_group='set -m; sh -c "$1" & wait $!; kill -KILL -- -$! 2>/dev/null; true'
LINGER=$QUIT_LINGER session "$FAKES/claude" "$(hook_line claude start '{"session_id":"s-group","cwd":"/work"}');
  bash -c $(quote "$in_own_group") _ $(quote "$(hook_line claude end '{"session_id":"s-group","reason":"other"}')"); sleep 1"
check "the wait for the agent to exit survives the hook's process group being killed" eventually missing "$STATE/claude.s-group.json"
mkdir -p "$WORK/count"
printf '#!/bin/sh\necho >>%s\nexec %s "$@"\n' "$(quote "$WORK/ps-calls")" "$(quote "$real_ps")" >"$WORK/count/ps"
chmod +x "$WORK/count/ps"
PATH="$WORK/count:$PATH" hook claude start '{"session_id":"s-cheap","cwd":"/work"}'
check "the start hook reads the process table once, not once per ancestor" \
  bash -c "[ -e '$STATE/claude.s-cheap.json' ] && [ \$(wc -l <'$WORK/ps-calls') -le 5 ]"

echo "hooks: Codex (its hooks run in a background daemon)"
fresh_home
mkdir -p "$HOME/work/web" "$HOME/work/api" "$HOME/work/ops"
# Run by Codex's daemon, which its windows share and which runs outside all of them.
codex_hook() { "$FAKES/codex" app-server --listen unix:// "$(hook_line codex "$1" "$2")" </dev/null; }
# a Codex window: the agent in a folder, under a shell, in a terminal
(cd "$HOME/work/web" && session "$FAKES/codex" 'sleep 5') &
sleep 0.7
codex_hook start "{\"session_id\":\"c-1\",\"cwd\":\"$HOME/work/web\"}"
check "the session is matched to the Codex window open in its folder" \
  bash -c "ps -ww -o comm= -p \$(jq .pid '$STATE/codex.c-1.json') | grep -qE '(^|/)codex\$'"
codex_hook start "{\"session_id\":\"c-2\",\"cwd\":\"$HOME/work/api\"}"
check "no Codex window in its folder, no record" missing "$STATE/codex.c-2.json"
codex_hook end '{"session_id":"c-1","reason":"other"}'
sleep 3.5
check "an end while its window stays open (Codex unloads idle sessions) keeps it" exists "$STATE/codex.c-1.json"
wait
(cd "$HOME/work/api" && python3 "$ROOT/tests/in_terminal.py" /bin/sh -c "$(quote "$FAKES/codex") 'sleep 1'; sleep 5" </dev/null) &
sleep 0.7
codex_hook start "{\"session_id\":\"c-3\",\"cwd\":\"$HOME/work/api\"}"
sleep 0.8
codex_hook end '{"session_id":"c-3","reason":"other"}'
check "an end after its window quit, while its shell lives on, forgets it" eventually missing "$STATE/codex.c-3.json"
wait
(cd "$HOME/work/ops" && python3 "$ROOT/tests/in_terminal.py" --close-after 2 /bin/sh -c "$(quote "$FAKES/codex") 'sleep 3.5'; true" </dev/null) &
sleep 0.6
codex_hook start "{\"session_id\":\"c-4\",\"cwd\":\"$HOME/work/ops\"}"
sleep 2 # the terminal closes; the window outlives it for a moment
codex_hook end '{"session_id":"c-4","reason":"other"}'
sleep 3.5
check "an end after its terminal closed keeps it" exists "$STATE/codex.c-4.json"
wait
mkdir -p "$HOME/work/new" "$HOME/work/reboot" "$HOME/work/ide" "$HOME/work/npm"
(cd "$HOME/work/new" && LINGER=$QUIT_LINGER session "$FAKES/codex" 'sleep 3') &
sleep 0.7
codex_hook start "{\"session_id\":\"c-5\",\"cwd\":\"$HOME/work/new\"}"
window=$(jq .pid "$STATE/codex.c-5.json" 2>/dev/null)
codex_hook end '{"session_id":"c-5","reason":"other"}' # /new: the window ends its session and starts another
codex_hook start "{\"session_id\":\"c-6\",\"cwd\":\"$HOME/work/new\"}"
check "a second session in the same window (/new, /resume) is recorded against it" \
  jq -e --argjson pid "${window:-0}" '.pid == $pid' "$STATE/codex.c-6.json"
check "  and replaces the first one's record: a window runs one session at a time" missing "$STATE/codex.c-5.json"
(cd "$HOME/work/reboot" && session "$FAKES/codex" 'sleep 3') &
sleep 0.7
codex_hook start "{\"session_id\":\"c-7\",\"cwd\":\"$HOME/work/reboot\"}"
# a record from before a reboot, whose pid the new window happens to have
jq '.session_id = "before-reboot" | .process_started = "Thu Jan  1 00:00:00 1970"' "$STATE/codex.c-7.json" >"$STATE/codex.before-reboot.json"
window=$(jq .pid "$STATE/codex.c-7.json" 2>/dev/null)
rm -f "$STATE/codex.c-7.json"
codex_hook start "{\"session_id\":\"c-8\",\"cwd\":\"$HOME/work/reboot\"}"
check "an old record naming a pid that a window now has does not keep that window from its session" \
  jq -e --argjson pid "${window:-0}" '.pid == $pid' "$STATE/codex.c-8.json"
(cd "$HOME/work/ide" && session "$FAKES/codex" 'sleep 3') &
sleep 0.7
# an app-server of an IDE's or the Codex app's own, which talks to its client over stdio
payload="{\"session_id\":\"ide-1\",\"cwd\":\"$HOME/work/ide\"}"
"$FAKES/codex" app-server "$(hook_line codex start "$payload")" </dev/null
check "a session from an app-server of its own (an IDE, the Codex app) is not taken for a window in its folder" \
  missing "$STATE/codex.ide-1.json"
codex_hook start "{\"session_id\":\"c-9\",\"cwd\":\"$HOME/work/ide\"}"
check "  which stays free for its own session" exists "$STATE/codex.c-9.json"
wait
# npm's launcher on an older Node: node runs the native codex as its child, and exits with it
(cd "$HOME/work/npm" && LINGER="sleep 5" session "$FAKES/node" /usr/local/lib/node_modules/@openai/codex/bin/codex.js \
  "$(quote "$FAKES/codex") 'sleep 1.5'") &
sleep 0.7
codex_hook start "{\"session_id\":\"c-10\",\"cwd\":\"$HOME/work/npm\"}"
cp "$STATE/codex.c-10.json" "$WORK/seen.c-10" 2>/dev/null
codex_hook end '{"session_id":"c-10","reason":"other"}'
check "with npm's launcher between the shell and Codex, a quit while the tab stays forgets it" \
  eventually recorded_then_gone c-10 codex
wait

echo "hooks: Gemini CLI (one node process under another)"
fresh_home
cat >"$WORK/inner.sh" <<EOF
$(hook_line gemini start '{"session_id":"g-1","cwd":"/work/infra","transcript_path":"/t/g-1.json"}')
# the two node processes above this script, nearest first, whether or not a shell sits between them
p=\$\$; nodes=""
while [ "\$p" -gt 1 ] && [ \$(echo \$nodes | wc -w) -lt 2 ]; do
  case "\$(ps -o comm= -p \$p)" in *node) nodes="\$nodes \$p" ;; esac
  p=\$(ps -o ppid= -p \$p | tr -d ' ')
done
echo \$nodes >"$WORK/pids"
EOF
chmod +x "$WORK/inner.sh"
session "$FAKES/node" /opt/lib/gemini-cli/gemini "exec $(quote "$FAKES/node") /opt/lib/gemini-cli/gemini --relaunched $(quote "$WORK/inner.sh")"
read -r inner outer <"$WORK/pids"
check "the session belongs to the outer process, the one under the shell" jq -e --argjson outer "$outer" '.pid == $outer' "$STATE/gemini.g-1.json"
check "not to the relaunched one inside it" bash -c "[ '$inner' != '$outer' ]"

echo "hooks: Qwen Code"
fresh_home
start_then_end qwen q-1 '{"session_id":"q-1","reason":"prompt_input_exit"}' "$FAKES/node" /opt/lib/qwen-code/cli.js/qwen
check "Qwen's prompt_input_exit, sent even when the terminal closes, is settled by the shell: here you quit" eventually recorded_then_gone q-1 qwen
FAKE_AGENT_ON_HUP="$(hook_line qwen end '{"session_id":"q-2","reason":"prompt_input_exit"}'); touch $(quote "$WORK/ended.q-2")" \
  session --close-after 0.5 "$FAKES/node" /opt/lib/qwen-code/cli.js/qwen "$(hook_line qwen start '{"session_id":"q-2","cwd":"/work/ml"}'); sleep 5"
sleep 2
check "and here the terminal closed, so it is kept" bash -c "[ -e '$WORK/ended.q-2' ] && [ -e '$STATE/qwen.q-2.json' ]"

echo "hooks: Copilot CLI, Cursor CLI, Factory Droid, Kiro CLI, OpenCode"
fresh_home
hook copilot start '{"sessionId":"cp-1","cwd":"/work/a","timestamp":1}'
check "Copilot CLI: its camelCase sessionId and cwd" jq -e '.session_id == "cp-1" and .cwd == "/work/a"' "$STATE/copilot.cp-1.json"
session "$FAKES/node" /opt/cursor-agent/versions/2026.10.22/index.js \
  "$(hook_line cursor start '{"conversation_id":"cu-1","workspace_roots":["/work/b"]}')"
check "Cursor CLI: its conversation_id, its first workspace root, its node process" \
  jq -e '.session_id == "cu-1" and .cwd == "/work/b"' "$STATE/cursor.cu-1.json"
hook droid start '{"session_id":"d-1","cwd":"/work/c","transcript_path":"/t/d-1.jsonl"}'
check "Factory Droid: Claude Code's fields" jq -e '.session_id == "d-1" and .cwd == "/work/c"' "$STATE/droid.d-1.json"
session "$FAKES/kiro-cli" "$(hook_line kiro start '{"hook_event_name":"SessionStart","session_id":"k-1","cwd":"/work/d"}')"
check "Kiro CLI: under its kiro-cli process" jq -e '.session_id == "k-1"' "$STATE/kiro.k-1.json"
USER_PROMPT="split the deploy job in two" session "$FAKES/kiro-cli" "$(hook_line kiro prompt '{"session_id":"k-1","cwd":"/work/d"}')"
check "Kiro CLI: its prompt, which it passes in USER_PROMPT" jq -e '.first_prompt == "split the deploy job in two"' "$STATE/kiro.k-1.json"
out=$(session "$FAKES/claude" "$(hook_line claude start '{"session_id":"quiet","cwd":"/work"}');
  $(hook_line claude prompt '{"session_id":"quiet","prompt":"hello"}'); $(hook_line claude end '{"session_id":"quiet","reason":"clear"}')")
check "the hooks print nothing: Kiro and Copilot hand a hook's output to the model" is "$out" ""
hook opencode start '{"session_id":"ses_2fA9xQ","cwd":"/work/e"}'
check "OpenCode: what its plugin sends, ses_ ids included" jq -e '.session_id == "ses_2fA9xQ"' "$STATE/opencode.ses_2fA9xQ.json"
mkdir -p "$HOME/work/shared"
(cd "$HOME/work/shared" && session "$FAKES/claude" 'sleep 3') & # a Claude Code window, not recorded yet
sleep 0.7
payload="{\"session_id\":\"cp-as-claude\",\"cwd\":\"$HOME/work/shared\"}"
session "$FAKES/copilot" "$(hook_line claude start "$payload")"
check "Copilot CLI also runs Claude Code's hooks: respawn does not take them for Claude sessions," \
  missing "$STATE/claude.cp-as-claude.json"
check "  not even for a Claude Code window open in the same folder" missing "$STATE/claude.cp-as-claude.json"
wait
mkdir -p "$HOME/work/oc"
payload="{\"session_id\":\"ses_npm\",\"cwd\":\"$HOME/work/oc\"}"
# npm's launcher for OpenCode: node, which runs the native binary as its child
(cd "$HOME/work/oc" && LINGER="sleep 4" session "$FAKES/node" /usr/local/lib/node_modules/opencode-ai/bin/opencode \
  "$(quote "$FAKES/opencode") $(quote "$(hook_line opencode start "$payload"); sleep 0.5")") &
sleep 2 # OpenCode has quit (it has no end hook); its tab's shell is still there
check "OpenCode installed with npm, quit while its tab stays, is not listed as cut off" \
  bash -c "[ -e '$STATE/opencode.ses_npm.json' ] && ! '$BIN' --list | grep -qF '~/work/oc'"
wait

echo "listing"
fresh_home
mkdir -p "$HOME/work/api"
fake_record claude cut-off "$HOME/work/api"
transcript cut-off
claude_history cut-off "/model opus"
claude_history cut-off "migrate the billing tables to the new schema"
claude_history cut-off "go on"
sleep 300 &
running_pid=$!
fake_record claude still-running "$HOME/work/web" "$running_pid" "$(process_started "$running_pid")"
transcript still-running
sleep 300 &
shell_pid=$!
fake_record claude tab-still-open "$HOME/work/open" 99997 "Thu Jan  1 00:00:00 1970" "$shell_pid" "$(process_started "$shell_pid")"
transcript tab-still-open
fake_record claude never-written "$HOME/work"
fake_record claude too-old "$HOME/work"
transcript too-old
touch -t 202001010000 "$HOME/.claude/projects/p/too-old.jsonl"
list=$("$BIN" --list)
check "a session whose process is gone is listed" has "$list" "work/api"
check "it is described by its first prompt that is not a slash command" has "$list" "migrate the billing tables"
check "a session whose process still runs is not listed" lacks "$list" "work/web"
check "nor one whose agent is gone but whose tab is still open" lacks "$list" "work/open"
check "a session that never wrote a transcript is dropped" missing "$STATE/claude.never-written.json"
check "a session cut off more than a week ago is dropped" missing "$STATE/claude.too-old.json"
check "the count matches" has "$list" "1 agent session was cut off"
echo "restoring"
fake_record claude folder-gone "$HOME/no/such/folder"
transcript folder-gone
dry=$("$BIN" --dry-run)
check "a dry run prints each session's resume command in its folder" has "$dry" "cd $HOME/work/api && claude --resume cut-off"
check "a session whose folder is gone resumes from HOME" has "$dry" "cd $HOME && claude --resume folder-gone"
check "a dry run keeps the records" exists "$STATE/claude.cut-off.json"
check "picking a session that is not listed fails" bash -c "echo 9 | '$BIN'; [ \$? -eq 2 ]"
check "answering no reopens nothing and keeps the records" bash -c "echo n | '$BIN' && [ -e '$STATE/claude.cut-off.json' ]"
check "an unknown terminal is refused" bash -c "'$BIN' --in nowhere -y; [ \$? -eq 2 ]"
check "so is an option respawn does not know, wherever it is" bash -c "'$BIN' --list --bogus; [ \$? -eq 2 ]"
check "  and two modes at once" bash -c "'$BIN' -y --list; [ \$? -eq 2 ]"
printed=$("$BIN" --in print -y)
check "--in print prints the commands" has "$printed" "claude --resume cut-off"
check "and keeps the records, since nothing was reopened" exists "$STATE/claude.cut-off.json"
"$BIN" --clear >/dev/null
check "--clear forgets the cut-off sessions" missing "$STATE/claude.cut-off.json"
check "--clear keeps the ones still running" exists "$STATE/claude.still-running.json"
kill "$running_pid" "$shell_pid" 2>/dev/null
wait "$running_pid" "$shell_pid" 2>/dev/null

echo "listing: dates, previews, start times"
fresh_home
mkdir -p "$HOME/work/copilot" "$HOME/work/kiro"
week_and_a_day=$((8 * 86400))
fake_record copilot cp-old "$HOME/work/copilot" # no transcript: Copilot CLI, Kiro CLI and OpenCode send none
fake_record kiro k-old "$HOME/work/kiro"
jq '.first_prompt = "earlier"' "$STATE/kiro.k-old.json" >"$WORK/r" && mv "$WORK/r" "$STATE/kiro.k-old.json"
for id in copilot.cp-old kiro.k-old; do
  jq --argjson ago "$week_and_a_day" '.transcript = "" | .recorded_at -= $ago' "$STATE/$id.json" >"$WORK/r" && mv "$WORK/r" "$STATE/$id.json"
  backdate "$STATE/$id.json" "$week_and_a_day"
done
hook copilot prompt '{"sessionId":"cp-old","prompt":"still at it"}'
session "$FAKES/kiro-cli" "$(hook_line kiro prompt '{"session_id":"k-old","prompt":"and this"}')"
list=$("$BIN" --list)
check "a session with no transcript, started 8 days ago and prompted since, is still offered" \
  bash -c "grep -qF 'still at it' <<<\"\$1\" && grep -qF 'earlier' <<<\"\$1\"" _ "$list"
check "  and dated by its last prompt" bash -c "[ \$(grep -c ' 0m ago ' <<<\"\$1\") -eq 2 ]" _ "$list"
fresh_home
fake_record claude accents "$HOME/work"
transcript accents
long="$(printf 'x%.0s' $(seq 1 59))è e poi il resto"
jq --arg prompt "$long" '.first_prompt = $prompt' "$STATE/claude.accents.json" >"$WORK/r" && mv "$WORK/r" "$STATE/claude.accents.json"
list=$(LC_ALL=C "$BIN" --list)
check "a preview is cut by characters, never inside one, whatever the locale" \
  bash -c "printf '%s' \"\$1\" | iconv -f UTF-8 -t UTF-8 >/dev/null" _ "$list"
check "  and keeps the character at the cut whole" has "$list" "xè"
if [ -r /proc/self/stat ]; then
  fresh_home
  # procps computes ps's start time from the clock: once the clock is stepped (NTP), it moves
  mkdir -p "$WORK/clock"
  printf '#!/bin/bash\ncase " $* " in *lstart*) %s "$@" | sed "s/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/00:00:00/" ;; *) exec %s "$@" ;; esac\n' \
    "$(quote "$real_ps")" "$(quote "$real_ps")" >"$WORK/clock/ps"
  chmod +x "$WORK/clock/ps"
  (session "$FAKES/claude" "$(hook_line claude start '{"session_id":"live","cwd":"/work"}'); sleep 4") &
  sleep 1.5
  echo '{}' >"$WORK/t.jsonl"
  jq --arg t "$WORK/t.jsonl" '.transcript = $t' "$STATE/claude.live.json" >"$WORK/r" && mv "$WORK/r" "$STATE/claude.live.json"
  check "Linux: a session still running is not taken for cut off once the clock has been stepped" \
    bash -c "[ -e '$STATE/claude.live.json' ] && PATH='$WORK/clock':\$PATH '$BIN' --list | grep -q 'No cut-off agent sessions'"
  wait
else
  skip "Linux start times and a stepped clock: no /proc here (macOS's start times don't move with the clock)"
fi


echo "terminals: tmux"
if command -v tmux >/dev/null; then
  fresh_home
  export TMUX_TMPDIR="$WORK" # a tmux server of the test's own
  mkdir -p "$HOME/work/a b" "$HOME/work/c"
  fake_record claude one "$HOME/work/a b"
  transcript one
  fake_record claude two "$HOME/work/c"
  transcript two
  # the windows' shells find a stand-in claude, not one that may be installed here
  mkdir -p "$WORK/agents"
  printf '#!/bin/sh\necho "resuming $*"\n' >"$WORK/agents/claude"
  chmod +x "$WORK/agents/claude"
  PATH="$WORK/agents:$PATH" tmux new-session -d -s respawn-test -x 200 -y 50
  TMUX=$(tmux display-message -p '#{socket_path},#{pid},0') "$BIN" --in tmux -y >/dev/null
  sleep 1
  paths=$(tmux list-windows -t respawn-test -F '#{pane_current_path}')
  a_b=$(cd "$HOME/work/a b" && pwd -P)
  c=$(cd "$HOME/work/c" && pwd -P)
  check "a tmux window opens in each session's folder, spaces and all" bash -c "grep -qxF \"\$1\" <<<\"\$3\" && grep -qxF \"\$2\" <<<\"\$3\"" _ "$a_b" "$c" "$paths"
  typed=$(for w in $(tmux list-windows -t respawn-test -F '#{window_id}'); do tmux capture-pane -p -t "$w"; done)
  check "and types the session's resume command" \
    bash -c "grep -qF 'claude --resume one' <<<\"\$1\" && grep -qF 'claude --resume two' <<<\"\$1\"" _ "$typed"
  check "the reopened sessions' records are cleared (each records itself again)" missing "$STATE/claude.one.json"
  for round in first second; do
    fake_record claude "$round" "$HOME/work/c"
    transcript "$round"
    out=$(env -u TMUX PATH="$WORK/agents:$PATH" "$BIN" --in tmux -y 2>&1)
  done
  check "outside tmux, a second reopen while the first respawn session is still there gets a session of its own" \
    has "$out" "tmux attach -t respawn-2"
  tmux kill-server
  unset TMUX_TMPDIR
else
  skip "tmux is not installed"
fi

echo "terminals: what each one is sent (stubbed)"
reopen_in() { # terminal: reopens two sessions there, one in a folder with a space; leaves what was sent in $SENT
  fresh_home
  mkdir -p "$HOME/work/a b" "$HOME/work/c"
  fake_record claude one "$HOME/work/a b"
  transcript one
  fake_record claude two "$HOME/work/c"
  transcript two
  backdate "$HOME/.claude/projects/p/two.jsonl" 60 # one is newer, so it comes first
  export STUB_LOG="$WORK/sent"
  : >"$STUB_LOG"
  OUT=$(PATH="$STUBS:$PATH" "$BIN" --in "$1" -y </dev/null 2>&1)
  sleep 0.3 # some openers start their terminal in the background
  SENT=$(cat "$STUB_LOG")
}
keep_shell="$SHELL -lic 'claude --resume one; exec $SHELL -l'"
darwin() { [ "$(uname)" = Darwin ]; }

reopen_in warp
warp_dir="$HOME/.warp/launch_configurations"
darwin || warp_dir="$HOME/.local/share/warp-terminal/launch_configurations"
yaml=$(cat "$warp_dir/respawn.yaml" 2>/dev/null)
check "Warp: a launch configuration named respawn" has "$yaml" "name: respawn"
check "Warp: a tab per session, in its folder, typing its command" bash -c "grep -qF 'cwd: \"$HOME/work/a b\"' <<<'$yaml' && grep -qF 'exec: \"claude --resume two\"' <<<'$yaml'"
check "Warp: opened by name" has "$SENT" "arg: warp://launch/respawn"
check "Warp: says what it did" has "$OUT" "Reopened 2 sessions in Warp."

reopen_in iterm2
check "iTerm2: AppleScript that makes a window and a tab per session" bash -c "grep -qF 'stdin:   tell application \"iTerm2\"' <<<\"\$1\" && grep -qF 'create tab with default profile' <<<\"\$1\"" _ "$SENT"
check "iTerm2: folders and commands are passed as arguments, never spliced into the script" bash -c "grep -qxF 'arg: $HOME/work/a b' <<<\"\$1\" && grep -qxF 'arg: claude --resume one' <<<\"\$1\"" _ "$SENT"

reopen_in terminal
check "Terminal.app: AppleScript with a do script per session" bash -c "grep -qF 'tell application \"Terminal\"' <<<\"\$1\" && grep -qF 'do script' <<<\"\$1\" && grep -qxF 'arg: $HOME/work/c' <<<\"\$1\"" _ "$SENT"

reopen_in ghostty
if darwin; then
  check "Ghostty (macOS): AppleScript with a surface configuration per tab" bash -c "grep -qF 'tell application \"Ghostty\"' <<<\"\$1\" && grep -qF 'new tab in w with configuration cfg' <<<\"\$1\"" _ "$SENT"
else
  check "Ghostty (Linux): +new-window, then +new-tab, each in its folder" bash -c "grep -qxF 'arg: +new-window' <<<\"\$1\" && grep -qxF 'arg: +new-tab' <<<\"\$1\" && grep -qxF 'arg: --working-directory=$HOME/work/a b' <<<\"\$1\"" _ "$SENT"
fi

reopen_in kitty
session=$(cat "$XDG_STATE_HOME/respawn/kitty.session" 2>/dev/null)
check "kitty: a session file with a tab per session in its folder" bash -c "grep -qxF 'cd $HOME/work/a b' <<<\"\$1\" && [ \$(grep -c '^new_tab ' <<<\"\$1\") -eq 2 ]" _ "$session"
check "kitty: each tab runs its command in a login shell that stays open" has "$session" "launch $keep_shell"
check "kitty: opened from that session file" has "$SENT" "arg: --session"

reopen_in wezterm
check "WezTerm: a new window, then a tab in it for the next session" bash -c "grep -qxF 'arg: --new-window' <<<\"\$1\" && grep -A1 -xF 'arg: --pane-id' <<<\"\$1\" | grep -qxF 'arg: 1'" _ "$SENT"
check "WezTerm: types each command into its pane" bash -c "grep -qF 'claude --resume two' <<<\"\$1\" && grep -qxF 'arg: send-text' <<<\"\$1\"" _ "$SENT"

reopen_in alacritty
check "Alacritty: a window per session, in its folder, in a shell that stays" bash -c "[ \$(grep -cxF 'arg: create-window' <<<\"\$1\") -eq 2 ] && grep -qxF 'arg: $HOME/work/a b' <<<\"\$1\" && grep -qxF \"arg: claude --resume one; exec $SHELL -l\" <<<\"\$1\"" _ "$SENT"

reopen_in zellij
layout=$(cat "$XDG_STATE_HOME/respawn/zellij-layout.kdl" 2>/dev/null)
check "Zellij: a layout with a tab per session in its folder" bash -c "grep -qF 'cwd=\"$HOME/work/a b\"' <<<\"\$1\" && grep -qF 'claude --resume two' <<<\"\$1\"" _ "$layout"
check "Zellij: opened from that layout" has "$SENT" "arg: --layout"

reopen_in gnome-terminal
check "GNOME Terminal: a window, then a tab, each in its folder" bash -c "grep -qxF 'arg: --window' <<<\"\$1\" && grep -qxF 'arg: --tab' <<<\"\$1\" && grep -qxF 'arg: --working-directory=$HOME/work/a b' <<<\"\$1\"" _ "$SENT"

reopen_in ptyxis
check "Ptyxis: a window, then a tab, the command quoted for its parser" bash -c "grep -qxF 'arg: --new-window' <<<\"\$1\" && grep -qxF 'arg: --tab' <<<\"\$1\" && grep -qxF \"arg: $keep_shell\" <<<\"\$1\"" _ "$SENT"

reopen_in konsole
tabs=$(cat "$XDG_STATE_HOME/respawn/konsole-tabs" 2>/dev/null)
check "Konsole: a tabs file with each session's folder" has "$tabs" "workdir: $HOME/work/a b;;"
check "Konsole: each tab runs a script that resumes its session" has "$(cat "$XDG_STATE_HOME/respawn/konsole-tab-1.sh" 2>/dev/null)" "exec $keep_shell"

reopen_in x-terminal-emulator
check "x-terminal-emulator: a window per session, folder and command as arguments" bash -c "[ \$(grep -cxF '=== x-terminal-emulator' <<<\"\$1\") -eq 2 ] && grep -qxF 'arg: $HOME/work/a b' <<<\"\$1\" && grep -qxF 'arg: claude --resume one' <<<\"\$1\"" _ "$SENT"

kept_and_printed() { # the terminal failed: respawn says so, prints the commands and keeps both records
  has "$OUT" "could not open tabs" && has "$OUT" "claude --resume one" && has "$OUT" "claude --resume two" &&
    exists "$STATE/claude.one.json" && exists "$STATE/claude.two.json"
}
for terminal in gnome-terminal ptyxis konsole x-terminal-emulator; do
  STUB_EXIT=1 reopen_in "$terminal"
  check "$terminal failing (no display, say): the commands are printed and the records kept" kept_and_printed
done
if ! command -v konsole >/dev/null; then
  mv "$STUBS/konsole" "$STUBS/konsole.off"
  reopen_in konsole
  mv "$STUBS/konsole.off" "$STUBS/konsole"
  check "konsole not installed: the same" kept_and_printed
else
  skip "Konsole is installed here: its absence can't be tested"
fi
# The first tab resumed its session, which recorded itself anew, before the terminal returned (Zellij outside a
# session runs in the foreground until you detach).
STUB_RUN='jq ".pid = 4242" "$STATE/claude.one.json" >"$STATE/new" && mv "$STATE/new" "$STATE/claude.one.json"' reopen_in zellij
check "a session that recorded itself again while its terminal opened keeps its new record" \
  jq -e '.pid == 4242' "$STATE/claude.one.json"
check "  while one that has not is forgotten" missing "$STATE/claude.two.json"

fresh_home
mkdir -p "$HOME/work/c"
fake_record claude one "$HOME/work/c"
transcript one
export STUB_LOG="$WORK/sent"
: >"$STUB_LOG"
out=$(PATH="$STUBS:$PATH" "$BIN" -y --in kitty </dev/null 2>&1)
check "--in is read after the mode too" has "$out" "Reopened 1 session in kitty."
fake_record claude one "$HOME/work/c"
: >"$STUB_LOG"
PATH="$STUBS:$PATH" "$BIN" --in kitty </dev/null >/dev/null 2>&1
check "the input ending at the question is a no: nothing is opened" is "$(cat "$STUB_LOG")" ""
check "  and the record is kept" exists "$STATE/claude.one.json"
out=$(printf 1 | PATH="$STUBS:$PATH" "$BIN" --in kitty 2>&1)
check "  while an answer the input ends on, with no newline, still counts" has "$out" "Reopened 1 session in kitty."

echo "terminals: which one respawn reopens into"
fresh_home
unset RESPAWN_TERMINAL
detected() { env -u TMUX -u ZELLIJ -u KITTY_WINDOW_ID -u WEZTERM_PANE -u ALACRITTY_WINDOW_ID -u KONSOLE_VERSION \
  -u PTYXIS_VERSION -u GNOME_TERMINAL_SERVICE -u LC_TERMINAL -u TERM_PROGRAM -u TERM "$@" "$BIN" doctor | sed -n 's/^Terminal: //p'; }
check "inside tmux, tmux, whatever the outer terminal" is "$(detected TMUX=/tmp/s,1,0 TERM_PROGRAM=iTerm.app)" tmux
check "kitty by its TERM, even with another terminal's TERM_PROGRAM inherited" is "$(detected TERM=xterm-kitty TERM_PROGRAM=WarpTerminal)" kitty
check "Warp by its TERM_PROGRAM" is "$(detected TERM_PROGRAM=WarpTerminal)" Warp
check "iTerm2 by its TERM_PROGRAM" is "$(detected TERM_PROGRAM=iTerm.app)" iTerm2
check "an editor's terminal gets the commands printed" is "$(detected TERM_PROGRAM=vscode)" "this terminal (printed commands)"
check "Konsole by its marker" is "$(detected KONSOLE_VERSION=240802)" Konsole
check "RESPAWN_TERMINAL wins over everything" is "$(detected RESPAWN_TERMINAL=wezterm TMUX=/tmp/s,1,0)" WezTerm
export RESPAWN_TERMINAL=print

echo "quoting"
fresh_home
mkdir -p "$HOME/work/it's \$here"
fake_record claude quoted "$HOME/work/it's \$here"
transcript quoted
line=$("$BIN" --dry-run | sed -n 's/^  \(cd .*\) && claude --resume quoted$/\1/p')
check "a printed cd lands in a folder named with a quote, a space and a dollar sign" bash -c "eval \"\$1\" && [ \"\$PWD\" = \"\$2\" ]" _ "$line" "$HOME/work/it's \$here"

echo "setup"
fresh_home
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ] }
}
EOF
"$BIN" setup >/dev/null
settings="$HOME/.claude/settings.json"
check "Claude Code gets its three hooks" jq -e '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.SessionEnd] | map(length) == [1, 1, 1]' "$settings"
check "they run this respawn" jq -e --arg bin "$BIN" '.hooks.SessionEnd[0].hooks[0].command == ($bin + " hook claude end")' "$settings"
check "existing settings and hooks are kept" jq -e '.model == "opus" and .hooks.Stop[0].hooks[0].command == "say done"' "$settings"
"$BIN" setup >/dev/null
check "setting up again adds nothing" jq -e '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.SessionEnd] | map(length) == [1, 1, 1]' "$settings"
check "doctor sees the hooks" bash -c "'$BIN' doctor | grep -q 'Claude Code *hooks installed'"
"$BIN" uninstall >/dev/null
check "uninstall removes respawn's hooks and nothing else" jq -e '.hooks | keys == ["Stop"]' "$settings"
check "and keeps every other setting" jq -e '.model == "opus"' "$settings"
echo '{ not json' >"$settings"
"$BIN" setup >/dev/null 2>&1
check "a settings file that is not JSON is left as it was" bash -c "[ \"\$(cat '$settings')\" = '{ not json' ]"

# Stand-ins for the agents' commands, so that setup finds them installed. Gemini CLI prints a version.
agents_on_path() { # gemini-version [qwen-version]
  mkdir -p "$WORK/bin"
  for command in codex qwen copilot cursor-agent droid kiro-cli opencode; do
    printf '#!/bin/sh\n' >"$WORK/bin/$command"
    chmod +x "$WORK/bin/$command"
  done
  printf '#!/bin/sh\necho %s\n' "$1" >"$WORK/bin/gemini"
  chmod +x "$WORK/bin/gemini"
  printf '#!/bin/sh\necho >>%s\necho %s\n' "$(quote "$WORK/qwen-asked")" "${2:-}" >"$WORK/bin/qwen" # already executable
}
fresh_home
agents_on_path 0.22.2 0.13.0 # an old Gemini CLI, which runs hooks only when told to; a Qwen Code before hooks
mkdir -p "$HOME/.cursor" "$HOME/.factory"
echo '{"version":1,"hooks":{"stop":[{"command":"say done"}]}}' >"$HOME/.cursor/hooks.json"
out=$(PATH="$WORK/bin:$PATH" "$BIN" setup)
check "Codex gets its hooks in hooks.json" jq -e --arg bin "$BIN" \
  '.hooks.SessionStart[0].hooks[0].command == ($bin + " hook codex start") and (.hooks.UserPromptSubmit | length) == 1 and (.hooks.SessionEnd | length) == 1' "$HOME/.codex/hooks.json"
check "and a note to approve them in Codex" has "$out" "/hooks"
check "Gemini CLI gets its own prompt event, BeforeAgent, with a timeout in milliseconds" jq -e \
  '.hooks.BeforeAgent[0].hooks[0].timeout == 10000 and (.hooks.SessionStart | length) == 1 and (.hooks.SessionEnd | length) == 1' "$HOME/.gemini/settings.json"
check "an old Gemini CLI also gets hooks switched on" jq -e '.tools.enableHooks == true' "$HOME/.gemini/settings.json"
check "Qwen Code gets its hooks" jq -e '(.hooks.SessionStart | length) == 1 and .hooks.UserPromptSubmit[0].hooks[0].timeout == 10' "$HOME/.qwen/settings.json"
check "  and a note that a Qwen Code before 0.14 runs none yet" has "$out" "Qwen Code 0.13.0 has no hooks yet"
check "  for which setup asks it for its version once" is "$(wc -l <"$WORK/qwen-asked" | tr -d ' ')" 1
check "Copilot CLI gets a hook file of respawn's own" jq -e --arg bin "$BIN" \
  '.version == 1 and .hooks.sessionStart[0].bash == ($bin + " hook copilot start") and .hooks.userPromptSubmitted[0].timeoutSec == 10' \
  "$HOME/.copilot/hooks/respawn.json"
check "Cursor CLI gets its three events, next to its own hooks" jq -e \
  '.version == 1 and .hooks.stop[0].command == "say done" and (.hooks.sessionStart | length) == 1 and (.hooks.beforeSubmitPrompt | length) == 1' \
  "$HOME/.cursor/hooks.json"
check "Factory Droid, with no hooks.json, gets them in settings.json" jq -e '(.hooks.SessionStart | length) == 1' "$HOME/.factory/settings.json"
check "Kiro CLI gets a hook file of respawn's own" jq -e \
  '.version == "v1" and ([.hooks[].trigger] == ["SessionStart", "UserPromptSubmit", "SessionEnd"])' "$HOME/.kiro/hooks/respawn.json"
plugin="$HOME/.config/opencode/plugins/respawn.js"
check "OpenCode gets a plugin that calls this respawn" has "$(cat "$plugin" 2>/dev/null)" "const RESPAWN = \"$BIN\""
if command -v node >/dev/null; then
  cp "$plugin" "$WORK/plugin.mjs" 2>/dev/null
  check "and the plugin is valid JavaScript" node --check "$WORK/plugin.mjs"
  # OpenCode loads it: here node, under a name ps shows as opencode, in a terminal, in a shell
  mkdir -p "$WORK/oc" "$HOME/work/oc"
  ln -s "$(command -v node)" "$WORK/oc/opencode"
  cat >"$WORK/load-plugin.mjs" <<'EOF'
const [plugin, directory, id, elapsed] = process.argv.slice(2)
const { Respawn } = await import(plugin)
const hooks = await Respawn({ directory })
const started = Date.now()
await hooks.event({ event: { type: "session.created", properties: { info: { id, directory } } } })
;(await import("node:fs")).writeFileSync(elapsed, String(Date.now() - started))
await new Promise((resolve) => setTimeout(resolve, 1000))
await hooks["chat.message"]({ sessionID: id }, { parts: [{ type: "text", text: "tidy the docs" }] })
setTimeout(() => {}, 1500) // OpenCode runs on, and the hooks it started finish meanwhile
EOF
  session "$WORK/oc/opencode" "$WORK/load-plugin.mjs" "$WORK/plugin.mjs" "$HOME/work/oc" ses_plugin "$WORK/elapsed"
  check "the plugin records its session from inside OpenCode, with its first prompt" \
    jq -e '.session_id == "ses_plugin" and .first_prompt == "tidy the docs"' "$STATE/opencode.ses_plugin.json"
  printf '#!/bin/sh\nsleep 2\n' >"$WORK/slow-respawn" # a respawn that takes its time
  chmod +x "$WORK/slow-respawn"
  sed "s|^const RESPAWN = .*|const RESPAWN = $(json_quote "$WORK/slow-respawn")|" "$WORK/plugin.mjs" >"$WORK/slow-plugin.mjs"
  node "$WORK/load-plugin.mjs" "$WORK/slow-plugin.mjs" "$HOME/work/oc" ses_slow "$WORK/elapsed-slow" >/dev/null 2>&1
  check "  and never makes OpenCode wait for respawn" bash -c "[ \$(cat '$WORK/elapsed-slow') -lt 1000 ]"
else
  skip "node is not installed: the OpenCode plugin is neither syntax-checked nor run"
fi
PATH="$WORK/bin:$PATH" "$BIN" uninstall >/dev/null
check "uninstall removes respawn's own files" bash -c "[ ! -e '$HOME/.copilot/hooks/respawn.json' ] && [ ! -e '$HOME/.kiro/hooks/respawn.json' ] && [ ! -e '$plugin' ]"
check "and respawn's entries from a shared hooks file, keeping the rest" \
  jq -e '.hooks == {"stop": [{"command": "say done"}]}' "$HOME/.cursor/hooks.json"

fresh_home
agents_on_path 0.66.0
mkdir -p "$HOME/.factory"
echo '{"PreToolUse":[{"hooks":[{"type":"command","command":"lint"}]}]}' >"$HOME/.factory/hooks.json"
PATH="$WORK/bin:$PATH" "$BIN" setup >/dev/null
check "Factory Droid, with a hooks.json, gets them at its top, next to its own" \
  jq -e '(.SessionStart | length) == 1 and .PreToolUse[0].hooks[0].command == "lint"' "$HOME/.factory/hooks.json"
PATH="$WORK/bin:$PATH" "$BIN" uninstall >/dev/null
check "and loses only those on uninstall" jq -e '. == {"PreToolUse": [{"hooks": [{"type": "command", "command": "lint"}]}]}' "$HOME/.factory/hooks.json"
fresh_home
agents_on_path 0.66.0
PATH="$WORK/bin:$PATH" "$BIN" setup >/dev/null
check "a current Gemini CLI, which runs hooks by default, is left without the switch" jq -e '.tools == null' "$HOME/.gemini/settings.json"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify-me"}]}]}}' >"$HOME/.codex/hooks.json"
PATH="$WORK/bin:$PATH" "$BIN" setup >/dev/null
PATH="$WORK/bin:$PATH" "$BIN" uninstall >/dev/null
check "uninstall takes respawn's hooks out of every agent" bash -c "! grep -qs 'respawn hook' '$HOME/.gemini/settings.json' '$HOME/.codex/hooks.json'"
check "a config file keeps its permissions" bash -c "[ \"\$(ls -l '$HOME/.codex/hooks.json' | cut -c1-10)\" = '-rw-r--r--' ]"
check "and leaves the agents' own hooks" jq -e '.hooks.Stop[0].hooks[0].command == "notify-me"' "$HOME/.codex/hooks.json"

fresh_home
agents_on_path 0.66.0
PATH="$WORK/bin:$PATH" "$BIN" setup >/dev/null
mkdir -p "$HOME/.warp/launch_configurations" "$HOME/.local/share/warp-terminal/launch_configurations"
touch "$HOME/.warp/launch_configurations/respawn.yaml" "$HOME/.local/share/warp-terminal/launch_configurations/respawn.yaml"
"$BIN" uninstall >/dev/null # the agents are not on PATH: removed since, or installed with nvm
no_hooks_left() {
  local file
  for file in "$HOME/.codex/hooks.json" "$HOME/.gemini/settings.json" "$HOME/.qwen/settings.json" \
    "$HOME/.factory/settings.json" "$HOME/.cursor/hooks.json" "$HOME/.claude/settings.json"; do
    if grep -qs 'respawn.* hook ' "$file"; then return 1; fi
  done
  missing "$HOME/.copilot/hooks/respawn.json" && missing "$HOME/.kiro/hooks/respawn.json" &&
    missing "$HOME/.config/opencode/plugins/respawn.js"
}
check "uninstall takes the hooks out of every agent, on PATH or not" no_hooks_left
check "  and Warp's launch configuration, where macOS and Linux keep it" \
  bash -c "[ ! -e '$HOME/.warp/launch_configurations/respawn.yaml' ] && [ ! -e '$HOME/.local/share/warp-terminal/launch_configurations/respawn.yaml' ]"

fresh_home
mkdir -p "$WORK/dotfiles"
echo '{"model": "opus"}' >"$WORK/dotfiles/claude.json"
chmod 640 "$WORK/dotfiles/claude.json"
ln -s ../../dotfiles/claude.json "$HOME/.claude/settings.json" # as stow links it
"$BIN" setup >/dev/null
check "a settings file that is a symlink (stow, chezmoi) stays one" test -L "$HOME/.claude/settings.json"
check "  and the file it points to gets the hooks, with its permissions" \
  bash -c "jq -e '.model == \"opus\" and (.hooks.SessionStart | length) == 1' '$WORK/dotfiles/claude.json' >/dev/null && [ \"\$(ls -l '$WORK/dotfiles/claude.json' | cut -c1-10)\" = '-rw-r-----' ]"
"$BIN" uninstall >/dev/null
check "  as it does on uninstall" bash -c "[ -L '$HOME/.claude/settings.json' ] && jq -e '.hooks == null' '$WORK/dotfiles/claude.json' >/dev/null"

fresh_home
mkdir -p "$HOME/.local/bin" "$HOME/.claude/session-restore"
printf '#!/bin/sh\n' >"$HOME/.local/bin/claude-restore"
legacy_settings() { # claude-restore 0.1.0's three hooks, next to one of the user's own
  jq -n --arg bin "$HOME/.local/bin/claude-restore" '{hooks: {
    SessionStart: [{hooks: [{type: "command", command: ($bin + " record"), timeout: 10}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: ($bin + " record-once"), timeout: 10}]}],
    SessionEnd: [{hooks: [{type: "command", command: ($bin + " forget")}]}],
    Stop: [{hooks: [{type: "command", command: "say done"}]}]}}' >"$HOME/.claude/settings.json"
}
legacy_settings
out=$("$BIN" setup)
check "setup takes out the hooks of claude-restore 0.1.0, which respawn replaces" \
  bash -c "! grep -qE 'claude-restore (record|record-once|forget)' '$HOME/.claude/settings.json'"
check "  keeps the user's own and adds respawn's" \
  jq -e '.hooks.Stop[0].hooks[0].command == "say done" and ([.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.SessionEnd] | map(length) == [1, 1, 1])' "$HOME/.claude/settings.json"
check "  and says what claude-restore left behind" has "$out" "rm -f $HOME/.local/bin/claude-restore && rm -rf ~/.claude/session-restore"
legacy_settings
"$BIN" uninstall >/dev/null
check "uninstall takes them out too" jq -e '.hooks | keys == ["Stop"]' "$HOME/.claude/settings.json"

echo "installer"
fresh_home
mkdir -p "$HOME/.claude"
BIN_DIR="$HOME/.local/bin" bash "$ROOT/install.sh" >/dev/null
check "install.sh puts respawn on disk and it runs" "$HOME/.local/bin/respawn" --version
check "and sets up the agents it finds" jq -e '.hooks.SessionStart | length == 1' "$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin" bash "$ROOT/install.sh" --uninstall >/dev/null
check "install.sh --uninstall removes respawn" missing "$HOME/.local/bin/respawn"
check "and its hooks" jq -e '.hooks == null' "$HOME/.claude/settings.json"

rm -rf "$FAKES" "$STUBS"
echo
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
