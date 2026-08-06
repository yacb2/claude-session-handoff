#!/bin/sh
# Smoke test for the shared-wrapper coordination between
# claude-restart and claude-session-handoff installers.
#
# Verifies (in an isolated sandbox, no real $HOME/.claude touched):
#   1. Install handoff then restart -> shared block has both in registered-by,
#      wrapper installed once, both hook sets present in settings.json.
#   2. Install restart then handoff -> same result (order-independence).
#   3. Uninstall one -> block keeps the other; wrapper kept.
#   4. Uninstall both -> block removed; wrapper removed.
#   5. Pre-existing legacy `# claude-restart: start` block gets migrated.
#   6. Wrapper version comparison (lower-version installer keeps the
#      already-installed higher-version wrapper).
#
# Does NOT exercise the runtime end-to-end (SIGTERM to PPID, fresh claude
# launch) — those require a real TTY and a real claude binary. Smoke test
# is purely installer protocol.
#
# Usage: ./tests/smoke.sh

set -e

REPO_HANDOFF="$(cd "$(dirname "$0")/.." && pwd)"
REPO_RESTART="${REPO_RESTART:-$(cd "$REPO_HANDOFF/../claude-restart" && pwd)}"

[ -x "$REPO_HANDOFF/install.sh" ] || { echo "FAIL: handoff installer not found at $REPO_HANDOFF"; exit 1; }
[ -x "$REPO_RESTART/install.sh" ] || { echo "FAIL: claude-restart installer not found at $REPO_RESTART"; exit 1; }

SANDBOX_BASE=$(mktemp -d /tmp/cl-smoke.XXXXXX)
trap 'rm -rf "$SANDBOX_BASE"' EXIT

PASS=0
FAIL=0

# --- helpers ---

new_sandbox() {
  SB="$SANDBOX_BASE/$1"
  rm -rf "$SB"
  mkdir -p "$SB/claude"
  : > "$SB/zshrc"
  CLAUDE_DIR="$SB/claude"
  RC_FILE="$SB/zshrc"
  export CLAUDE_DIR RC_FILE_OVERRIDE="$RC_FILE" SHELL_NAME_OVERRIDE=zsh
}

run_handoff()  { ( cd "$REPO_HANDOFF"  && ./install.sh "$@" ) >/dev/null; }
run_restart()  { ( cd "$REPO_RESTART"  && ./install.sh "$@" ) >/dev/null; }

assert() {
  DESC="$1"; shift
  if eval "$@"; then
    echo "  PASS  $DESC"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $DESC"
    FAIL=$((FAIL+1))
  fi
}

registered_by() {
  awk '/^# claude-wrapper: start/{f=1;next}/^# claude-wrapper: end/{f=0}f && /^# registered-by:/{sub(/^# registered-by:[[:space:]]*/,"");print;exit}' "$1"
}

block_present() { grep -q "^# claude-wrapper: start" "$1" 2>/dev/null; }

# --- Case 1: install handoff then restart ---
echo "Case 1: handoff then restart"
new_sandbox case1
run_handoff
run_restart
assert "shared block present"            'block_present "$RC_FILE"'
assert "wrapper file exists"             '[ -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'
assert "registered-by contains handoff"  '[ "$(registered_by "$RC_FILE" | grep -c claude-session-handoff)" -eq 1 ]'
assert "registered-by contains restart"  '[ "$(registered_by "$RC_FILE" | grep -c claude-restart)" -eq 1 ]'
assert "SessionStart handoff hook"       'grep -q handoff-session-start.sh "$CLAUDE_DIR/settings.json"'
assert "SessionStart capture hook"       'grep -q capture-session-id.sh "$CLAUDE_DIR/settings.json"'
assert "UserPromptSubmit handoff hook"   'grep -q handoff-prompt-hook.sh "$CLAUDE_DIR/settings.json"'
assert "UserPromptSubmit restart hook"   'grep -q restart-hook.sh "$CLAUDE_DIR/settings.json"'

