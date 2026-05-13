---
name: session-handoff
description: Hand off the current Claude Code session to a fresh new one with the current context seeded as a handoff prompt. Use when the user wants to keep working in a clean session without losing the plan — faster and cheaper than /compact since it opens a new process with hooks, skills, MCP, and the Claude Code binary reloaded.
when_to_use: |
  Use when the user asks to hand off the session, start a fresh session that keeps the current context, restart while preserving what we're working on, or continue with the next phase of a plan in a clean session. Also suggest proactively when the user runs /compact on a long conversation, wants to reload hooks/skills/MCP servers mid-session, or hits compaction errors.
  Do NOT use for /clear or wiping the conversation, for short conversations where /compact is enough, for restarting unrelated things like the dev server or docker, for delegating a task to a subagent, or for questions about what /compact or /clear actually do.
---

# Session Handoff

This skill closes the current Claude Code session and opens a new one with a handoff prompt injected as initial context via the `SessionStart` hook.

## When to use this skill

**Direct trigger** — the user explicitly asks for a handoff:
- "do a handoff" / "hand off" / "hand off this session"
- "haz handoff" / "haz un handoff" / "inicia sesión nueva con contexto"
- "start a new session with context" / "restart preserving context"
- "transfiere el contexto" / "sigamos en limpio" / "estamos largos, sesión nueva"
- "reinicia preservando contexto"

**Proactive trigger** — suggest `/handoff` (or this skill) instead of `/compact` when:
- The user runs or mentions `/compact` and the conversation is large (>50% context used).
- Compaction errors appear in long sessions.
- The user wants to reload hooks, skills, MCP servers, or pick up a new Claude Code binary version.
- The user says "start fresh but don't lose the plan" / "empezar de cero pero sin perder el plan".

**Do NOT use** when:
- The user only wants `/clear` (no context preserved).
- The conversation is short and `/compact` is enough.
- The user wants to keep responding in the same session without restarting.

## Why handoff vs. /compact

| | /compact | /handoff |
|---|---|---|
| Tokens | Processes the entire conversation to summarize | Only the current turn that produces the prompt |
| Time | Slow on large sessions, can fail | Near-instant |
| Process | Same process — stale hooks, stale binary | Fresh process: hooks, skills, MCP, binary up to date |
| Residual context | Summary + new turns accumulate | Zero — starts clean with only the seeded prompt |

When the user just needs to "keep working in a clean session", handoff wins on cost and speed.

## How to execute the handoff

### Step 1 — draft the handoff prompt

Use this minimal structure. **Every sentence must be information the next session cannot derive from reading the code or `CLAUDE.md`.**

```
## Current goal
<one sentence>

## State
<files touched, what's done, what's left>

## Decisions taken
<only the non-obvious ones — agreed conventions, rejected tradeoffs>

## Next concrete step
<single, actionable>

## Constraints / gotchas
<what the next session would trample if it didn't know>
```

Drafting rules:
- Be terse. Skip any section that adds nothing.
- Zero filler, zero obvious explanations.
- If the user already provided a prompt, use it as-is — do not rewrite it.

### Step 2 — execute

Check `$CLAUDE_HANDOFF_ID`. If it is not set, the wrapper is not running — tell the user and stop.

With the payload ready, run via Bash:

```sh
mkdir -p "$HOME/.claude/tmp"
PAYLOAD_FILE="$HOME/.claude/tmp/handoff-payload-$CLAUDE_HANDOFF_ID"
FLAG_FILE="$HOME/.claude/tmp/handoff-flag-$CLAUDE_HANDOFF_ID"

cat > "$PAYLOAD_FILE" <<'__HANDOFF_PAYLOAD_EOF__'
<THE HANDOFF PROMPT HERE>
__HANDOFF_PAYLOAD_EOF__

touch "$FLAG_FILE"
kill -TERM $PPID
```

After `kill -TERM`, do not emit any more output — the wrapper will close this process and launch the new session.

### Step 3 — zero-token alternative

If the user already has the prompt drafted and wants to fire the handoff without spending tokens on this turn, suggest they type directly:

```
handoff: <their prompt here>
```

The `UserPromptSubmit` hook intercepts it and runs the handoff without going through the model.
