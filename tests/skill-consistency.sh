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
# when_to_use: a YAML block scalar — everything indented under the key, up to
# the next top-level key or the closing front-matter fence. Only the budget
# check reads it now; nothing cross-checks its prose against the body.
WTU=$(awk '
  /^when_to_use:/ { inblock = 1; next }
  inblock && (/^[a-zA-Z_-]+:/ || /^---[[:space:]]*$/) { inblock = 0 }
  inblock { print }
' "$SKILL")

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
DESC=$(sed -n 's/^description:[[:space:]]*//p' "$SKILL" | head -1)
WTU_TEXT=$(printf '%s\n' "$WTU" | sed 's/^[[:space:]]*//')
LISTING_LEN=$(printf '%s%s' "$DESC" "$WTU_TEXT" | wc -m | tr -d '[:space:]')

if [ "$LISTING_LEN" -le "$BUDGET" ]; then
  ok "description + when_to_use is $LISTING_LEN chars (budget $BUDGET, observed cut ~1535)"
else
  no "description + when_to_use is $LISTING_LEN chars, over the $BUDGET budget — the listing truncates tail-first and the 'Do NOT use' exclusions are what falls off"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
