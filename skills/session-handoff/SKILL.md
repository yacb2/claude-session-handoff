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

The front-matter only routes — it decides whether this skill gets surfaced at all. This section is what decides whether to *execute* or to *propose*, and it is authoritative. Do not act on the always-loaded listing alone: the handoff is one Bash block and is easy to fire straight from a description, which is exactly how the wrong case gets run.

**Direct trigger — execute immediately.** The user explicitly asks for a handoff: hand off this session, start a new session keeping context, restart preserving context, next phase of the plan in a clean session. Claude handles the user's intent across any language they write in; no need to enumerate translations.

**Proactive trigger — suggest, then execute on confirmation.** Recommend a handoff (and ask before running it) when:
- The user runs or mentions `/compact` and the conversation is already large.
- Compaction errors appear in long sessions.
- The user wants to reload hooks, skills, MCP servers, or pick up a new Claude Code binary version.

**Soft signal — propose, do not execute.** When the user drops an idiomatic cue that a fresh session would help — "this chat is getting unwieldy", "we need a fresh start", "I think we should start over" — do not execute the handoff directly — propose it in one line naming what would be seeded (current goal + open thread), then ask if they want it triggered. Only execute after they confirm.

**Asked for the prompt, not for the move — draft it, then offer.** When the user asks for *a prompt* to continue in a new session — "dame un prompt para iniciar una nueva sesión con este contexto", "give me a prompt I can paste into a new session" — what the words request is **text**. Produce it: write the handoff prompt **in the reply, never as a file on disk**, then offer to fire it and execute only if they confirm. Either path works once they do — this skill's Step 2, or having them type `handoff: <the prompt>` themselves (Step 3, zero tokens).

The discriminator is *what the words request*, not what they are about. "Has handoff a una nueva sesión" requests the **action**, and answering it with a document is the failure this skill exists to prevent. "Dame un prompt" requests the **text**, and producing it is compliance, not that failure. Both sentences are about moving to a new session; only one asks you to close this one.

**Tie-break — did they ask, or did they observe?** Check **Do NOT use** first. It wins outright; this tie-break only arbitrates between Direct, Proactive and Soft. An exclusion stays excluded however directly it is asked for — "borrá todo lo de esta conversación y empezamos de cero, no necesito ningún contexto" is a plain imperative, but what it asks for is `/clear`, so it is excluded rather than Direct. Read "asked for it" below as *asked for the handoff*, not as *used the imperative mood*.

Past that, one sentence can match Direct, Proactive and Soft at once: "let's start over in a new session but keep the plan" matches all three, and wanting to keep the context does not separate them, because every case above wants that. Decide on this and nothing else:

- The user **asked for it** — imperative ("hand off this session"), cohortative ("let's move to a clean session"), or an interrogative request ("can we...?", "¿podemos...?") — then it is a Direct trigger. Execute.
- The user **stated a first-person want for the move itself** — "I want a fresh session, keep the plan", "quiero seguir en una sesión nueva" — then they are asking, even with no question and no imperative. Execute. What the want is aimed at decides: a want aimed at the *work* is not a request for anything — "but I want to keep going on the CORS bug" names what they want preserved, and leaves the sentence a description.
- The user **described a state or voiced a hedged opinion** without asking — "this chat is getting unwieldy", "I think we should start over" — then it is a soft signal. Propose.

Proactive situations run through the same three branches; they set the *subject*, never the verdict. Asked inside one — "instalé un plugin nuevo, ¿podemos reiniciar pero seguir donde voy?" — is Direct: execute. Merely reported — "necesito recargar los hooks nuevos que metí, pero quiero seguir donde estoy con el bug del CORS" — stays Proactive: propose, because the only first-person want there is aimed at the work.

A question that asks for *options* rather than for the handoff — "is there another way to keep working clean without losing the plan?" — is describing, not asking. Propose.

**Mandated by a running process — execute, do not propose.** When an unattended run (plan execution, audit, loop) reaches its handoff step, the handoff is a mandated step of that process, not a suggestion to the user. Execute it. Do not ask — stopping to ask is the failure this case exists to prevent.

This case is narrow by design and does not weaken the one above it: it requires an unattended run to be **in flight**. A conversational session never qualifies, no matter how long it has run or how clearly a fresh session would help — there, the soft-signal rule still applies and you propose first, unless the project records a standing authorization (next case).

**Standing authorization recorded in the project — execute, do not re-ask.** When the project's own CLAUDE.md or memory, or a user-level rule in `~/.claude/rules/` (which covers every project), carries a durable grant — e.g. *"handoff at context threshold without asking"* — the proactive and soft-signal cases escalate to execute: the confirmation was given once, durably, and asking again is exactly the friction the grant exists to remove. The grant's scope is this one move — opening the successor session with the seeded brief. It never extends to publishing, deploying, or anything else the session might also want to do.

