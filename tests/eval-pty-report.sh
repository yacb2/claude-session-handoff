#!/bin/sh
# Structural guard for tests/eval-pty.sh's reporting layer.
#
# eval-pty.sh spends ~100 minutes driving real claude sessions, so its report
# logic — rates, intermittency, per-mode tallies, the noise floor — was
# previously only ever exercised by a run nobody would repeat to check a
# formatting change. This drives the same code path in seconds by putting a
# stub `expect` on PATH.
#
# What the stub does: it reads the here-doc eval-pty.sh feeds to expect, pulls
# the flag/held paths out of it, and creates them on a fixed rule keyed to the
# rep number. That makes every outcome DETERMINISTIC, which is the point — it
# tests that the harness reports what happened, not what the model did.
#
# What this therefore does NOT test: that the real eval is reproducible. The
# stub is deterministic by construction; the model is not. Only a real run can
# speak to that, and BL-010 exists precisely because it does not.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

SANDBOX=$(mktemp -d -t eval-pty-report.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# --- stub expect ----------------------------------------------------------
# Rule, chosen so a single run produces every verdict code the report can
# print, and produces them as a mix rather than as flat pass/fail:
#
#   non-propose : fire on odd reps only      -> 2/3, mixed
#   propose     : rep 3 skips the "held" marker (looks like an immediate
#                 execution), reps 1-2 hold off and only rep 1 follows
#                 through                    -> 1/3, two distinct codes
cat > "$SANDBOX/bin/expect" <<'STUB'
#!/bin/sh
IN=$(cat)
FLAG=$(printf '%s' "$IN" | grep -o '/[^"]*handoff-flag-[^"]*' | head -1)
HELD=$(printf '%s' "$IN" | grep -o '/[^"]*handoff-held-[^"]*' | head -1)
[ -n "$FLAG" ] || exit 0
REP=${FLAG##*-}
case "$IN" in
  *'"propose" == "propose"'*)
    [ "$REP" = "3" ] || touch "$HELD"
    [ "$REP" = "1" ] && touch "$FLAG"
    ;;
  *)
    case $((REP % 2)) in 1) touch "$FLAG" ;; esac
    ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/expect"

# `claude` only needs to exist — the stub expect never spawns it.
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/claude"
chmod +x "$SANDBOX/bin/claude"

# --- eval set with one query per mode, in a known order -------------------
cat > "$SANDBOX/set.json" <<'JSON'
[
  { "query": "ALPHA execute probe", "expect": "execute" },
  { "query": "BRAVO propose probe",  "expect": "propose" },
  { "query": "CHARLIE ignore probe", "expect": "ignore"  }
]
JSON

OUT="$SANDBOX/out.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set.json" --reps 3 --jobs 2 --timeout 1 > "$OUT" 2>&1
RC=$?

# --- assertions -----------------------------------------------------------
# 1. rates, not verdicts: each query reports passes/reps.
grep -qE '^\[01\] execute .*2/3 :: ALPHA'  "$OUT" \
  && ok "execute query reports a rate (2/3), not a flat verdict" \
  || no "execute query did not report 2/3 — got: $(grep -E '^\[01\]' "$OUT")"

# 2. intermittency is named, so a flaky query cannot read as a clean fail.
grep -qE '^\[01\] execute +FLAKY' "$OUT" \
  && ok "a query that passed some reps is marked FLAKY" \
  || no "intermittent query was not marked FLAKY"

# 3. the two propose failure modes stay distinct in the per-query line.
grep -qE '^\[02\] propose .*executed-immediately' "$OUT" \
  && grep -qE '^\[02\] propose .*no-execute-after-confirm' "$OUT" \
  && ok "both propose failure modes are reported, not collapsed" \
  || no "propose failure modes collapsed — got: $(grep -E '^\[02\]' "$OUT")"

# 4. ...and stay distinct in the summary tallies.
grep -qE 'executed immediately +: 1' "$OUT" \
  && grep -qE 'no execute after confirm +: 1' "$OUT" \
  && ok "summary tallies the propose failure modes separately" \
  || no "summary did not tally propose modes separately"

# 5. per-mode totals count reps, not queries.
grep -qE '^# execute : 2 / 3' "$OUT" && grep -qE '^# ignore  : 1 / 3' "$OUT" \
  && ok "per-mode totals are counted over reps (2/3, 1/3)" \
  || no "per-mode totals wrong — got: $(grep -E '^# (execute|ignore)' "$OUT")"

# 6. the noise floor is printed and equals the intermittent-query count.
grep -qE '^# intermittent queries: 3' "$OUT" \
  && grep -qE '^# NOISE FLOOR: \+/- 3 passes out of 9' "$OUT" \
  && ok "noise floor is reported and matches the intermittent count" \
  || no "noise floor missing or wrong — got: $(grep -E 'NOISE FLOOR|intermittent' "$OUT")"

# 7. report order follows the eval set, not job completion order.
ORDER=$(grep -oE '^\[0[0-9]\]' "$OUT" | tr -d '[]' | tr '\n' ' ' | sed 's/ *$//')
[ "$ORDER" = "01 02 03" ] \
  && ok "report is ordered by eval set despite concurrent execution" \
  || no "report order was '$ORDER', expected '01 02 03'"

# 8. anything short of every rep passing is a non-zero exit.
[ "$RC" -ne 0 ] \
  && ok "exit status is non-zero when reps are intermittent" \
  || no "harness exited 0 despite intermittent queries"

# 9. MUTATION: with a stub that always fires, an execute query must go clean.
cat > "$SANDBOX/bin/expect" <<'STUB2'
#!/bin/sh
IN=$(cat)
FLAG=$(printf '%s' "$IN" | grep -o '/[^"]*handoff-flag-[^"]*' | head -1)
[ -n "$FLAG" ] && touch "$FLAG"
exit 0
STUB2
chmod +x "$SANDBOX/bin/expect"
printf '[{"query":"ALPHA execute probe","expect":"execute"}]\n' > "$SANDBOX/set2.json"
OUT2="$SANDBOX/out2.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set2.json" --reps 3 --jobs 3 --timeout 1 > "$OUT2" 2>&1
RC2=$?
{ [ "$RC2" -eq 0 ] && grep -qE '^# NOISE FLOOR: \+/- 0 passes' "$OUT2"; } \
  && ok "a uniformly passing set exits 0 with a zero noise floor" \
  || no "uniform pass did not exit clean (rc=$RC2)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