# --- Case 2: reverse order ---
echo "Case 2: restart then handoff"
new_sandbox case2
run_restart
run_handoff
assert "registered-by contains both"     '[ "$(registered_by "$RC_FILE" | wc -w)" -eq 2 ]'
assert "single shared block"             '[ "$(grep -c "^# claude-wrapper: start" "$RC_FILE")" -eq 1 ]'

# --- Case 3: uninstall one keeps the other ---
echo "Case 3: uninstall handoff, restart still registered"
run_handoff --uninstall
assert "block still present"             'block_present "$RC_FILE"'
assert "only restart registered"         '[ "$(registered_by "$RC_FILE")" = "claude-restart" ]'
assert "wrapper kept"                    '[ -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'
assert "handoff hook gone"               '! grep -q handoff-prompt-hook.sh "$CLAUDE_DIR/settings.json"'
assert "restart hook still there"        'grep -q restart-hook.sh "$CLAUDE_DIR/settings.json"'

# --- Case 4: uninstall both ---
echo "Case 4: uninstall the rest"
run_restart --uninstall
assert "block removed"                   '! block_present "$RC_FILE"'
assert "wrapper removed"                 '[ ! -f "$CLAUDE_DIR/scripts/claude-wrapper.sh" ]'

# --- Case 5: legacy migration ---
echo "Case 5: legacy claude-restart block migration"
new_sandbox case5
cat > "$RC_FILE" << 'EOF'
# user content above

# claude-restart: start
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
# claude-restart: end

# user content below
EOF
run_handoff
assert "legacy block removed"            '! grep -q "^# claude-restart: start" "$RC_FILE"'
assert "shared block present"            'block_present "$RC_FILE"'
assert "restart preserved in registered-by" 'echo " $(registered_by "$RC_FILE") " | grep -q " claude-restart "'
assert "handoff added in registered-by"  'echo " $(registered_by "$RC_FILE") " | grep -q " claude-session-handoff "'

# --- Case 6: version comparison ---
echo "Case 6: lower-version installer keeps higher-version wrapper"
new_sandbox case6
run_handoff
# Bump version on installed wrapper to v99 to simulate a newer wrapper already present.
sed -i.bak 's/^# claude-wrapper version: .*/# claude-wrapper version: 99/' "$CLAUDE_DIR/scripts/claude-wrapper.sh"
rm -f "$CLAUDE_DIR/scripts/claude-wrapper.sh.bak"
run_restart
INSTALLED_VERSION=$(awk '/^# claude-wrapper version:/{print $4;exit}' "$CLAUDE_DIR/scripts/claude-wrapper.sh")
assert "wrapper kept at v99 (not downgraded)" '[ "$INSTALLED_VERSION" = "99" ]'

# --- Case 7: exit-trigger pattern (v4+) ---
# The model side must use `touch $EXIT_TRIGGER` instead of `kill -TERM $PPID`,
# and the wrapper must own the SIGTERM via a background watcher.
echo "Case 7: exit-trigger pattern (no kill on the skill side)"
new_sandbox case7
run_handoff
WRAP="$CLAUDE_DIR/scripts/claude-wrapper.sh"
SKILL="$CLAUDE_DIR/skills/session-handoff/SKILL.md"
CMD="$CLAUDE_DIR/commands/handoff.md"
HOOK="$CLAUDE_DIR/scripts/handoff-prompt-hook.sh"
assert "wrapper defines HANDOFF_EXIT sentinel"  'grep -q "HANDOFF_EXIT=" "$WRAP"'
assert "wrapper has run_claude helper"          'grep -q "^run_claude()" "$WRAP"'
assert "wrapper watcher signals SIGTERM"        'grep -q "kill -TERM \"\$CLAUDE_PID\"" "$WRAP"'
assert "skill uses touch \$EXIT_TRIGGER"        'grep -q "touch \"\$EXIT_TRIGGER\"" "$SKILL"'
assert "skill no longer kills PPID"             '! grep -q "kill -TERM \$PPID" "$SKILL"'
assert "slash command uses touch trigger"       'grep -q "touch \"\$EXIT_TRIGGER\"" "$CMD"'
assert "slash command no longer kills PPID"     '! grep -q "kill -TERM \$PPID" "$CMD"'
assert "slash command drops kill from allowed-tools" '! grep -q "Bash(kill" "$CMD"'
assert "hook uses touch trigger"                'grep -q "touch \"\$EXIT_TRIGGER\"" "$HOOK"'
assert "hook no longer kills PPID"              '! grep -q "kill -TERM \$PPID" "$HOOK"'
assert "wrapper version is >= 4"                '[ "$(awk "/^# claude-wrapper version:/{print \$4;exit}" "$WRAP")" -ge 4 ]'

