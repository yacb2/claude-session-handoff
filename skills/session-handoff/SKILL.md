---
name: session-handoff
description: Hand off the current Claude Code session to a fresh new one with the current context seeded as a handoff prompt. Use when the user wants to keep working in a clean session without losing the plan — faster and cheaper than /compact since it opens a new process with hooks, skills, MCP, and the Claude Code binary reloaded.
when_to_use: |
  Use when the user asks to hand off the session, start a fresh session that keeps the current context, restart while preserving what we're working on, or continue with the next phase of a plan in a clean session. Also suggest proactively when the user runs /compact on a long conversation, wants to reload hooks/skills/MCP servers mid-session, or hits compaction errors.
  When the user drops idiomatic signals that a fresh session would help — "this chat is getting unwieldy", "we need a fresh start", "I think we should start over", "let's wrap this up and continue in a new chat" — do not execute the handoff directly. Propose it, summarize what would be seeded, and confirm before running.
  The one exception is a handoff mandated by a running process rather than requested by a person: when an unattended run (plan execution, audit, loop) reaches its own handoff step, execute it without asking. Stopping to ask is the interruption such a run exists to avoid. This applies only while a run is in flight; in ordinary conversation the propose-first rule above stands unchanged.
  Do NOT use for /clear or wiping the conversation, for short conversations where /compact is enough, for restarting unrelated things like the dev server or docker, or for questions about what /compact or /clear actually do.
---

# Session Handoff

This skill closes the current Claude Code session and opens a new one with a handoff prompt injected as initial context via the `SessionStart` hook.

## When to use this skill

**Direct trigger — execute immediately.** The user explicitly asks for a handoff: hand off this session, start a new session keeping context, restart preserving context, give me a prompt to continue in a new session, next phase of the plan in a clean session. Claude handles the user's intent across any language they write in; no need to enumerate translations.

**Proactive trigger — suggest, then execute on confirmation.** Recommend a handoff (and ask before running it) when:
- The user runs or mentions `/compact` and the conversation is already large.
- Compaction errors appear in long sessions.
- The user wants to reload hooks, skills, MCP servers, or pick up a new Claude Code binary version.
- The user says something like "start fresh but don't lose the plan".

**Soft signal — propose, do not execute.** When the user drops an idiomatic cue that a fresh session would help — "this chat is getting unwieldy", "we need a fresh start", "I think we should start over", "let's wrap this up and continue in a new chat" — do not call the handoff bash directly. Reply with a one-line proposal that names what would be seeded (current goal + open thread) and ask if they want it triggered. Only execute after they confirm.

**Mandated by a running process — execute, do not propose.** When an unattended run (plan execution, audit, loop) reaches its handoff step, the handoff is a mandated step of that process, not a suggestion to the user. Execute it. Do not ask — stopping to ask is the failure this case exists to prevent.

This case is narrow by design and does not weaken the one above it: it requires an unattended run to be **in flight**. A conversational session never qualifies, no matter how long it has run or how clearly a fresh session would help — there, the soft-signal rule still applies and you propose first.

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
EXIT_TRIGGER="$HOME/.claude/tmp/handoff-exit-$CLAUDE_HANDOFF_ID"

cat > "$PAYLOAD_FILE" <<'__HANDOFF_PAYLOAD_EOF__'
<THE HANDOFF PROMPT HERE>
__HANDOFF_PAYLOAD_EOF__

touch "$FLAG_FILE"
touch "$EXIT_TRIGGER"
```

After touching `$EXIT_TRIGGER`, do not emit any more output — the wrapper's watcher will close this process within ~0.5s and launch the new session.

Why `touch` instead of signalling the wrapper directly: the new sandbox/automode classifier escalates any process-signal primitive regardless of allowlist rules. The wrapper now owns the termination — it spawns a background watcher that polls `$EXIT_TRIGGER` and signals claude. The skill only needs the benign `touch` capability.

### Step 3 — zero-token alternative

If the user already has the prompt drafted and wants to fire the handoff without spending tokens on this turn, suggest they type directly:

```
handoff: <their prompt here>
```

The `UserPromptSubmit` hook intercepts it and runs the handoff without going through the model.
