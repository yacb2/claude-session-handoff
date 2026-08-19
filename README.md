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
SessionStart hook reads the payload, injects it as additionalContext,
shows a systemMessage banner, titles the session `↻N · <slug>` and
records the link; deletes the payload (one-shot)
        │
        ▼
New session opens with the handoff context loaded.
```

## Three ways to trigger a handoff

### 1. `handoff: <text>` (zero tokens, you write the prompt)

```
> handoff: finishing the /api/orders endpoint. Serializer and viewset done; the
  permissions test is still missing. Next step: add a test that asserts a user
  without the "manager" role gets 403.
```

The hook intercepts it. No tokens consumed this turn. The new session opens with that text as seeded context.

Two variants on the same path, also free:

- **`handoff`** — seeds the previous session's **last reply**, which the hook reads straight out
  of the transcript. For the case the skill cannot serve: a session long enough that prompting it
  at all is expensive, where drafting a proper brief means one request over the whole
  conversation with a cold cache. The payload is labelled as a raw tail, because it is one — no
  goal, no state, no next step. Cheaper than a brief, and worse than one.
- **`handoff --clean`** — seeds nothing. A genuinely empty session.

### 2. `/handoff [optional text]` (slash command)

```
> /handoff
```

With no args, Claude generates the handoff prompt from the conversation context. With args, it uses them as-is.

**Spends tokens for the current turn** because the model writes the prompt — but infinitely less than `/compact`.

### 3. `session-handoff` skill (natural language)

```
> do a handoff
> start a new session keeping this context
> let's wrap this up and continue in a clean session
> next phase of the plan in a new session
```

The skill activates, drafts the structured prompt, and runs the handoff. It also suggests handoff proactively when it sees you typing `/compact` on a large conversation, or drops idiomatic cues like "this chat is getting unwieldy" or "we need a fresh start" — in those cases it asks before executing.

The skill works across any language Claude understands; the description is in English but you can ask in Spanish, Portuguese, French, etc.

### 4. `handoff` alone (no text)

```
> handoff
```

Zero tokens, and **not** an empty session: the hook copies the previous session's last reply out
of the transcript and seeds that, labelled as a raw tail rather than a curated brief. It exists
for the session too expensive to prompt — a 600k-token conversation with a cold cache, where
asking the model to draft a brief costs one request over the whole thing.

### 5. `handoff --clean` (deliberately empty)

```
> handoff --clean
```

Fresh session, **no seeded context**, and a new chain: the ordinal does not carry across a clean
break. The wrapper prints an explicit warning before closing. Equivalent to `/clear` but with a
full process restart.

## Session titles and chain lineage

Claude Code has no notion of one session succeeding another, so an untitled handoff session gets
auto-titled after its first prompt — and the wrapper's first prompt is the word *continue*. Five
handoffs used to render as five identical rows in `claude --resume`.

Each link is now titled with its position in front of the chain's name, because the picker
truncates the tail:

```
↻4 · Refactor auth      2m ago    feature/auth   412 KB
↻3 · Refactor auth      1h ago    feature/auth   380 KB
↻2 · Refactor auth      3h ago    feature/auth   210 KB
```

The ordinal is not parsed back out of the title — `Ctrl+R` lets you rename a session, which would
silently overwrite it. It is read from an append-only record at
`~/.claude/handoff-chains/<project>.jsonl`, one line per link:

```json
{"chain":"c1","n":3,"slug":"Refactor auth","session":"…","prev":"…","wrapper":"4711","at":"…Z"}
```

The record is what survives the wrapper dying, and it is the only thing that can see a fork —
resume an old link, hand off again, and two sessions are legitimately the N+1th child of the same
parent. The newcomer is marked `"sibling":true` rather than renumbered.

The chain is named by the `slug:` line the brief opens with, so `handoff: <text>` re-describes it
and bare `handoff` inherits it. `--uninstall` leaves the records alone: they are history, not
install state.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on `PATH`
- [jq](https://jqlang.github.io/jq/)
- Shell: **zsh**, **bash**, or **fish**

## Install

```bash
git clone https://github.com/yacb2/claude-session-handoff.git
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

## Optional: audible bell on handoff (`HANDOFF_BELL`)

By default a handoff announces itself with the on-screen banner only. If you step away while a
long turn finishes and want an audible cue when the new session lands, export:

