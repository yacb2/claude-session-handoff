#!/usr/bin/env python3
"""Reduce a Claude Code transcript to the prose a retro can read.

The chain ledger's write path has one hole: the deltas are written by the DYING
session, which needs its context live. After an hour away with a cold cache that
means re-sending the whole conversation to the largest model just to ask what
changed — and on the bare `handoff` paths no model runs at all, so nothing is
written.

The sequence that removes both costs is inverted: the handoff jumps first (free),
and the ARRIVING session runs a small agent over its predecessor's transcript,
from disk, before it continues. This file is what makes that affordable. A
transcript is mostly tool traffic — file contents read back, command output,
diffs — and none of it is what a retro needs. Measured on a real link: 2.8 MB of
transcript, 56 KB of prose, 1.9%. On the largest transcript on this machine
(260 MB) the same filter returns 0.9%.

It is mechanical on purpose. No model runs here, so this step costs nothing and
cannot itself hallucinate; the judgement happens one layer up, on the digest.

Usage:  handoff-retro-filter.py <transcript.jsonl> [--max-bytes N]

Writes the digest to stdout. Exits 1 with nothing on stdout when the transcript
is unreadable or holds no prose — the callers degrade to silence rather than
emitting a pointer to nothing.
"""

import json
import re
import sys

# A digest big enough to hold a working session's whole argument, small enough
# that a small model reads it in one request. 200 KB is roughly 50k tokens; the
# real digests measured land an order of magnitude under it, so this is a guard
# against a pathological session, not the operating point.
DEFAULT_MAX_BYTES = 200_000

# Text the harness injects into the conversation, not text anyone wrote. It is
# the largest single source of prose noise: reminders repeat verbatim on most
# turns, and a retro that reads them describes the harness instead of the work.
SYSTEM_REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
COMMAND_ENVELOPE = re.compile(
    r"<(command-name|command-message|command-args|local-command-stdout|"
    r"local-command-stderr|user-prompt-submit-hook)>.*?</\1>", re.S)

# The predecessor's own rendered ledger block, verbatim in its transcript —
# item ids and all. Stripping it is not tidiness: an agent reading `d2 OWED ...`
# in the digest is one step from writing `CLOSE d2`, and a close retires a real
# item permanently in the one mechanism whose stated property is that items
# leave only when something closes them. The block is regenerated for the
# arriving session anyway, so nothing is lost by cutting it here.
LEDGER_BLOCK = re.compile(
    r"=== CHAIN LEDGER ===.*?=== END CHAIN LEDGER ===", re.S)

ELISION = "\n[... middle of the session elided to fit the digest budget ...]\n"


def clean(text):
    if not text:
        return ""
    text = LEDGER_BLOCK.sub("", text)
    text = SYSTEM_REMINDER.sub("", text)
    text = COMMAND_ENVELOPE.sub("", text)
    # Collapse runs of blank lines left behind by the cuts above.
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def blocks_text(content):
    """Every text block on a line, whatever else the line carries.

    Deliberately NOT the sibling hook's predicate. `extract_last_reply` selects
    assistant lines carrying no tool_use, which is right for "the last reply"
    and wrong here: most of a working session's reasoning lives in text blocks
    on lines that DO carry a tool call, and dropping them would leave a digest
    of the session's small talk.
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for b in content:
        if isinstance(b, dict) and b.get("type") == "text":
            t = b.get("text")
            if isinstance(t, str):
                out.append(t)
    return "\n".join(out)


def extract(path):
    entries = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            # Subagent turns live in the same file under isSidechain. They are
            # a different conversation — the retro is about what THIS session
            # decided, and a subagent's internal chatter would outweigh it.
            if d.get("isSidechain"):
                continue
            kind = d.get("type")
            if kind not in ("user", "assistant"):
                continue
            msg = d.get("message")
            if not isinstance(msg, dict):
                continue
            text = clean(blocks_text(msg.get("content")))
            if not text:
                continue
            entries.append((kind, text))
    return entries


def render(entries, max_bytes):
    # Every line prefixed, so no line of the digest can be read as a delimiter
    # or as an instruction addressed to the reader. Same structural answer the
    # prompt hook uses on the transcript tail, and for the same reason: this
    # text is copied with no human in the loop and routinely quotes material
    # the session did not author.
    chunks = []
    for kind, text in entries:
        label = "OWNER" if kind == "user" else "SESSION"
        body = "\n".join("| " + ln for ln in text.split("\n"))
        chunks.append("--- %s ---\n%s" % (label, body))
    if not chunks:
        return ""

    doc = "\n\n".join(chunks)
    if len(doc.encode("utf-8")) <= max_bytes:
        return doc

    # Over budget: keep both ends. The head carries what the session set out to
    # do and the tail carries where it ended up, and a retro needs both — a
    # tail-only digest reports the last hour as if it were the session.
    half = max_bytes // 2
    head, head_n = [], 0
    for c in chunks:
        n = len(c.encode("utf-8")) + 2
        if head_n + n > half:
            break
        head.append(c)
        head_n += n
    tail, tail_n = [], 0
    for c in reversed(chunks[len(head):]):
        n = len(c.encode("utf-8")) + 2
        if tail_n + n > max_bytes - head_n:
            break
        tail.append(c)
        tail_n += n
    tail.reverse()
    dropped = len(chunks) - len(head) - len(tail)
    return "\n\n".join(head) + ELISION.replace(
        "middle of the session elided",
        "%d of %d turns elided from the middle" % (dropped, len(chunks))
    ) + "\n\n".join(tail)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: handoff-retro-filter.py <transcript.jsonl> "
                         "[--max-bytes N]\n")
        return 2
    path = argv[1]
    max_bytes = DEFAULT_MAX_BYTES
    if "--max-bytes" in argv:
        try:
            max_bytes = int(argv[argv.index("--max-bytes") + 1])
        except (IndexError, ValueError):
            sys.stderr.write("--max-bytes needs an integer\n")
            return 2
    if max_bytes < 1000:
        max_bytes = 1000
    try:
        entries = extract(path)
    except (IOError, OSError):
        return 1
    out = render(entries, max_bytes)
    if not out:
        return 1
    sys.stdout.write(out)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
