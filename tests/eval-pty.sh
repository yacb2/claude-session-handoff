#!/bin/sh
# PTY-based interactive trigger eval for the session-handoff skill.
#
# Why this exists: tests/eval-trigger.sh runs the skill-creator harness via
# `claude -p` against a slash-command shim. In one-shot headless mode the model
# refuses to invoke a tool described as "kill/restart the session", so the
# harness reports 0% recall — see .context/references/testing/00-index.md.
#
# This harness drives a *real* interactive claude session via expect, lets the
# skill execute its actual body, and checks the side effect the skill produces
# (the handoff-flag-<id> marker file). No -p, no shim, no destructive action
# against the test process — we fake the wrapper by only setting
# CLAUDE_HANDOFF_ID, so the skill writes the marker and touches the exit
# trigger, but no watcher is listening and the session stays alive until we
# send /exit.
#
# Eval-set schema (both files in skills/session-handoff/evals/):
#
#   [ { "query": "...", "expect": "execute" | "propose" | "ignore" }, ... ]
#
# `expect` names the behaviour SKILL.md mandates, not merely whether the skill
# is relevant. The earlier boolean `should_trigger` could not express this: it
# scored PASS only when the marker appeared, so the proactive and soft-signal
# queries — where the skill must ask FIRST — were scored FAIL for behaving
# correctly, and PASS only when the model broke the propose-first rule. Roughly
# 30% of the positives were unwinnable, which put a structural ceiling under
# every measurement taken with it.
#
# ---------------------------------------------------------------------------
# ONE RUN OF ONE QUERY IS NOT A MEASUREMENT  (BL-010)
# ---------------------------------------------------------------------------
# Measured 2026-08-05: the same query, four times, same skill, same budget and
# same confirmation string, produced THREE different outcomes (FAIL/PASS/PASS/
# FAIL). Both mechanical explanations were tested and eliminated — the turn-2
# budget (a query passed at 75s and failed at 200s, which a timeout bound
# cannot do) and the bilingual confirmation string (variance persists with a
# plain `sí, hazlo`). The model's behaviour on these sentences is genuinely
# non-deterministic.
#
# That second elimination ruled out BILINGUALITY, not the imperative: `sí, hazlo`
# is itself an instruction to act, so it was never a control for the confound
# BL-021 later found. The variance finding stands; the string does not.
#
# So this harness repeats every query `--reps` times and reports a RATE with a
# per-query breakdown. A query that passes 2 of 3 is printed as intermittent,
# not as a flat verdict, and the summary carries a noise floor that says how
# large a difference has to be before it means anything.
#
# What NOT to do with the non-determinism: never retry until green. A
# retry-until-pass loop converts the variance into a silent pass and destroys
# exactly the signal this repetition exists to expose.
#
# Requires: expect, jq, the session-handoff skill installed in ~/.claude/skills/.
# Usage:    ./tests/eval-pty.sh [--query-limit N] [--timeout SECONDS]
#                               [--eval-set FILE] [--model NAME]
#                               [--reps N] [--jobs N] [--allow-stale]

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_SET="$REPO/skills/session-handoff/evals/trigger-eval.json"
TMP_DIR="${HOME}/.claude/tmp"
PER_QUERY_TIMEOUT=150
QUERY_LIMIT=0  # 0 = no limit
# Where per-unit results land. Empty means a temp dir cleaned on success; set it
# to keep them, which is what you want for a run long enough to be interrupted.
RESULTS_DIR_OVERRIDE=""
MODEL="claude-sonnet-4-6"
# Default >1 on purpose: a single rep is the defect this file was rewritten to
# stop reporting as a measurement.
REPS=3
# Concurrency is what keeps repetition affordable. Arms A and B were run
# concurrently on 2026-08-05 with no interference: CLAUDE_HANDOFF_ID is unique
# per (pid, query, rep), so parallel sessions never share a marker file.
JOBS=3
# Measuring an installed skill that is not this repo's: legitimate, but never by
# accident. See the staleness check below.
ALLOW_STALE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --query-limit) QUERY_LIMIT="$2"; shift 2 ;;
    --timeout)     PER_QUERY_TIMEOUT="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --eval-set)    EVAL_SET="$2"; shift 2 ;;
    --reps)        REPS="$2"; shift 2 ;;
    --results-dir) RESULTS_DIR_OVERRIDE="$2"; shift 2 ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    --allow-stale) ALLOW_STALE=1; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ "$REPS" -ge 1 ] 2>/dev/null || { echo "--reps must be >= 1" >&2; exit 1; }
