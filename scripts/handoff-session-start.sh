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
rm -f "$PAYLOAD_FILE"

if [ -z "$PAYLOAD" ]; then
  exit 0
fi

WRAPPED=$(printf '=== HANDOFF FROM PREVIOUS SESSION ===\n%s\n=== END HANDOFF ===\n\nYou are starting a fresh session. The text above is the handoff brief from the previous session — treat it as authoritative context.\n\nIMPORTANT — opening behavior:\nOn the user'"'"'s very first message in this session (whatever it is, even "hola", "continue", or an unrelated question), you MUST begin your reply with a one-line acknowledgement in the user'"'"'s language indicating that this is a fresh session seeded from a previous handoff, followed by a one-sentence summary of the handoff brief. Example: "Handoff recibido — vengo de la sesión previa con: <resumen de 1 frase>." Then address the user'"'"'s message normally, resuming from where the previous session left off based on the brief.' "$PAYLOAD")

PAYLOAD_BYTES=$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')
BANNER="↻ Handoff recibido — sesión nueva sembrada con ${PAYLOAD_BYTES} bytes de la sesión previa. Cuando escribas, Claude abrirá confirmando el handoff."

# additionalContext  -> goes to Claude's context (invisible to user)
# systemMessage      -> shown to user on session start (the docs-supported way
#                       to surface text at start; additionalContext alone is silent)
jq -nc \
  --arg ctx "$WRAPPED" \
  --arg msg "$BANNER" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $ctx
    },
    systemMessage: $msg
  }'
