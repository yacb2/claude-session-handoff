#!/bin/sh
# handoff-fire.sh — the one place a MODEL-driven handoff is fired (BL-041).
#
# SKILL.md Step 2 and commands/handoff.md used to each carry a full copy of this
# guard-and-write block, and the copies drifted. They now both make one call:
#
#   sh "$HOME/.claude/scripts/handoff-fire.sh" <<'__HANDOFF_EOF__'
#   <the brief>
#   __HANDOFF_DELTA__
#   <ledger deltas, one per line — or drop this line and everything after it>
#   __HANDOFF_EOF__
#
# stdin is the brief. The FIRST line that is exactly `__HANDOFF_DELTA__` splits
# it: before goes to the payload file, after goes to the chain-ledger delta file.
# Only a whole-line match splits (leading/trailing space, tab and CR ignored; a
# mid-line mention does not), and the split is purely textual, so the line also
# splits inside a fenced block. A brief with no non-blank line is refused. No such line, or
# nothing after it, means no delta file is written.
#
# handoff-prompt-hook.sh keeps its own guard: it must answer in the hook's JSON
# `block` protocol and shares variables with the rest of that hook.
#
# Exit 0 only when the sentinels the wrapper watches were written; any refusal
# writes nothing and says why on stderr.

if [ -z "${CLAUDE_HANDOFF_ID:-}" ]; then
  echo "handoff: wrapper not detected. Launch claude via the shell function that claude-session-handoff installs." >&2
  exit 1
fi

# The Bash tool's sandbox cannot exec ps (rc 127) and denies kill -0 too, so the
# walk below would see an empty chain and blame the wrapper. Say which it is.
if ! ps -o ppid= -p $$ >/dev/null 2>&1; then
  echo "handoff: ps cannot run here, so the wrapper cannot be verified (the Bash tool's sandbox hides the process tree). Nothing was written. Rerun this command with dangerouslyDisableSandbox: true." >&2
  exit 1
fi

# Same walk as handoff-prompt-hook.sh's is_wrapper_ancestor(): a set variable
# proves a wrapper ran somewhere up the tree, not that mine is still watching.
is_wrapper_ancestor() {
  _pid=$$
  while _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' '); [ -n "$_pid" ]; do
    case "$_pid" in
      0|1) return 1 ;;
    esac
    [ "$_pid" = "$CLAUDE_HANDOFF_ID" ] && return 0
  done
  return 1
}

if ! is_wrapper_ancestor; then
  echo "handoff: wrapper PID $CLAUDE_HANDOFF_ID is not an ancestor of this session (stale or inherited env var). Nothing was written and this session will not close." >&2
  exit 1
fi

DIR="$HOME/.claude/tmp"
mkdir -p "$DIR" || exit 1

# The payload is conversation content; transcripts are 0600, so it must not be
# more readable than its source. Unlink first: umask only applies at creation.
umask 077

PAYLOAD_FILE="$DIR/handoff-payload-$CLAUDE_HANDOFF_ID"
DELTA_FILE="$DIR/handoff-ledger-$CLAUDE_HANDOFF_ID"
FLAG_FILE="$DIR/handoff-flag-$CLAUDE_HANDOFF_ID"
EXIT_TRIGGER="$DIR/handoff-exit-$CLAUDE_HANDOFF_ID"

# awk creates the delta file only when a line reaches it, so an empty or absent
# delta section leaves no file (and an older stale one is not touched).
rm -f "$PAYLOAD_FILE"
: > "$PAYLOAD_FILE" || exit 1
# The separator is compared after trimming [ \t\r], as handoff-ledger.sh does for
# delta lines, so an indented or CRLF line still splits.
awk -v p="$PAYLOAD_FILE" -v d="$DELTA_FILE" '
  { t = $0; gsub(/^[ \t\r]+|[ \t\r]+$/, "", t) }
  !seen && t == "__HANDOFF_DELTA__" { seen = 1; next }
  { if (seen) print > d; else print > p }
' || exit 1

# A brief with no non-blank line would seed the successor with nothing and still
# close this session: refuse before any touch.
if ! grep -q '[^[:space:]]' "$PAYLOAD_FILE"; then
  rm -f "$PAYLOAD_FILE" "$DELTA_FILE"
  echo "handoff: the brief is empty (nothing before the __HANDOFF_DELTA__ line). Nothing was written and this session will not close." >&2
  exit 1
fi

touch "$FLAG_FILE"
# Signal, never kill: the wrapper's watcher polls this and signals claude itself.
touch "$EXIT_TRIGGER"
