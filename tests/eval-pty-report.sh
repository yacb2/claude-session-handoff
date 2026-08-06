#!/bin/sh
# Structural guard for tests/eval-pty.sh's reporting and classification layers.
#
# eval-pty.sh spends ~1 hour driving real claude sessions, so its report logic —
# rates, intermittency, per-mode tallies, the noise floor — would otherwise only
# ever be exercised by a run nobody repeats to check a formatting change. This
# drives the same code path in seconds by putting a stub `expect` on PATH.
#
# THE STUB MUST BE FAITHFUL. An earlier version produced `executed-immediately`
# by creating neither the flag nor the turn-1 marker — a state the real harness
# cannot reach, since the marker is written exactly when the flag exists at the
# end of turn 1. That left the real correlation untested: inverting the
# `propose` classifier kept this file at 9/9 green. Every stub below now writes
# the same markers, in the same combinations, that the expect script writes.
#
# What this still does NOT test: that the real eval is reproducible. The stub is
# deterministic by construction; the model is not. Only a real run speaks to
# that, and BL-010 exists because it does not.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

SANDBOX=$(mktemp -d -t eval-pty-report.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/claude"
chmod +x "$SANDBOX/bin/claude"

# --- the faithful stub ----------------------------------------------------
# Marker contract, mirroring the expect script exactly:
#   FLAG  — the skill fired (at any point)
#   TURN1 — the skill fired during turn 1   (implies FLAG)
#   ALIVE — turn 1 completed in a live session (always, unless the run died)
#
# Rule, chosen so one run produces every verdict code as a MIX, not a flat
# pass/fail, and so `propose` reaches each of its outcomes the way a real
# session would:
#   non-propose : fire on odd reps          -> 2/3
#   propose r1  : hold, then fire on turn 2 -> ok
#   propose r2  : hold, never fire          -> no-execute-after-confirm
#   propose r3  : fire on TURN 1            -> executed-immediately (faithful)
#
# The stub also writes the `handoff-fired-<id>` timing file wherever the real
# expect script would (BL-014 step 1): whenever the flag appears, tagged with
# the turn it appeared on. Fixed values, since the point is the aggregation,
# not the latency — turn1 7s, turn2 11s.
write_stub() {
  cat > "$SANDBOX/bin/expect" <<'STUB'
#!/bin/sh
IN=$(cat)
pathof() { printf '%s' "$IN" | grep -o "/[^\"]*handoff-$1-[^\"]*" | head -1; }
FLAG=$(pathof flag); ALIVE=$(pathof alive); TURN1=$(pathof turn1)
FIRED=$(pathof fired)
[ -n "$FLAG" ] || exit 0
BASE=${FLAG##*/}; REP=${BASE##*-}; REST=${BASE%-*}; QN=${REST##*-}
# Inverted latency: earlier queries finish LAST, so completion order differs
# from eval-set order and the ordering assertion has something to catch.
case "$QN" in 1) sleep 0.6 ;; 2) sleep 0.3 ;; esac
case "$IN" in
  *'"propose" == "propose"'*)
    case "$REP" in
      1) touch "$ALIVE"; touch "$FLAG"; printf 'turn2 11\n' > "$FIRED" ;;
      2) touch "$ALIVE" ;;
      3) touch "$FLAG"; touch "$TURN1"; touch "$ALIVE"; printf 'turn1 7\n' > "$FIRED" ;;
    esac ;;
  *)
    touch "$ALIVE"
    case $((REP % 2)) in
      1) touch "$FLAG"; touch "$TURN1"; printf 'turn1 7\n' > "$FIRED" ;;
    esac ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/expect"
}
write_stub

cat > "$SANDBOX/set.json" <<'JSON'
[
  { "query": "ALPHA execute probe", "expect": "execute" },
  { "query": "BRAVO propose probe",  "expect": "propose" },
  { "query": "CHARLIE ignore probe", "expect": "ignore"  }
]
JSON

OUT="$SANDBOX/out.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set.json" --reps 3 --jobs 9 --timeout 1 > "$OUT" 2>&1
RC=$?

# --- assertions -----------------------------------------------------------
grep -qE '^\[01\] execute .*2/3 :: ALPHA'  "$OUT" \
  && ok "execute query reports a rate (2/3), not a flat verdict" \
  || no "execute query did not report 2/3 — got: $(grep -E '^\[01\]' "$OUT")"

grep -qE '^\[01\] execute +FLAKY' "$OUT" \
  && ok "a query that passed some reps is marked FLAKY" \
  || no "intermittent query was not marked FLAKY"

grep -qE '^\[02\] propose .*executed-immediately' "$OUT" \
  && grep -qE '^\[02\] propose .*no-execute-after-confirm' "$OUT" \
  && ok "both propose failure modes are reported, not collapsed" \
  || no "propose failure modes collapsed — got: $(grep -E '^\[02\]' "$OUT")"

grep -qE 'executed immediately +: 1' "$OUT" \
  && grep -qE 'no execute after confirm +: 1' "$OUT" \
  && ok "summary tallies the propose failure modes separately" \
  || no "summary did not tally propose modes separately"

grep -qE '^# execute : 2 / 3' "$OUT" && grep -qE '^# ignore  : 1 / 3' "$OUT" \
  && ok "per-mode totals are counted over reps (2/3, 1/3)" \
  || no "per-mode totals wrong — got: $(grep -E '^# (execute|ignore)' "$OUT")"

