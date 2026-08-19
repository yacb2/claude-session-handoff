#!/bin/sh
# SessionStart hook for claude-session-handoff.
# If a handoff payload exists for this wrapper, inject it as additionalContext
# and delete the file (one-shot — payload only seeds the very next session).
# If a handoff TITLE exists, this session is a link in a handoff chain: emit its
# sessionTitle and append one record line to ~/.claude/handoff-chains/.
#
# Requires: jq, CLAUDE_HANDOFF_ID env var (set by handoff-wrapper.sh).

# Read stdin ONCE, before any early exit. `--clean` carries no payload but is
# still a chain event, and session_id — which only this side knows — is what the
# record is keyed by. Probed on 2.1.235: SessionStart stdin carries session_id,
# cwd, hook_event_name and source. See .context/proofs/session-title-lineage/.
#
# Guarded by `-t 0` because the cost of being wrong is asymmetric. Claude Code
# always pipes the JSON and closes the pipe, but a hook invoked with a terminal
# on stdin blocks in `cat` FOREVER — and this one runs at session start, so the
# failure is "the session never opens", not "a field is missing". It cost a
# hung tests/smoke.sh to find. Without stdin the lineage half degrades to
# nothing and the payload is still seeded, which is the same trade the no-jq
# path takes.
INPUT=""
[ -t 0 ] || INPUT=$(cat 2>/dev/null)

WRAPPER_ID="${CLAUDE_HANDOFF_ID:-}"
if [ -z "$WRAPPER_ID" ]; then
  exit 0
fi

PAYLOAD_FILE="${HOME}/.claude/tmp/handoff-payload-${WRAPPER_ID}"
TITLE_FILE="${HOME}/.claude/tmp/handoff-title-${WRAPPER_ID}"

# Every ordinary `claude` start lands here. It must write nothing at all — no
# title, no record — or the chain file fills with noise and sessions this tool
# never handed off get renamed. Covered by hook-guard.sh Case Y.
if [ ! -f "$PAYLOAD_FILE" ] && [ ! -f "$TITLE_FILE" ]; then
  exit 0
fi

PAYLOAD=""
[ -f "$PAYLOAD_FILE" ] && PAYLOAD=$(cat "$PAYLOAD_FILE")

if [ -z "$PAYLOAD" ] && [ ! -f "$TITLE_FILE" ]; then
  rm -f "$PAYLOAD_FILE"
  exit 0
fi

WRAPPED=""
if [ -n "$PAYLOAD" ]; then
  WRAPPED=$(printf '=== HANDOFF FROM PREVIOUS SESSION ===\n%s\n=== END HANDOFF ===\n\nYou are starting a fresh session. The text above is the handoff brief from the previous session — treat it as authoritative context.\n\nIMPORTANT — opening behavior:\nOn the user'"'"'s very first message in this session (whatever it is, even "hola", "continue", or an unrelated question), you MUST begin your reply with a one-line acknowledgement in the user'"'"'s language indicating that this is a fresh session seeded from a previous handoff, followed by a one-sentence summary of the handoff brief. Example: "Handoff recibido — vengo de la sesión previa con: <resumen de 1 frase>." Then address the user'"'"'s message normally, resuming from where the previous session left off based on the brief.' "$PAYLOAD")
fi

# The skill path writes the payload with its own Bash block and never passes
# through the UserPromptSubmit hook, so it leaves no title file — and it cannot
# name a predecessor either, because a session does not know its own id. What it
# CAN do is say what the chain is called, and it already knows: the brief opens
# with a `slug:` line (SKILL.md Step 1). That single instruction is what puts
# every skill-driven handoff — interactive or unattended — on a chain, without
# restating the protocol in each `aidex-*` skill that mandates the step.
#
# Sanitised on arrival: this is model-written text and it is about to be joined
# into a title and a JSON record. One line, no control characters, bounded.
PAYLOAD_SLUG=""
if [ -n "$PAYLOAD" ]; then
  PAYLOAD_SLUG=$(printf '%s\n' "$PAYLOAD" | head -5 \
    | sed -n 's/^[[:space:]]*[Ss]lug:[[:space:]]*//p' | head -1 \
    | tr -d '\000-\037' | cut -c1-80)
fi

