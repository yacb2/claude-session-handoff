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
#   B. Uninstall must not delete unrelated hooks that share a matcher group.
#   C. A jq failure must not be reported as success, and uninstall must
#      require jq rather than claiming it removed hooks it left registered.
#   D. An empty settings.json must be seeded, and a non-empty one that is not
#      a JSON object must never be clobbered.
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
  OUT=$( PATH="${PATH_OVERRIDE:-$PATH}"; export PATH; cd "$IDIR" && ./install.sh "$@" 2>&1 ) || STATUS=$?
  return "$STATUS"
}
PATH_OVERRIDE=""

tool_name() {
  case "$1" in
    handoff) echo "claude-session-handoff" ;;
    restart) echo "claude-restart" ;;
  esac
}

# The SessionStart hook command each installer registers and removes.
session_start_hook() {
  case "$1" in
    handoff) echo "~/.claude/scripts/handoff-session-start.sh" ;;
    restart) echo "~/.claude/scripts/capture-session-id.sh" ;;
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

# ---------------------------------------------------------------------------
# Case B: uninstall must not take unrelated hooks down with ours
#
# `.hooks[$ev] |= map(select(.hooks | all(.command != $cmd)))` filters the OUTER
# group array, so a matcher group is dropped whole as soon as any hook inside it
# matches. A user who keeps their own hook in the same group lost it silently.
# ---------------------------------------------------------------------------

for TOOL in handoff restart; do
  echo "Case B ($TOOL): uninstall keeps unrelated hooks in a shared group"

  new_sandbox "caseB-$TOOL"
  OURS=$(session_start_hook "$TOOL")
  # A hand-consolidated SessionStart: the user's own hook sits in the SAME
  # group as ours, plus a second group that is entirely theirs.
  cat > "$CLAUDE_DIR/settings.json" << EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/my-precious-analytics.sh" },
          { "type": "command", "command": "$OURS" }
        ]
      },
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/scripts/unrelated-group.sh" }
        ]
      }
    ]
  }
}
EOF
  run_installer "$TOOL" --uninstall
  assert "B unrelated hook in the shared group survives" \
    'jq -e "[.. | .command? // empty] | index(\"~/.claude/scripts/my-precious-analytics.sh\")" "$CLAUDE_DIR/settings.json" >/dev/null'
  assert "B unrelated hook in its own group survives" \
    'jq -e "[.. | .command? // empty] | index(\"~/.claude/scripts/unrelated-group.sh\")" "$CLAUDE_DIR/settings.json" >/dev/null'
  assert "B our own hook is gone" \
    '! grep -q "$(basename "$OURS")" "$CLAUDE_DIR/settings.json"'
  assert "B no empty matcher group is left behind" \
    'jq -e "[.hooks.SessionStart[] | select((.hooks | length) == 0)] | length == 0" "$CLAUDE_DIR/settings.json" >/dev/null'

  # B2 — a group that held only our hook is removed, not left empty
  new_sandbox "caseB2-$TOOL"
  run_installer "$TOOL"
  run_installer "$TOOL" --uninstall
  assert "B2 SessionStart key removed when nothing remains" \
    'jq -e "(.hooks.SessionStart // []) | length == 0" "$CLAUDE_DIR/settings.json" >/dev/null'
done

# ---------------------------------------------------------------------------
# Case C: a jq that fails, and a machine with no jq at all
#
# `jq … > "$TMP" && mv …` is an AND-list, and `set -e` does not fire on those
# (verified in sh and dash), so the following `info "… added"` ran regardless.
# A settings.json jq cannot parse produced a parse error, then
# `[+] SessionStart hook added`, then `Done!`, exit 0 — nothing registered and
# the tool permanently mute. uninstall() additionally never checked for jq, so
# on a jq-less machine it reported both hooks removed while leaving them
# registered, pointing at scripts it had just deleted.
# ---------------------------------------------------------------------------

REAL_JQ=$(command -v jq)

# A PATH holding everything the installer needs EXCEPT jq. Built by symlinking
# an explicit allow-list: a sandbox missing an ordinary tool manufactures false
# greens (a payload once "survived" only because cleanup crashed), so C2 pairs
# this with a control positive that adds jq back and must succeed.
make_stripped_path() {
  SPATH="$1"
  mkdir -p "$SPATH"
  for T in awk grep sed cat cp mv rm chmod mkdir touch basename dirname cmp ls env sh; do
    TP=$(command -v "$T" 2>/dev/null) && ln -sf "$TP" "$SPATH/$T"
  done
}

for TOOL in handoff restart; do
  echo "Case C ($TOOL): jq failures are not success"

  # C1 — jq exists but fails on the settings.json mutation
  new_sandbox "caseC1-$TOOL"
  STUB_DIR="$SB/stub-bin"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/jq" << EOF
#!/bin/sh
# Fail every settings.json mutation, pass every probe through. The mutations
# are exactly the calls that bind --arg cmd; the probes never do.
case "\$*" in
  *'--arg cmd'*) exit 1 ;;
