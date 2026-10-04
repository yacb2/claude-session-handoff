#!/bin/sh
# BL-041: the trigger miner must count a model-fired handoff through the installed
# fire script as `executed`; the old copies wrote handoff-payload-/flag- inline,
# which is what FIRED matched. Layer: unit of classify() on a fixture transcript.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(REPO="$REPO" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("m", os.environ["REPO"] + "/scripts/mine-handoff-triggers.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cmd = "sh \"$HOME/.claude/scripts/handoff-fire.sh\" <<'__HANDOFF_EOF__'\nbrief\n__HANDOFF_EOF__"
rows = [
  {"type": "user", "message": {"content": "haz handoff"}},
  {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}},
]
print(m.classify(rows, 0)[0])
PY
)
if [ "$OUT" = executed ]; then echo "ok   - miner: a handoff-fire.sh call classifies as executed"; echo; echo "1 passed, 0 failed"; exit 0; fi
echo "FAIL - miner classified the fire-script call as [$OUT]"; echo; echo "0 passed, 1 failed"; exit 1
