#!/bin/sh
# Regression tests for scripts/handoff-prompt-hook.sh guards.
#
# Covers the hardening ported from claude-restart PR #1 (#1 "Harden restart
# hook"), adapted to handoff's watcher-owned-SIGTERM design:
#
#   - jq-optional prompt extraction: a "handoff" prompt must still trigger
#     when jq is not on PATH (previously the trigger silently no-op'd).
#   - wrapper-ancestor PID validation: a stale / inherited CLAUDE_HANDOFF_ID
#     must NOT hand off the wrong session — block with a reason instead of
#     touching another wrapper's sentinel.
#   - the not-wrapped case blocks via {"decision":"block"} (not exit 2).
#   - non-handoff prompts stay inert (unchanged behavior preserved).
#
# Each case runs the hook with an isolated HOME so sentinel files never
# touch the real ~/.claude/tmp.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/handoff-prompt-hook.sh"
TEST_PID=$$            # a genuine ancestor of the hook process when invoked below
PASS=0
FAIL=0

# Build a bin dir with every tool the hook (and its interpreter) needs EXCEPT
# jq, so Case B genuinely exercises the no-jq fallback. PATH stripping alone
# is not enough here: this machine ships /usr/bin/jq alongside the POSIX
# tools, so we symlink the allow-list and omit jq.
NOJQ=$(mktemp -d)
for t in sh grep sed awk tr cut head cat ps mkdir touch; do
  for d in /usr/bin /bin /usr/sbin /sbin; do
    [ -x "$d/$t" ] && { ln -s "$d/$t" "$NOJQ/$t"; break; }
  done
done
trap 'rm -rf "$NOJQ"' EXIT

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

# run_hook <prompt-json> <chid> <path-override>
# Sets: OUT, RC, TRIGGERED (1 if a handoff sentinel was created)
run_hook() {
  SANDBOX=$(mktemp -d)
  OUT=$(printf '%s' "$1" | HOME="$SANDBOX" PATH="$3" CLAUDE_HANDOFF_ID="$2" \
    sh "$HOOK" 2>"$SANDBOX/stderr")
  RC=$?
  if ls "$SANDBOX"/.claude/tmp/handoff-exit-* >/dev/null 2>&1; then
    TRIGGERED=1
  else
    TRIGGERED=0
  fi
  rm -rf "$SANDBOX"
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Case A — happy path: wrapper is an ancestor, jq available, "handoff" fires
run_hook '{"prompt":"handoff"}' "$TEST_PID" "$PATH"
if [ "$TRIGGERED" = 1 ] && contains "$OUT" '"reason":"Handoff initiated via hook"'; then
  ok "A: handoff triggers when wrapper is an ancestor"
else
  no "A: handoff triggers when wrapper is an ancestor (rc=$RC out=$OUT trig=$TRIGGERED)"
fi

# Case B — jq-optional: jq genuinely absent from PATH (NOJQ allow-list)
run_hook '{"prompt":"handoff: do the thing"}' "$TEST_PID" "$NOJQ"
if [ "$TRIGGERED" = 1 ] && contains "$OUT" '"reason":"Handoff initiated via hook"'; then
  ok "B: handoff still triggers without jq (grep/sed fallback)"
else
  no "B: handoff still triggers without jq (rc=$RC out=$OUT trig=$TRIGGERED)"
fi

# Case C — not wrapped: empty CLAUDE_HANDOFF_ID must block with a reason and
# create NO sentinel (no wrong-session handoff, no raw exit 2).
run_hook '{"prompt":"handoff"}' "" "$PATH"
if [ "$TRIGGERED" = 0 ] && [ "$RC" = 0 ] && contains "$OUT" '"decision":"block"' \
  && contains "$OUT" "not available"; then
  ok "C: no wrapper env -> blocked with reason, no sentinel"
else
  no "C: no wrapper env -> blocked with reason, no sentinel (rc=$RC out=$OUT trig=$TRIGGERED)"
fi

# Case D — stale/inherited env: CLAUDE_HANDOFF_ID set but NOT an ancestor.
# This is the wrong-session bug: must block, must NOT touch a sentinel.
run_hook '{"prompt":"handoff"}' "999999" "$PATH"
if [ "$TRIGGERED" = 0 ] && [ "$RC" = 0 ] && contains "$OUT" '"decision":"block"' \
  && contains "$OUT" "ancestor"; then
  ok "D: stale CLAUDE_HANDOFF_ID -> blocked, no wrong-session handoff"
else
  no "D: stale CLAUDE_HANDOFF_ID -> blocked, no wrong-session handoff (rc=$RC out=$OUT trig=$TRIGGERED)"
fi

# Case E — non-handoff prompt stays inert (regression guard for unchanged path)
run_hook '{"prompt":"hello there"}' "$TEST_PID" "$PATH"
if [ "$TRIGGERED" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; then
  ok "E: non-handoff prompt is inert"
else
  no "E: non-handoff prompt is inert (rc=$RC out=$OUT trig=$TRIGGERED)"
fi

# Case F — no eval query may itself trigger the hook.
#
# `claude --settings <overlay>` MERGES with user settings rather than replacing
# them (docs, cli-reference: "Values you set here override the same keys in your
# settings.json files for this session. Keys you omit keep their file-based
# values."). tests/eval-pty.sh's overlay sets only `permissions`, so every
# globally registered UserPromptSubmit hook — including this project's own
# handoff-prompt-hook.sh — is live inside every eval run.
#
# The collision is exact: the hook writes handoff-flag-$CLAUDE_HANDOFF_ID and
# the eval treats that same path as proof the *skill* fired. A query whose
# first word is "handoff" would therefore be scored PASS with the model never
# having seen it — a tautology, not a test.
#
# This replays every query through the real hook rather than re-implementing
# its keyword rule (tolower of $1, ':' onward stripped), so the check cannot
# drift from the logic it guards.
EVAL_DIR="$REPO/skills/session-handoff/evals"
if ! command -v jq >/dev/null 2>&1; then
  no "F: jq required to replay eval queries"
else
  F_TOTAL=0
  F_BAD=""
  for SET in "$EVAL_DIR"/trigger-eval.json "$EVAL_DIR"/trigger-eval-multilang.json; do
    [ -f "$SET" ] || { no "F: eval set missing: $SET"; continue; }
    # Index-driven rather than read-from-a-pipe: POSIX sh has no `read -d`,
    # and piping would move the counters into a subshell where they'd be lost.
    # jq builds the hook payload directly, so no query content is ever
    # reinterpreted by the shell.
    # A guard that skips what it cannot parse reports success for work it never
    # did. An unparseable set makes `jq length` fail and F_N empty, and because
    # the OTHER set keeps F_TOTAL above zero the emptiness check below would not
    # fire — 8 queries would go unchecked under a green "ok". So the count is
    # validated as a positive integer before it is trusted.
    F_N=$(jq 'length' "$SET" 2>/dev/null)
    case "$F_N" in
      ''|*[!0-9]*) no "F: $(basename "$SET") is not a readable JSON array"; continue ;;
      0)           no "F: $(basename "$SET") contains no queries"; continue ;;
    esac

    F_I=0
    while [ "$F_I" -lt "$F_N" ]; do
      # An entry with no `.query` string would replay as {"prompt":null}, which
      # the hook treats as an empty prompt and always ignores — counted, but
      # tested vacuously. A malformed entry must fail loudly instead, since the
      # tautology this case exists to catch could hide inside one.
      F_Q=$(jq -r ".[$F_I].query // empty" "$SET")
      if [ -z "$F_Q" ]; then
        no "F: entry $F_I of $(basename "$SET") has no non-empty .query string"
        F_I=$((F_I + 1))
        continue
      fi

      F_TOTAL=$((F_TOTAL + 1))
      run_hook "$(jq -c ".[$F_I] | {prompt: .query}" "$SET")" "$TEST_PID" "$PATH"
      if [ "$TRIGGERED" = 1 ]; then
        F_BAD="$F_BAD
    - $(printf '%s' "$F_Q" | cut -c1-60)"
      fi
      F_I=$((F_I + 1))
    done
  done

  if [ "$F_TOTAL" = 0 ]; then
    no "F: no eval queries were replayed (eval sets empty or unreadable)"
  elif [ -z "$F_BAD" ]; then
    ok "F: none of $F_TOTAL eval queries trigger the hook directly"
  else
    no "F: eval queries that fire the hook without the model (tautological PASS):$F_BAD"
  fi