[ "$JOBS" -ge 1 ] 2>/dev/null || { echo "--jobs must be >= 1" >&2; exit 1; }

command -v expect >/dev/null || { echo "expect not installed"; exit 1; }
command -v jq     >/dev/null || { echo "jq not installed"; exit 1; }
command -v claude >/dev/null || { echo "claude not in PATH"; exit 1; }
[ -f "$EVAL_SET" ] || { echo "eval set not found: $EVAL_SET"; exit 1; }
[ -d "$HOME/.claude/skills/session-handoff" ] \
  || { echo "session-handoff skill not installed at ~/.claude/skills/"; exit 1; }

# --- refuse to measure a stale install ------------------------------------
# This harness scores the skill in ~/.claude/skills, never the repo copy. Edit
# SKILL.md, skip ./install.sh, and the run measures the PREVIOUS policy while
# reporting it as the new one — no error, no warning, a plausible number, and
# an hour spent producing it.
#
# It was a written warning in CLAUDE.md before it was a check, which held right
# up until it didn't: on 2026-08-06 the order had to be remembered by hand twice
# in one session, once while a measurement was already running.
#
# --allow-stale exists for the one legitimate case — deliberately measuring an
# installed variant that is not the repo's. It is a flag rather than silence so
# it shows up in the command line, and therefore in whatever recorded that run.
#
# INSTALLED_SKILL_OVERRIDE is for the test sandbox only, matching install.sh's
# RC_FILE_OVERRIDE / SHELL_NAME_OVERRIDE convention. Do not set it to point the
# check somewhere else in a real run: the spawned claude reads ~/.claude
# regardless, so the check would be comparing against a file nobody loads.
INSTALLED_SKILL="${INSTALLED_SKILL_OVERRIDE:-$HOME/.claude/skills/session-handoff/SKILL.md}"
REPO_SKILL="$REPO/skills/session-handoff/SKILL.md"
if [ "$ALLOW_STALE" = 0 ] && [ -f "$REPO_SKILL" ] && [ -f "$INSTALLED_SKILL" ] \
   && ! cmp -s "$INSTALLED_SKILL" "$REPO_SKILL"; then
  echo "the installed skill differs from this repo's — run ./install.sh first." >&2
  echo "  installed: $INSTALLED_SKILL" >&2
  echo "  repo:      $REPO_SKILL" >&2
  echo "This harness measures the INSTALLED skill, so running now would score the" >&2
  echo "old policy and report it as the new one. Pass --allow-stale if the" >&2
  echo "difference is deliberate." >&2
  exit 1
fi

mkdir -p "$TMP_DIR"

# Settings overlay: pre-approves the bash commands the skill body runs, so we
# don't need to drive the bypassPermissions dialog and can run in default mode.
SETTINGS_OVERLAY=$(mktemp -t eval-pty-settings.XXXXXX.json)
cat > "$SETTINGS_OVERLAY" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(touch:*)",
      "Bash(cat:*)",
      "Bash(printf:*)",
      "Bash(sh:*)",
      "Bash(test:*)",
      "Bash(echo:*)",
      "Write"
    ]
  }
}
JSON

# Per-(query,rep) verdicts land here as one file each, which is also how the
# counters survive concurrency: background jobs cannot write to the parent's
# variables, so the filesystem is the channel.
#
# The report prints only once EVERY unit has completed, so an interrupted run
# used to leave nothing at all: a run killed at 54 of 99 units on 2026-08-06
# produced no output, and its verdicts and fire times had to be scraped out of
# the live process by hand before the trap removed them. Two changes, so that
# cannot repeat: progress.tsv is appended per unit as it finishes, and the
# directory now outlives an abnormal exit.
if [ -n "$RESULTS_DIR_OVERRIDE" ]; then
  RESULT_DIR="$RESULTS_DIR_OVERRIDE"
  mkdir -p "$RESULT_DIR"
  KEEP_RESULTS=1          # the caller named it; it is theirs to delete
else
  RESULT_DIR=$(mktemp -d -t eval-pty-results.XXXXXX)
  KEEP_RESULTS=0
