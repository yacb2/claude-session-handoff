#!/bin/sh
# Drift guard for skills/session-handoff/SKILL.md.
#
# The trigger policy is written twice: once in the `when_to_use` front-matter
# (what Claude Code reads when deciding whether to surface the skill) and again
# in the body's "When to use this skill" section (what the model reads once it
# has). They agree today; nothing checked that they keep agreeing.
#
# That is not a theoretical risk. BL-001 — the missing "mandated by a running
# process" case — requires editing BOTH copies. A fix applied to one leaves the
# skill self-contradicting in exactly the way that produced BL-001's symptom.
#
# Design note: the case registry below is a third copy, which is a real cost.
# It buys the one property the other two cannot give each other — adding a case
# to the body without registering it here FAILS on the count check, so the
# registry cannot silently fall behind. A guard that can be bypassed by
# forgetting it is not a guard.
set -u

SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/session-handoff/SKILL.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

[ -f "$SKILL" ] || { echo "SKILL.md not found: $SKILL"; exit 1; }

# --- case registry --------------------------------------------------------
# id | regex that must appear in when_to_use | regex that must appear in body
# Keep in sync when adding a trigger case; the count check below enforces it.
CASES='direct|asks to hand off|\*\*Direct trigger
proactive|suggest proactively|\*\*Proactive trigger
soft|idiomatic signals|\*\*Soft signal
mandated|mandated by a running process|\*\*Mandated by a running process
donot|Do NOT use|\*\*Do NOT use\*\*'

# --- extract the two copies ----------------------------------------------
# when_to_use: a YAML block scalar — everything indented under the key, up to
# the next top-level key or the closing front-matter fence.
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

# --- 1. every registered case appears on both sides -----------------------
MISSING=""
printf '%s\n' "$CASES" | while IFS='|' read -r ID WTU_RE BODY_RE; do
  [ -n "$ID" ] || continue
  W=0; B=0
  printf '%s' "$WTU"  | grep -qE "$WTU_RE"  || W=1
  printf '%s' "$BODY" | grep -qE "$BODY_RE" || B=1
  [ "$W" = 0 ] && [ "$B" = 0 ] && continue
  # No spaces in WHERE: the report below word-splits deliberately to get one
  # line per case, so a space here would split a single case across lines.
  WHERE=""
  [ "$W" = 1 ] && WHERE="when_to_use"
  [ "$B" = 1 ] && WHERE="${WHERE:+$WHERE+}body"
  echo "$ID:$WHERE" >> "${TMPDIR:-/tmp}/skill-drift-$$"
done

if [ -f "${TMPDIR:-/tmp}/skill-drift-$$" ]; then
  MISSING=$(cat "${TMPDIR:-/tmp}/skill-drift-$$")
  rm -f "${TMPDIR:-/tmp}/skill-drift-$$"
fi

REG_COUNT=$(printf '%s\n' "$CASES" | grep -c '|')

if [ -z "$MISSING" ]; then
  ok "all $REG_COUNT trigger cases present in BOTH when_to_use and body"
else
  no "trigger cases missing from one copy (drift):$(printf '\n    - %s' $MISSING)"
fi

# --- 2. the body declares no case the registry doesn't know about ---------
# Counts bold case labels at line start inside the section. If someone adds a
# fifth case to the body, this fails until the registry (and therefore the
# when_to_use check) covers it.
BODY_COUNT=$(printf '%s\n' "$BODY" | grep -cE '^\*\*')

if [ "$BODY_COUNT" = "$REG_COUNT" ]; then
  ok "body declares exactly $BODY_COUNT cases, matching the registry"
else
  no "body declares $BODY_COUNT bold case labels but the registry has $REG_COUNT — register the new case (and add it to when_to_use)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