fi

# Case G — every eval entry carries a usable `expect`.
#
# eval-pty.sh scores three behaviours (execute / propose / ignore) and skips an
# entry whose `expect` it does not recognise. A skip inside a ~100-minute run is
# a bad place to discover a typo, and the old boolean schema would be silently
# unusable rather than loud. This is the fast check that catches it.
#
# It also guards the migration itself: a leftover `should_trigger` key means an
# entry was never converted.
if command -v jq >/dev/null 2>&1; then
  G_BAD=""
  G_TOTAL=0
  for SET in "$EVAL_DIR"/trigger-eval.json "$EVAL_DIR"/trigger-eval-multilang.json; do
    [ -f "$SET" ] || continue
    G_OUT=$(jq -r '
      to_entries[]
      | select((.value.expect | IN("execute","propose","ignore")) | not)
        // empty
      | "\(.key):\(.value.expect // "<missing>")"
    ' "$SET" 2>/dev/null)
    G_LEGACY=$(jq -r '[.[] | select(has("should_trigger"))] | length' "$SET" 2>/dev/null)
    G_TOTAL=$((G_TOTAL + $(jq 'length' "$SET" 2>/dev/null || echo 0)))
    [ -n "$G_OUT" ] && G_BAD="$G_BAD
    - $(basename "$SET") entries with a bad expect: $(printf '%s' "$G_OUT" | tr '\n' ' ')"
    [ "${G_LEGACY:-0}" != 0 ] && G_BAD="$G_BAD
    - $(basename "$SET") still has $G_LEGACY unmigrated should_trigger entries"
  done

  if [ "$G_TOTAL" = 0 ]; then
    no "G: no eval entries found to validate"
  elif [ -z "$G_BAD" ]; then
    ok "G: all $G_TOTAL eval entries carry a valid expect value"
  else
    no "G: eval schema problems (eval-pty.sh would skip these):$G_BAD"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
