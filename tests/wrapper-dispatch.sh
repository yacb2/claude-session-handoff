#!/bin/sh
# Regression tests for the dispatch loop in scripts/claude-wrapper.sh.
#
# smoke.sh checks the installer protocol and the wrapper's file properties; it
# never runs the loop. This drives the loop with a stub `claude` on PATH that
# records its argv per invocation, so what the wrapper actually launches is
# observable.
#
# Covers the PAYLOAD_BYTES stale-variable defect: PAYLOAD_BYTES is assigned only
# in the payload-present branch and never reset per iteration, so a payload-LESS
# handoff following a payload handoff still satisfies `[ -n "$PAYLOAD_BYTES" ]`
# and relaunches with the `continue` kickoff — while the user is told on stdout
# that the session "arranca limpia, sin contexto sembrado".
set -u

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-wrapper.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

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
# $PPID is the wrapper: run_claude backgrounds claude, so the stub's parent is
# the wrapper shell whose PID is the WRAPPER_ID in every flag filename.
cat > "$BIN/claude" <<'STUB'
#!/bin/sh
N_FILE="$HOME/.claude/tmp/stub-count"
N=$(cat "$N_FILE" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$N_FILE"
printf '%s|%s\n' "$N" "$*" >> "$HOME/.claude/tmp/argv.log"
TMP="$HOME/.claude/tmp"
# Consume the payload the way the real SessionStart hook does
# (handoff-session-start.sh: read it, then `rm -f`). Without this the file
# survives into the next iteration and the payload-less case never happens.
rm -f "$TMP/handoff-payload-$PPID"
case "$N" in
  1) printf 'seeded brief' > "$TMP/handoff-payload-$PPID"; touch "$TMP/handoff-flag-$PPID" ;;
  2) touch "$TMP/handoff-flag-$PPID" ;;
esac
exit 0
STUB
chmod +x "$BIN/claude"

HOME="$SANDBOX" PATH="$BIN:$PATH" sh "$WRAPPER" >"$SANDBOX/out.log" 2>&1

ARGV_LOG="$SANDBOX/.claude/tmp/argv.log"
if [ ! -f "$ARGV_LOG" ]; then
  no "wrapper never launched the stub (see $SANDBOX/out.log)"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

argv_of() { awk -F'|' -v n="$1" '$1 == n { print $2; exit }' "$ARGV_LOG"; }
COUNT=$(wc -l < "$ARGV_LOG" | tr -d ' ')

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

# 4. the user-facing message and the launch form must agree
if grep -q "arranca limpia" "$SANDBOX/out.log" && [ -z "$(argv_of 3)" ]; then
  ok "warning text and launch form agree"
elif grep -q "arranca limpia" "$SANDBOX/out.log"; then
  no "wrapper printed 'arranca limpia' but still passed a kickoff prompt"
else
  no "expected the payload-less warning on stdout"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
