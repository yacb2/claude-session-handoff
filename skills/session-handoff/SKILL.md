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

This case is narrow by design and does not weaken the one above it: it requires an unattended run to be **in flight**. A conversational session never qualifies, no matter how long it has run or how clearly a fresh session would help — there, the soft-signal rule still applies and you propose first, unless the project records a standing authorization (next case).

**Standing authorization recorded in the project — execute, do not re-ask.** When the project's own CLAUDE.md or memory carries a durable grant — e.g. *"handoff at context threshold without asking"* — the proactive and soft-signal cases escalate to execute: the confirmation was given once, durably, and asking again is exactly the friction the grant exists to remove. The grant's scope is this one move — opening the successor session with the seeded brief. It never extends to publishing, deploying, or anything else the session might also want to do.

The grant has to live somewhere durable to exist at all. When the user grants it **in-session** — *"haz handoff cada vez que necesites, no me lo tienes que consultar"* — honor it for the session **and offer once to record it** in the project's CLAUDE.md (one line, theirs to delete). A grant that lives only in the conversation dies with it: one usage-retro window caught the same user re-dictating this grant seven times in three days across three projects, and sessions still closing with "¿lanzo el handoff?".

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

**The `slug:` line names the chain, and it is the only line the mechanism reads.** The
`SessionStart` hook takes it from the first five lines of the brief, prefixes the ordinal it
reads off `~/.claude/handoff-chains/`, and that becomes the session's title in the `--resume`
picker: `↻3 · Refactor auth`. Without it the new session is auto-titled after its first prompt —
which is the word *continue* — and a five-session chain renders as five identical rows.

Keep the chain's current slug unless the **subject** of the work changed. A new phase of the same
work is not a new subject: re-describing the chain at every link drifts its name once per hop,
which is exactly as unreadable as never changing it. In an unattended run the slug is not invented
at all — take it from the run's artifact (the plan, the loop-spec, the workflow-spec, the audit
run) and append the phase. That name already exists, it was written down before the first handoff,
and it is more stable than any phrasing produced per hop.

One line, and no ordinal of your own — the ordinal comes from the record, and a hand-written one
would be counted twice.

### The chain ledger — what the brief must stop carrying

A session in an established chain opens with a `=== CHAIN LEDGER ===` block above the brief.
It is not something a previous session re-typed: it is a per-chain file the `SessionStart` hook
renders with no model involved, and an item leaves it **only when a `CLOSE` delta closes it**.

That block exists because the brief cannot hold these things. The brief is re-drafted from
scratch at every hop, so it carries what the outgoing session happened to touch. Measured over
21 real links on 2026-08-22: a fact survives one hop 33% of the time, and the decay does not
care whether the fact was allowed to expire — items owed to the user survived **17%**, the worst
class of all. In one seven-link chain the "Owed by the owner" block travelled links 1 to 4 and
then vanished at link 5, unclosed and undecided; two links later nothing referenced it. And 6 of
those 21 links carried no drafted brief at all, because bare `handoff` seeds the transcript tail
with no model in the loop — so no rule written here can reach them. The ledger can, which is the
whole reason it is a file and not a better instruction.

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
| `TURN <text>` | The work changed direction — an approach dropped because something worked better, a problem found mid-execution, a decision taken on the fly. Not an obligation and nothing closes it; it renders in the chain's trajectory. |

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
none — but a session that settled an owed item and did not close it leaves the next six links
reading a question the user already answered.

Drafting rules:
- Be terse. Skip any section that adds nothing — **except `Next concrete step`**, which is never
  skipped.
