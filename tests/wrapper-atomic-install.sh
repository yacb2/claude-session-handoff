#!/bin/sh
# Regression test for how install.sh WRITES the shared wrapper (BL-007).
#
# `cp` truncates and rewrites the destination's existing inode. A POSIX shell
# reads a script incrementally, and claude-wrapper.sh blocks inside
# `run_claude "$@"` for the entire session with its dispatch loop still unread.
# So overwriting the wrapper in place while a session is live makes that shell
# resume at a saved byte offset that now points into different content — in the
# process that owns the user's terminal. Writing a sibling temp file and
# `mv`-ing it into place swaps the directory entry to a NEW inode; the running
# shell keeps its open file description on the old one and finishes cleanly.
#
# The test asserts that property, not the inode: a wrapper-shaped victim script
# is started and parked at a blocking point, the REAL installer is run against
# a sandboxed CLAUDE_DIR, and the victim must still execute ITS OWN tail.
# Running the real installer is what makes this a regression test — an inline
# temp+mv here would keep passing after install.sh regressed.
#
# Measured shape of the failure (both /bin/sh and dash, macOS):
#   cp -> victim exits 0 with its tail never executed (offset past new EOF)
#   mv -> victim runs its tail
# Which is why the assertion is "the old marker is present", and why the victim
# is padded: ~65KB before the blocking point puts the saved offset beyond the
# end of the real ~6.5KB wrapper (so an in-place overwrite reads EOF instead of
# executing the real wrapper's body from a stray offset), and ~130KB after it
# puts the tail past any interpreter read-ahead, so the tail is genuinely
# re-read from disk after the installer has written.
#
# Usage: ./tests/wrapper-atomic-install.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO/install.sh"

PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no()      { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; }

