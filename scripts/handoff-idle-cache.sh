#!/bin/sh
# Stop hook, registered `async` + `asyncRewake`: wake an idle session shortly
# before its prompt cache expires, so it can hand off instead of re-writing its
# whole context on the owner's next message.
#
# Claude Code caches the prompt for an hour. A deep session left idle past that
# pays its full depth again, at cache-write price, the moment the owner comes
# back — measured 2026-09-25 over 14 days of transcripts: 49 returns after more
# than an hour at >=200k tokens, 16.5M tokens re-written. This hook sleeps ~54
# min after every Stop; if nothing happened since and the session is deep, it
# exits 2, which Claude Code shows the session as a system reminder, waking it
# while the cache is still warm. Whether to hand off is the session's call:
# SKILL.md, "Idle cache expiry". Covered by tests/idle-cache.sh.
#
# Silent (exit 0) when: stdin is a terminal, the session is not under the
# handoff wrapper (it could not hand off anyway), jq is missing, a newer Stop of
# the same session superseded this one, the transcript changed while waiting,
# the session is gone, the session is shallow, or this idle period already
# woke it once.
set -u
IDLE_S="${HANDOFF_IDLE_S:-3240}"
POLL_S="${HANDOFF_IDLE_POLL_S:-60}"
MIN_DEPTH="${HANDOFF_IDLE_MIN_DEPTH:-200000}"
TAG="[handoff-idle]"

[ -t 0 ] && exit 0
[ -n "${CLAUDE_HANDOFF_ID:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
IN=$(cat)
SID=$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$SID" ] && [ -f "$TP" ] || exit 0

DIR="$HOME/.claude/tmp"
mkdir -p "$DIR" 2>/dev/null || exit 0
# One arm file per session ever run; prune this hook's own state after a week.
find "$DIR" -maxdepth 1 -name 'handoff-idle-*' -mtime +7 -delete 2>/dev/null
ARM="$DIR/handoff-idle-arm-$SID"    # token of this session's newest Stop
WOKE="$DIR/handoff-idle-woke-$SID"  # last real prompt when the session was woken

# Timestamp of the last prompt a person typed: not a meta line, not a subagent
# notification, not this hook's own reminder if Claude Code records it.
last_prompt() {
  jq -r --arg tag "$TAG" 'select(.type == "user" and (.message.content | type) == "string"
      and (.isMeta | not)
      and (.message.content | startswith("<task-notification>") | not)
      and (.message.content | contains($tag) | not)) | .timestamp // empty' "$TP" 2>/dev/null | tail -1
}

# One wake per idle period. The woken turn ends with a Stop of its own; arming
# again on it would re-read the cache every hour, all night, keeping it warm for
# nobody. Only a new real prompt starts a new idle period.
PROMPT=$(last_prompt)
[ -f "$WOKE" ] && [ "$(cat "$WOKE")" = "$PROMPT" ] && exit 0

TOKEN="$$"
printf '%s' "$TOKEN" > "$ARM"

size() { wc -c < "$TP" 2>/dev/null | tr -d ' '; }

# Lines written right after Stop (hook bookkeeping) are not activity, so the
# baseline is taken after the first poll, not at arm time.
WAITED=0
BASE=""
while [ "$WAITED" -lt "$IDLE_S" ]; do
  sleep "$POLL_S"
  WAITED=$((WAITED + POLL_S))
  [ "$(cat "$ARM" 2>/dev/null)" = "$TOKEN" ] || exit 0
  [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = 1 ] && exit 0
  [ -n "$BASE" ] || BASE=$(size)
done
[ "$(size)" = "$BASE" ] || exit 0

DEPTH=$(jq -r 'select(.message.usage) | .message.usage
    | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' \
    "$TP" 2>/dev/null | tail -1)
[ -n "$DEPTH" ] && [ "$DEPTH" -ge "$MIN_DEPTH" ] || exit 0

printf '%s' "$PROMPT" > "$WOKE"
printf '%s Idle ~%s min at ~%sk tokens of context. The prompt cache expires at 60 min, and the owner'"'"'s next message would re-write all of it. If a standing handoff grant covers this session and a handoff is safe now, hand off with `mode: idle` as the brief'"'"'s second line (session-handoff skill, "Idle cache expiry"). Otherwise end the turn with one line.\n' \
  "$TAG" "$((IDLE_S / 60))" "$((DEPTH / 1000))" >&2
exit 2