# --- chain lineage (ADR 2026-08-19-handoff-chain-lineage) --------------------
#
# The incoming half. The outgoing session wrote what the chain is CALLED and who
# it is; this side works out WHERE in the chain we land, and it is the only place
# every field is knowable at once: I am session X (stdin), my predecessor was Y
# (title file), so I am link N of chain C (the record). The ordinal is therefore
# taken from the record and never parsed out of a title — Ctrl+R overwrites that
# string, and a title-parsing implementation silently restarts the count there
# (C4). Covered by hook-guard.sh Case AA.
TITLE=""
CLEAN=""
RECORD=""
CHAIN_FILE=""
SESSION_ID=""

title_field() {
  [ -f "$TITLE_FILE" ] || return 0
  while IFS= read -r _line; do
    case "$_line" in
      "$1"=*) printf '%s' "${_line#*=}"; return 0 ;;
    esac
  done < "$TITLE_FILE"
}

if command -v jq >/dev/null 2>&1 && { [ -f "$TITLE_FILE" ] || [ -n "$PAYLOAD_SLUG" ]; }; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
  [ -n "$CWD" ] && CHAIN_FILE="${HOME}/.claude/handoff-chains/$(printf '%s' "$CWD" | tr '/' '-').jsonl"
fi

# A title is emitted only for a link that gets RECORDED. Missing stdin means no
# session id and no cwd, so there is nowhere to append — and an ordinal no
# record backs is worse than none: every link after it would recompute the same
# number off the same absent parent, so the chain would read ↻2, ↻2, ↻2.
# Covered by hook-guard.sh Case AF.
if [ -n "$SESSION_ID" ] && [ -n "$CHAIN_FILE" ]; then
  PREV=$(title_field prev)
  SLUG=$(title_field slug)
  [ -n "$SLUG" ] || SLUG="$PAYLOAD_SLUG"
  CLEAN=$(title_field clean)
  SIBLING=""

  if [ "$CLEAN" = "1" ]; then
    # A clean session is a deliberate break, so the ordinal does not carry
    # across it (D3). The chain is named after this session because it is its
    # first link — the only id that is knowable here and stable afterwards.
    CHAIN="$SESSION_ID"
    N=1
    PREV=""
  else
    # The skill path writes the payload directly and cannot know its own
    # session id, so it leaves `prev` empty. Under one wrapper sessions run
    # strictly one after another, so the last link this wrapper recorded IS the
    # predecessor. Known limitation, same family as the ancestor check in the
    # sibling hook: a recycled wrapper PID in the same project inherits a
    # stranger's ordinal. Cosmetic, and the record shows it.
    if [ -z "$PREV" ] && [ -n "$CHAIN_FILE" ] && [ -f "$CHAIN_FILE" ]; then
      PREV=$(jq -r --arg w "$WRAPPER_ID" 'select(.wrapper == $w) | .session // empty' \
        "$CHAIN_FILE" 2>/dev/null | tail -1)
    fi

    PARENT=""
    if [ -n "$PREV" ] && [ -n "$CHAIN_FILE" ] && [ -f "$CHAIN_FILE" ]; then
      PARENT=$(jq -c --arg s "$PREV" 'select(.session == $s)' "$CHAIN_FILE" 2>/dev/null | tail -1)
      # A fork: resume an old link, hand off again, and two sessions are both
      # the N+1th child of the same parent (C5). The record is the only place
      # that can see it. Mark the newcomer; never renumber and never rewrite the
      # sibling that got there first — the file is append-only. An EMPTY prev is
      # not a repeated one: two chains whose first link has no recorded ancestor
      # would otherwise flag each other on the dominant path. Case AB / AB2.
      if [ -n "$(jq -r --arg p "$PREV" 'select(.prev == $p) | .session // empty' \
        "$CHAIN_FILE" 2>/dev/null | head -1)" ]; then
        SIBLING=1
      fi
    fi

    if [ -n "$PARENT" ]; then
      CHAIN=$(printf '%s' "$PARENT" | jq -r '.chain // empty')
      N=$(( $(printf '%s' "$PARENT" | jq -r '.n // 1') + 1 ))
      [ -n "$SLUG" ] || SLUG=$(printf '%s' "$PARENT" | jq -r '.slug // empty')
    elif [ -n "$PREV" ]; then
      # A predecessor that was never recorded — the chain's first handoff. It
      # was link 1 by definition, so this one is link 2, and it names the chain.
      CHAIN="$PREV"
      N=2
    else
      CHAIN="$SESSION_ID"
      N=1
    fi
  fi

  # The ordinal goes in FRONT: the picker truncates the tail, and the ordinal is
  # the one part that has to survive the cut. Link 1 renders bare — `↻1 · x`
  # would claim a lineage that does not exist.
  if [ -n "$SLUG" ]; then
    if [ "$N" -le 1 ]; then
      TITLE="$SLUG"
    else
      TITLE="↻${N} · ${SLUG}"
    fi
  fi

  RECORD=$(jq -nc \
    --arg chain "$CHAIN" \
    --argjson n "$N" \
    --arg slug "$SLUG" \
    --arg session "$SESSION_ID" \
    --arg prev "$PREV" \
    --arg wrapper "$WRAPPER_ID" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sibling "$SIBLING" \
    --arg clean "$CLEAN" \
    '{chain:$chain, n:$n, slug:$slug, session:$session, prev:$prev, wrapper:$wrapper, at:$at}
     + (if $sibling == "" then {} else {sibling: true} end)
     + (if $clean == "" then {} else {clean: true} end)' 2>/dev/null)
fi

if [ -n "$PAYLOAD" ]; then
  PAYLOAD_BYTES=$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')
  BANNER="↻ Handoff recibido — sesión nueva sembrada con ${PAYLOAD_BYTES} bytes de la sesión previa. Cuando escribas, Claude abrirá confirmando el handoff."
elif [ "$CLEAN" = "1" ]; then
  # The clean path is silent by design — no payload, nothing seeded. Saying so
  # is what keeps a deliberate new chain distinguishable from the mechanism
  # having failed, which is the same silence (D3).
  BANNER="↻ Sesión limpia — cadena nueva${TITLE:+: $TITLE}. No se sembró contexto."
else
  BANNER=""
fi

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
# grepped out of a PTY log. A neighbouring SessionStart field
# (initialUserMessage) is documented and does nothing — ruled headless-only by a
# maintainer in anthropics/claude-code#85951 — so on this hook "the docs say so"
# is not evidence. See .context/proofs/sessionstart-initialusermessage/.
BELL_SEQ=""
if [ "${HANDOFF_BELL:-0}" = "1" ]; then
  BELL_SEQ=$(printf '\007')
fi

# additionalContext  -> goes to Claude's context (invisible to user)
# sessionTitle       -> names the session in the --resume picker. Probed working
#                       on 2.1.235; it writes `custom-title`, which outranks the
#                       auto-titler's `ai-title` in the picker (and also writes
#                       an `agent-name` with the same string — which surface
#                       that drives is an accepted open unknown, see the ADR).
# systemMessage      -> shown to user on session start (the docs-supported way
#                       to surface text at start; additionalContext alone is silent)
# terminalSequence   -> omitted entirely unless the bell is opted in
# Emit FIRST, delete only on success. The payload is the previous session's
# only copy of its context; deleting it before jq has produced output means any
# failure in between — jq missing, jq erroring — loses the brief irrecoverably
# and the new session starts blank with no indication anything was lost. The
# title file is consumed under the same rule, and for the same reason: it is
# one-shot state that only the outgoing session could have written. Covered by
# hook-guard.sh Cases J and AC.
if OUTPUT=$(jq -nc \
  --arg ctx "$WRAPPED" \
  --arg msg "$BANNER" \
  --arg seq "$BELL_SEQ" \
  --arg title "$TITLE" \
  '{
    hookSpecificOutput: ({hookEventName: "SessionStart"}
      + (if $ctx == "" then {} else {additionalContext: $ctx} end)
      + (if $title == "" then {} else {sessionTitle: $title} end))
  }
  + (if $msg == "" then {} else {systemMessage: $msg} end)
  + (if $seq == "" then {} else {terminalSequence: $seq} end)'); then
  printf '%s\n' "$OUTPUT"

  # The chain file is not one-shot temp state: it lives outside ~/.claude/tmp,
  # it never expires, and it carries slugs derived from conversation content.
  # Case S's argument applies with more force here, so the directory is created
  # under the same umask rather than chmod-ed afterwards. Covered by Case AD.
  if [ -n "$RECORD" ]; then
    (umask 077; mkdir -p "${CHAIN_FILE%/*}" && printf '%s\n' "$RECORD" >> "$CHAIN_FILE")
  fi

  rm -f "$PAYLOAD_FILE" "$TITLE_FILE"
fi
