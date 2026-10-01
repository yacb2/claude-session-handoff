#!/bin/sh
# Regression test: terminals that start at the same moment must not attach to the same
# session through `claude-attach.sh -f`.
#
# 2026-10-01: Zed reopened a window with two saved terminals; both ran the zshrc hook, both
# listed the same free session before either client showed as attached, and both attached
# to it. A fake `abduco` on PATH marks a session attached 0.3 s after `-a`, like the real one.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-attach.sh"
PASS=0
FAIL=0
ok()      { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no()      { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; }

[ -f "$SCRIPT" ] || { echo "script not found: $SCRIPT"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"
mkdir -p "$BIN" "$SANDBOX/.claude/tmp"
: > "$SANDBOX/attached"

cat > "$BIN/abduco" <<EOF
#!/bin/sh
if [ "\$1" = -a ]; then
  echo "\$2" >> "$SANDBOX/attach.log"
  sleep 0.3; echo "\$2" >> "$SANDBOX/attached"; sleep 1; exit 0
fi
echo "Active sessions (on host test)"
for n in claude-proj-100000-aaaa1111 claude-proj-100001-bbbb2222; do
  if grep -qx "\$n" "$SANDBOX/attached"; then echo "* Thu	 2026-10-01 10:00:00	\$n"
  else echo "  Thu	 2026-10-01 10:00:00	\$n"; fi
done
EOF
chmod +x "$BIN/abduco"

run() { env HOME="$SANDBOX" PATH="$BIN:/usr/bin:/bin" sh "$SCRIPT" -f proj >/dev/null 2>&1; }
run & run & wait

n=$(sort "$SANDBOX/attach.log" | uniq | wc -l | tr -d ' ')
t=$(wc -l < "$SANDBOX/attach.log" | tr -d ' ')
[ "$t" -eq 2 ] && ok "both terminals attached" || no "$t attaches for 2 terminals"
[ "$n" -eq 2 ] && ok "each terminal got its own session" || no "same session attached twice: $(tr '\n' ' ' < "$SANDBOX/attach.log")"

summary
[ "$FAIL" -eq 0 ]