- Zero filler, zero obvious explanations.
- If the user already provided a prompt, use it as-is — do not rewrite it.
- **State claims about the environment are cheap to re-check and expensive to get wrong —
  re-check them while drafting.** A brief is a claims artifact nobody verifies on arrival:
  in one 3-day window an arriving session had to correct its brief on the record ("dijo que
  'la BD de E2E no se tocó' — eso es falso"), a second brief assumed a UI button that did not
  exist, and a third scared the user about production over a fixture load. `git status`, a
  worktree list, a migration check cost seconds at draft time; mark anything not re-checked
  as ASSUMED so the next session verifies before repeating it to the user as fact.

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

**A recorded fork belongs in the ledger, not only in the brief.** `Next concrete step` is
re-drafted at the next hop and the fork survives exactly as long as some session happens
to re-type it — measured at 17% per hop, the worst-surviving class there is. `OPEN OWED`
survives until you answer it. Write it in both if the next step really is the fork; write
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

With the payload ready, run via Bash. Both checks are part of the block, not notes above it.

The first is the one you can guess: unset, every path below still runs and writes
`handoff-payload-`, `handoff-flag-` and `handoff-exit-` with an empty suffix — files no wrapper is
watching — and then reports success. The second is the one you cannot: the wrapper exports
`$CLAUDE_HANDOFF_ID` as its own PID, and **every descendant inherits it**, including sessions the
wrapper never launched and does not supervise — a `--fork-session`, a `--resume`, a harness
background job. There the variable is set and its wrapper is long dead, so a set/unset test passes
in exactly the case it exists to catch. What separates the two is ancestry, which is why the block
walks the parent chain.

```sh
if [ -z "$CLAUDE_HANDOFF_ID" ]; then
  echo "handoff: wrapper not detected. Launch claude via the shell function that claude-session-handoff installs." >&2
  exit 1
fi

# Same walk as handoff-prompt-hook.sh's is_wrapper_ancestor(): a set variable
# proves a wrapper ran somewhere up the tree, not that mine is still watching.
is_wrapper_ancestor() {
  _pid=$$
  while _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' '); [ -n "$_pid" ]; do
    case "$_pid" in
      0|1) return 1 ;;
    esac
    [ "$_pid" = "$CLAUDE_HANDOFF_ID" ] && return 0
  done
  return 1
}

if ! is_wrapper_ancestor; then
  echo "handoff: wrapper PID $CLAUDE_HANDOFF_ID is not an ancestor of this session (stale or inherited env var). Nothing was written and this session will not close." >&2
  exit 1
fi

mkdir -p "$HOME/.claude/tmp"

# The payload is conversation content. Claude Code stores transcripts 0600; the
# default umask would write this 0644, i.e. more readable than its source.
umask 077

# Ledger deltas. Same drop-a-file pattern as the payload, and for the same
# reason: this session knows neither its own id nor its chain, so it cannot key
# a ledger. The SessionStart hook — the one place chain identity exists — applies
# these. OMIT this whole cat when nothing changed; an empty delta is a no-op but
# a fabricated one is a lie that outlives the session.
DELTA_FILE="$HOME/.claude/tmp/handoff-ledger-$CLAUDE_HANDOFF_ID"
cat > "$DELTA_FILE" <<'__HANDOFF_DELTA_EOF__'
<ONE DELTA PER LINE — OPEN / CLOSE / TURN / CHARTER — OR OMIT THIS BLOCK ENTIRELY>
__HANDOFF_DELTA_EOF__

PAYLOAD_FILE="$HOME/.claude/tmp/handoff-payload-$CLAUDE_HANDOFF_ID"
FLAG_FILE="$HOME/.claude/tmp/handoff-flag-$CLAUDE_HANDOFF_ID"
EXIT_TRIGGER="$HOME/.claude/tmp/handoff-exit-$CLAUDE_HANDOFF_ID"

cat > "$PAYLOAD_FILE" <<'__HANDOFF_PAYLOAD_EOF__'
<THE HANDOFF PROMPT HERE>
__HANDOFF_PAYLOAD_EOF__

touch "$FLAG_FILE"
touch "$EXIT_TRIGGER"
```

Read the block's exit status before deciding what to say. Non-zero means it refused and printed
why: nothing was written, this session is not closing, and staying silent leaves the user watching
a handoff that never happened — the BL-024 failure. Report the reason in that same turn and stop.

Only on exit 0, having touched `$EXIT_TRIGGER`, do not emit any more output — the wrapper's watcher
will close this process within ~0.5s and launch the new session, so anything else is lost anyway.

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
