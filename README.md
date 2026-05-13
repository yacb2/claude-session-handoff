# claude-session-handoff

Closes the current [Claude Code](https://docs.anthropic.com/en/docs/claude-code) session and opens a new one with a handoff prompt seeded as initial context. Fresh session, reloaded hooks, zero residual context — only the brief you (or Claude) wrote.

> **Inspired by** [yacb2/claude-restart](https://github.com/yacb2/claude-restart). Same wrapper trick, different goal: instead of `--resume`ing the same session, start a fresh one with context injected via the `SessionStart` hook. The two tools share a unified wrapper and coexist cleanly — see [coexistence](#coexistence-with-claude-restart) below.

## Why not just `/compact`?

`/compact` is built-in and works — but it has costs:

| | `/compact` (built-in) | `handoff` |
|---|---|---|
| **Tokens** | Processes the entire conversation to summarize | Only the current turn that generates the prompt |
| **Time** | Slow on large sessions, can fail | Near-instant |
| **Process** | Same process — stale hooks, stale binary | Fresh process: hooks, skills, MCP, binary up to date |
| **Residual context** | Summary + new turns accumulate | Zero — starts with only the seeded prompt |
| **Zero-token trigger** | No | Yes (`handoff: <text>` via the hook path) |

When you just want to keep working in a clean session, handoff wins on cost and speed.

## How it works

```
You type "handoff: <text>" in the prompt
        │
        ▼
UserPromptSubmit hook intercepts it before the model sees it
        │
        ▼
Writes payload + flag, sends SIGTERM to the wrapper
(zero tokens — the model never sees the prompt)
        │
        ▼
Wrapper sees the flag and launches a fresh `claude` (no --resume)
        │
        ▼
SessionStart hook reads the payload, injects it as additionalContext +
shows a systemMessage banner, deletes the payload (one-shot)
        │
        ▼
New session opens with the handoff context loaded.
```

For the full flow including the slash command and skill paths, see [`.context/references/architecture/00-index.md`](.context/references/architecture/00-index.md) (private to the repo; included here as a pointer).

## Three ways to trigger a handoff

### 1. `handoff: <text>` (zero tokens, you write the prompt)

```
> handoff: finishing the /api/orders endpoint. Serializer and viewset done; the
  permissions test is still missing. Next step: add a test that asserts a user
  without the "manager" role gets 403.
```

The hook intercepts it. No tokens consumed this turn. The new session opens with that text as seeded context.

### 2. `/handoff [optional text]` (slash command)

```
> /handoff
```

With no args, Claude generates the handoff prompt from the conversation context. With args, it uses them as-is.

**Spends tokens for the current turn** because the model writes the prompt — but infinitely less than `/compact`.

### 3. `session-handoff` skill (natural language)

```
> do a handoff
> haz un handoff
> dame un prompt para iniciar una nueva sesión con este contexto
> start a new session for the next phase of the plan
> sigamos en limpio
```

The skill activates, drafts the structured prompt, and runs the handoff. It also suggests handoff proactively when it sees you typing `/compact` on a large conversation.

### 4. `handoff` alone (no text)

```
> handoff
```

Fresh session, **no seeded context**. The wrapper prints an explicit warning before closing. Equivalent to `/clear` but with a full process restart.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on `PATH`
- [jq](https://jqlang.github.io/jq/)
- Shell: **zsh**, **bash**, or **fish**

## Install

```bash
git clone https://github.com/<your-user>/claude-session-handoff.git
cd claude-session-handoff
./install.sh
```

The installer is **idempotent**. Sandbox testing is supported via `CLAUDE_DIR`, `RC_FILE_OVERRIDE`, and `SHELL_NAME_OVERRIDE` environment variables.

### What the installer does

1. Installs the unified `claude-wrapper.sh` to `~/.claude/scripts/` (only if its version is newer than what's already there — see [coexistence](#coexistence-with-claude-restart)).
2. Installs the handoff hook scripts to `~/.claude/scripts/`.
3. Installs `/handoff` to `~/.claude/commands/`.
4. Installs the `session-handoff` skill to `~/.claude/skills/`.
5. Maintains a shared `# claude-wrapper: start/end` block in your shell rc, adding `claude-session-handoff` to its `# registered-by:` line.
6. Registers two hooks in `~/.claude/settings.json`:
   - `SessionStart` → injects the handoff payload (both as `additionalContext` for Claude and `systemMessage` for the user banner).
   - `UserPromptSubmit` → intercepts `handoff:` for the zero-token path.
7. Creates `~/.claude/tmp/` for the per-PID flag and payload files.

Pre-existing legacy blocks from older versions of either tool are migrated automatically.

## Coexistence with `claude-restart`

`claude-session-handoff` and [`claude-restart`](https://github.com/yacb2/claude-restart) share a unified wrapper file at `~/.claude/scripts/claude-wrapper.sh`. Either tool can be installed first; either can be uninstalled without breaking the other. Both register themselves in a single `# claude-wrapper: start/end` block in your shell rc; the wrapper is only removed once the last tool is uninstalled.

The wrapper loop checks both flag patterns (`restart-flag-<pid>` and `handoff-flag-<pid>`) and dispatches accordingly. When both flags are set in the same iteration, handoff takes precedence (a fresh clean session reflects the most recent user intent).

If you upgrade an old `claude-restart` installation, the new shared block will be created and the old `# claude-restart: start/end` block migrated automatically.

## Components

| File | Purpose |
|---|---|
| `scripts/claude-wrapper.sh` | Unified POSIX wrapper that runs `claude` in a loop. On exit, checks per-PID flag files and either relaunches fresh (handoff) or with `--resume` (restart). Byte-for-byte identical to the copy in `claude-restart`. |
| `scripts/handoff-session-start.sh` | SessionStart hook: reads `~/.claude/tmp/handoff-payload-<pid>`, emits both `additionalContext` (for Claude) and `systemMessage` (banner for you), deletes the payload. |
| `scripts/handoff-prompt-hook.sh` | UserPromptSubmit hook: intercepts `handoff` / `handoff: <text>` and triggers a handoff without going through the model. |
| `commands/handoff.md` | `/handoff` slash command — model-driven path that drafts the prompt and runs the handoff. |
| `skills/session-handoff/SKILL.md` | Skill with natural-language triggers (English, Spanish, Portuguese, French) and a structured prompt template. |
| `install.sh` | Installer with shell detection, idempotency, version comparison, and `--uninstall` support. |
| `tests/smoke.sh` | Installer protocol validation (6 cases, 22 asserts). Requires `claude-restart` as a sibling repo. |
| `tests/eval-trigger.sh` | Skill description trigger eval (wraps `skill-creator`'s harness, hides the real skill to avoid shadow-skill measurement issues). |

## Limitations

- **Requires the wrapper**: the zero-token hook path only works when `claude` is launched via the `claude()` shell function the installer adds. If you start Claude from an IDE integration that calls the binary directly, use `/handoff` (the slash command) or the skill.
- **Strict match on the hook**: the UserPromptSubmit hook fires only on `handoff` or `handoff: ...` at the start of the prompt (case-insensitive).
- **Payload is one-shot**: each handoff seeds exactly one session and is deleted afterwards. There is no persistent state.
- **Skill trigger eval is conservative**: the `tests/eval-trigger.sh` harness uses `claude -p` with a slash-command shim, which under-measures side-effect-heavy skills like this one. Real interactive triggering is more reliable than the harness score. See [`.context/references/testing/00-index.md`](.context/references/testing/00-index.md) for details.

## Uninstall

```bash
./install.sh --uninstall
```

This removes the handoff hooks, slash command, skill, and unregisters `claude-session-handoff` from the shared rc block. If `claude-restart` is still installed, the wrapper and the rc block stay in place. If this was the last tool, both are removed.

## License

MIT