fi
PROGRESS_LOG="$RESULT_DIR/progress.tsv"
COMPLETED=0

cleanup() {
  rm -f "$SETTINGS_OVERLAY"
  if [ "$KEEP_RESULTS" = 1 ]; then
    return
  fi
  if [ "$COMPLETED" = 1 ]; then
    rm -rf "$RESULT_DIR"
  else
    echo "# interrupted before the report — partial results kept in:" >&2
    echo "#   $RESULT_DIR" >&2
    echo "# progress.tsv has one line per completed unit: unit, mode, verdict," >&2
    echo "#   fire turn, fire seconds. Delete the directory when done with it." >&2
  fi
}
trap cleanup EXIT
# Without these, a SIGINT/SIGTERM skips the EXIT trap's message in some shells.
trap 'exit 130' INT
trap 'exit 143' TERM

# Per-query expect runner. Writes a single verdict CODE to $RESULT_FILE.
#
# Key mechanics:
# - --settings overlay pre-approves the skill's bash commands (no permission
#   dialog, no bypassPermissions warning).
# - Enter is sent as the kitty-protocol code "\x1b[13u" because Claude Code
#   runs in CSI-u disambiguated mode where bare "\r" is interpreted as a
#   newline inside the input editor instead of submit.
# - The polling loop uses `expect -timeout 1 -re ".+"` instead of `sleep 1`
#   so the PTY keeps draining — without that the spawned claude blocks on
#   output and never finishes thinking.
#
# Three-way scoring. SKILL.md defines three behaviours, and the marker file
# alone only separates "executed" from "did not". Collapsing that into a
# boolean is what made ~30% of the positives unwinnable: a query the skill
# must PROPOSE on scored FAIL for behaving correctly, and scored PASS only by
# violating the propose-first rule.
#
# `propose` is therefore measured with a second turn rather than by parsing the
# reply. Text parsing is not an option here — the PTY log echoes the query
# itself, so grepping for "handoff" matches the user's own words. Confirming is
# mechanical and uses the same trustworthy signal:
#
#   execute -> the marker must appear on turn 1.
#   ignore  -> the marker must never appear.
#   propose -> the marker must NOT appear on turn 1, and MUST appear after a
#              confirmation. That is exactly SKILL.md's "Only execute after
#              they confirm."
#
# LIVENESS IS MEASURED, NOT ASSUMED. Two markers the expect script writes:
#
#   handoff-alive-<id>  touched once turn 1 has genuinely completed in a
#                       session that reached its prompt.
#   handoff-turn1-<id>  touched iff the skill fired during turn 1.
#
# Without the first, "the skill correctly declined" and "no session was ever
# spawned" are the SAME observation — marker absent — so an `ignore` query
# scores a pass off a harness that did nothing. A set of `ignore` entries would
# then exit 0, fully green, having measured nothing. Any of a typo'd --model,
# an expired token, a changed startup banner or an unbalanced brace in a query
# produces exactly that.
#
# Without the second, `propose` is classified from the ABSENCE of a file, so an
# expect that dies before turn 2 scores `executed-immediately` — a false red
# pointing straight at SKILL.md's propose policy, which someone would then
# "fix". The turn-1 outcome is now recorded positively instead.
#
# Verdict codes, kept distinct because they have different causes and the
# summary must not collapse them (BL-010): `propose` fails in two opposite
# ways, and only `executed-immediately` is a trigger-policy defect.
#
#   ok
#   never-executed            (execute: the skill never fired)
#   executed-unasked          (ignore:  fired on a query it should leave alone)
#   executed-immediately      (propose: skipped the ask — policy defect)
#   no-execute-after-confirm  (propose: held off, then failed to follow through)
#   harness-error             (the session never ran; NEVER counts as a pass)
#
# Known weak spot, no longer hypothetical: a model that ignores a `propose`
# query entirely and then executes on the confirmation scores a false `ok`. It
# cannot produce a false `ok` for the failure this fixes — an immediate un-asked
# execution always fails turn 1.
#
# It was OBSERVED on 2026-08-06 and the confirmation string was the cause. With
# the old `sí, hazlo / yes, go ahead`, BL-020's `[29]` scored 3/3; with a bare
# token, 0/3, nothing else changed. So the imperative was the whole score. The
# string is now a bare `ok` and is pinned by eval-pty-report.sh (BL-021).
#
# Every `propose` number measured before that change is an UPPER BOUND, the
# 2026-08-06 baseline's `propose 5/6` included. Do not compare across it: it is
# not noise, it is a different ruler.
#
# THE TURN-2 CONFIRMATION IS A BARE TOKEN, AND THAT IS LOAD-BEARING. It used to
# be a bilingual string ending in "hazlo" / "go ahead" — an imperative to act,
# which fires the handoff on its own regardless of what turn 1 said. Measured on
# one query with nothing else changed: 3/3 with the imperative, 0/3 with a bare
# token. Pinned by eval-pty-report.sh; read BL-021 before editing it.
#
# Note this lives OUT here, not next to the send. Everything between `<<EXP` and
# `EXP` is expanded by the shell first, so a backtick in a Tcl comment there is
# command substitution — which is exactly how this note, in its first form, ran
# the old confirmation string as a shell command on every unit of a 45-unit run.
run_one() {
  HANDOFF_ID="$1"
  QUERY="$2"
  TIMEOUT="$3"
  MODE="$4"
  RESULT_FILE="$5"
  FLAG_FILE="$TMP_DIR/handoff-flag-$HANDOFF_ID"
  PAYLOAD_FILE="$TMP_DIR/handoff-payload-$HANDOFF_ID"
  EXIT_TRIGGER="$TMP_DIR/handoff-exit-$HANDOFF_ID"
  ALIVE_FILE="$TMP_DIR/handoff-alive-$HANDOFF_ID"
  TURN1_FILE="$TMP_DIR/handoff-turn1-$HANDOFF_ID"
  FIRED_FILE="$TMP_DIR/handoff-fired-$HANDOFF_ID"
  # Turn 1's own words, next to the verdict. Lives in the results dir, not in
  # $TMP_DIR with the markers: it is evidence to read afterwards, not a signal
  # the run consumes, and it must not be swept by the marker cleanup below.
  TURN1_LOG="$RESULT_FILE.turn1"
  # One list, used before and after. Enumerating the markers twice is how one
  # of them survives into the next rep — and reps of a query now run
  # concurrently, which is the contamination the per-rep id exists to stop.
  MARKERS="$FLAG_FILE $PAYLOAD_FILE $EXIT_TRIGGER $ALIVE_FILE $TURN1_FILE $FIRED_FILE"
  rm -f $MARKERS

  CLAUDE_HANDOFF_ID="$HANDOFF_ID" expect <<EXP >"$TURN1_LOG" 2>&1 || true
    set timeout [expr {$TIMEOUT + 30}]
    # log_user 1, not 0, and expect's stdout is redirected to the turn-1
    # transcript by the caller above. The log_file command was tried first and
    # records NOTHING while log_user is 0 — nine 0-byte files, which the stub
    # could never have revealed, because the stub is not expect.
    log_user 1
    spawn -noecho claude --settings $SETTINGS_OVERLAY --model $MODEL
    # Wait for the session to be up before starting the clock, so the measured
    # window is model time and not startup time. A session that never reaches
    # its prompt must NOT fall through and be scored — it exits without
    # touching the liveness marker, which the caller reads as harness-error.
    expect -timeout 60 -re {auto mode|Welcome back|Try "} {} timeout { exit 3 }
    send -- {$QUERY}
    send -- "\x1b\[13u"
    set t1 [clock seconds]
    set deadline [expr {\$t1 + $TIMEOUT}]
    while {[clock seconds] < \$deadline} {
      expect -timeout 1 -re ".+"
      if {[file exists "$FLAG_FILE"]} { break }
    }
    # Record turn 1's outcome POSITIVELY, then declare the run live. Order
    # matters: turn1 before alive means a crash between them still reads as
    # harness-error rather than as a turn-1 miss.
    if {[file exists "$FLAG_FILE"]} {
      exec touch "$TURN1_FILE"
      set fh [open "$FIRED_FILE" w]
      puts \$fh "turn1 [expr {[clock seconds] - \$t1}]"
      close \$fh
    }
    exec touch "$ALIVE_FILE"
    # Stop capturing HERE, so the file holds turn 1 and nothing else. Left on,
    # it would also record the confirmation and whatever followed, and the one
    # question it exists to answer — what did the model do BEFORE being
    # confirmed? — would need the reader to find the seam by eye.
    log_user 0
    # Turn 2, only for propose, and only if turn 1 correctly held off.
    # The confirmation is a bare token on purpose — see the note above run_one.
    if {"$MODE" == "propose" && ![file exists "$FLAG_FILE"]} {
      send -- {ok}
      send -- "\x1b\[13u"
      set t2 [clock seconds]
      set deadline2 [expr {\$t2 + $TIMEOUT}]
      while {[clock seconds] < \$deadline2} {
        expect -timeout 1 -re ".+"
        if {[file exists "$FLAG_FILE"]} { break }
      }
      if {[file exists "$FLAG_FILE"]} {
        set fh [open "$FIRED_FILE" w]
        puts \$fh "turn2 [expr {[clock seconds] - \$t2}]"
        close \$fh
      }
    }
    send -- "/exit"
    send -- "\x1b\[13u"
    expect eof
EXP

  # Classify against the files themselves, then clean up. Carrying each result
  # into a variable first required an inverted `0 = true` convention that made
  # every arm read backwards ("FIRED = 1" meaning it did not fire).
  if [ ! -f "$ALIVE_FILE" ]; then
    # Nothing was measured. This must never resolve to `ok`, and in particular
    # must not resolve to `ok` for `ignore`, whose pass condition is an absence.
    CODE="harness-error"
  else
    case "$MODE" in
      execute) [ -f "$FLAG_FILE" ] && CODE="ok" || CODE="never-executed" ;;
      ignore)  [ -f "$FLAG_FILE" ] && CODE="executed-unasked" || CODE="ok" ;;
      propose) if   [ -f "$TURN1_FILE" ]; then CODE="executed-immediately"
               elif [ -f "$FLAG_FILE" ];  then CODE="ok"
               else CODE="no-execute-after-confirm"; fi ;;
      *)       CODE="unknown-mode" ;;
    esac
  fi
  # Preserve the fire timing before the markers go. Kept in a sidecar rather
  # than appended to $RESULT_FILE, whose whole contents the report `cat`s into
  # a `case` — a second line there would be read as part of the verdict code.
  FIRE_TURN="-"; FIRE_SECS="-"
  if [ -f "$FIRED_FILE" ]; then
    cat "$FIRED_FILE" > "$RESULT_FILE.fire"
    read -r FIRE_TURN FIRE_SECS < "$FIRED_FILE" || true
  fi
  rm -f $MARKERS
  printf '%s\n' "$CODE" > "$RESULT_FILE"
  # Durable record, appended the moment this unit finishes. A single short
  # line opened O_APPEND is written atomically, so concurrent units interleave
  # cleanly rather than tearing.
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(basename "$RESULT_FILE")" "$MODE" "$CODE" "$FIRE_TURN" "$FIRE_SECS" >> "$PROGRESS_LOG"
}