esac
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$STUB_DIR/jq"
  PATH_OVERRIDE="$STUB_DIR:$PATH"
  C1_STATUS=0
  run_installer "$TOOL" || C1_STATUS=$?
  PATH_OVERRIDE=""
  assert "C1 install fails when jq fails"             '[ "$C1_STATUS" -ne 0 ]'
  assert "C1 does not claim the hook was added"       '! echo "$OUT" | grep -q "hook .* added"'
  assert "C1 does not print Done!"                    '! echo "$OUT" | grep -q "Done!"'
  assert "C1 leaves no .tmp turd next to settings"    '[ ! -e "$CLAUDE_DIR/settings.json.tmp" ]'

  # C2 — no jq on PATH at all, on the uninstall path
  new_sandbox "caseC2-$TOOL"
  run_installer "$TOOL"
  cp "$CLAUDE_DIR/settings.json" "$SB/settings-before"
  STRIPPED="$SB/nojq-bin"
  make_stripped_path "$STRIPPED"

  # Control positive: the same stripped PATH *with* jq must uninstall cleanly.
  # If this fails, C2's result says nothing about jq detection.
  ln -sf "$REAL_JQ" "$STRIPPED/jq"
  PATH_OVERRIDE="$STRIPPED"
  CTRL_STATUS=0
  run_installer "$TOOL" --uninstall || CTRL_STATUS=$?
  PATH_OVERRIDE=""
  assert "C2 control: stripped PATH with jq uninstalls cleanly" '[ "$CTRL_STATUS" -eq 0 ]'
  assert "C2 control: the hook really was removed" \
    '! grep -q "$(basename "$(session_start_hook "$TOOL")")" "$CLAUDE_DIR/settings.json"'

  # Now the real arm: same PATH, jq removed.
  new_sandbox "caseC2b-$TOOL"
  run_installer "$TOOL"
  cp "$CLAUDE_DIR/settings.json" "$SB/settings-before"
  rm -f "$STRIPPED/jq"
  PATH_OVERRIDE="$STRIPPED"
  C2_STATUS=0
  run_installer "$TOOL" --uninstall || C2_STATUS=$?
  PATH_OVERRIDE=""
  assert "C2 uninstall fails when jq is missing"      '[ "$C2_STATUS" -ne 0 ]'
  assert "C2 does not claim hooks were removed"       '! echo "$OUT" | grep -q "hook .* removed"'
  assert "C2 settings.json is untouched"              'cmp -s "$CLAUDE_DIR/settings.json" "$SB/settings-before"'
  assert "C2 the hook scripts are still on disk"      '[ -f "$CLAUDE_DIR/scripts/$(basename "$(session_start_hook "$TOOL")")" ]'
done

# ---------------------------------------------------------------------------
# Case D: empty vs. malformed settings.json
#
# ensure_settings only seeded `{}` when the file was ABSENT. On empty input
# `jq '. + {…}'` exits 0 with empty output, so `mv` installed the empty file and
# the installer reported success — distinct from Case C, since here jq succeeds
# and an exit-code check alone does not catch it.
#
# The mirror-image risk is seeding `{}` over a settings.json that failed to
# parse: that is the user's config, and overwriting it is worse than the bug
# being fixed. Only jq's exit 4 (no output at all) means "safe to seed"; 5
# (parse error) and 1 (valid JSON, wrong type) mean real content.
# ---------------------------------------------------------------------------

for TOOL in handoff restart; do
  echo "Case D ($TOOL): empty settings.json is seeded, malformed is preserved"
  HOOK_BASENAME=$(basename "$(session_start_hook "$TOOL")")

  # D1 — zero-byte file
  new_sandbox "caseD1-$TOOL"
  : > "$CLAUDE_DIR/settings.json"
  run_installer "$TOOL"
  assert "D1 settings.json is a JSON object"          'jq -e "type == \"object\"" "$CLAUDE_DIR/settings.json" >/dev/null'
  assert "D1 the SessionStart hook got registered"    'grep -q "$HOOK_BASENAME" "$CLAUDE_DIR/settings.json"'

  # D2 — whitespace only, which jq also treats as no input
  new_sandbox "caseD2-$TOOL"
  printf '\n   \n' > "$CLAUDE_DIR/settings.json"
  run_installer "$TOOL"
  assert "D2 settings.json is a JSON object"          'jq -e "type == \"object\"" "$CLAUDE_DIR/settings.json" >/dev/null'
  assert "D2 the SessionStart hook got registered"    'grep -q "$HOOK_BASENAME" "$CLAUDE_DIR/settings.json"'

  # D3 — unparseable but real: a JSONC-style comment the user put there
  new_sandbox "caseD3-$TOOL"
  cat > "$CLAUDE_DIR/settings.json" << 'EOF'
{
  // jq cannot parse this, but it is still the user's config
  "model": "opus",
  "hooks": {}
}
EOF
  cp "$CLAUDE_DIR/settings.json" "$SB/settings-before"
  D3_STATUS=0
  run_installer "$TOOL" || D3_STATUS=$?
  assert "D3 install fails on unparseable settings"   '[ "$D3_STATUS" -ne 0 ]'
  assert "D3 settings.json is left byte-identical"    'cmp -s "$CLAUDE_DIR/settings.json" "$SB/settings-before"'
  assert "D3 does not print Done!"                    '! echo "$OUT" | grep -q "Done!"'

  # D4 — valid JSON, wrong type. jq exits 1 here, not 4; seeding would drop it.
  new_sandbox "caseD4-$TOOL"
  printf '["not", "an", "object"]\n' > "$CLAUDE_DIR/settings.json"
  cp "$CLAUDE_DIR/settings.json" "$SB/settings-before"
  D4_STATUS=0
  run_installer "$TOOL" || D4_STATUS=$?
  assert "D4 install fails on a non-object settings"  '[ "$D4_STATUS" -ne 0 ]'
  assert "D4 settings.json is left byte-identical"    'cmp -s "$CLAUDE_DIR/settings.json" "$SB/settings-before"'
done

echo ""
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
