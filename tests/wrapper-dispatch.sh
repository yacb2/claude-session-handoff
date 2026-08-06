#!/bin/sh
# Regression tests for the dispatch loop in scripts/claude-wrapper.sh.
#
# smoke.sh checks the installer protocol and the wrapper's file properties; it
# never runs the loop. This drives the loop with a stub `claude` on PATH that
# records its argv per invocation, so what the wrapper actually launches is
# observable.
#
# Covers the stale-kickoff defect: the loop used to test the payload twice —
# once to pick the message, then again through a `PAYLOAD_BYTES` variable that
# was never reset per iteration — so a payload-LESS handoff following a seeded
# one inherited the previous value and relaunched with the `continue` kickoff
# while telling the user the session "arranca limpia, sin contexto sembrado".
# The wrapper now folds both into one if/else, which is why check 3 below is
# the one that matters: it asserts the launch form directly, so it holds
# whether the bug is patched or designed out.
set -u

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-wrapper.sh"
PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no()      { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; }

[ -f "$WRAPPER" ] || { echo "wrapper not found: $WRAPPER"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"
mkdir -p "$BIN" "$SANDBOX/.claude/tmp"

# Stub claude. Each invocation appends its argv to argv.log, then stages the
# next handoff by writing the wrapper's per-PID flag files directly:
#   1st -> payload + flag  (a seeded handoff)
#   2nd -> flag only       (a payload-less handoff)
#   3rd -> nothing         (loop ends)
#
# Flag filenames key off $CLAUDE_HANDOFF_ID, which the wrapper exports as its
# documented contract (claude-wrapper.sh: "exported as both CLAUDE_RESTART_ID
# and CLAUDE_HANDOFF_ID so hooks from either tool work") and which the real
# hooks and SKILL.md both consume. $PPID would work today only because
# run_claude happens to background claude directly with no intervening
# subshell; wrapping that launch in a pipeline or `( ... ) &` later would break
# this test with "expected 3 invocations, got 1", pointing at the wrapper
# rather than at the stale assumption. Test the public seam, not the accident.
#
# The log is also the counter: line N is invocation N's argv. Arithmetic
# expansion around `wc -l` is load-bearing — BSD wc pads its output, and the
# padded form would not match the `case` arms below.
cat > "$BIN/claude" <<'STUB'
#!/bin/sh
TMP="$HOME/.claude/tmp"
printf '%s\n' "$*" >> "$TMP/argv.log"
N=$(( $(wc -l < "$TMP/argv.log") ))
# Consume the payload the way the real SessionStart hook does
# (handoff-session-start.sh: read it, then `rm -f`). Without this the file
# survives into the next iteration and the payload-less case never happens.
rm -f "$TMP/handoff-payload-$CLAUDE_HANDOFF_ID"
case "$N" in
  1) printf 'seeded brief' > "$TMP/handoff-payload-$CLAUDE_HANDOFF_ID"
     touch "$TMP/handoff-flag-$CLAUDE_HANDOFF_ID" ;;
  2) touch "$TMP/handoff-flag-$CLAUDE_HANDOFF_ID" ;;
esac
exit 0
STUB
chmod +x "$BIN/claude"

HOME="$SANDBOX" PATH="$BIN:$PATH" sh "$WRAPPER" >"$SANDBOX/out.log" 2>&1

ARGV_LOG="$SANDBOX/.claude/tmp/argv.log"
if [ ! -f "$ARGV_LOG" ]; then
  no "wrapper never launched the stub (see $SANDBOX/out.log)"
  summary
  exit 1
fi

# Line N of the log is invocation N's argv. `sed -n Np` rather than splitting a
# prefix, so an argv containing the delimiter could not truncate the record.
argv_of() { sed -n "${1}p" "$ARGV_LOG"; }
COUNT=$(( $(wc -l < "$ARGV_LOG") ))

# 1. the loop ran three times: initial, seeded handoff, payload-less handoff
if [ "$COUNT" = 3 ]; then
  ok "dispatch loop ran 3 invocations"
else
  no "expected 3 invocations, got $COUNT (log: $(cat "$ARGV_LOG" | tr '\n' ' '))"
fi

# 2. a seeded handoff relaunches with the kickoff prompt (current design)
if [ "$(argv_of 2)" = "continue" ]; then
  ok "seeded handoff relaunches with the kickoff prompt"