grep -qE '^# intermittent queries: 3' "$OUT" \
  && grep -qE '^# NOISE FLOOR: \+/- 3 passes out of 9' "$OUT" \
  && ok "noise floor is reported and matches the intermittent count" \
  || no "noise floor missing or wrong — got: $(grep -E 'NOISE FLOOR|intermittent' "$OUT")"

# Ordering: the stub gives query 1 the longest sleep and runs all 9 units at
# once, so completion order is genuinely 3,2,1. Report order must still be
# eval-set order.
ORDER=$(grep -oE '^\[[0-9]+\]' "$OUT" | tr -d '[]' | tr '\n' ' ' | sed 's/ *$//')
[ "$ORDER" = "01 02 03" ] \
  && ok "report follows eval-set order though completion order is reversed" \
  || no "report order was '$ORDER', expected '01 02 03'"

[ "$RC" -ne 0 ] \
  && ok "exit status is non-zero when reps are intermittent" \
  || no "harness exited 0 despite intermittent queries"

# Fire timings (BL-014 step 1). The stub fires on 6 of the 9 units — q1 and q3
# on reps 1 and 3 (turn 1), q2 on rep 1 (turn 2) and rep 3 (turn 1) — so the
# aggregate must be n=6 with turn1 max 7s, turn2 max 11s, overall max 11s.
# Asserting the breakdown and not just "a line appeared" is the point: step 2
# sets the absence-arm deadline off this max, and a max computed over the wrong
# subset would justify a deadline that truncates real fires.
grep -qE '^# observed fire times \(n=6 of 9 units\): turn1 max 7s · turn2 max 11s · overall max 11s' "$OUT" \
  && ok "fire times are aggregated per turn and overall" \
  || no "fire-time aggregate wrong — got: $(grep -E 'observed fire times' "$OUT")"

# --- the classifier must depend on the turn-1 marker, not on an absence ---
# Fires on turn 1 for a propose query. A classifier that reads "no held file"
# instead of "turn 1 fired" cannot tell this from a dead run.
cat > "$SANDBOX/bin/expect" <<'STUB'
#!/bin/sh
IN=$(cat)
pathof() { printf '%s' "$IN" | grep -o "/[^\"]*handoff-$1-[^\"]*" | head -1; }
FLAG=$(pathof flag); ALIVE=$(pathof alive); TURN1=$(pathof turn1)
[ -n "$FLAG" ] || exit 0
touch "$FLAG"; touch "$TURN1"; touch "$ALIVE"
exit 0
STUB
chmod +x "$SANDBOX/bin/expect"
printf '[{"query":"BRAVO propose probe","expect":"propose"}]\n' > "$SANDBOX/set3.json"
OUT3="$SANDBOX/out3.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set3.json" --reps 2 --jobs 2 --timeout 1 > "$OUT3" 2>&1
RC3=$?
{ [ "$RC3" -ne 0 ] && grep -qE '^\[01\] propose +FAIL +0/2 .*executed-immediately' "$OUT3"; } \
  && ok "a propose query that fires on turn 1 scores executed-immediately" \
  || no "turn-1 execution not classified — got: $(grep -E '^\[01\]' "$OUT3")"

# --- a dead harness must never be scored ---------------------------------
# The critical arm: `ignore` passes on the ABSENCE of the flag, so a harness
# that never ran anything looks identical to a correct decline. Before the
# liveness marker, an ignore-only set exited 0, fully green, having measured
# nothing at all.
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$SANDBOX/bin/expect"
chmod +x "$SANDBOX/bin/expect"
printf '[{"query":"CHARLIE ignore probe","expect":"ignore"}]\n' > "$SANDBOX/set4.json"
OUT4="$SANDBOX/out4.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set4.json" --reps 2 --jobs 2 --timeout 1 > "$OUT4" 2>&1
RC4=$?
{ [ "$RC4" -ne 0 ] && grep -qE '^\[01\] ignore +FAIL +0/2' "$OUT4"; } \
  && ok "an ignore query cannot pass off a harness that never ran a session" \
  || no "DEAD HARNESS SCORED AS PASS (rc=$RC4) — got: $(grep -E '^\[01\]' "$OUT4")"

grep -qE 'HARNESS ERROR \(not measured\): 2' "$OUT4" \
  && grep -qE '^# !! 2 rep\(s\) never ran a session' "$OUT4" \
  && ok "harness errors are tallied and shouted, not folded into the rates" \
  || no "harness errors not surfaced — got: $(grep -iE 'harness' "$OUT4")"

# --- uniform pass ---------------------------------------------------------
write_stub
printf '[{"query":"BRAVO propose probe","expect":"propose"}]\n' > "$SANDBOX/set2.json"
OUT2="$SANDBOX/out2.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set2.json" --reps 1 --jobs 1 --timeout 1 > "$OUT2" 2>&1
RC2=$?
{ [ "$RC2" -eq 0 ] && grep -qE '^# NOISE FLOOR: \+/- 0 passes' "$OUT2"; } \
  && ok "a uniformly passing set exits 0 with a zero noise floor" \
  || no "uniform pass did not exit clean (rc=$RC2)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
