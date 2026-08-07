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

# --- static source checks, BEFORE the harness is ever executed ------------
# These read eval-pty.sh as TEXT and must run first. The assertions further
# down invoke it against a stub, and invoking it expands the very heredoc one
# of these checks exists to police — so ordering them after the run would mean
# executing the defect and then reporting it.
# --- nothing in the expect heredoc may be shell-expanded by accident -------
# `expect <<EXP` is an UNQUOTED heredoc, so the shell expands its body before
# expect ever sees it. That is deliberate for `$QUERY`, `$TIMEOUT`, `$MODEL` —
# and a trap for everything else.
#
# Measured, not imagined: a comment added on 2026-08-06 quoted the old
# confirmation string in backticks. Backticks inside an unquoted heredoc are
# command substitution, so every unit of every run tried to execute
# `sí, hazlo / yes, go ahead` as a shell command. A Tcl comment hides it from
# the reader, and the harness's own `2>&1 || true` does not suppress it — the
# substitution happens during expansion, before that redirection applies.
#
# It cost a 45-unit run. Cheap to prevent, invisible to review.
#
# BOTH substitution forms, not just the one that bit us. Checking backticks
# alone would leave `$(...)` — the same defect in the spelling most people
# actually reach for — walking straight through a guard reporting green. The
# heredoc contains neither today, so closing the class costs nothing.
#
# `${...}` is deliberately NOT rejected: it is parameter expansion and cannot
# run a command, so banning it would overstate what this check is for. Escaped
# forms (`\$t1`, `\$fh`) are how the file already defers expansion to Tcl and
# stay legal — hence the "not preceded by a backslash" match.
HEREDOC=$(awk '/expect <<EXP/{f=1;next} /^EXP$/{f=0} f' "$REPO/tests/eval-pty.sh")
BADSUB=$(printf '%s\n' "$HEREDOC" | grep -nE '(^|[^\\])(`|\$\()' | head -3 | tr '\n' ' ')
if [ -z "$BADSUB" ]; then
  ok "the expect heredoc has no command substitution for the shell to execute"
else
  no "command substitution inside the expect heredoc — the shell runs it on every unit: $BADSUB
    Put the note above run_one() instead, outside the heredoc."
fi

# --- the turn-2 confirmation is a measurement-defining constant ------------
# `propose` is scored by sending this string and checking whether the marker
# appears afterwards, so its WORDING decides the score. The previous value,
# `sí, hazlo / yes, go ahead`, carried an imperative to act — and the imperative
# alone was producing the passes. BL-020's [29] scored propose 3/3 with it and
# 0/3 with a bare confirmation, changing nothing else. That is the weak spot
# eval-pty.sh had recorded as hypothetical at its own lines ~217-220, and it
# means every propose number taken before 2026-08-06 is an upper bound (BL-021).
#
# Pinned to an exact string on purpose, rather than matched against a rule.
# Changing it changes the ruler, so it must FAIL here and force a re-baseline of
# every propose entry instead of passing quietly. An "allowlist of contentless
# affirmations" was considered and rejected: it is a rule authored to fit one
# observation, and it would wave through the next `claro, dale` while still
# reporting green.
CONFIRM_LINE=$(grep -c '^      send -- {ok}$' "$REPO/tests/eval-pty.sh")
if [ "$CONFIRM_LINE" = 1 ]; then
  ok "eval-pty.sh confirms propose with the pinned bare token"
else
  no "eval-pty.sh's turn-2 confirmation is not the pinned 'ok' — got: $(grep -n 'send -- {' "$REPO/tests/eval-pty.sh" | grep -v QUERY | tr '\n' ' ')
    Changing it re-baselines every propose score; record the new reference (BL-021) rather than editing this line to match."
fi

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
# The turn-1 transcript is whatever expect writes to STDOUT — the caller
# redirects it into the file. So the stub earns its transcript the same way the
# real thing does, by printing, rather than by knowing a path.
printf 'stub turn-1 transcript\n'
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

# --- a run's results must survive the run (BL-014) ------------------------
# The report prints only after every unit completes, and the results directory
# is a mktemp cleaned by trap. A ~67-minute job interrupted at minute 60
# therefore produced NOTHING: every verdict and every fire time went with it.
# Observed for real on 2026-08-06 — a run killed at 54 of 99 units left no
# output at all, and the data had to be scraped from the live process by hand.
#
# --results-dir makes the directory the caller's, and progress.tsv is appended
# per unit as it completes, so an interrupted run still leaves what it measured.
write_stub
KEEP="$SANDBOX/keep-results"
OUT5="$SANDBOX/out5.txt"
PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set.json" --reps 3 --jobs 9 --timeout 1 \
  --results-dir "$KEEP" > "$OUT5" 2>&1

[ -d "$KEEP" ] \
  && ok "--results-dir survives a completed run" \
  || no "--results-dir was deleted; an interrupted run would leave nothing"

