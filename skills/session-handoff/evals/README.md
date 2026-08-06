# What these eval sets measure — and what they do not

Two sets, scored by `tests/eval-pty.sh` against the **installed** skill
(`~/.claude/skills/session-handoff/SKILL.md`, never the repo copy — run `./install.sh` first).

| Set | Entries | Purpose |
|---|---|---|
| `trigger-eval.json` | 33 | The main set: all three behaviours, mostly Spanish and English |
| `trigger-eval-multilang.json` | 16 | The same policy expressed in German, Italian, Japanese and Chinese |

## Schema

Each entry is `{ "query": …, "expect": "execute" \| "propose" \| "ignore" }`, plus an optional
`why` naming the SKILL.md branch that decides it. `expect` is **not** a boolean: it encodes which
of the skill's three behaviours is correct, because a query the skill must *propose* on scored FAIL
for behaving correctly under the old boolean schema.

`tests/hook-guard.sh` validates `expect` (Case G) and asserts no query would trip the
`UserPromptSubmit` hook by itself (Case F). `eval-pty.sh` reads only `query` and `expect`; extra
keys such as `why` are ignored by both.

## A green run does NOT cover the "Mandated by a running process" case

SKILL.md carries five trigger cases. Four are measured here. The fifth — an unattended run
reaching its handoff step, where the skill must execute and must **not** ask — has **zero
coverage**, and `eval-pty.sh` cannot give it any: the harness spawns one conversational session per
query, so the precondition (an unattended run in flight) never holds.

`trigger-eval.json`'s entry 32 looks close but is not it: a user *reporting* that the plan says to
hand off is a Direct ask, which the tie-break already resolves.

So a 100% run means "the four conversational cases held", not "the policy is covered". Testing the
fifth needs a different harness — one that runs the skill inside an actual `aidex-plan-exec` or
loop — and none exists.

## Four entries measure the precondition, not the trigger

`trigger-eval.json` entries 5, 8, 12 and 29 refer to context the harness never supplies —
"con **este contexto**", "ya quedó cerrada **la fase 1**", "**the plan** we just agreed on".
Every unit is a **fresh** session whose first message is the query, so there is no such context.

Turn-1 transcripts show the model routing correctly and then asking for the missing material —
*"I don't have access to the previous conversation where the plan was agreed on … Could you
paste the plan? I'll draft the handoff prompt and fire the new session immediately"* — including
the zero-token `handoff:` path. It declines to invent a brief about work it cannot see.

So their scores are about the precondition, not the trigger. The split is visible across the
whole set: entries that **carry** their context pass (entry 2 names the repo and the bug and
scores 3/3); entries that merely **point at** it fail. All four now carry a `why` saying so, so
a future 0/3 does not get diagnosed as a SKILL.md defect the way this one nearly was.

They were deliberately **not** rewritten to carry their context. "Keep the plan we just agreed
on" is how people actually ask; a version that recites its own referent is a sentence nobody
types, and the set would lose its only coverage of implicit reference while gaining a number
that looks better.

**So implicit reference is a second known-uncovered shape**, alongside the "Mandated by a
running process" case above. Covering it needs the harness to establish context before sending
the query — a priming turn — which re-baselines every entry, not just these four. Until then,
four of 33 entries in the main set measure the precondition, and the headline rate carries them
at face value.

## Five entries measure comprehension, not policy

`trigger-eval.json` entries 21, 22, 25, 26 and 31 — "hand off this task to the code-reviewer
subagent", "delegate this to another agent", "dame un prompt corto para el issue tracker", "give me
a prompt I can use for ChatGPT", "transferí el ticket a Maria" — are lexical collisions on
*handoff*, *prompt* and *transfer*. They score `ignore` because the model understands the domain
object, not because any rule in SKILL.md excludes them.

That is deliberate: the `Do NOT use` list should not grow a bullet per homonym. But it means a
regression in those five is a comprehension result, not a trigger-description problem — diagnose it
accordingly before editing the skill's prose.

## Reading a result

A single run is not a measurement. `eval-pty.sh` repeats every query (`--reps`, default 3) and
prints a **noise floor**; a before/after delta at or below it is not reportable, and variance is
never "fixed" with a retry-until-green loop (BL-010: two identical runs scored 6/6 then 5/6).

The run also prints **observed fire times**, which exist to earn a shorter timeout for the absence
arms rather than guess one (BL-014). Every `ignore` query and every `propose` turn 1 burns the full
`--timeout` by design — their pass condition *is* the flag never appearing — so an idle break there
would score `ok` for a query that was about to fire.
