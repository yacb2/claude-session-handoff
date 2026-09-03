#!/usr/bin/env python3
"""Mine real sessions for handoff requests and how the first reply handled them.

Why this exists: tests/eval-pty.sh measures the skill in FRESH sessions, and the
two misses that motivated BL-029 happened inside 200-300k-token sessions where
the harness cannot go. The transcripts under ~/.claude/projects/ are the only
record of how the skill triggers where it is actually used. This walks them,
finds every user turn that asks for a new session or a handoff, and classifies
the assistant's first reply — executed, proposed, refused, or something else —
plus whether the user's next turn reads as a correction.

Zero tokens; read-only. Not installed by install.sh; run from the repo:

    python3 scripts/mine-handoff-triggers.py [--since YYYY-MM-DD] [--json] [--misses]

A `corrected` row is the strongest miss signal: the user asked, the model did
not fire, and the user had to ask again. Every such row prints the exact
phrasing, which is what feeds skills/session-handoff/evals/trigger-eval.json.
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

ASK = re.compile(
    r"(inicia|iniciar|abre|abrir|abramos|arranca|empieza|empecemos|comienza|vamos a|pasemos a|mudarnos a|seguir en|sigamos en|"
    r"continuar en|continuemos en|hagamos|hacer|haz|has|lanza|lanzar|dispara|corre|ejecuta)\b[^.\n]{0,40}"
    r"(nueva\s+sesi[oó]n|otra\s+sesi[oó]n|sesi[oó]n\s+(nueva|limpia|fresca)|sesi[oó]n\s+en\s+limpio|(un\s+|el\s+)?(?<!session\s)hand\s?off)"
    r"|(start|open|spin up|move to|continue in|let'?s (start|go|move)|do|run|make|kick off)\b[^.\n]{0,40}"
    r"(new\s+session|fresh\s+session|clean\s+session|a\s+hand\s?off|the\s+hand\s?off)(?!\s+(skill|project|repo))"
    r"|\bhand\s?off\s+(this|the)\s+(session|conversation)"
    r"|(^|\s)hand\s?off\s*(,|\.|$|\s+(por\s+favor|porfa|please|y\s|and\s|para\s|to\s))"
    r"|traspaso\s+a\s+(una\s+)?(nueva\s+)?sesi[oó]n",
    re.I,
)
# Pasted skill bodies, slash-command expansions and review prompts mention these
# words without asking for anything.
NOISE = re.compile(r"^\s*(Base directory for this skill|# /handoff|Review this change|You previously flagged)"
                   r"|<command-message>|<cross-session-message|<task-notification>", re.I)
# Talking ABOUT a handoff that already happened or might happen is not asking
# for one: "acabo de hacer el handoff", "antes de hacer handoff, me gustaría".
MENTION = re.compile(r"(acabo de|hice|hiciste|hicimos|ya (hice|hicimos)|antes de|despu[eé]s de|luego de|podemos hacer|"
                     r"deber[ií]amos hacer|si hacemos|cuando hagas|when you|before (you|we)|after (you|we)|just did)"
                     r"\s+(hacer\s+)?(el\s+|un\s+|a\s+|the\s+)?hand\s?off", re.I)
# Zero-token path and slash command never reach the model; not a trigger event.
NOT_ASK = re.compile(r"^\s*(handoff:|/handoff|/restart|<command-name>|<local-command)", re.I)
REFUSAL = re.compile(
    r"no puedo (abrir|iniciar|lanzar|crear)|no tengo (ninguna )?(herramienta|forma|manera)"
    r"|\bcan(no|')t (open|start|launch)|i (do not|don't) have (a|any) (tool|way)|no (existe|hay) (ninguna )?herramienta",
    re.I,
)
PROPOSAL = re.compile(r"\?|¿", re.S)
CORRECTION = re.compile(r"tienes un skill|te ped[ií]|sigues sin|no tienes|otra vez|again|\bhand\s?off\b|sesi[oó]n|session", re.I)
FIRED = re.compile(r"handoff-flag-|EXIT_TRIGGER|handoff-payload-|handoff-exit-")


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    return "\n".join(b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text")


def is_user_prompt(row):
    if row.get("type") != "user":
        return False
    c = row.get("message", {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return False
    t = text_of(row.get("message", {}))
    if not t.strip() or t.lstrip().startswith("<system-reminder>"):
        return False
    if NOT_ASK.search(t) or NOISE.search(t) or len(t) > 1500:
        return False
    return True


def tool_uses(row):
    c = row.get("message", {}).get("content")
    if not isinstance(c, list):
        return []
    return [b for b in c if isinstance(b, dict) and b.get("type") == "tool_use"]


def classify(rows, i):
    """Look at the assistant turns after user row i, up to the next user prompt."""
    verdict = "other"
    texts = []
    model = ""
    ctx = 0
    version = rows[i].get("version", "")
    j = i + 1
    while j < len(rows) and not is_user_prompt(rows[j]):
        r = rows[j]
        if r.get("type") == "assistant":
            m = r.get("message", {})
            model = m.get("model") or model
            u = m.get("usage") or {}
            ctx = max(ctx, (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
                      + (u.get("cache_creation_input_tokens") or 0))
            for tu in tool_uses(r):
                if tu.get("name") == "Skill" and "session-handoff" in json.dumps(tu.get("input", {})):
                    return "executed", model, ctx, version, j
                if tu.get("name") == "Bash" and FIRED.search(json.dumps(tu.get("input", {}))):
                    return "executed", model, ctx, version, j
            texts.append(text_of(m))
        j += 1
    body = "\n".join(texts)
    if REFUSAL.search(body):
        verdict = "refused"
    elif ASK.search(body) and PROPOSAL.search(body):
        verdict = "proposed"
    return verdict, model, ctx, version, j


def scan(since):
    hits = []
    for path in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
        try:
            rows = [json.loads(l) for l in open(path, encoding="utf-8", errors="replace")]
        except (OSError, ValueError):
            continue
        project = os.path.basename(os.path.dirname(path))
        project = project[project.rfind("projects-") + 9:] if "projects-" in project else project
        sid = os.path.basename(path)[:8]
        first = next((text_of(r["message"]) for r in rows if is_user_prompt(r)), "")
        child = first.strip().lower() == "continue" or any(
            "handoff" in json.dumps(r.get("message", {}).get("content", ""))[:400].lower()
            for r in rows[:3] if r.get("type") == "user")
        for i, r in enumerate(rows):
            if not is_user_prompt(r):
                continue
            t = text_of(r["message"])
            m = ASK.search(t)
            if not m or MENTION.search(t):
                continue
            flat = " ".join(t.split())
            k = flat.lower().find(m.group(0).split()[0].lower())
            snippet = flat[max(0, k - 70):k + 110] if k >= 0 else flat[:180]
            ts = (r.get("timestamp") or "")[:16].replace("T", " ")
            if since and ts[:10] < since:
                continue
            verdict, model, ctx, version, nxt = classify(rows, i)
            corrected = False
            if nxt < len(rows) and verdict != "executed":
                corrected = bool(CORRECTION.search(text_of(rows[nxt]["message"])))
            hits.append({
                "ts": ts, "project": project, "session": sid, "child": child,
                "model": (model or "?").replace("claude-", ""), "ctx_k": ctx // 1000,
                "cc": version, "verdict": verdict, "corrected": corrected,
                "ask": snippet,
            })
    return hits


def bucket(k):
    return "<100k" if k < 100 else "100-200k" if k < 200 else ">200k"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="", help="YYYY-MM-DD")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--misses", action="store_true", help="only rows that did not execute")
    a = ap.parse_args()
    hits = sorted(scan(a.since), key=lambda h: h["ts"])
    if a.json:
        json.dump(hits, sys.stdout, ensure_ascii=False, indent=1)
        return
    shown = [h for h in hits if h["verdict"] != "executed"] if a.misses else hits
    for h in shown:
        flag = " CORRECTED" if h["corrected"] else ""
        print(f'{h["ts"]}  {h["project"]:<22} {h["session"]}  {h["model"]:<12} {h["ctx_k"]:>4}k  {h["cc"]:<8} '
              f'{"child" if h["child"] else "root ":5}  {h["verdict"]:<9}{flag}\n    {h["ask"]}')
    n = len(hits)
    if not n:
        print("no handoff requests found")
        return
    ex = sum(h["verdict"] == "executed" for h in hits)
    print(f"\n# requests: {n} · executed first try: {ex} ({100*ex//n}%) · "
          f'proposed: {sum(h["verdict"]=="proposed" for h in hits)} · refused: {sum(h["verdict"]=="refused" for h in hits)} · '
          f'other: {sum(h["verdict"]=="other" for h in hits)} · corrected by user: {sum(h["corrected"] for h in hits)}')
    for key, label in (("model", "model"), (None, "context"), ("cc", "claude code"), ("child", "session origin")):
        tally = defaultdict(Counter)
        for h in hits:
            k = bucket(h["ctx_k"]) if key is None else ("child" if h["child"] else "root") if key == "child" else h[key]
            tally[k][h["verdict"]] += 1
        print(f"# by {label}:")
        for k in sorted(tally):
            c = tally[k]
            tot = sum(c.values())
            print(f"    {str(k):<14} {c['executed']}/{tot} executed first try"
                  + (f", {c['refused']} refused" if c["refused"] else "")
                  + (f", {c['proposed']} proposed" if c["proposed"] else ""))


if __name__ == "__main__":
    main()
