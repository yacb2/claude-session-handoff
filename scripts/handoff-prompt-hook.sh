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

# `printf '%s'`, never `echo`: /bin/sh on macOS (bash with xpg_echo) and dash
# both interpret backslash escapes in echo, so the JSON's \n became a real
# newline INSIDE a JSON string and jq rejected the whole object. stderr is
# discarded, so a multi-line handoff prompt silently did nothing at all — on
# the primary, documented path. Covered by hook-guard.sh Case H.
TRANSCRIPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
  # Probed on 2.1.224, not read off the docs: UserPromptSubmit stdin carries
  # cwd, hook_event_name, permission_mode, prompt, prompt_id, session_id and
  # transcript_path. See .context/proofs/handoff-ask-when-present/.
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
else
  # The fallback must decode JSON, not merely find it. A `[^"]*` match ends at
  # the first ESCAPED quote, so `handoff: fix the \"parser\" bug` arrived as
  # `handoff: fix the \` — the rest of the brief silently lost. And without
  # unescaping, a multi-line brief arrives carrying literal two-character \n
  # sequences, which is the same "the brief read is not the brief written"
  # failure the jq path was fixed for. Covered by hook-guard.sh Cases H and K,
  # which now run under BOTH paths.
  #
  # `(([^"\\]|\\.)*)` is a JSON string body: any char that is neither quote
  # nor backslash, or any escaped pair. Unescaping order matters — backslash
  # last, so a literal \\n is not turned into a newline.
  PROMPT=$(printf '%s' "$INPUT" \
    | sed -nE 's/.*"prompt"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
    | sed -e 's/\\n/\
/g' -e 's/\\t/\t/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
fi

# Trim surrounding whitespace at STRING level. `sed 's/^[[:space:]]*//'` is
# line-oriented and would strip the indentation of every line of the brief;
# a handoff payload is multi-line by construction and its formatting matters.
TRIMMED=${PROMPT#"${PROMPT%%[![:space:]]*}"}
TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}

# Leading keyword, payload casing preserved. Taken with parameter expansion
# rather than awk, which printed field 1 of EVERY line.
#
# The case-insensitive match is a glob rather than a `tr` pipeline because this
# gate runs on EVERY prompt submit in every session, and ~100% of them are not
# handoffs — it is the one line in this hook on a hot path, so it pays no forks.
FIRSTWORD=${TRIMMED%%[[:space:]]*}

case "${FIRSTWORD%%:*}" in
  [Hh][Aa][Nn][Dd][Oo][Ff][Ff])
    ;;
  *)
    exit 0
    ;;
esac

