---
name: session-handoff
description: Hand off the current Claude Code session to a fresh new one with the current context seeded as a handoff prompt. Use when the user wants to keep working in a clean session without losing the plan — faster and cheaper than /compact since it opens a new process with hooks, skills, MCP, and the Claude Code binary reloaded.
when_to_use: |
  Use when the user asks to hand off the session, start a fresh session that keeps the current context, restart while preserving what we're working on, or continue with the next phase of a plan in a clean session.
  Also surface — without treating it as a request — when the user runs /compact on a long conversation, hits compaction errors, wants to reload hooks/skills/MCP servers mid-session, or signals that a fresh session would help ("this chat is getting unwieldy", "we need a fresh start").
  Do NOT use for /clear or wiping the conversation, for short conversations where /compact is enough, for restarting unrelated things like the dev server or docker, or for questions about what /compact or /clear actually do.
  Surfacing is not executing: read the skill body before acting — it decides execute vs. propose-and-confirm — and when in doubt, propose and confirm, unless an unattended run mandates the handoff.
---

# Session Handoff

This skill closes the current Claude Code session and opens a new one with a handoff prompt injected as initial context via the `SessionStart` hook.

## When to use this skill

The front-matter only routes — it decides whether this skill gets surfaced at all. This section is what decides whether to *execute* or to *propose*, and it is authoritative. Do not act on the always-loaded listing alone: the handoff is six lines of Bash and is easy to fire straight from a description, which is exactly how the wrong case gets run.

**Direct trigger — execute immediately.** The user explicitly asks for a handoff: hand off this session, start a new session keeping context, restart preserving context, next phase of the plan in a clean session. Claude handles the user's intent across any language they write in; no need to enumerate translations.

**Proactive trigger — suggest, then execute on confirmation.** Recommend a handoff (and ask before running it) when:
- The user runs or mentions `/compact` and the conversation is already large.
- Compaction errors appear in long sessions.
- The user wants to reload hooks, skills, MCP servers, or pick up a new Claude Code binary version.

**Soft signal — propose, do not execute.** When the user drops an idiomatic cue that a fresh session would help — "this chat is getting unwieldy", "we need a fresh start", "I think we should start over" — do not execute the handoff directly — propose it, summarize what would be seeded, and confirm before running. In practice: a one-line proposal naming what would be seeded (current goal + open thread), then ask if they want it triggered. Only execute after they confirm.

**Asked for the prompt, not for the move — draft it, then offer.** When the user asks for *a prompt* to continue in a new session — "dame un prompt para iniciar una nueva sesión con este contexto", "give me a prompt I can paste into a new session" — what the words request is **text**. Produce it: write the handoff prompt **in the reply, never as a file on disk**, then offer to fire it and execute only if they confirm. Either path works once they do — this skill's Step 2, or having them type `handoff: <the prompt>` themselves (Step 3, zero tokens).

The discriminator is *what the words request*, not what they are about. "Has handoff a una nueva sesión" requests the **action**, and answering it with a document is the failure this skill exists to prevent — it drew verbatim user corrections twice. "Dame un prompt" requests the **text**, and producing it is compliance, not that failure. Both sentences are about moving to a new session; only one asks you to close this one.

**Tie-break — did they ask, or did they observe?** Check **Do NOT use** first. It wins outright; this tie-break only arbitrates between Direct, Proactive and Soft. An exclusion stays excluded however directly it is asked for — "borrá todo lo de esta conversación y empezamos de cero, no necesito ningún contexto" is a plain imperative, but what it asks for is `/clear`, so it is excluded rather than Direct. Read "asked for it" below as *asked for the handoff*, not as *used the imperative mood*.

Past that, one sentence can match Direct, Proactive and Soft at once: "let's start over in a new session but keep the plan" matches all three, and wanting to keep the context does not separate them, because every case above wants that. Decide on this and nothing else:

- The user **asked for it** — imperative ("hand off this session"), cohortative ("let's move to a clean session"), or an interrogative request ("can we...?", "¿podemos...?") — then it is a Direct trigger. Execute.
- The user **stated a first-person want for the move itself** — "I want a fresh session, keep the plan", "quiero seguir en una sesión nueva" — then they are asking, even with no question and no imperative. Execute. What the want is aimed at decides: a want aimed at the *work* is not a request for anything — "but I want to keep going on the CORS bug" names what they want preserved, and leaves the sentence a description.
- The user **described a state or voiced a hedged opinion** without asking — "this chat is getting unwieldy", "I think we should start over" — then it is a soft signal. Propose.

Proactive situations run through the same three branches; they set the *subject*, never the verdict. Asked inside one — "instalé un plugin nuevo, ¿podemos reiniciar pero seguir donde voy?" — is Direct: execute. Merely reported — "necesito recargar los hooks nuevos que metí, pero quiero seguir donde estoy con el bug del CORS" — stays Proactive: propose, because the only first-person want there is aimed at the work.

A question that asks for *options* rather than for the handoff — "is there another way to keep working clean without losing the plan?" — is describing, not asking. Propose.

**Mandated by a running process — execute, do not propose.** When an unattended run (plan execution, audit, loop) reaches its handoff step, the handoff is a mandated step of that process, not a suggestion to the user. Execute it. Do not ask — stopping to ask is the failure this case exists to prevent.

