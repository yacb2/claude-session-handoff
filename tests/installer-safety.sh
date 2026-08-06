#!/bin/sh
# Installer data-safety regressions (BL-011).
#
# Every case here is a defect that destroyed user data or reported success
# while doing nothing. The code under test is shared byte-for-byte between
# claude-session-handoff and claude-restart, so each case runs against BOTH
# installers: fixing one repo and hand-copying to the other leaves the sibling
# untested, which is how these bugs got two homes in the first place.
#
# Covers:
#   A. An unterminated marker block must not delete the rc file to EOF,
#      and no rc rewrite proceeds without a .bak.
#
# Usage: ./tests/installer-safety.sh

set -e

REPO_HANDOFF="$(cd "$(dirname "$0")/.." && pwd)"
REPO_RESTART="${REPO_RESTART:-$(cd "$REPO_HANDOFF/../claude-restart" && pwd)}"

[ -x "$REPO_HANDOFF/install.sh" ] || { echo "FAIL: handoff installer not found at $REPO_HANDOFF"; exit 1; }
[ -x "$REPO_RESTART/install.sh" ] || { echo "FAIL: claude-restart installer not found at $REPO_RESTART"; exit 1; }

SANDBOX_BASE=$(mktemp -d /tmp/cl-safety.XXXXXX)
trap 'rm -rf "$SANDBOX_BASE"' EXIT

PASS=0
FAIL=0

# --- helpers ---

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

# $1 = handoff|restart, remaining args are passed to that repo's install.sh.
# Exit status is preserved; stdout/stderr land in $OUT for assertions.
OUT=""
run_installer() {
  case "$1" in
    handoff) IDIR="$REPO_HANDOFF" ;;
    restart) IDIR="$REPO_RESTART" ;;
  esac
  shift
  STATUS=0
  OUT=$( cd "$IDIR" && ./install.sh "$@" 2>&1 ) || STATUS=$?
  return "$STATUS"
}

tool_name() {
  case "$1" in
    handoff) echo "claude-session-handoff" ;;
    restart) echo "claude-restart" ;;
  esac
}

new_sandbox() {
  SB="$SANDBOX_BASE/$1"
  rm -rf "$SB"
  mkdir -p "$SB/claude"
  : > "$SB/zshrc"
  CLAUDE_DIR="$SB/claude"
  RC_FILE="$SB/zshrc"
  export CLAUDE_DIR RC_FILE_OVERRIDE="$RC_FILE" SHELL_NAME_OVERRIDE=zsh
}

# ---------------------------------------------------------------------------
# Case A: an unterminated marker block must not eat the rest of the rc file
#
# `sed "\|START|,\|END|d"` runs to EOF when the closing address never matches.
# One hand-dropped end-marker line was enough to delete every export below it,
# with no backup and a `[+] Migrated legacy block` success message.
# ---------------------------------------------------------------------------

for TOOL in handoff restart; do
  echo "Case A ($TOOL): unterminated block does not truncate the rc file"

  # A1 — install path (migrate_legacy_block)
  new_sandbox "caseA1-$TOOL"
  cat > "$RC_FILE" << 'EOF'
# user content above

# claude-restart: start
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
export CRITICAL=yes
source ~/work/env.sh
EOF
  A1_STATUS=0
  run_installer "$TOOL" || A1_STATUS=$?
  assert "A1 install survives the unterminated legacy block" '[ "$A1_STATUS" -eq 0 ]'
  assert "A1 user export below the marker survives"  'grep -q "^export CRITICAL=yes" "$RC_FILE"'
  assert "A1 user source below the marker survives"  'grep -q "^source ~/work/env.sh" "$RC_FILE"'
  assert "A1 content above the marker survives"      'grep -q "^# user content above" "$RC_FILE"'
  assert "A1 does not claim a migration happened"    '! echo "$OUT" | grep -q "Migrated legacy block"'
  assert "A1 warns about the unterminated block"     'echo "$OUT" | grep -qi "unterminated"'
  assert "A1 still installs the shared block"        'grep -q "^# claude-wrapper: start" "$RC_FILE"'

  # A2 — uninstall path (rc_block_unregister)
  new_sandbox "caseA2-$TOOL"
  cat > "$RC_FILE" << EOF
# user content above

# claude-wrapper: start
# registered-by: $(tool_name "$TOOL")
claude() {
  ~/.claude/scripts/claude-wrapper.sh "\$@"
}
export CRITICAL=yes
source ~/work/env.sh
EOF
  A2_STATUS=0
  run_installer "$TOOL" --uninstall || A2_STATUS=$?
  assert "A2 uninstall survives the unterminated shared block" '[ "$A2_STATUS" -eq 0 ]'
  assert "A2 user export below the marker survives"  'grep -q "^export CRITICAL=yes" "$RC_FILE"'
  assert "A2 user source below the marker survives"  'grep -q "^source ~/work/env.sh" "$RC_FILE"'
  assert "A2 does not claim the block was removed"   '! echo "$OUT" | grep -q "Removed shared wrapper block"'

  # A3 — a well-formed rewrite still happens, and leaves a .bak of the original
  new_sandbox "caseA3-$TOOL"
  cat > "$RC_FILE" << 'EOF'
# user content above

# claude-restart: start
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
# claude-restart: end

export CRITICAL=yes
EOF
  run_installer "$TOOL"
  assert "A3 terminated legacy block is removed"     '! grep -q "^# claude-restart: start" "$RC_FILE"'
  assert "A3 shared block replaces it"               'grep -q "^# claude-wrapper: start" "$RC_FILE"'
  assert "A3 user content survives the rewrite"      'grep -q "^export CRITICAL=yes" "$RC_FILE"'
  assert "A3 the rewrite left a .bak behind"         '[ -s "$RC_FILE.bak" ]'
  assert "A3 the .bak is a real rc, not a stub"      'grep -q "^export CRITICAL=yes" "$RC_FILE.bak"'

  # A4 — a dotfiles-managed rc is a symlink; the rewrite must follow it,
  # not replace the link with a regular file.
  new_sandbox "caseA4-$TOOL"
  mkdir -p "$SB/dotfiles"
  cat > "$SB/dotfiles/zshrc" << 'EOF'
# user content above

# claude-restart: start
claude() {
  ~/.claude/scripts/claude-wrapper.sh "$@"
}
# claude-restart: end
EOF
  rm -f "$RC_FILE"
  ln -s "$SB/dotfiles/zshrc" "$RC_FILE"
  run_installer "$TOOL"
  assert "A4 rc file is still a symlink"             '[ -L "$RC_FILE" ]'
  assert "A4 the symlink target received the edit"   'grep -q "^# claude-wrapper: start" "$SB/dotfiles/zshrc"'

  # A5 — the .bak holds exactly what the rewrite replaced. Uninstalling one of
  # two registered tools rewrites the registered-by line and nothing else, so
  # this is the one flow with a single, deterministic rewrite to compare against.
  new_sandbox "caseA5-$TOOL"
  run_installer handoff
  run_installer restart
  cp "$RC_FILE" "$SB/rc-before"
  run_installer "$TOOL" --uninstall
  assert "A5 .bak holds the pre-rewrite rc exactly"  'cmp -s "$RC_FILE.bak" "$SB/rc-before"'
done

echo ""
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
