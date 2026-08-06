#!/bin/sh
# SessionStart hook for claude-session-handoff.
# If a handoff payload exists for this wrapper, inject it as additionalContext
# and delete the file (one-shot — payload only seeds the very next session).
#
# Requires: jq, CLAUDE_HANDOFF_ID env var (set by handoff-wrapper.sh).

WRAPPER_ID="${CLAUDE_HANDOFF_ID:-}"
if [ -z "$WRAPPER_ID" ]; then
  exit 0
fi

PAYLOAD_FILE="${HOME}/.claude/tmp/handoff-payload-${WRAPPER_ID}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  exit 0
fi

PAYLOAD=$(cat "$PAYLOAD_FILE")

if [ -z "$PAYLOAD" ]; then
  rm -f "$PAYLOAD_FILE"
  exit 0
fi

WRAPPED=$(printf '=== HANDOFF FROM PREVIOUS SESSION ===\n%s\n=== END HANDOFF ===\n\nYou are starting a fresh session. The text above is the handoff brief from the previous session — treat it as authoritative context.\n\nIMPORTANT — opening behavior:\nOn the user'"'"'s very first message in this session (whatever it is, even "hola", "continue", or an unrelated question), you MUST begin your reply with a one-line acknowledgement in the user'"'"'s language indicating that this is a fresh session seeded from a previous handoff, followed by a one-sentence summary of the handoff brief. Example: "Handoff recibido — vengo de la sesión previa con: <resumen de 1 frase>." Then address the user'"'"'s message normally, resuming from where the previous session left off based on the brief.' "$PAYLOAD")

PAYLOAD_BYTES=$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')
BANNER="↻ Handoff recibido — sesión nueva sembrada con ${PAYLOAD_BYTES} bytes de la sesión previa. Cuando escribas, Claude abrirá confirmando el handoff."

# Opt-in audible bell. Default OFF: a handoff is not always something the user
# is waiting on, and an unrequested bell is worse than no bell.
#
# terminalSequence is a TOP-LEVEL field (peer of hookSpecificOutput), and its
# value is a raw escape string Claude Code writes verbatim to the PTY. Only
# OSC 0/1/2, 9, 99, 777 and bare BEL are allowed; anything else is silently
# dropped. Bare BEL is used here because it is the one form every terminal
# handles — the OSC notification variants each need a different sequence per
# terminal emulator.
#
# Verified live on 2.1.221, not taken from the docs: the exact bytes were
# grepped out of a PTY log. Two neighbouring SessionStart fields
# (initialUserMessage, sessionTitle) are documented and do nothing, so on this
# hook "the docs say so" is not evidence. See
# .context/proofs/sessionstart-initialusermessage/.
BELL_SEQ=""
if [ "${HANDOFF_BELL:-0}" = "1" ]; then
  BELL_SEQ=$(printf '\007')
fi

# additionalContext  -> goes to Claude's context (invisible to user)
# systemMessage      -> shown to user on session start (the docs-supported way
#                       to surface text at start; additionalContext alone is silent)
# terminalSequence   -> omitted entirely unless the bell is opted in
# Emit FIRST, delete only on success. The payload is the previous session's
# only copy of its context; deleting it before jq has produced output means any
# failure in between — jq missing, jq erroring — loses the brief irrecoverably
# and the new session starts blank with no indication anything was lost.
# One-shot semantics are preserved: the file is removed once it has been
# emitted. Covered by hook-guard.sh Case J.
if OUTPUT=$(jq -nc \
  --arg ctx "$WRAPPED" \
  --arg msg "$BANNER" \
  --arg seq "$BELL_SEQ" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $ctx
    },
    systemMessage: $msg
  }
  + (if $seq == "" then {} else {terminalSequence: $seq} end)'); then
  printf '%s\n' "$OUTPUT"
  rm -f "$PAYLOAD_FILE"
fi