The grant has to live somewhere durable to exist at all. When the user grants it **in-session** — *"haz handoff cada vez que necesites, no me lo tienes que consultar"* — honor it for the session **and, unless a user-level rule in `~/.claude/rules/` already grants it, offer once to record it** in the project's CLAUDE.md (one line, theirs to delete). A grant that lives only in the conversation dies with it, and the user ends up re-dictating it in every project while sessions still close with "¿lanzo el handoff?".

**Idle cache expiry — execute under a standing grant, otherwise one line.** A system reminder tagged `[handoff-idle]` means `handoff-idle-cache.sh` woke this session: it has sat idle ~54 minutes at depth, and its prompt cache expires at 60, after which the owner's next message re-writes the whole context. Nobody is at the keyboard, so never ask. Hand off only when a standing authorization (the case above) covers this session **and** the handoff is safe: no subagent running (its hand-back would reach a dead session), no question to the owner still unanswered, and your own uncommitted work named path by path in the brief. Put `mode: idle` as the brief's second line, under `slug:`: the successor then shows the brief and waits instead of acting on the wrapper's automatic `continue`. Any condition missing: end the turn with one line and nothing else — the hook wakes a session once per idle period, so doing nothing costs one cache read.

**Do NOT use** when:
- The user only wants `/clear` (no context preserved). A *narrower* context is still preserved context: "inicia una nueva sesión y discutamos solamente X" asks for a handoff whose brief carries X and nothing else, not for `/clear` — the narrowing is the brief's scope, never the exclusion. And there is no *tool* that opens a session, so a `ToolSearch` for one finding nothing says nothing about this skill; two 2026-09-01 sessions answered "no puedo abrir una sesión nueva" from exactly that lookup while the skill was installed.
- The conversation is short and `/compact` is enough.
- The user wants to keep responding in the same session without restarting.
- The user wants to restart something that is not the Claude Code session — the dev server, docker, a container, a tmux pane, an ssh connection.
- The user is asking what `/compact`, `/clear` or `--resume` *do*. Answer the question; do not act on it.

This list is the authoritative one. `when_to_use` carries the same exclusions so the routing layer can drop the obvious cases before the skill is ever surfaced, but where the two differ, this list governs.

## Why handoff vs. /compact

Handoff costs only the turn that writes the prompt, is near-instant, reloads hooks, skills, MCP and the binary, and starts with zero residual context; `/compact` re-processes the whole conversation and keeps a stale process.

## How to execute the handoff

### Step 1 — draft the handoff prompt

Use this minimal structure. **Every sentence must be information the next session cannot derive from reading the code, any `CLAUDE.md` or `~/.claude/rules/`; do not restate a rule they already carry unless this session saw it broken.**

```
slug: <what this chain of sessions is called>

## Current goal
<one sentence>

## State
<files touched, what's done, what's left. Environment and data claims — DB
contents, running services, UI behavior — carry their standing: VERIFIED
(re-checked while drafting this brief; name the check) or ASSUMED (carried
from earlier turns; say so). Never as bare fact>

## Decisions taken
<only the non-obvious ones — agreed conventions, rejected tradeoffs>

## Next concrete step
<single, actionable — or, if the next step is a decision only the user can make,
name it as such: the options, what each costs, and what is already verified>

## Constraints / gotchas
<what the next session would trample if it didn't know>
```

**The `slug:` line names the chain, and it is the only line the mechanism reads** — besides `mode: idle`, which only the idle-cache case writes, and the optional `chain: new` below. The
`SessionStart` hook takes it from the first five lines of the brief, prefixes the ordinal it
reads off `~/.claude/handoff-chains/`, and that becomes the session's title in the `--resume`
picker: `↻3 · Refactor auth`. Without it the new session is auto-titled after its first prompt —
which is the word *continue* — and a five-session chain renders as five identical rows.

Keep the chain's current slug. A new phase of the same
work is not a new subject: re-describing the chain at every link drifts its name once per hop,
which is exactly as unreadable as never changing it. The one exception is an unattended run, where
the slug is not invented at all — take it from the run's artifact (the plan, the loop-spec, the
workflow-spec, the audit run) and append the phase. That name already exists, it was written down before the first handoff,
and it is more stable than any phrasing produced per hop.

