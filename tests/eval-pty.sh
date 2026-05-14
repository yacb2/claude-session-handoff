#!/bin/sh
# PTY-based interactive trigger eval for the session-handoff skill.
#
# Why this exists: tests/eval-trigger.sh runs the skill-creator harness via
# `claude -p` against a slash-command shim. In one-shot headless mode the model
# refuses to invoke a tool described as "kill/restart the session", so the
# harness reports 0% recall — see .context/references/testing/00-index.md.
#
# This harness drives a *real* interactive claude session via expect, lets the
# skill execute its actual body, and checks the side effect the skill produces
# (the handoff-flag-<id> marker file). No -p, no shim, no destructive action
# against the test process — we fake the wrapper by only setting
# CLAUDE_HANDOFF_ID, so the skill writes the marker and touches the exit
# trigger, but no watcher is listening and the session stays alive until we
# send /exit.
#
# Requires: expect, jq, the session-handoff skill installed in ~/.claude/skills/.
# Usage:    ./tests/eval-pty.sh [--query-limit N] [--timeout SECONDS]

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_SET="$REPO/skills/session-handoff/evals/trigger-eval.json"
TMP_DIR="${HOME}/.claude/tmp"
PER_QUERY_TIMEOUT=150
QUERY_LIMIT=0  # 0 = no limit
MODEL="claude-sonnet-4-6"

while [ $# -gt 0 ]; do
  case "$1" in
    --query-limit) QUERY_LIMIT="$2"; shift 2 ;;
    --timeout)     PER_QUERY_TIMEOUT="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --eval-set)    EVAL_SET="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v expect >/dev/null || { echo "expect not installed"; exit 1; }
command -v jq     >/dev/null || { echo "jq not installed"; exit 1; }
command -v claude >/dev/null || { echo "claude not in PATH"; exit 1; }
[ -f "$EVAL_SET" ] || { echo "eval set not found: $EVAL_SET"; exit 1; }
[ -d "$HOME/.claude/skills/session-handoff" ] \
  || { echo "session-handoff skill not installed at ~/.claude/skills/"; exit 1; }

mkdir -p "$TMP_DIR"

# Settings overlay: pre-approves the bash commands the skill body runs, so we
# don't need to drive the bypassPermissions dialog and can run in default mode.
SETTINGS_OVERLAY=$(mktemp -t eval-pty-settings.XXXXXX.json)
cat > "$SETTINGS_OVERLAY" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(touch:*)",
      "Bash(cat:*)",
      "Bash(printf:*)",
      "Bash(sh:*)",
      "Bash(test:*)",
      "Bash(echo:*)",
      "Write"
    ]
  }
}
JSON
trap 'rm -f "$SETTINGS_OVERLAY"' EXIT

# Per-query expect runner. Returns 0 if the marker file is created.
#
# Key mechanics:
# - --settings overlay pre-approves the skill's bash commands (no permission
#   dialog, no bypassPermissions warning).
# - Enter is sent as the kitty-protocol code "\x1b[13u" because Claude Code
#   runs in CSI-u disambiguated mode where bare "\r" is interpreted as a
#   newline inside the input editor instead of submit.
# - The polling loop uses `expect -timeout 1 -re ".+"` instead of `sleep 1`
#   so the PTY keeps draining — without that the spawned claude blocks on
#   output and never finishes thinking.
run_one() {
  HANDOFF_ID="$1"
  QUERY="$2"
  TIMEOUT="$3"
  FLAG_FILE="$TMP_DIR/handoff-flag-$HANDOFF_ID"
  PAYLOAD_FILE="$TMP_DIR/handoff-payload-$HANDOFF_ID"
  EXIT_TRIGGER="$TMP_DIR/handoff-exit-$HANDOFF_ID"
  rm -f "$FLAG_FILE" "$PAYLOAD_FILE" "$EXIT_TRIGGER"

  CLAUDE_HANDOFF_ID="$HANDOFF_ID" expect <<EXP >/dev/null 2>&1 || true
    set timeout [expr {$TIMEOUT + 30}]
    log_user 0
    spawn -noecho claude --settings $SETTINGS_OVERLAY --model $MODEL
    # Drain startup output (5s, no real match).
    expect -timeout 5 -re "no_match_drain"
    send -- {$QUERY}
    send -- "\x1b\[13u"
    set deadline [expr {[clock seconds] + $TIMEOUT}]
    while {[clock seconds] < \$deadline} {
      expect -timeout 1 -re ".+"
      if {[file exists "$FLAG_FILE"]} { break }
    }
    send -- "/exit"
    send -- "\x1b\[13u"
    expect eof
EXP

  if [ -f "$FLAG_FILE" ]; then
    rm -f "$FLAG_FILE" "$PAYLOAD_FILE" "$EXIT_TRIGGER"
    return 0
  fi
  return 1
}

QUERIES=$(jq -c '.[]' "$EVAL_SET")
TOTAL=0
HITS=0
N=0

echo "# eval-pty: session-handoff trigger eval"
echo "# eval-set: $EVAL_SET"
echo "# per-query timeout: ${PER_QUERY_TIMEOUT}s"
echo

printf '%s\n' "$QUERIES" | while IFS= read -r row; do
  N=$((N + 1))
  if [ "$QUERY_LIMIT" -gt 0 ] && [ "$N" -gt "$QUERY_LIMIT" ]; then break; fi

  SHOULD=$(printf '%s' "$row" | jq -r '.should_trigger')
  QUERY=$(printf '%s' "$row"  | jq -r '.query')
  HANDOFF_ID="eval-$$-$N"

  PREVIEW=$(printf '%s' "$QUERY" | cut -c1-70)
  printf '[%02d] should_trigger=%s :: %s ... ' "$N" "$SHOULD" "$PREVIEW"

  if run_one "$HANDOFF_ID" "$QUERY" "$PER_QUERY_TIMEOUT"; then
    TRIGGERED=true
  else
    TRIGGERED=false
  fi

  if [ "$SHOULD" = "true" ] && [ "$TRIGGERED" = "true" ]; then
    echo "PASS (triggered)"
    HITS=$((HITS + 1))
  elif [ "$SHOULD" = "false" ] && [ "$TRIGGERED" = "false" ]; then
    echo "PASS (correctly skipped)"
    HITS=$((HITS + 1))
  elif [ "$SHOULD" = "true" ] && [ "$TRIGGERED" = "false" ]; then
    echo "FAIL (missed)"
  else
    echo "FAIL (false positive)"
  fi
  TOTAL=$((TOTAL + 1))
  # Counters lost across pipe subshells in POSIX sh — write to disk.
  echo "$TOTAL $HITS" > "$TMP_DIR/eval-pty-tally-$$"
done

if [ -f "$TMP_DIR/eval-pty-tally-$$" ]; then
  read TOTAL HITS < "$TMP_DIR/eval-pty-tally-$$"
  rm -f "$TMP_DIR/eval-pty-tally-$$"
fi

echo
echo "# result: $HITS / $TOTAL"
[ "$TOTAL" -eq 0 ] || [ "$HITS" -eq "$TOTAL" ]
