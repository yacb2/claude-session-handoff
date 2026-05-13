#!/bin/sh
# Run the skill-creator trigger eval against the session-handoff skill, but
# temporarily move the installed skill aside so the harness's slash-command
# shim isn't shadowed by the real skill. Restores on exit (or any signal).
#
# Background: skill-creator's run_eval.py creates a one-off slash command in
# the project's .claude/commands/ with the candidate description, then runs
# `claude -p <query>` and watches the stream for invocations of that shim.
# If the real skill is also installed under ~/.claude/skills/session-handoff/,
# Claude prefers the real one (it has the full SKILL.md body) and the harness
# misses the trigger — reporting 0% recall even when the description is good.
#
# This wrapper hides the real skill for the duration of the test.
#
# Usage:
#   ./tests/eval-trigger.sh                          # uses SKILL.md description
#   ./tests/eval-trigger.sh --description "..."      # tests a candidate
#   DESCRIPTION_FILE=path ./tests/eval-trigger.sh    # description from file

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$HOME/.claude/skills/session-handoff"
BACKUP_DIR="$HOME/.claude/skills/.session-handoff.eval-backup"
SKILL_CREATOR="$HOME/.claude/plugins/cache/claude-plugins-official/skill-creator/unknown/skills/skill-creator"
EVAL_SET="$REPO/skills/session-handoff/evals/trigger-eval.json"

[ -d "$SKILL_CREATOR" ] || { echo "skill-creator plugin not found at $SKILL_CREATOR"; exit 1; }
[ -f "$EVAL_SET" ]      || { echo "eval set not found at $EVAL_SET"; exit 1; }

restore_skill() {
  if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$SKILL_DIR"
    mv "$BACKUP_DIR" "$SKILL_DIR"
    echo "[eval-trigger] Restored real skill at $SKILL_DIR" >&2
  fi
}
trap restore_skill EXIT INT TERM

if [ -d "$SKILL_DIR" ]; then
  if [ -e "$BACKUP_DIR" ]; then
    echo "[eval-trigger] Stale backup at $BACKUP_DIR — refusing to clobber. Remove it manually if you know it's stale." >&2
    exit 1
  fi
  mv "$SKILL_DIR" "$BACKUP_DIR"
  echo "[eval-trigger] Hid real skill (-> $BACKUP_DIR) for the duration of the eval" >&2
fi

# Build args for run_eval. Either --description "..." passed by caller, or
# the description from the repo's SKILL.md (default behavior of run_eval).
EXTRA_ARGS=""
if [ -n "$DESCRIPTION_FILE" ] && [ -f "$DESCRIPTION_FILE" ]; then
  DESC=$(cat "$DESCRIPTION_FILE")
  EXTRA_ARGS="--description"
  set -- "$@" "$EXTRA_ARGS" "$DESC"
fi

cd "$SKILL_CREATOR"
python -m scripts.run_eval \
  --eval-set "$EVAL_SET" \
  --skill-path "$REPO/skills/session-handoff" \
  --model claude-opus-4-7 \
  "$@"
