#!/bin/sh
# UserPromptSubmit hook for claude-session-handoff.
# Intercepts "handoff" or "handoff: <text>" prompts and executes the handoff
# directly, bypassing the model (zero tokens consumed for the trigger itself).
#
#   handoff           → fresh session, no seeded context (with warning in wrapper)
#   handoff: <text>   → fresh session, <text> injected as additionalContext
#
# Requires: CLAUDE_HANDOFF_ID env var (set by the wrapper).
# Optional: jq (falls back to grep/sed if missing, so the trigger never
# silently no-ops on a machine without jq).

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
else
  PROMPT=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^"prompt"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi

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

# Verify the handoff wrapper is actually an ancestor of this process.
#
# A stale or inherited CLAUDE_HANDOFF_ID (SSH forwarding, tmux, a nested
# claude started outside the wrapper) would otherwise make us touch the
# sentinel of a *different* wrapper's watcher and hand off the wrong
# session. A non-empty env var is not enough — the wrapper PID must be in
# this process's ancestor chain.
#
# Known limitation: a nested claude started without the wrapper still has
# the outer wrapper in its ancestor chain, so this passes for it. A full
# fix needs a per-invocation token from the wrapper — out of scope for
# this hook-only guard. Still strictly better than accepting any
# non-empty value.
is_wrapper_ancestor() {
  _pid=$$
  while true; do
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    case "$_pid" in
      ''|0|1) return 1 ;;
    esac
    [ "$_pid" = "$CLAUDE_HANDOFF_ID" ] && return 0
  done
}

if [ -z "$CLAUDE_HANDOFF_ID" ]; then
  MSG="handoff is not available — this session was started without the handoff wrapper."
  MSG="$MSG Start a new terminal and run claude to use handoff."
  printf '{"decision":"block","reason":"%s"}' "$MSG"
  exit 0
fi

if ! is_wrapper_ancestor; then
  MSG="handoff is not available — wrapper PID $CLAUDE_HANDOFF_ID is not an ancestor of this session (stale or inherited env var?)."
  MSG="$MSG Start a new terminal and run claude to use handoff."
  printf '{"decision":"block","reason":"%s"}' "$MSG"
  exit 0
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