QUERIES=$(jq -c '.[]' "$EVAL_SET")

echo "# eval-pty: session-handoff trigger eval"
echo "# eval-set: $EVAL_SET"
echo "# per-query timeout: ${PER_QUERY_TIMEOUT}s · reps: $REPS · jobs: $JOBS"
echo

# --- schedule every (query, rep) unit, throttled to $JOBS ------------------
# POSIX-only throttling: track launched pids and, once at the cap, block on the
# OLDEST one. `wait -n` would be tidier but is not POSIX and this repo's shell
# scripts are expected to run under dash as well as bash/zsh.
PIDS=""
N=0
BAD=0

while IFS= read -r row; do
  [ -n "$row" ] || continue
  N=$((N + 1))
  if [ "$QUERY_LIMIT" -gt 0 ] && [ "$N" -gt "$QUERY_LIMIT" ]; then break; fi

  MODE=$(printf '%s' "$row"  | jq -r '.expect // empty')
  QUERY=$(printf '%s' "$row" | jq -r '.query // empty')

  case "$MODE" in
    execute|propose|ignore) ;;
    *) printf '[%02d] SKIP :: unusable entry (expect=%s)\n' "$N" "${MODE:-<missing>}"
       BAD=$((BAD + 1)); continue ;;
  esac

  # Remember the plan so the report can be printed in eval-set order after the
  # concurrent phase, rather than in whatever order jobs happen to finish.
  printf '%s\t%s\t%s\n' "$N" "$MODE" "$QUERY" >> "$RESULT_DIR/plan.tsv"

  R=0
  while [ "$R" -lt "$REPS" ]; do
    R=$((R + 1))
    # Unique per (pid, query, rep) — parallel reps of the SAME query would
    # otherwise share one marker file and score each other's runs.
    HANDOFF_ID="eval-$$-$N-$R"
    run_one "$HANDOFF_ID" "$QUERY" "$PER_QUERY_TIMEOUT" "$MODE" \
            "$RESULT_DIR/q$N.r$R" &
    PIDS="$PIDS $!"

    # `set --` gives the count in $# for free; the previous form forked a
    # subshell per scheduled unit to compute what the next line already had.
    set -- $PIDS
    if [ $# -ge "$JOBS" ]; then
      OLDEST=$1; shift
      wait "$OLDEST" 2>/dev/null || true
      PIDS="$*"
    fi
  done
done <<QUERY_ROWS
$QUERIES
QUERY_ROWS

# Drain the tail.
for P in $PIDS; do wait "$P" 2>/dev/null || true; done

# --- report ---------------------------------------------------------------
TOTAL=0; HITS=0
H_execute=0; T_execute=0
H_propose=0; T_propose=0
H_ignore=0;  T_ignore=0
C_never=0; C_unasked=0; C_immediate=0; C_noconfirm=0; C_harness=0
INTERMITTENT=0
FLAT_FAIL=0

[ -f "$RESULT_DIR/plan.tsv" ] || { echo "# nothing ran"; exit 1; }

while IFS="$(printf '\t')" read -r QN QMODE QTEXT; do
  [ -n "$QN" ] || continue
  PASSES=0
  CODES=""
  R=0
  while [ "$R" -lt "$REPS" ]; do
    R=$((R + 1))
    F="$RESULT_DIR/q$QN.r$R"
    CODE=$([ -f "$F" ] && cat "$F" || echo "no-result")
    case "$CODE" in
      ok)                       PASSES=$((PASSES + 1)) ;;
      never-executed)           C_never=$((C_never + 1)) ;;
      executed-unasked)         C_unasked=$((C_unasked + 1)) ;;
      executed-immediately)     C_immediate=$((C_immediate + 1)) ;;
      no-execute-after-confirm) C_noconfirm=$((C_noconfirm + 1)) ;;
      harness-error|no-result)  C_harness=$((C_harness + 1)) ;;
      *) C_harness=$((C_harness + 1))
         echo "# !! unrecognised verdict code '$CODE' — counted as a harness error" ;;
    esac
    [ "$CODE" = "ok" ] || CODES="$CODES $CODE"
  done

  PREVIEW=$(printf '%s' "$QTEXT" | cut -c1-52)
  if [ "$PASSES" -eq "$REPS" ]; then
    MARK="    "
  elif [ "$PASSES" -eq 0 ]; then
    MARK="FAIL"; FLAT_FAIL=$((FLAT_FAIL + 1))
  else
    # The state this rewrite exists to make visible: neither pass nor fail.
    MARK="FLAKY"; INTERMITTENT=$((INTERMITTENT + 1))
  fi
  UNIQ=$(printf '%s' "$CODES" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
  printf '[%02d] %-7s %-5s %d/%d :: %s%s\n' \
    "$QN" "$QMODE" "$MARK" "$PASSES" "$REPS" "$PREVIEW" \
    "$([ -n "$UNIQ" ] && printf '  <%s>' "$UNIQ")"

  HITS=$((HITS + PASSES))
  TOTAL=$((TOTAL + REPS))
  eval "H_$QMODE=\$((H_$QMODE + PASSES))"
  eval "T_$QMODE=\$((T_$QMODE + REPS))"
done < "$RESULT_DIR/plan.tsv"

echo
echo "# execute : $H_execute / $T_execute"
echo "# propose : $H_propose / $T_propose"
echo "# ignore  : $H_ignore / $T_ignore"
echo "# result  : $HITS / $TOTAL  (across $REPS reps)"
echo
echo "# failure modes (a propose query fails in two opposite ways; only the"
echo "#   'executed immediately' one is a trigger-policy defect):"
echo "#   never executed             : $C_never"
echo "#   executed unasked (ignore)  : $C_unasked"
echo "#   executed immediately       : $C_immediate"
echo "#   no execute after confirm   : $C_noconfirm"
echo "#   HARNESS ERROR (not measured): $C_harness"
echo

# --- observed fire times (BL-014 step 1) -----------------------------------
# The absence arms cannot exit their poll loop early: for every `ignore` query
# and for `propose` turn 1 the pass condition IS the flag never appearing, so
# each burns the full timeout after the model went quiet ~20s in. That is most
# of the run's wall clock.
#
# The fix is NOT an idle break. Breaking on N seconds of PTY silence is safe
# where an early break can only produce a loud false FAIL; on an absence arm it
# scores `ok` for a query that was about to fire — a silent false pass, the
# class the liveness marker exists to close.
#
# So the deadline gets shortened from data instead: this records how long a
# REAL fire took, on runs already being paid for. BL-014 step 2 sets the
# absence-arm deadline to max(observed) x margin, which is then justified
# rather than guessed. A max at or near $PER_QUERY_TIMEOUT means some fire was
# still in flight at the deadline — do not shorten anything on that run.
FIRE_N=0; FIRE_MAX=0; FIRE_T1_MAX=0; FIRE_T2_MAX=0
for FF in "$RESULT_DIR"/*.fire; do
  [ -f "$FF" ] || continue
  read -r FTURN FSECS < "$FF" || continue
  case "$FSECS" in ''|*[!0-9]*) continue ;; esac
  FIRE_N=$((FIRE_N + 1))
  [ "$FSECS" -gt "$FIRE_MAX" ] && FIRE_MAX=$FSECS
  case "$FTURN" in
    turn1) [ "$FSECS" -gt "$FIRE_T1_MAX" ] && FIRE_T1_MAX=$FSECS ;;
    turn2) [ "$FSECS" -gt "$FIRE_T2_MAX" ] && FIRE_T2_MAX=$FSECS ;;
  esac
done

if [ "$FIRE_N" -eq 0 ]; then
  echo "# observed fire times: none — no rep produced the flag, so this run"
  echo "#   bounds nothing. Do not shorten the absence-arm deadline from it."
else
  echo "# observed fire times (n=$FIRE_N of $TOTAL units): turn1 max ${FIRE_T1_MAX}s · turn2 max ${FIRE_T2_MAX}s · overall max ${FIRE_MAX}s"
  echo "#   absence arms each burned the full ${PER_QUERY_TIMEOUT}s. BL-014 step 2: set their"
  echo "#   deadline from this max x margin — not from an idle break, which false-passes them."
fi
echo
# --- the reportability rule ------------------------------------------------
# Each intermittent query is, by demonstration, capable of landing on a
# different count next run. So the summary can move by at least that many
# passes with nothing having changed. Any delta inside this band is noise, and
# reporting it as an effect is the defect BL-010 was filed for.
if [ "$C_harness" -gt 0 ]; then
  echo "# !! $C_harness rep(s) never ran a session. Those are NOT results — the numbers"
  echo "#    above are measured over fewer reps than requested. Fix the harness first."
  echo
fi
echo "# intermittent queries: $INTERMITTENT  ·  consistently failing: $FLAT_FAIL"
echo "# NOISE FLOOR: +/- $INTERMITTENT passes out of $TOTAL."
echo "#   A before/after difference of $INTERMITTENT passes or fewer is NOT reportable"
echo "#   as an effect — it is within what this run reproduced by doing nothing."
echo "#   Raise --reps to narrow the floor; never retry a query until it passes."
echo "#   The floor is a LOWER bound OBSERVED here, not a predicted one: an"
echo "#   unstable query that happens to pass every rep contributes 0 to it."
if [ "$REPS" -lt 3 ]; then
  echo "#   CAUTION: --reps $REPS cannot separate a stable query from a lucky one."
  echo "#   Observed 2026-08-06 at --reps 2: the same 3-query set scored 6/6 with a"
  echo "#   floor of 0, then 5/6 with a floor of 1, back to back and unchanged."
fi
[ "$BAD" -eq 0 ] || echo "# WARNING: $BAD entries skipped as unusable"

# The report is out, so the results directory has served its purpose and the
# EXIT trap may clean it.
COMPLETED=1

# Green means every rep of every query passed. Intermittency is a failure of
# the skill or of the harness, never a pass.
[ "$TOTAL" -gt 0 ] && [ "$BAD" -eq 0 ] && [ "$HITS" -eq "$TOTAL" ]