PROG="$KEEP/progress.tsv"
if [ -f "$PROG" ]; then
  PLINES=$(wc -l < "$PROG" | tr -d ' ')
  [ "$PLINES" = 9 ] \
    && ok "progress.tsv holds one line per unit (9)" \
    || no "progress.tsv has $PLINES lines, expected 9 (3 queries x 3 reps)"
  # The fire time is the column the killed run made expensive to lose.
  # columns: unit, mode, verdict, fire turn, fire seconds
  awk -F'\t' '$4 == "turn1" && $5 == 7 { found = 1 } END { exit !found }' "$PROG" \
    && ok "progress.tsv records the fire turn and elapsed seconds" \
    || no "progress.tsv lost the fire timing — got: $(head -2 "$PROG" | tr '\t' '|' | tr '\n' ' ')"
  # Verdicts must be there too, or a partial run says nothing about pass/fail.
  grep -q 'executed-immediately' "$PROG" \
    && ok "progress.tsv records the verdict alongside the timing" \
    || no "progress.tsv has no verdict column"
else
  no "progress.tsv was never written"
  no "progress.tsv was never written (timing)"
  no "progress.tsv was never written (verdict)"
fi

# --- turn 1 must be recoverable, for EVERY unit (BL-021) ------------------
# The harness scores `propose` from the presence or absence of a marker file,
# which cannot distinguish "held off and offered the handoff" from "answered
# something else entirely". Its own header calls that out: a model that ignores
# a propose query and is then pulled in by the confirmation scores a false `ok`.
#
# That stopped being hypothetical on 2026-08-06. BL-020's [29] scored 3/3 under
# an imperative confirmation and 0/3 under a bare one, and NOTHING in the run
# could say what turn 1 had actually done — so the defect could be measured and
# not diagnosed. Same for the three "give me a prompt" entries at 0/15: never
# offered, or offered and not followed through, are one observation here.
#
# So every unit now leaves its turn-1 transcript. Every unit, not just failures:
# a false `ok` is precisely the verdict whose text you need, and keeping only
# the reds would leave it unauditable.
# NON-EMPTY, not merely present. The shell creates the file by opening the
# redirect, so counting files would pass against a harness that captured
# nothing — which is exactly the first implementation of this: `log_file`
# records nothing while `log_user` is 0, and it produced nine 0-byte files that
# a presence check would have called green.
TURN1S=$(find "$KEEP" -name '*.turn1' -size +0 2>/dev/null | wc -l | tr -d ' ')
if [ "$TURN1S" = 9 ]; then
  ok "every unit leaves a NON-EMPTY turn-1 transcript (9)"
else
  EMPTY=$(find "$KEEP" -name '*.turn1' 2>/dev/null | wc -l | tr -d ' ')
  no "found $TURN1S non-empty turn-1 transcripts of $EMPTY files, expected 9 — propose verdicts stay undiagnosable without them"
fi

# --- a stale install must stop the run, not be scored -------------------
# eval-pty.sh measures the skill in ~/.claude/skills, never the repo copy. So
# editing SKILL.md and running the eval without ./install.sh scores the OLD
# policy and reports it as the new one — silently, with a plausible number.
#
# CLAUDE.md carries this as a written warning, which is exactly the kind of
# guard that works until the day it doesn't: on 2026-08-06 the sequence was
# caught by hand, twice, with nothing enforcing it.
#
# Paired assertions on purpose. A check that only proves the abort would still
# pass if it aborted unconditionally, which would break every real run — so the
# control positive below feeds it a MATCHING install and requires it to proceed.
write_stub
printf '[{"query":"ALPHA staleness probe","expect":"execute"}]\n' > "$SANDBOX/set-stale.json"

printf 'not the repo SKILL.md\n' > "$SANDBOX/stale-SKILL.md"
OUT6="$SANDBOX/out6.txt"
INSTALLED_SKILL_OVERRIDE="$SANDBOX/stale-SKILL.md" \
  PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set-stale.json" --reps 1 --jobs 1 --timeout 1 > "$OUT6" 2>&1
RC6=$?
if [ "$RC6" -ne 0 ] && grep -qi 'install' "$OUT6" && ! grep -q '^\[01\]' "$OUT6"; then
  ok "a stale installed skill aborts the run before any unit is scored"
else
  no "stale install was not refused (rc=$RC6) — the run would score the old policy: $(head -3 "$OUT6" | tr '\n' ' ')"
fi

cp "$REPO/skills/session-handoff/SKILL.md" "$SANDBOX/fresh-SKILL.md"
OUT7="$SANDBOX/out7.txt"
INSTALLED_SKILL_OVERRIDE="$SANDBOX/fresh-SKILL.md" \
  PATH="$SANDBOX/bin:$PATH" sh "$REPO/tests/eval-pty.sh" \
  --eval-set "$SANDBOX/set-stale.json" --reps 1 --jobs 1 --timeout 1 > "$OUT7" 2>&1
if grep -q '^\[01\]' "$OUT7"; then
  ok "a matching install runs normally (the guard is not a blanket refusal)"
else
  no "CONTROL POSITIVE FAILED — a matching install was also refused, so the guard blocks every real run: $(head -3 "$OUT7" | tr '\n' ' ')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