[ -x "$INSTALLER" ] || { echo "installer not found: $INSTALLER"; exit 1; }
# install.sh's own check_deps; failing here would look like a wrapper bug.
command -v jq >/dev/null 2>&1     || { echo "jq is required by install.sh"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude is required by install.sh"; exit 1; }

SANDBOX=$(mktemp -d /tmp/cl-atomic.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

REPO_VERSION=$(awk '/^# claude-wrapper version:/ { print $4; exit }' "$REPO/scripts/claude-wrapper.sh")

# A wrapper-shaped script: version header (so the installer sees an upgrade),
# a blocking wait standing in for a live claude session, and a tail standing in
# for the dispatch loop.
make_victim() {
  { echo '#!/bin/sh'
    echo '# claude-wrapper version: 1'
    awk 'BEGIN { for (i = 0; i < 1000; i++) print "# pad-before " i " -------------------------------------------------" }'
    echo 'touch "$VICTIM_BLOCKED"'
    echo 'while [ ! -f "$VICTIM_GO" ]; do sleep 0.05; done'
    awk 'BEGIN { for (i = 0; i < 2000; i++) print "# pad-after " i " --------------------------------------------------" }'
    echo 'echo OLD > "$VICTIM_RESULT"'
  } > "$1"
  chmod +x "$1"
}

# run_scenario <installer> <label>
# Sets SC_MARKER, SC_EXIT, SC_INODE_BEFORE, SC_INODE_AFTER, SC_INSTALLED_VERSION.
# Not a subshell: `wait` only reaches children of the shell that started them.
run_scenario() {
  SC_DIR="$SANDBOX/$2"
  mkdir -p "$SC_DIR/claude/scripts"
  : > "$SC_DIR/zshrc"
  SC_VICTIM="$SC_DIR/claude/scripts/claude-wrapper.sh"
  make_victim "$SC_VICTIM"

  VICTIM_GO="$SC_DIR/go"
  VICTIM_BLOCKED="$SC_DIR/blocked"
  VICTIM_RESULT="$SC_DIR/result"
  export VICTIM_GO VICTIM_BLOCKED VICTIM_RESULT

  # /bin/sh explicitly: the victim stands in for the wrapper, whose shebang is
  # #!/bin/sh, regardless of which interpreter runs this test file.
  /bin/sh "$SC_VICTIM" >"$SC_DIR/victim.log" 2>&1 &
  SC_PID=$!

  N=0
  while [ ! -f "$VICTIM_BLOCKED" ] && [ "$N" -lt 200 ]; do sleep 0.05; N=$((N + 1)); done
  if [ ! -f "$VICTIM_BLOCKED" ]; then
    kill "$SC_PID" 2>/dev/null
    echo "fatal: victim never reached its blocking point"
    exit 1
  fi

  SC_INODE_BEFORE=$(ls -i "$SC_VICTIM" | awk '{ print $1 }')

  # The installer must never be pointed at a real ~/.claude: this test runs it
  # for real, and an unset CLAUDE_DIR would reproduce BL-007 on the developer.
  case "$SC_DIR/claude" in
    "$SANDBOX"/*) : ;;
    *) echo "fatal: refusing to run install.sh outside the sandbox"; exit 1 ;;
  esac
  env CLAUDE_DIR="$SC_DIR/claude" RC_FILE_OVERRIDE="$SC_DIR/zshrc" \
      SHELL_NAME_OVERRIDE=zsh sh "$1" >"$SC_DIR/install.log" 2>&1

  SC_INODE_AFTER=$(ls -i "$SC_VICTIM" | awk '{ print $1 }')
  SC_INSTALLED_VERSION=$(awk '/^# claude-wrapper version:/ { print $4; exit }' "$SC_VICTIM")

  touch "$VICTIM_GO"
  wait "$SC_PID"
  SC_EXIT=$?
  SC_MARKER=$(cat "$VICTIM_RESULT" 2>/dev/null || echo "")
}

# --- The real installer must not disturb a running wrapper ---

run_scenario "$INSTALLER" real

if [ "$SC_INSTALLED_VERSION" = "$REPO_VERSION" ]; then
  ok "installer upgraded the wrapper to v$REPO_VERSION (the write happened)"
else
  no "installer did not upgrade the victim: version is '$SC_INSTALLED_VERSION', expected '$REPO_VERSION'"
fi

if [ "$SC_MARKER" = OLD ]; then
  ok "running shell completed on its own version of the script"
else
  no "running shell lost its tail: marker '$SC_MARKER', expected 'OLD' (exit $SC_EXIT)"
fi

if [ "$SC_EXIT" = 0 ]; then
  ok "running shell exited cleanly"
else
  no "running shell exited $SC_EXIT (see $SANDBOX/real/victim.log)"
fi

if [ "$SC_INODE_BEFORE" != "$SC_INODE_AFTER" ]; then
  ok "wrapper path points at a new inode after the upgrade"
else
  no "wrapper was rewritten in place: inode stayed $SC_INODE_BEFORE"
fi

# --- Mutation arm: reverting the write to in-place cp must break it ---
#
# Without this the checks above would also pass against an installer that never
# writes at all. The mutated copy lives in the sandbox and reaches the repo's
# payload through symlinks, since install.sh resolves SCRIPT_DIR from $0.

MUT_DIR="$SANDBOX/mutated"
mkdir -p "$MUT_DIR"
for d in scripts commands skills; do ln -s "$REPO/$d" "$MUT_DIR/$d"; done
sed 's/mv "$DST_TMP" "$DST"/cp "$DST_TMP" "$DST"/' "$INSTALLER" > "$MUT_DIR/install.sh"
chmod +x "$MUT_DIR/install.sh"

# An unmatched sed would turn this arm into a no-op that always passes.
if grep -qF 'cp "$DST_TMP" "$DST"' "$MUT_DIR/install.sh" &&
   ! grep -qF 'mv "$DST_TMP" "$DST"' "$MUT_DIR/install.sh"; then
  ok "mutation applied: atomic write reverted to in-place cp"
else
  no "mutation did NOT apply — the arm below would pass vacuously"
  summary
  exit 1
fi

run_scenario "$MUT_DIR/install.sh" mutated

if [ "$SC_MARKER" != OLD ]; then
  ok "in-place cp does corrupt the running shell (marker '$SC_MARKER', exit $SC_EXIT)"
else
  no "in-place cp left the running shell intact — this test proves nothing"
fi

summary
[ "$FAIL" = 0 ]