# --- Case 8: opt-in HANDOFF_BELL (terminalSequence) ---
# Runs the installed SessionStart hook for real, once per branch, and inspects
# its JSON. The bell must be absent by default and present only under
# HANDOFF_BELL=1 — asserting on the emitted payload, not on the source text.
echo "Case 8: opt-in HANDOFF_BELL via terminalSequence"
SS_HOOK="$CLAUDE_DIR/scripts/handoff-session-start.sh"
BELL_ID="smoke-bell-$$"
# The hook resolves its payload under $HOME/.claude/tmp, which is NOT
# $CLAUDE_DIR (the installer's override points at $SB/claude). So the bell
# case gets its own HOME rather than reusing the install sandbox's layout.
BELL_HOME="$SANDBOX_BASE/bell-home"
BELL_TMP="$BELL_HOME/.claude/tmp"
mkdir -p "$BELL_TMP"

# The hook consumes (deletes) the payload, so it is re-seeded per branch.
seed_and_run() {
  printf 'smoke payload' > "$BELL_TMP/handoff-payload-$BELL_ID"
  env HOME="$BELL_HOME" HANDOFF_BELL="$1" CLAUDE_HANDOFF_ID="$BELL_ID" \
    sh "$SS_HOOK" 2>/dev/null
}

BELL_OFF=$(seed_and_run 0)
BELL_ON=$(seed_and_run 1)

assert "bell off: hook still emits additionalContext" \
  'printf "%s" "$BELL_OFF" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'
assert "bell off: no terminalSequence key" \
  'printf "%s" "$BELL_OFF" | jq -e "has(\"terminalSequence\") | not" >/dev/null'
assert "bell on: terminalSequence present" \
  'printf "%s" "$BELL_ON" | jq -e "has(\"terminalSequence\")" >/dev/null'
assert "bell on: value is a bare BEL (allowlisted)" \
  '[ "$(printf "%s" "$BELL_ON" | jq -r ".terminalSequence")" = "$(printf "\007")" ]'
assert "bell on: systemMessage banner unaffected" \
  'printf "%s" "$BELL_ON" | jq -e ".systemMessage" >/dev/null'

# --- Case 9: the two repos ship the same wrapper ---
# The wrapper is co-owned and byte-for-byte identical by contract, but nothing
# enforced it — the protocol relied on whoever edited it remembering to copy.
# `install_wrapper` only overwrites when its version is HIGHER, so two repos at
# the same version with different content is the one divergence that never
# resolves itself: whichever installer runs second declines to overwrite.
echo "Case 9: both repos ship the identical wrapper"
assert "wrapper byte-identical across repos" \
  'cmp -s "$REPO_HANDOFF/scripts/claude-wrapper.sh" "$REPO_RESTART/scripts/claude-wrapper.sh"'
assert "both declare the same version" \
  '[ "$(awk "/^# claude-wrapper version:/{print \$4;exit}" "$REPO_HANDOFF/scripts/claude-wrapper.sh")" = "$(awk "/^# claude-wrapper version:/{print \$4;exit}" "$REPO_RESTART/scripts/claude-wrapper.sh")" ]'

echo ""
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
