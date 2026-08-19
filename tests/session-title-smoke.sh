#!/bin/sh
# Does Claude Code still honour `sessionTitle` from a SessionStart hook?
#
# This is the one seam no other suite reaches. `hook-guard.sh` drives both hooks
# directly and asserts on the title file and the chain record — everything up to
# the moment we hand JSON to the binary. What happens next is the binary's
# behaviour, and it is not ours to assume: `sessionTitle` was recorded as a
# silent no-op on 2.1.221, 2.1.223 and 2.1.224, then re-probed working on
# 2.1.235. It flipped once without a line of our code changing. It can flip back
# the same way, and every hook-guard case would stay green while the feature
# quietly stopped existing.
#
# Deliberately NOT an eval, and the distinction is not pedantic. The title is
# written by a hook and compared byte-for-byte, so the measurement is
# deterministic: one run is a result, and BL-010's noise-floor rule — which
# governs the model-scored trigger evals — does not apply here and must not be
# inherited by association. There is nothing to average.
#
# It also does not test our hooks. It registers a throwaway hook of its own that
# emits one known string, so a failure means the binary changed, not that
# handoff-session-start.sh regressed. Keeping those two apart is the entire
# value: this file answers "is the mechanism still there?", hook-guard answers
# "do we use it correctly?".
#
# Costs one short model call. Run it after a Claude Code version bump.
set -u

command -v claude >/dev/null || { echo "claude not in PATH"; exit 1; }
command -v jq >/dev/null     || { echo "jq not in PATH"; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

printf 'claude %s\n\n' "$(claude --version 2>/dev/null || echo '(version unknown)')"

# Unique per run, so a transcript left over from an earlier run can never be
# mistaken for this one's result. That is what lets a single run stand as proof.
NONCE="handoff-title-smoke-$$-$(date +%s)"

WORK=$(mktemp -d)
mkdir -p "$WORK/cwd"

cat > "$WORK/title-hook.sh" <<HOOKEOF
#!/bin/sh
# Claude Code pipes the event JSON and closes; drain it so nothing blocks.
[ -t 0 ] || cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","sessionTitle":"$NONCE"}}'
HOOKEOF
chmod +x "$WORK/title-hook.sh"

# An overlay, not a replacement: it adds this hook to whatever the user already
# has. The installed handoff SessionStart hook fires too and emits no title
# (no title file for this wrapper), which is the correct no-op.
cat > "$WORK/settings.json" <<SETEOF
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"$WORK/title-hook.sh"}]}]}}
SETEOF

# Find the transcript by the session id claude reports, not by deriving the
# per-project directory name from the cwd. That derivation is a guess about an
# undocumented mangling — and on macOS it is wrong before it even gets there,
# because mktemp hands back /var/folders/... while Claude Code resolves the
# physical /private/var/folders/... . A test that cannot find the transcript
# reports "no transcript" and reads as a broken feature.
TRANSCRIPT=""
cleanup() {
  rm -rf "$WORK"
  [ -n "$TRANSCRIPT" ] && rm -f "$TRANSCRIPT"
  # Only if this run's session was the only thing in there.
  [ -n "$TRANSCRIPT" ] && rmdir "${TRANSCRIPT%/*}" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

( cd "$WORK/cwd" && claude -p --output-format json \
    --settings "$WORK/settings.json" 'Responde solo: ok' ) \
  >"$WORK/stdout" 2>"$WORK/stderr"
RC=$?

# Assert the run happened before asserting anything about titles. Without this a
# claude that failed to start would produce no transcript, no custom-title, and
# a failure message pointing at the wrong thing entirely.
if [ "$RC" -eq 0 ]; then
  ok "claude -p completed (rc=0)"
else
  no "claude -p failed rc=$RC — $(head -3 "$WORK/stderr" 2>/dev/null | tr '\n' ' ')"
fi

SESSION_ID=$(jq -r '.session_id // empty' "$WORK/stdout" 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
  TRANSCRIPT=$(ls "$HOME/.claude/projects"/*/"$SESSION_ID.jsonl" 2>/dev/null | head -1)
fi
if [ -n "$TRANSCRIPT" ] && [ -s "$TRANSCRIPT" ]; then
  ok "a transcript was written for session $SESSION_ID"
else
  no "no transcript for session [$SESSION_ID] — nothing to assert against"
fi

if [ -n "$TRANSCRIPT" ] && [ -s "$TRANSCRIPT" ]; then
  TITLE=$(jq -r 'select(.type == "custom-title") | .customTitle // empty' \
    "$TRANSCRIPT" 2>/dev/null | tail -1)
  if [ "$TITLE" = "$NONCE" ]; then
    ok "SessionStart sessionTitle reached the transcript as custom-title"
  else
    no "custom-title is [$TITLE], expected [$NONCE] — sessionTitle is a no-op on this version, and the handoff chain is titling nothing"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
