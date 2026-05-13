#!/bin/sh
# UserPromptSubmit hook for claude-session-handoff.
# Intercepts "handoff" or "handoff: <text>" prompts and executes the handoff
# directly, bypassing the model (zero tokens consumed for the trigger itself).
#
#   handoff           → fresh session, no seeded context (with warning in wrapper)
#   handoff: <text>   → fresh session, <text> injected as additionalContext
#
# Requires: jq, CLAUDE_HANDOFF_ID env var (set by the wrapper).

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

# Trim surrounding whitespace
TRIMMED=$(printf '%s' "$PROMPT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Extract leading keyword (case-insensitive), preserving payload casing
KEYWORD=$(printf '%s' "$TRIMMED" | awk '{print tolower($1)}' | sed 's/:.*$//')

case "$KEYWORD" in
  handoff)
    ;;
  *)
    exit 0
    ;;
esac

# Detect payload — anything after "handoff" or "handoff:"
PAYLOAD=""
LOWER=$(printf '%s' "$TRIMMED" | tr '[:upper:]' '[:lower:]')
case "$LOWER" in
  handoff)
    PAYLOAD=""
    ;;
  handoff:*)
    # Strip the leading "handoff:" (case-insensitive, 8 chars) + optional whitespace
    PAYLOAD=$(printf '%s' "$TRIMMED" | cut -c9- | sed 's/^[[:space:]]*//')
    ;;
  *)
    # "handoff something" without colon — treat the rest as payload
    PAYLOAD=$(printf '%s' "$TRIMMED" | sed 's/^[hH][aA][nN][dD][oO][fF][fF][[:space:]]*//')
    ;;
esac

if [ -z "$CLAUDE_HANDOFF_ID" ]; then
  echo "handoff: not running inside handoff-wrapper — use /handoff instead, or launch claude via the wrapper" >&2
  exit 2
fi

HANDOFF_DIR="${HOME}/.claude/tmp"
mkdir -p "$HANDOFF_DIR"

PAYLOAD_FILE="${HANDOFF_DIR}/handoff-payload-${CLAUDE_HANDOFF_ID}"
FLAG_FILE="${HANDOFF_DIR}/handoff-flag-${CLAUDE_HANDOFF_ID}"
EXIT_TRIGGER="${HANDOFF_DIR}/handoff-exit-${CLAUDE_HANDOFF_ID}"

if [ -n "$PAYLOAD" ]; then
  printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"
fi
touch "$FLAG_FILE"
# Signal the wrapper's watcher to terminate claude. The watcher (started by
# claude-wrapper.sh v4+) polls this sentinel and sends SIGTERM itself, so the
# hook never needs to invoke `kill` directly.
touch "$EXIT_TRIGGER"

printf '{"decision":"block","reason":"Handoff initiated via hook"}'
exit 0