else
  no "seeded handoff should pass 'continue', got '$(argv_of 2)'"
fi

# 3. THE REGRESSION: a payload-less handoff must relaunch bare.
#    Before the fix this is 'continue', inherited from invocation 2.
if [ -z "$(argv_of 3)" ]; then
  ok "payload-less handoff relaunches bare (no stale kickoff)"
else
  no "payload-less handoff leaked a stale kickoff: got '$(argv_of 3)', expected no args"
fi

# 4. the payload-less warning is actually printed. Its AGREEMENT with the
#    launch form is check 3's job — re-testing argv here would only restate it.
if grep -q "arranca limpia" "$SANDBOX/out.log"; then
  ok "wrapper warned about the payload-less handoff"
else
  no "expected the payload-less warning on stdout"
fi

# --- exit status and stdin (BL-012) ---------------------------------------
# Both defects come from the same line: run_claude backgrounds claude so the
# exit watcher can run alongside it, and `cmd &` costs you two things — the
# status, because the script's last command is the dispatch `while` loop, and
# stdin, because POSIX assigns /dev/null to an asynchronous list's stdin when
# job control is off (sh and dash both do it).
#
# Each scenario gets its own HOME: the wrapper keys every file off its PID, but
# a shared tmp dir would still let one scenario's argv.log feed another's.
scenario() {
  SHOME="$SANDBOX/$1"
  SBIN="$SHOME/bin"
  mkdir -p "$SBIN" "$SHOME/.claude/tmp"
}

# 5. a non-zero status survives a run with no handoff at all.
#    The naive shape of this bug: the script ends on the `while` loop, and a
#    loop whose body never ran exits 0 regardless of what claude did.
scenario exitcode
cat > "$SBIN/claude" <<'STUB'
#!/bin/sh
exit 42
STUB
chmod +x "$SBIN/claude"
HOME="$SHOME" PATH="$SBIN:$PATH" sh "$WRAPPER" >/dev/null 2>&1
RC=$?
if [ "$RC" = 42 ]; then
  ok "wrapper propagates claude's exit status"
else
  no "expected exit 42 from the wrapper, got $RC — 'claude -p ... || handle' can never fire"
fi

# 6. and survives the dispatch loop too, where the failing run is the LAST
#    iteration rather than the only one. A fix that only propagates the first
#    run_claude passes check 5 and fails here.
scenario exitcode_loop
cat > "$SBIN/claude" <<'STUB'
#!/bin/sh
TMP="$HOME/.claude/tmp"
printf 'x\n' >> "$TMP/runs.log"
if [ "$(wc -l < "$TMP/runs.log")" -eq 1 ]; then
  touch "$TMP/handoff-flag-$CLAUDE_HANDOFF_ID"
  exit 0
fi
exit 42
STUB
chmod +x "$SBIN/claude"
HOME="$SHOME" PATH="$SBIN:$PATH" sh "$WRAPPER" >/dev/null 2>&1
RC=$?
if [ "$RC" = 42 ]; then
  ok "wrapper propagates the status of the LAST run, after a handoff"
else
  no "expected exit 42 after a handoff iteration, got $RC"
fi

# 7. piped stdin reaches claude. Verified against the pre-fix wrapper: the stub
#    logged an empty string for both a pipe and a redirected file, while the
#    same stub invoked directly received the data — so this is the wrapper's
#    doing, not the stub's.
scenario stdin
cat > "$SBIN/claude" <<'STUB'
#!/bin/sh
printf 'stdin=[%s]\n' "$(cat)" > "$HOME/.claude/tmp/stdin.log"
exit 0
STUB
chmod +x "$SBIN/claude"
printf 'hello-from-pipe' | HOME="$SHOME" PATH="$SBIN:$PATH" sh "$WRAPPER" -p "x" >/dev/null 2>&1
GOT=$(cat "$SHOME/.claude/tmp/stdin.log" 2>/dev/null || echo "<no log>")
if [ "$GOT" = "stdin=[hello-from-pipe]" ]; then
  ok "piped stdin reaches claude"
else
  no "piped stdin was replaced: stub saw '$GOT' — \`cat notes.md | claude -p\` sends nothing"
fi

summary
[ "$FAIL" = 0 ]