```sh
export HANDOFF_BELL=1
```

The `SessionStart` hook then also emits a terminal bell alongside the banner. It is **off by
default** on purpose — a handoff is not always something you are waiting on, and an unrequested
bell is worse than none.

Claude Code only forwards an allowlisted set of escape sequences from a hook (window/icon titles
via OSC 0/1/2, notifications via OSC 9/99/777, and a bare BEL); anything else is silently
dropped. This uses a bare BEL, the one form every terminal handles — the OSC notification
variants each need a different sequence per emulator.

## Components

| File | Purpose |
|---|---|
| `scripts/claude-wrapper.sh` | Unified POSIX wrapper that runs `claude` in a loop. On exit, checks per-PID flag files and either relaunches fresh (handoff) or with `--resume` (restart). Byte-for-byte identical to the copy in `claude-restart`. |
| `scripts/handoff-session-start.sh` | SessionStart hook: reads `~/.claude/tmp/handoff-payload-<pid>` and `handoff-title-<pid>`, emits `additionalContext` (for Claude), `systemMessage` (banner for you) and `sessionTitle` (the picker row), appends the chain link, plus an optional bell under `HANDOFF_BELL=1`; deletes both files. |
| `scripts/handoff-prompt-hook.sh` | UserPromptSubmit hook: intercepts `handoff` / `handoff: <text>` and triggers a handoff without going through the model. |
| `commands/handoff.md` | `/handoff` slash command — model-driven path that drafts the prompt and runs the handoff. |
| `skills/session-handoff/SKILL.md` | Skill with natural-language triggers and a structured prompt template; works across the languages Claude generalizes. |
| `install.sh` | Installer with shell detection, idempotency, version comparison, and `--uninstall` support. |
| `tests/smoke.sh` | Installer protocol + hook output validation (8 cases, 38 asserts). Requires `claude-restart` as a sibling repo. |
| `tests/wrapper-dispatch.sh` | Drives the wrapper's dispatch loop against a stub `claude` and asserts what it relaunches with. |
| `tests/hook-guard.sh` | Regression tests for the UserPromptSubmit hook's guards, plus a check that no eval query can satisfy the eval by firing the hook instead of the skill. |
| `tests/skill-consistency.sh` | Asserts the skill's `when_to_use` front-matter and its body enumerate the same trigger cases. |
| `tests/eval-trigger.sh` | Skill description trigger eval (wraps `skill-creator`'s harness, hides the real skill to avoid shadow-skill measurement issues). Derives a legacy boolean set from `expect`. |
| `tests/eval-pty.sh` | Interactive trigger eval over a real PTY. Scores `execute` / `propose` / `ignore` separately — a query the skill must ask about first is verified by confirming on a second turn. |

## Limitations

- **Requires the wrapper**: the zero-token hook path only works when `claude` is launched via the `claude()` shell function the installer adds. If you start Claude from an IDE integration that calls the binary directly, use `/handoff` (the slash command) or the skill.
- **Strict match on the hook**: the UserPromptSubmit hook fires only on `handoff` or `handoff: ...` at the start of the prompt (case-insensitive).
- **Bare `handoff` needs `jq` and a completed reply**: the transcript tail is parsed with `jq`, and the extraction takes the last assistant line carrying no tool call. Without `jq`, without a `transcript_path`, or on a session that never produced a reply, the handoff still fires and falls back to a clean session.
- **Lineage is per-project**: `claude --resume` is scoped to one project by default (`Ctrl+A` widens it). Ordinals make a chain legible *within* a project; across projects the slug does the work. And a chain started by the slash command or the skill takes its predecessor from the last link recorded under the same wrapper PID, so a recycled PID in the same project can inherit a stranger's ordinal — cosmetic, and the record shows it.
- **Payload is one-shot**: each handoff seeds exactly one session and is deleted afterwards. There is no persistent state.
- **Skill trigger eval is conservative**: the `tests/eval-trigger.sh` harness uses `claude -p` with a slash-command shim, which under-measures side-effect-heavy skills like this one. Real interactive triggering is more reliable than the harness score.

## Uninstall

```bash
./install.sh --uninstall
```

This removes the handoff hooks, slash command, skill, and unregisters `claude-session-handoff` from the shared rc block. If `claude-restart` is still installed, the wrapper and the rc block stay in place. If this was the last tool, both are removed.

## License

MIT
