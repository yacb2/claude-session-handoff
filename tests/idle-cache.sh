#!/bin/sh
# Suite for scripts/handoff-idle-cache.sh — the async Stop hook that wakes an
# idle session before its prompt cache expires.
#
# Timing is shrunk through the hook's own env knobs (HANDOFF_IDLE_S,
# HANDOFF_IDLE_POLL_S), so the suite runs in seconds. Every case that must stay
# silent has a control that must wake, built from the same transcript, so a
# hook that never wakes cannot pass by silence alone.
#
#   sh tests/idle-cache.sh   (also under dash)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/handoff-idle-cache.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

BOX=$(mktemp -d)
TP="$BOX/session.jsonl"

# transcript DEPTH — one real prompt, one assistant turn at that depth.
transcript() {
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-09-25T10:00:00Z","message":{"role":"user","content":"hola"}}' \
    "{\"type\":\"assistant\",\"timestamp\":\"2026-09-25T10:00:05Z\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":5,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":$(($1 - 1005)),\"output_tokens\":300}}}" \
    > "$TP"
}

# fire [SID] — run the hook as Claude Code would, fast timings. Sets RC, ERR.
fire() {
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "${1:-S1}" "$TP" \
    | HOME="$BOX" CLAUDE_HANDOFF_ID=4242 HANDOFF_IDLE_S=2 HANDOFF_IDLE_POLL_S=1 \
      sh "$HOOK" 2>"$BOX/err"
  RC=$?
  ERR=$(cat "$BOX/err")
}

# 1. deep and idle -> exit 2 with the tagged message (the control for 2-6)
transcript 250000
fire S1
if [ "$RC" = 2 ] && contains "$ERR" "[handoff-idle]" && contains "$ERR" "~250k" \
    && contains "$ERR" "mode: idle"; then
  ok "1: a deep idle session is woken with the tagged message"
else
  no "1: deep idle session not woken (rc=$RC err=[$ERR])"
fi

# 2. the Stop that ends the woken turn must not arm again: no new real prompt
#    since the wake, so another wake would only re-read the cache every hour.
fire S1
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then
  ok "2: the woken turn's own Stop does not re-arm"
else
  no "2: re-armed after a wake with no new prompt (rc=$RC)"
fi
#    ...and a wake-tagged reminder recorded as a user line is not a new prompt
printf '%s\n' '{"type":"user","timestamp":"2026-09-25T11:00:00Z","message":{"role":"user","content":"<system-reminder>[handoff-idle] Idle ~54 min</system-reminder>"}}' >> "$TP"
fire S1
if [ "$RC" = 0 ]; then
  ok "2: the wake reminder itself does not count as a new prompt"
else
  no "2: the wake reminder re-armed the hook (rc=$RC)"
fi
#    ...but a real prompt after the wake does re-arm (control)
printf '%s\n' '{"type":"user","timestamp":"2026-09-25T12:00:00Z","message":{"role":"user","content":"sigue"}}' >> "$TP"
fire S1
if [ "$RC" = 2 ]; then
  ok "2: a real prompt after the wake re-arms"
else
  no "2: a real prompt after the wake did not re-arm (rc=$RC)"
fi

# 3. shallow session -> silent
transcript 120000
fire S3
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then
  ok "3: a shallow session is left alone"
else
  no "3: shallow session woken (rc=$RC)"
fi

# 4. activity after the Stop -> silent. The line lands after the settle poll,
#    so it reads as a turn in flight, not as post-Stop bookkeeping.
transcript 250000
( sleep 1.5; printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}' >> "$TP" ) &
fire S4
wait
if [ "$RC" = 0 ]; then
  ok "4: a transcript that changed while waiting is not idle"
else
  no "4: woke despite activity (rc=$RC)"
fi

# 5. superseded: a newer Stop of the same session wins, the older one is silent
transcript 250000
( fire S5; echo "$RC" > "$BOX/rc-old" ) &
sleep 1
fire S5
wait
if [ "$(cat "$BOX/rc-old")" = 0 ] && [ "$RC" = 2 ]; then
  ok "5: only the newest Stop of a session can wake it"
else
  no "5: superseded Stop woke too (old=$(cat "$BOX/rc-old") new=$RC)"
fi

# 6. not under the handoff wrapper -> silent at once (it could not hand off)
transcript 250000
printf '{"session_id":"S6","transcript_path":"%s"}' "$TP" \
  | HOME="$BOX" CLAUDE_HANDOFF_ID= HANDOFF_IDLE_S=2 HANDOFF_IDLE_POLL_S=1 sh "$HOOK" 2>/dev/null
if [ "$?" = 0 ]; then
  ok "6: a session outside the wrapper is never woken"
else
  no "6: woke a session that cannot hand off"
fi

# 7. state files of sessions long gone do not pile up: one arm file per session
#    ever run, so the hook prunes its own files older than 7 days on every Stop.
mkdir -p "$BOX/.claude/tmp"
touch -t 202601010000 "$BOX/.claude/tmp/handoff-idle-arm-OLD" "$BOX/.claude/tmp/handoff-idle-woke-OLD"
touch "$BOX/.claude/tmp/handoff-other-OLD"
touch -t 202601010000 "$BOX/.claude/tmp/handoff-other-OLD"
transcript 120000
fire S7
if [ ! -e "$BOX/.claude/tmp/handoff-idle-arm-OLD" ] && [ ! -e "$BOX/.claude/tmp/handoff-idle-woke-OLD" ] \
    && [ -e "$BOX/.claude/tmp/handoff-other-OLD" ] && [ -e "$BOX/.claude/tmp/handoff-idle-arm-S7" ]; then
  ok "7: stale idle state is pruned, other files and fresh state are kept"
else
  no "7: pruning wrong ($(ls "$BOX/.claude/tmp" | tr '\n' ' '))"
fi

rm -rf "$BOX"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
