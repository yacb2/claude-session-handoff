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
# Eval-set schema (both files in skills/session-handoff/evals/):
#
#   [ { "query": "...", "expect": "execute" | "propose" | "ignore" }, ... ]
#
# `expect` names the behaviour SKILL.md mandates, not merely whether the skill
# is relevant. The earlier boolean `should_trigger` could not express this: it
# scored PASS only when the marker appeared, so the proactive and soft-signal
# queries — where the skill must ask FIRST — were scored FAIL for behaving
# correctly, and PASS only when the model broke the propose-first rule. Roughly
# 30% of the positives were unwinnable, which put a structural ceiling under
# every measurement taken with it.
#
# Requires: expect, jq, the session-handoff skill installed in ~/.claude/skills/.
# Usage:    ./tests/eval-pty.sh [--query-limit N] [--timeout SECONDS]
#                               [--eval-set FILE] [--model NAME]

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
#
# Three-way scoring. SKILL.md defines three behaviours, and the marker file
# alone only separates "executed" from "did not". Collapsing that into a
# boolean is what made ~30% of the positives unwinnable: a query the skill
# must PROPOSE on scored FAIL for behaving correctly, and scored PASS only by
# violating the propose-first rule.
#
# `propose` is therefore measured with a second turn rather than by parsing the
# reply. Text parsing is not an option here — the PTY log echoes the query
# itself, so grepping for "handoff" matches the user's own words. Confirming is
# mechanical and uses the same trustworthy signal:
#
#   execute -> the marker must appear on turn 1.
#   ignore  -> the marker must never appear.
#   propose -> the marker must NOT appear on turn 1, and MUST appear after a
#              confirmation. That is exactly SKILL.md's "Only execute after
#              they confirm."
#
# Known weak spot, recorded rather than papered over: a model that ignores a
# `propose` query entirely and then executes on the bare confirmation scores a
# false PASS. It cannot produce a false PASS for the failure this fixes — an
# immediate un-asked execution always fails turn 1.
run_one() {
  HANDOFF_ID="$1"
  QUERY="$2"
  TIMEOUT="$3"
  MODE="$4"
  FLAG_FILE="$TMP_DIR/handoff-flag-$HANDOFF_ID"
  PAYLOAD_FILE="$TMP_DIR/handoff-payload-$HANDOFF_ID"
  EXIT_TRIGGER="$TMP_DIR/handoff-exit-$HANDOFF_ID"
  HELD_FILE="$TMP_DIR/handoff-held-$HANDOFF_ID"
  rm -f "$FLAG_FILE" "$PAYLOAD_FILE" "$EXIT_TRIGGER" "$HELD_FILE"

  CLAUDE_HANDOFF_ID="$HANDOFF_ID" expect <<EXP >/dev/null 2>&1 || true
    set timeout [expr {$TIMEOUT + 30}]
    log_user 0
    spawn -noecho claude --settings $SETTINGS_OVERLAY --model $MODEL
    # Wait for the session to be up before starting the clock, so the measured
    # window is model time and not startup time.
    expect -timeout 60 -re {auto mode|Welcome back|Try "}
    send -- {$QUERY}
    send -- "\x1b\[13u"
    set deadline [expr {[clock seconds] + $TIMEOUT}]
    while {[clock seconds] < \$deadline} {
      expect -timeout 1 -re ".+"
      if {[file exists "$FLAG_FILE"]} { break }
    }
    # Turn 2, only for propose, and only if turn 1 correctly held off.
    if {"$MODE" == "propose" && ![file exists "$FLAG_FILE"]} {
      exec touch "$HELD_FILE"
      send -- {sí, hazlo / yes, go ahead}
      send -- "\x1b\[13u"
      set deadline2 [expr {[clock seconds] + $TIMEOUT}]
      while {[clock seconds] < \$deadline2} {
        expect -timeout 1 -re ".+"
        if {[file exists "$FLAG_FILE"]} { break }
      }
    }
    send -- "/exit"
    send -- "\x1b\[13u"
    expect eof
EXP

  FIRED=1; [ -f "$FLAG_FILE" ] && FIRED=0
  HELD=1;  [ -f "$HELD_FILE" ] && HELD=0
  rm -f "$FLAG_FILE" "$PAYLOAD_FILE" "$EXIT_TRIGGER" "$HELD_FILE"

  case "$MODE" in
    execute) [ "$FIRED" = 0 ] && return 0
             VERDICT="never executed"; return 1 ;;
    ignore)  [ "$FIRED" = 1 ] && return 0
             VERDICT="executed on a query it should have left alone"; return 1 ;;
    propose) if [ "$HELD" != 0 ]; then
               VERDICT="executed immediately instead of proposing"; return 1
             fi
             [ "$FIRED" = 0 ] && return 0
             VERDICT="held off, but did not execute after confirmation"; return 1 ;;
    *)       VERDICT="unknown expect value '$MODE'"; return 1 ;;
  esac
}

QUERIES=$(jq -c '.[]' "$EVAL_SET")
TOTAL=0
HITS=0
N=0
BAD=0
# Per-mode tallies: an aggregate score hides which behaviour is broken, and
# `propose` is the one this schema exists to measure.
H_execute=0; T_execute=0
H_propose=0; T_propose=0
H_ignore=0;  T_ignore=0

echo "# eval-pty: session-handoff trigger eval"
echo "# eval-set: $EVAL_SET"
echo "# per-query timeout: ${PER_QUERY_TIMEOUT}s"
echo

# Here-doc, not a pipe: a `printf | while` loop body runs in a subshell in
# POSIX sh, which is why the counters previously had to round-trip through a
# file on disk. Feeding the loop by redirect keeps them in this shell.
while IFS= read -r row; do
  [ -n "$row" ] || continue
  N=$((N + 1))
  if [ "$QUERY_LIMIT" -gt 0 ] && [ "$N" -gt "$QUERY_LIMIT" ]; then break; fi

  MODE=$(printf '%s' "$row"  | jq -r '.expect // empty')
  QUERY=$(printf '%s' "$row" | jq -r '.query // empty')

  case "$MODE" in
    execute|propose|ignore) ;;
    *) printf '[%02d] SKIP :: unusable entry (expect=%s)\n' "$N" "${MODE:-<missing>}"
       BAD=$((BAD + 1)); continue ;;
  esac

  HANDOFF_ID="eval-$$-$N"
  PREVIEW=$(printf '%s' "$QUERY" | cut -c1-64)
  printf '[%02d] %-7s :: %s ... ' "$N" "$MODE" "$PREVIEW"

  VERDICT=""
  if run_one "$HANDOFF_ID" "$QUERY" "$PER_QUERY_TIMEOUT" "$MODE"; then
    echo "PASS"
    HITS=$((HITS + 1))
    eval "H_$MODE=\$((H_$MODE + 1))"
  else
    echo "FAIL ($VERDICT)"
  fi
  TOTAL=$((TOTAL + 1))
  eval "T_$MODE=\$((T_$MODE + 1))"
done <<QUERY_ROWS
$QUERIES
QUERY_ROWS

echo
echo "# execute : $H_execute / $T_execute"
echo "# propose : $H_propose / $T_propose"
echo "# ignore  : $H_ignore / $T_ignore"
echo "# result  : $HITS / $TOTAL"
[ "$BAD" -eq 0 ] || echo "# WARNING: $BAD entries skipped as unusable"
[ "$TOTAL" -gt 0 ] && [ "$BAD" -eq 0 ] && [ "$HITS" -eq "$TOTAL" ]
