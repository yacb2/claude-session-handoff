#!/bin/sh
# Drift guard for skills/session-handoff/SKILL.md.
#
# The two front-matter fields Claude Code always loads (`description` +
# `when_to_use`) answer "should I surface this skill?". The body's "When to use
# this skill" section answers "execute or propose?". They are different
# questions with different consumers, and since BL-005 the trigger policy lives
# in the body ALONE — the front-matter routes and defers.
#
# So the drift this file used to guard (the same policy written twice, edited
# once) no longer exists to guard: the earlier when_to_use/body cross-checks
# were removed with the duplication itself. What replaced them is the failure
# that duplication was hiding — the combined listing outgrew its budget and was
# truncated tail-first, silently dropping the `Do NOT use` exclusions.
#
# Design note: the case registry below is a second copy of the body's case
# list, which is a real cost. It buys the one property the body cannot give
# itself — adding a case without registering it here FAILS on the count check,
# so the registry cannot silently fall behind.
set -u

SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/session-handoff/SKILL.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

[ -f "$SKILL" ] || { echo "SKILL.md not found: $SKILL"; exit 1; }

# --- case registry --------------------------------------------------------
# id | regex that must appear in the body
# Keep in sync when adding a trigger case; the count check below enforces it.
CASES='direct|\*\*Direct trigger
proactive|\*\*Proactive trigger
soft|\*\*Soft signal
tiebreak|\*\*Tie-break
mandated|\*\*Mandated by a running process
donot|\*\*Do NOT use\*\*'

# --- extract the two regions ----------------------------------------------
# field_of FILE KEY — the value of a front-matter key, whether it is written
# as an inline scalar (`key: text`) or as a block scalar (`key: |` + indented
# lines). Both spellings are legal YAML and mean the same thing to Claude Code,
# so a check that only understands one of them is not a check.
#
# That is not hypothetical. An earlier version read `description` with
# `sed -n 's/^description:[[:space:]]*//p'`, which returns the bare `|` when the
# field is a block scalar. Reformatting `description` to block style and adding
# ~640 chars moved the REAL listing to 1878 chars — past the ~1535 cut — while
# this guard reported 914 and passed. The budget check silently measured
# nothing, which is the exact failure it exists to prevent.
field_of() {
  awk -v key="$2" '
    index($0, key ":") == 1 {
      inblock = 1
      line = $0
      sub("^" key ":[[:space:]]*", "", line)
      # `|`, `>`, `|-`, `>-` are block indicators, not content.
      if (line != "" && line !~ /^[|>][-+]?[0-9]*$/) print line
      next
    }
    inblock && (/^[a-zA-Z_-]+:/ || /^---[[:space:]]*$/) { inblock = 0 }
    inblock { print }
  ' "$1"
}

WTU=$(field_of "$SKILL" when_to_use)