This case is narrow by design and does not weaken the one above it: it requires an unattended run to be **in flight**. A conversational session never qualifies, no matter how long it has run or how clearly a fresh session would help — there, the soft-signal rule still applies and you propose first.

**Do NOT use** when:
- The user only wants `/clear` (no context preserved).
- The conversation is short and `/compact` is enough.
- The user wants to keep responding in the same session without restarting.
- The user wants to restart something that is not the Claude Code session — the dev server, docker, a container, a tmux pane, an ssh connection.
- The user is asking what `/compact`, `/clear` or `--resume` *do*. Answer the question; do not act on it.

This list is the authoritative one. `when_to_use` carries the same exclusions so the routing layer can drop the obvious cases before the skill is ever surfaced, but where the two differ, this list governs.

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
<single, actionable — or, if the next step is a decision only the user can make,
name it as such: the options, what each costs, and what is already verified>

## Constraints / gotchas
<what the next session would trample if it didn't know>
```

Drafting rules:
- Be terse. Skip any section that adds nothing — **except `Next concrete step`**, which is never
  skipped.
- Zero filler, zero obvious explanations.
- If the user already provided a prompt, use it as-is — do not rewrite it.

**Never manufacture a next step to fill that section.** Answer one question — *is the next step
mine or the user's?* — and write the answer down. A recorded fork is a valid answer; an implicit
one is not. Both halves of that matter: skipping the section hides a fork the next session then
has to rediscover, and inventing a single step to fill it makes the next session execute a
decision the user never made.

The failure this prevents, observed: a run ended with its remaining items blocked *by decision*
and a large batch unpublished — a genuine fork. The brief did not record it, so the new session
inferred it from an intentless first message and opened with *"'Continue' can mean two very
different things here"*. Same fork, but blamed on the user's word instead of read off the state.
Recorded, it opens as *"the next step is your call: A or B"* — the handoff working, not failing.

Watch the quieter route to the same place: instead of skipping the section, the fork gets demoted
into `Constraints / gotchas` as a prohibition — *"do not push without an explicit ask"* — while
`Next concrete step` holds a manufactured action. The next session then reads a rule to obey where
a choice was waiting, and never surfaces the decision at all. A fork belongs in `Next concrete
step` as a fork.

**When the user is present, resolve the fork here instead of recording it.** They asked for this
handoff, so they are one turn away. Ask which thread continues, then hand off next turn with their
answer written in as the single next step — the new session opens executing instead of opening on
a menu. Recording is the fallback for when asking is impossible, not the default.

**This is the one carve-out to "Direct trigger — execute immediately".** It has to be, or it
never fires: a Direct request is exactly the case where the user is present, and reading Direct
as winning outright collapses the carve-out to nothing. Executing is still the default; a live
fork is the sole reason to spend a turn first.

Three conditions, all of them: a genuine fork exists; this is a Direct or Proactive handoff the
user asked for in this conversation; and what you are asking is *which thread continues*. Fail
any and you record the fork instead.

**Ask once — that is a rule about how you ask, not about how forked the state is.** Several open
decisions do not become several questions and do not disqualify asking; they become one question
offering them as options. A heavily forked state is when asking is worth the most, so reading
"one question" as "only if there is exactly one decision" gets it backwards.

Never ask in the mandated-by-a-running-process case — no one is at the keyboard, and stopping a
run to ask is the exact failure that case exists to prevent. Never ask on the `handoff:` hook
path either; it bypasses the model entirely, so there is nothing to ask with.

The bound matters because the mechanism gives you no third option: touching `$EXIT_TRIGGER` ends
this session in ~0.5s, so asking *is* postponing the handoff by a turn. Deferring a handoff the
user asked for, to ask them something, is how this skill's worst failure mode looks from the
outside — answering a request for the move with words instead. So: ask only about which thread,
never about whether to hand off, and never twice.

### Step 2 — execute

With the payload ready, run via Bash. The `$CLAUDE_HANDOFF_ID` check is part of the block, not a
note above it: unset, every path below still runs and writes `handoff-payload-`, `handoff-flag-`
and `handoff-exit-` with an empty suffix — files no wrapper is watching — and then reports success.

```sh
if [ -z "$CLAUDE_HANDOFF_ID" ]; then
  echo "handoff: wrapper not detected. Launch claude via the shell function that claude-session-handoff installs." >&2
  exit 1
fi

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

### Step 3 — zero-token alternatives

The `UserPromptSubmit` hook intercepts these before the model runs, so the turn costs nothing:

| Typed | Seeds |
|---|---|
| `handoff: <text>` | that text, verbatim — the user's own brief |
| `handoff` | the previous session's last reply, read from the transcript by the hook |
| `handoff --clean` | nothing; a genuinely empty session |

Suggest `handoff: <text>` when the user already has the prompt drafted.

Suggest bare `handoff` for the case this skill cannot serve: a session so long that prompting it
at all is expensive. Drafting a good brief costs one request over the whole conversation, and
with a cold cache that is exactly what the user is trying to avoid. The tail is worse context
than a drafted brief — it has no goal, state or next step — so it is the cheap path, not the
good one. Offer it when the cost is the problem, not otherwise.