# Detect payload — anything after "handoff" or "handoff:".
# Branch on FIRSTWORD, which is already computed: the gate above has already
# established that it is `handoff` or `handoff:...`. The previous form
# lowercased the ENTIRE multi-line brief with tr just to test its first token,
# and parsed the prompt a second time under a different grammar.
case "$FIRSTWORD" in
  *:*)
    # Everything after the first colon. `cut -c9-` was line-oriented and cut 8
    # characters off EVERY line: "Next phase is the parser." arrived as
    # "se is the parser.". Covered by hook-guard.sh Case H.
    REST=${TRIMMED#*:}
    ;;
  *)
    # "handoff" alone, or "handoff something" without a colon. Stripping the
    # first word yields "" in the bare case, so both fold into one arm.
    REST=${TRIMMED#"$FIRSTWORD"}
    ;;
esac
# One leading-whitespace strip for every arm, rather than one per arm.
PAYLOAD=${REST#"${REST%%[![:space:]]*}"}

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

# Bare `handoff` seeds the previous session's last reply, extracted from the
# transcript by this hook — no model call, so it costs nothing on a session too
# expensive to prompt (the case it exists for: a 600k-token session with a cold
# cache, where invoking the skill to draft a brief means one request over the
# whole conversation).
#
# `handoff --clean` is the way back to a genuinely empty session.
#
# Unit is the last *reply*, not the last text block. An assistant turn holds
# several text blocks interleaved with tool_use, so flattening every block and
# taking the last one returns a mid-turn lead-in ("Now the check that matters:",
# 107 chars) rather than the 1816-char reply the user actually saw.
#
# The filter takes the last assistant line carrying no tool_use. That is the
# final reply *because of when this hook runs*: a prompt is only submitted
# between turns, so the previous turn has closed and its last line is its reply.
# Run it against a transcript mid-turn — as the first test of it accidentally
# did — and it returns that turn's lead-in instead, correctly and uselessly.
# Both measurements in .context/proofs/handoff-transcript-tail/.
#
# Streamed, never slurped: `jq -s` would load the whole JSONL, and this feature
# targets long sessions specifically (1.4 MB after one working day, and that is
# a small one). Each match is emitted as a one-line JSON string so `tail -1` is
# safe on replies containing newlines, then decoded.
extract_last_reply() {
  [ -n "$TRANSCRIPT" ] || return 1
  [ -f "$TRANSCRIPT" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  _reply=$(jq -c '
      select(.type == "assistant")
      | select([.message.content[]? | select(.type == "tool_use")] | length == 0)
      | ([.message.content[]? | select(.type == "text") | .text] | join(""))
      | select(length > 0)
    ' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r . 2>/dev/null)

  [ -n "$_reply" ] || return 1
  printf '%s' "$_reply"
}

# A raw tail is NOT a brief, and the SessionStart hook wraps whatever it finds
# with "treat it as authoritative context". Saying so inside the payload is what
# keeps the next session from acting on a partial reply as if it were a curated
# state summary — and it needs no change to handoff-session-start.sh.
TAIL_HEADER='[RAW TRANSCRIPT TAIL — NOT a curated handoff brief]
The text below is the previous session'"'"'s last reply, copied verbatim by a hook with no
model involved. It has no goal / state / next-step structure, and it may be partial or
stale. Verify the real state before acting on it; do not treat its claims as current fact.

--- last reply ---'

# 16 KB is a guard against a pathological reply, not a content judgement — a
# normal reply is 1-4 KB. Truncation is announced so the next session knows it
# is reading a fragment rather than silently trusting a cut-off sentence.
TAIL_MAX_BYTES=16384

# The empty branch must ASSERT the absence, not merely skip the write.
# CLAUDE_HANDOFF_ID is the wrapper PID and is stable for the whole dispatch
# loop, so this path is identical for every session that wrapper launches: an
# orphaned payload would survive until wrapper exit, and the wrapper would then
# announce "N bytes de contexto sembrado" and relaunch with a stale brief.
# Covered by hook-guard.sh Case I.
#
# Three payload shapes, in precedence order:
#   handoff: <text>  -> the text, verbatim (a curated brief)
#   handoff --clean  -> no payload; the wrapper announces a clean start
#   handoff          -> the transcript tail, if one can be extracted
#
# `--clean` is tested before the generic non-empty branch because it arrives as
# PAYLOAD="--clean" and would otherwise be written out as a one-word brief.
if [ "$PAYLOAD" = "--clean" ]; then
  rm -f "$PAYLOAD_FILE"
elif [ -n "$PAYLOAD" ]; then
  printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"
elif TAIL=$(extract_last_reply); then
  # Truncate on a byte budget, and say so. `head -c` counts bytes, so a cut can
  # land mid-UTF-8; the marker follows on its own line, and the next session is
  # already told the text is a fragment.
  if [ "$(printf '%s' "$TAIL" | wc -c | tr -d ' ')" -gt "$TAIL_MAX_BYTES" ]; then
    TAIL=$(printf '%s' "$TAIL" | head -c "$TAIL_MAX_BYTES")
    TAIL="$TAIL
[… truncated at ${TAIL_MAX_BYTES} bytes …]"
  fi
  printf '%s\n%s\n' "$TAIL_HEADER" "$TAIL" > "$PAYLOAD_FILE"
else
  # No transcript, no jq, or a transcript with no completed reply yet. Falls
  # through to the wrapper's existing "arranca limpia" warning rather than
  # failing the handoff — a clean session is a worse outcome than a seeded one,
  # not a broken one.
  rm -f "$PAYLOAD_FILE"
fi
touch "$FLAG_FILE"
# Signal the wrapper's watcher to terminate claude. The watcher (started by
# claude-wrapper.sh v4+) polls this sentinel and sends SIGTERM itself, so the
# hook never needs to invoke `kill` directly.
touch "$EXIT_TRIGGER"

printf '{"decision":"block","reason":"Handoff initiated via hook"}'
exit 0