# body: the "## When to use this skill" section, up to the next H2.
BODY=$(awk '
  /^## When to use this skill/ { insec = 1; next }
  insec && /^## / { insec = 0 }
  insec { print }
' "$SKILL")

[ -n "$WTU" ]  || no "could not extract when_to_use front-matter block"
[ -n "$BODY" ] || no "could not extract body 'When to use this skill' section"

# --- 1. every registered case is declared in the body ---------------------
# Fed by a here-doc, not a pipe: a `printf | while` loop body runs in a SUBSHELL
# in POSIX sh, so MISSING would be discarded at the `done`.
MISSING=""
REG_COUNT=0
while IFS='|' read -r ID BODY_RE; do
  [ -n "$ID" ] || continue
  # Derived here rather than by re-scanning $CASES afterwards, so the count
  # describes exactly the cases this loop checked. A separate `grep -c '|'`
  # would also count a malformed line that `[ -n "$ID" ]` skips.
  REG_COUNT=$((REG_COUNT + 1))
  printf '%s' "$BODY" | grep -qE "$BODY_RE" && continue
  # No spaces in the accumulated ids: the report below word-splits deliberately
  # to get one line per case.
  MISSING="$MISSING $ID"
done <<EOF
$CASES
EOF

if [ -z "$MISSING" ]; then
  ok "all $REG_COUNT registered trigger cases are declared in the body"
else
  no "registered cases missing from the body:$(printf '\n    - %s' $MISSING)"
fi

# --- 2. the body declares no case the registry doesn't know about ---------
# Counts bold case labels at line start inside the section. If someone adds a
# case to the body, this fails until the registry covers it.
BODY_COUNT=$(printf '%s\n' "$BODY" | grep -cE '^\*\*')

if [ "$BODY_COUNT" = "$REG_COUNT" ]; then
  ok "body declares exactly $BODY_COUNT cases, matching the registry"
else
  no "body declares $BODY_COUNT bold case labels but the registry has $REG_COUNT — register the new case"
fi

# --- 3. the combined listing stays under the truncation budget ------------
# `description` + `when_to_use` are concatenated into the always-loaded skill
# listing, and that listing is truncated TAIL-FIRST once it gets too long.
# Measured 2026-08-05 from a live session's own listing: the entry was cut
# mid-word ("...or wiping th…") at ~1535 chars, severing the `Do NOT use`
# exclusions — the one description-level lever BL-002 records as having a
# measured effect. Whether that limit is a budget or a renderer cap does not
# change the fix; the observed effect is what this guards.
#
# The threshold sits below the observed cut on purpose: the listing adds a
# separator and scaffolding around these two fields that we cannot pin from
# here, and the margin absorbs it.
#
# `wc -m` counts characters under a UTF-8 locale and bytes under LC_ALL=C.
# Either result is >= the true character count, so this check can never let an
# over-budget front-matter pass — at worst it over-reports.
BUDGET=1450
DESC=$(field_of "$SKILL" description)

# Both fields must be non-empty. An extractor that silently returns nothing
# measures 0 chars and passes any budget — a vacuous guard is worse than none,
# because it reports success.
if [ -z "$DESC" ]; then
  no "could not extract the description field"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

measure() { printf '%s%s' "$1" "$(printf '%s\n' "$2" | sed 's/^[[:space:]]*//')" | wc -m | tr -d '[:space:]'; }
LISTING_LEN=$(measure "$DESC" "$WTU")

if [ "$LISTING_LEN" -le "$BUDGET" ]; then
  ok "description + when_to_use is $LISTING_LEN chars (budget $BUDGET, observed cut ~1535)"
else
  no "description + when_to_use is $LISTING_LEN chars, over the $BUDGET budget — the listing truncates tail-first and the 'Do NOT use' exclusions are what falls off"
fi

# --- 4. the extractor survives a block-scalar reformat --------------------
# Check 3 is only as good as field_of. This runs it against a fixture whose
# `description` is block-style and whose true length is known, so a regression
# to a line-oriented extractor fails here instead of silently passing check 3.
FIXTURE="${TMPDIR:-/tmp}/skill-consistency-fixture.$$.md"
PAD=$(i=0; while [ $i -lt 40 ]; do printf 'padding '; i=$((i+1)); done)
{
  printf -- '---\n'
  printf 'name: fixture\n'
  printf 'description: |\n  %s\n' "$PAD"
  printf 'when_to_use: |\n  %s\n' "$PAD"
  printf -- '---\n'
} > "$FIXTURE"
# 40 * 8 chars = 320 per field, both block scalars.
FIX_LEN=$(measure "$(field_of "$FIXTURE" description)" "$(field_of "$FIXTURE" when_to_use)")
rm -f "$FIXTURE"

if [ "$FIX_LEN" -ge 600 ]; then
  ok "field_of reads block-scalar fields (fixture measured $FIX_LEN chars)"
else
  no "field_of collapsed a block-scalar field: fixture measured $FIX_LEN chars, expected ~640 — the budget check would silently measure nothing"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