When the **subject** of the work changed, do not re-slug this chain: add a line `chain: new` within the first five lines, under a `slug:` that names the new subject. The successor then starts a new chain (link 1) instead of continuing this one. Never for a new phase or step of the same work, and never without the `slug:` line. The handoff still writes its deltas: `CLOSE`/`OPEN`/`TURN` land on the old chain, and a `CHARTER` delta opens the new one (without one, the brief's first sentence does).

One line, and no ordinal of your own — the ordinal comes from the record, and a hand-written one
would be counted twice.

### The chain ledger — what the brief must stop carrying

A session in an established chain opens with a `=== CHAIN LEDGER ===` block above the brief.
It is not something a previous session re-typed: it is a per-chain file the `SessionStart` hook
renders with no model involved, and an item leaves it **only when a `CLOSE` delta closes it**.

The brief is re-drafted at every hop and drops what the outgoing session did not touch, items owed to the user worst of all, and bare `handoff` runs no model, so only a file can carry them.

**Do not re-type ledger items into the brief.** They are already carried, and copying them back
is how the two records start disagreeing. The brief keeps what it is good at: the volatile
state, re-verified each hop.

Three kinds of thing go in, and nothing else:

| Delta line | For |
|---|---|
| `CHARTER <text>` | What this chain exists to do. Written once, at the chain's first handoff. |
| `OPEN OWED <text>` | A decision only the user can make. **This is where a recorded fork goes** — the `Next concrete step` fork survives one hop; an `OWED` item survives until answered. |
| `OPEN RULE <text>` | A standing constraint of theirs — "do not merge or push this branch". |
| `CLOSE d<n> <how>` | Settled. `d<n>` is the id shown in the rendered block. |
| `TURN <text>` | The work changed direction — an approach dropped because something worked better, a problem found mid-execution, a decision taken on the fly. Not an obligation and nothing closes it; it renders in the chain's trajectory. **Name the item id when a turn bears on one** — `TURN d1 turned out to depend on X` — because that is what carries the entry forward once it falls outside the trajectory window. |

There is a fifth verb, `NOTE`, written only by the hooks and **not yours to write**: it counts nowhere, so using it in place of `TURN` hides that link's work from the staleness count. Write `TURN`.

### The predecessor retro — the links no session could write for

Deltas are written by the **dying** session, which needs its context live — after an hour
away with a cold cache that means re-sending the whole conversation just to ask what changed
— and on the bare `handoff` paths no model runs at all. So the handoff jumps **first**, and
the **arriving** session — empty context, warm cache by construction — reads its
predecessor's transcript off disk and writes that link's deltas before it does anything else.

When the hook injects a `=== PREDECESSOR RETRO ===` block (only where no model wrote that link's deltas), run its commands exactly as emitted, at column 0 and with unindented delta lines (an indented heredoc terminator swallows the commands after it). Delegate the digest to one small-model subagent with an explicit read-only or lookup `subagent_type` (never unset or `general-purpose`), hand it the open items the block pastes (an `OWED` is a decision the owner has not made), and never let it write `CLOSE`, only `TURN` and `OPEN`: a transcript quotes live ledger ids, and `apply` refuses a retro `CLOSE`.

**Correcting something an earlier link got wrong needs no rewrite, and must not get
one.** The file is append-only. `CLOSE` the item with what actually turned out, then
`OPEN` the corrected one: both lines stay, in order, with the link each happened at.
That is the trajectory an arriving session reads to learn where the chain has *been*,
not only where it stands — and rewriting history would destroy exactly that.

**Promotion — how an item leaves for good.** An item that turns out to deserve
permanence does not stay here. Write it as an ADR, a backlog item or a plan, then
`CLOSE` it naming that reference. The ledger is the *pre-artifact* layer: what is owed
inside this chain and not yet worth a document. Skipping this is how it silently
becomes a second backlog that nothing reindexes and no one archives.

Ids are assigned by the mechanism, never written by you — you can only reference an id the block
already showed you. Volatile state, commit SHAs, gate results and next steps do **not** go in;
they belong in the brief, where re-verifying them each hop is correct.

**Every handoff writes its deltas.** Nothing changed is a legitimate answer and means writing
none — but a session that settled an owed item and did not close it leaves every later link
reading a question the user already answered. A `chain: new` handoff is no exception: its
deltas are written, and land as described above.

Drafting rules:
- Be terse. Skip any section that adds nothing — **except `Next concrete step`**, which is never
  skipped.
- Zero filler, zero obvious explanations.
- If the user already provided a prompt, use it as-is — do not rewrite it.
- **State claims about the environment are cheap to re-check and expensive to get wrong —
  re-check them while drafting.** A brief is a claims artifact nobody verifies on arrival,
  so a wrong claim about the database, a UI element or production reaches the user as fact.
  A worktree list, a migration check cost seconds at draft time; mark anything not re-checked
  as ASSUMED so the next session verifies before repeating it. Skip the git re-check for the
  repo you are in: the successor starts with Claude Code's own `gitStatus` of it. That
  covers the cwd's repo only, so a nested repo or another worktree the brief names is still
  re-checked.

**Never manufacture a next step to fill that section.** Answer one question — *is the next step
mine or the user's?* — and write the answer down. A recorded fork is a valid answer; an implicit
one is not. Both halves of that matter: skipping the section hides a fork the next session then
has to rediscover, and inventing a single step to fill it makes the next session execute a
decision the user never made.

Recorded, the next session opens with *"the next step is your call: A or B"*. Unrecorded, it
opens guessing what *continue* means and blames the user's word for a fork it should have read
off the state.

**A recorded fork belongs in the ledger, not only in the brief.** `Next concrete step` is
re-drafted at the next hop and the fork survives exactly as long as some session happens
to re-type it. `OPEN OWED` survives until you answer it. Write it in both if the next step really is the fork; write
it in the ledger regardless.

Watch the quieter route to the same place: instead of skipping the section, the fork gets demoted
into `Constraints / gotchas` as a prohibition — *"do not push without an explicit ask"* — while
`Next concrete step` holds a manufactured action. The next session then reads a rule to obey where
a choice was waiting, and never surfaces the decision at all. A fork belongs in `Next concrete
step` as a fork.

**When the user is present, resolve the fork here instead of recording it.** They asked for this
handoff, so they are one turn away. Ask which thread continues, then hand off next turn with their
answer written in as the single next step — the new session opens executing instead of opening on
a menu. Recording is the fallback for when asking is impossible, not the default.

**This is the one carve-out to "Direct trigger — execute immediately".** Executing is still
the default; a live fork is the sole reason to spend a turn first.

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

The bound matters because the mechanism gives you no third option: firing the handoff ends
this session in ~0.5s, so asking *is* postponing the handoff by a turn. Deferring a handoff the
user asked for, to ask them something, is how this skill's worst failure mode looks from the
outside — answering a request for the move with words instead. So: ask only about which thread,
never about whether to hand off, and never twice.

### Step 2 — execute

With the payload ready, run `handoff-fire.sh` via Bash. The guards live in the script, not in
notes above it. Run it inside the sandbox first: if it answers that `ps` cannot run, rerun it once
with `dangerouslyDisableSandbox: true` — the ancestry walk needs the process tree, and the sandbox
hides it. That is the only reason to disable the sandbox here, and the script tells you when it
applies.

The script refuses when `$CLAUDE_HANDOFF_ID` is unset, and also when it is set but its wrapper is dead (the wrapper exports it as its own PID and every descendant inherits it, including `--fork-session`, `--resume` and harness jobs), which it detects by walking the parent chain.

stdin is the brief. The first line that is `__HANDOFF_DELTA__` (surrounding blanks ignored) ends
the brief wherever it appears, quoted or fenced text included, so never put it alone on a line of
the brief itself. What follows is the
ledger deltas, one per line (OPEN / CLOSE / TURN / CHARTER), written to the delta file. The delta
file exists for the same reason as the payload: this session knows neither its own id nor its chain,
so the SessionStart hook — the one place chain identity exists — applies it. OMIT the
`__HANDOFF_DELTA__` line and everything after it when nothing changed; an empty delta is a no-op but
a fabricated one is a lie that outlives the session.

```sh
sh "$HOME/.claude/scripts/handoff-fire.sh" <<'__HANDOFF_EOF__'
<THE HANDOFF PROMPT HERE>
__HANDOFF_DELTA__
<ONE DELTA PER LINE — OPEN / CLOSE / TURN / CHARTER — OR DROP THE LINE ABOVE AND THIS ONE>
__HANDOFF_EOF__
```

Read the exit status before deciding what to say. Non-zero means it refused and printed
why: nothing was written, this session is not closing, and staying silent leaves the user watching
a handoff that never happened. Report the reason in that same turn and stop.

Only on exit 0, do not emit any more output — the wrapper's watcher
will close this process within ~0.5s and launch the new session, so anything else is lost anyway.

### Step 3 — zero-token alternatives

The `UserPromptSubmit` hook intercepts these before the model runs, so the turn costs nothing:

| Typed | Seeds |
|---|---|
| `handoff: <text>` | that text, verbatim — the user's own brief |
| `handoff <words>` | what bare `handoff` seeds, plus `<words>` as the user's instruction for the new session; the chain's curated brief is kept |
| `handoff` | the last completed turn — the user's ask and the reply that answered it — read from the transcript by the hook, plus the chain's last curated brief and its file paths |
| `handoff --new: <text>` | that text, verbatim, and the new session starts a NEW chain (own ledger, charter from the text's first line, ordinal 1) — for unrelated work that still needs the context |
| `handoff --clean` | nothing; a genuinely empty session |

Suggest `handoff: <text>` when the user already has the prompt drafted.

Suggest bare `handoff` for the case this skill cannot serve: a session so long that prompting it
at all is expensive. Drafting a good brief costs one request over the whole conversation, and
with a cold cache that is exactly what the user is trying to avoid. The tail is worse context
than a drafted brief — it has no goal, state or next step — so it is the cheap path, not the
good one. Offer it when the cost is the problem, not otherwise.
