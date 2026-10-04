#!/usr/bin/env python3
"""Extract usage/token/cost stats from handoff chain ledgers + Claude Code transcripts.
Stdlib only. Maintainer readout, not installed by install.sh.

Usage: measure-chain-cost.py PROJECTS_DIR CHAINS_DIR OUTPUT_DIR
  PROJECTS_DIR  Claude Code transcripts, e.g. ~/.claude/projects
  CHAINS_DIR    handoff chain ledgers, e.g. ~/.claude/handoff-chains
  OUTPUT_DIR    where calls.csv, sessions.csv, chains.csv and
                chain_counterfactual.csv are written (created if missing)
"""
import json
import sys
import os
import csv
import glob
import datetime
from collections import defaultdict, Counter

if len(sys.argv) != 4:
    sys.exit(__doc__)
PROJECTS_DIR, CHAINS_DIR, SCRATCH = sys.argv[1:4]
os.makedirs(SCRATCH, exist_ok=True)

UNCHAINED_CUTOFF = datetime.datetime(2026, 8, 19, tzinfo=datetime.timezone.utc)
BASELINE_START = datetime.datetime(2026, 7, 1, tzinfo=datetime.timezone.utc)
BASELINE_END = datetime.datetime(2026, 8, 18, 23, 59, 59, tzinfo=datetime.timezone.utc)


def parse_ts(ts):
    if ts is None:
        return None
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        return datetime.datetime.fromisoformat(ts)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# 1. Load chain ledgers
# ---------------------------------------------------------------------------
ledger_links = []  # list of dicts: chain,n,slug,session,prev,wrapper,at,project_dir(from filename)
ledger_files = sorted(glob.glob(os.path.join(CHAINS_DIR, "*.jsonl")))

for lf in ledger_files:
    base = os.path.basename(lf)
    # project_dir key is filename minus ".jsonl"
    proj_key = base[:-len(".jsonl")]
    with open(lf, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            rec["_proj_key"] = proj_key
            ledger_links.append(rec)

# session -> ledger link info (last one wins if dup, but sessions should be unique per chain link)
session_to_ledger = {}
chain_max_n = defaultdict(int)
chain_slug_first = {}
chain_proj = {}
for rec in ledger_links:
    sess = rec.get("session")
    chain = rec.get("chain")
    n = rec.get("n")
    if sess:
        session_to_ledger[sess] = rec
    if chain:
        try:
            nn = int(n)
        except Exception:
            nn = 0
        if nn > chain_max_n[chain]:
            chain_max_n[chain] = nn
        if nn == 1:
            chain_slug_first[chain] = rec.get("slug", "")
            chain_proj[chain] = rec.get("_proj_key", "")
        chain_proj.setdefault(chain, rec.get("_proj_key", ""))

ledger_sessions_total = len(session_to_ledger)

# ---------------------------------------------------------------------------
# 2. Find all top-level transcript files (session-uuid.jsonl directly under a project dir)
#    and index subagent transcript files separately.
# ---------------------------------------------------------------------------
top_level_files = {}   # session_uuid -> (path, project_dir_name)
subagent_files = defaultdict(list)  # parent_session_uuid -> [paths]
subagent_layouts_found = set()

for proj_dir in sorted(glob.glob(os.path.join(PROJECTS_DIR, "*"))):
    if not os.path.isdir(proj_dir):
        continue
    proj_name = os.path.basename(proj_dir)
    for entry in sorted(glob.glob(os.path.join(proj_dir, "*.jsonl"))):
        if "/subagents/" in entry:
            continue
        sess_uuid = os.path.basename(entry)[:-len(".jsonl")]
        # only accept if looks like a uuid (36 chars with dashes) - session transcripts
        if len(sess_uuid) == 36 and sess_uuid.count("-") == 4:
            top_level_files[sess_uuid] = (entry, proj_name)
    # look for subagent dirs anywhere under this project dir (session-uuid/subagents/*)
    for sub_glob in glob.glob(os.path.join(proj_dir, "*", "subagents", "*.jsonl")):
        # path: proj_dir/<session-uuid>/subagents/<file>.jsonl
        parts = sub_glob.split(os.sep)
        try:
            idx = parts.index("subagents")
            parent_sess = parts[idx - 1]
        except ValueError:
            continue
        subagent_files[parent_sess].append(sub_glob)
        subagent_layouts_found.add("<proj>/<session-uuid>/subagents/*.jsonl")
    # also check deeper: proj_dir/**/subagents/*.jsonl already covered by glob with one level;
    # try a broader recursive search in case nesting differs
    for sub_glob in glob.glob(os.path.join(proj_dir, "**", "subagents", "*.jsonl"), recursive=True):
        parts = sub_glob.split(os.sep)
        try:
            idx = parts.index("subagents")
            parent_sess = parts[idx - 1]
        except ValueError:
            continue
        if sub_glob not in subagent_files[parent_sess]:
            subagent_files[parent_sess].append(sub_glob)
            subagent_layouts_found.add("<proj>/.../<session-uuid>/subagents/*.jsonl")

transcripts_scanned = len(top_level_files)

# ---------------------------------------------------------------------------
# 3. Determine cohort membership
# ---------------------------------------------------------------------------
# match ledger sessions by uuid filename (already done via session_to_ledger keys)
ledger_links_no_transcript = []
for sess in session_to_ledger:
    if sess not in top_level_files:
        ledger_links_no_transcript.append(sess)

# get first timestamp per top-level transcript (fast scan of first few lines)
def get_first_last_ts(path):
    first_ts = None
    last_ts = None
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ts = rec.get("timestamp")
                if ts:
                    dt = parse_ts(ts)
                    if dt:
                        if first_ts is None:
                            first_ts = dt
                        last_ts = dt
    except Exception:
        pass
    return first_ts, last_ts

# We need first_ts for: (a) sessions not in ledger, to check unchained_recent cutoff
# (b) baseline candidates in date window.
# To determine cohort for ALL top-level sessions, compute first_ts for those not already
# guaranteed by ledger membership if within date logic needed. We compute for all - cheap enough since just need timestamps not full parse re-cost (we'll do full parse once and reuse cache).

first_ts_cache = {}
last_ts_cache = {}

def ensure_ts(sess):
    if sess in first_ts_cache:
        return first_ts_cache[sess], last_ts_cache[sess]
    path, _ = top_level_files[sess]
    f, l = get_first_last_ts(path)
    first_ts_cache[sess] = f
    last_ts_cache[sess] = l
    return f, l

# Assistant call count for baseline candidate ranking - need full parse anyway later;
# but for selecting the 5 baseline_old sessions we need counts BEFORE full processing.
# We'll do a lightweight pre-pass: count assistant lines with usage (not deduped) as a proxy,
# then do full processing on selected transcripts. Actually we need full processing on ALL
# matched cohort sessions anyway (chained + unchained_recent + baseline_old). Baseline_old
# candidates: all sessions NOT already in ledger, with first_ts in [BASELINE_START,BASELINE_END].
# We must rank ALL such candidates by assistant-call count to pick top 5 - requires scanning
# all of them once for counts. Given transcripts_scanned likely modest, do it directly.

candidate_baseline = []
unchained_recent_sessions = []
chained_or_single_sessions = set(session_to_ledger.keys()) & set(top_level_files.keys())

for sess, (path, proj_name) in top_level_files.items():
    if sess in session_to_ledger:
        continue  # already ledger-covered
    f, l = ensure_ts(sess)
    if f is None:
        continue
    if f >= UNCHAINED_CUTOFF:
        unchained_recent_sessions.append(sess)
    elif BASELINE_START <= f <= BASELINE_END:
        candidate_baseline.append(sess)

# count assistant calls (deduped by message.id) for baseline candidates to rank top 5
def count_assistant_calls(path):
    seen = {}
    order = []
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "assistant":
                    continue
                if rec.get("isSidechain"):
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage")
                if not usage:
                    continue
                mid = msg.get("id")
                if mid is None:
                    continue
                if mid not in seen:
                    order.append(mid)
                seen[mid] = True
    except Exception:
        pass
    return len(order)

baseline_counts = []
for sess in candidate_baseline:
    path, _ = top_level_files[sess]
    c = count_assistant_calls(path)
    baseline_counts.append((c, sess))

baseline_counts.sort(key=lambda x: -x[0])
baseline_old_sessions = [s for c, s in baseline_counts[:5]]
baseline_old_info = baseline_counts[:5]  # (count, sess)

# Build full set of sessions to fully process
sessions_to_process = set(chained_or_single_sessions) | set(unchained_recent_sessions) | set(baseline_old_sessions)

def cohort_for(sess):
    if sess in session_to_ledger:
        rec = session_to_ledger[sess]
        chain = rec.get("chain")
        if chain_max_n.get(chain, 0) >= 2:
            return "chained"
        else:
            return "chain_single"
    if sess in unchained_recent_sessions:
        return "unchained_recent"
    if sess in baseline_old_sessions:
        return "baseline_old"
    return "unknown"

# ---------------------------------------------------------------------------
# 4. Brief files: <proj_key>.<session>.brief bytes
# ---------------------------------------------------------------------------
brief_bytes_by_session = {}
for bf in glob.glob(os.path.join(CHAINS_DIR, "*.brief")):
    base = os.path.basename(bf)
    # format: <proj_key>.<session-uuid>.brief
    name = base[:-len(".brief")]
    parts = name.rsplit(".", 1)
    if len(parts) == 2:
        sess = parts[1]
        try:
            size = os.path.getsize(bf)
        except Exception:
            size = 0
        brief_bytes_by_session[sess] = brief_bytes_by_session.get(sess, 0) + size

sessions_with_brief = sum(1 for s in sessions_to_process if s in brief_bytes_by_session)

# ---------------------------------------------------------------------------
# 5. Full per-call processing for sessions_to_process (main series)
#    plus subagent aggregation for those parent sessions.
# ---------------------------------------------------------------------------

MODEL_DEFAULT_CC_5M_WEIGHT = 1.25  # fallback multiplier when no cc breakdown


def cost_of(input_t, cache_read, cc_1h, cc_5m, output_t, cc_total, has_breakdown):
    if has_breakdown:
        return (1.0 * input_t + 0.1 * cache_read + 2.0 * cc_1h + 1.25 * cc_5m + 5.0 * output_t)
    else:
        return (1.0 * input_t + 0.1 * cache_read + 1.25 * cc_total + 5.0 * output_t)


assistant_lines_read = 0
lines_dropped_dedupe = 0
sidechain_lines_skipped = 0

calls_rows = []  # for calls.csv
session_agg = {}  # session -> dict of aggregates
chain_link_final_context = defaultdict(dict)  # chain -> {n: final_context}

for sess in sessions_to_process:
    path, proj_name = top_level_files[sess]
    ledger_rec = session_to_ledger.get(sess)
    chain = ledger_rec.get("chain") if ledger_rec else ""
    n = ledger_rec.get("n") if ledger_rec else ""
    slug = ledger_rec.get("slug", "") if ledger_rec else ""
    cohort = cohort_for(sess)

    # first pass: read all lines, keep last per message.id, track order of first appearance
    last_by_id = {}
    order_of_first_seen = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "assistant":
                continue
            if rec.get("isSidechain"):
                sidechain_lines_skipped += 1
                continue
            msg = rec.get("message") or {}
            usage = msg.get("usage")
            if not usage:
                continue
            assistant_lines_read += 1
            mid = msg.get("id")
            if mid is None:
                continue
            if mid not in last_by_id:
                order_of_first_seen.append(mid)
            else:
                lines_dropped_dedupe += 1
            last_by_id[mid] = rec  # keep last (overwritten each time -> final is last line seen)

    # chronological order: sort by timestamp of the kept (last) record; fall back to first-seen order
    def sort_key(mid):
        rec = last_by_id[mid]
        ts = parse_ts(rec.get("timestamp"))
        return ts or datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)

    ordered_ids = sorted(order_of_first_seen, key=sort_key)

    prev_ts = None
    prev_context = None
    position = 0

    calls = 0
    sum_input = sum_cache_read = sum_cache_creation = sum_output = 0
    sum_cost = 0.0
    contexts = []
    model_counter = Counter()
    n_gap = 0
    n_compact = 0
    first_ts = None
    last_ts = None
    final_context = None

    for mid in ordered_ids:
        rec = last_by_id[mid]
        msg = rec.get("message") or {}
        usage = msg.get("usage") or {}
        model = msg.get("model", "")
        ts = parse_ts(rec.get("timestamp"))

        input_t = usage.get("input_tokens", 0) or 0
        cache_read = usage.get("cache_read_input_tokens", 0) or 0
        cache_creation = usage.get("cache_creation_input_tokens", 0) or 0
        output_t = usage.get("output_tokens", 0) or 0
        cc_detail = usage.get("cache_creation")
        if isinstance(cc_detail, dict):
            cc_1h = cc_detail.get("ephemeral_1h_input_tokens", 0) or 0
            cc_5m = cc_detail.get("ephemeral_5m_input_tokens", 0) or 0
            has_breakdown = True
        else:
            cc_1h = 0
            cc_5m = 0
            has_breakdown = False

        context = input_t + cache_read + cache_creation
        cost = cost_of(input_t, cache_read, cc_1h, cc_5m, output_t, cache_creation, has_breakdown)

        position += 1
        is_first_call = 1 if position == 1 else 0
        if prev_ts is None:
            gap_gt_1h = 1
        else:
            gap_gt_1h = 1 if (ts and prev_ts and (ts - prev_ts).total_seconds() > 3600) else 0

        compact_drop = 0
        if prev_context is not None and prev_context > 50000 and context < 0.5 * prev_context:
            compact_drop = 1

        calls_rows.append({
            "project_dir": proj_name,
            "session": sess,
            "chain": chain,
            "n": n,
            "slug": slug,
            "position": position,
            "ts": rec.get("timestamp", ""),
            "model": model,
            "input": input_t,
            "cache_read": cache_read,
            "cache_creation": cache_creation,
            "cc_1h": cc_1h,
            "cc_5m": cc_5m,
            "output": output_t,
            "context": context,
            "cost": round(cost, 4),
            "is_first_call": is_first_call,
            "gap_gt_1h": gap_gt_1h,
            "compact_drop": compact_drop,
            "cohort": cohort,
        })

        calls += 1
        sum_input += input_t
        sum_cache_read += cache_read
        sum_cache_creation += cache_creation
        sum_output += output_t
        sum_cost += cost
        contexts.append(context)
        if model:
            model_counter[model] += 1
        if gap_gt_1h:
            n_gap += 1
        if compact_drop:
            n_compact += 1
        if first_ts is None:
            first_ts = rec.get("timestamp", "")
        last_ts = rec.get("timestamp", "")
        final_context = context

        prev_ts = ts
        prev_context = context

    model_main = model_counter.most_common(1)[0][0] if model_counter else ""

    # subagent aggregation
    sub_calls = 0
    sub_cost = 0.0
    for sub_path in subagent_files.get(sess, []):
        last_by_id_sub = {}
        with open(sub_path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "assistant":
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage")
                if not usage:
                    continue
                mid = msg.get("id")
                if mid is None:
                    continue
                last_by_id_sub[mid] = rec
        for mid, rec in last_by_id_sub.items():
            msg = rec.get("message") or {}
            usage = msg.get("usage") or {}
            input_t = usage.get("input_tokens", 0) or 0
            cache_read = usage.get("cache_read_input_tokens", 0) or 0
            cache_creation = usage.get("cache_creation_input_tokens", 0) or 0
            output_t = usage.get("output_tokens", 0) or 0
            cc_detail = usage.get("cache_creation")
            if isinstance(cc_detail, dict):
                cc_1h = cc_detail.get("ephemeral_1h_input_tokens", 0) or 0
                cc_5m = cc_detail.get("ephemeral_5m_input_tokens", 0) or 0
                has_breakdown = True
            else:
                cc_1h = 0
                cc_5m = 0
                has_breakdown = False
            cost = cost_of(input_t, cache_read, cc_1h, cc_5m, output_t, cache_creation, has_breakdown)
            sub_calls += 1
            sub_cost += cost

    brief_bytes = brief_bytes_by_session.get(sess, 0)

    session_agg[sess] = {
        "session": sess,
        "project_dir": proj_name,
        "chain": chain,
        "n": n,
        "slug": slug,
        "cohort": cohort,
        "model_main": model_main,
        "first_ts": first_ts or "",
        "last_ts": last_ts or "",
        "calls": calls,
        "sum_input": sum_input,
        "sum_cache_read": sum_cache_read,
        "sum_cache_creation": sum_cache_creation,
        "sum_output": sum_output,
        "sum_cost": round(sum_cost, 4),
        "mean_context": round(sum(contexts) / len(contexts), 2) if contexts else 0,
        "max_context": max(contexts) if contexts else 0,
        "final_context": final_context if final_context is not None else 0,
        "n_gap_gt_1h": n_gap,
        "n_compact_drop": n_compact,
        "subagent_calls": sub_calls,
        "subagent_cost": round(sub_cost, 4),
        "brief_bytes": brief_bytes,
    }

    if chain and n != "":
        try:
            nn = int(n)
        except Exception:
            nn = n
        chain_link_final_context[chain][nn] = final_context if final_context is not None else 0

# ---------------------------------------------------------------------------
# 6. Write calls.csv
# ---------------------------------------------------------------------------
calls_csv_path = os.path.join(SCRATCH, "calls.csv")
with open(calls_csv_path, "w", newline="") as fh:
    fieldnames = ["project_dir", "session", "chain", "n", "slug", "position", "ts", "model",
                  "input", "cache_read", "cache_creation", "cc_1h", "cc_5m", "output",
                  "context", "cost", "is_first_call", "gap_gt_1h", "compact_drop", "cohort"]
    w = csv.DictWriter(fh, fieldnames=fieldnames)
    w.writeheader()
    for row in calls_rows:
        w.writerow(row)

# ---------------------------------------------------------------------------
# 7. Write sessions.csv
# ---------------------------------------------------------------------------
sessions_csv_path = os.path.join(SCRATCH, "sessions.csv")
with open(sessions_csv_path, "w", newline="") as fh:
    fieldnames = ["session", "project_dir", "chain", "n", "slug", "cohort", "model_main",
                  "first_ts", "last_ts", "calls", "sum_input", "sum_cache_read",
                  "sum_cache_creation", "sum_output", "sum_cost", "mean_context", "max_context",
                  "final_context", "n_gap_gt_1h", "n_compact_drop", "subagent_calls",
                  "subagent_cost", "brief_bytes"]
    w = csv.DictWriter(fh, fieldnames=fieldnames)
    w.writeheader()
    for sess, row in session_agg.items():
        w.writerow(row)

# ---------------------------------------------------------------------------
# 8. Write chains.csv
# ---------------------------------------------------------------------------
chain_agg = defaultdict(lambda: {
    "links": 0, "total_calls": 0, "total_cost": 0.0, "total_cost_with_subagents": 0.0,
    "sum_final_context_of_links": 0, "sum_brief_bytes": 0, "max_link_calls": 0,
    "first_ts": None, "last_ts": None,
})

for sess, row in session_agg.items():
    chain = row["chain"]
    if not chain:
        continue
    ca = chain_agg[chain]
    ca["links"] += 1
    ca["total_calls"] += row["calls"]
    ca["total_cost"] += row["sum_cost"]
    ca["total_cost_with_subagents"] += row["sum_cost"] + row["subagent_cost"]
    ca["sum_final_context_of_links"] += row["final_context"]
    ca["sum_brief_bytes"] += row["brief_bytes"]
    ca["max_link_calls"] = max(ca["max_link_calls"], row["calls"])
    ft = row["first_ts"]
    lt = row["last_ts"]
    if ft:
        if ca["first_ts"] is None or ft < ca["first_ts"]:
            ca["first_ts"] = ft
    if lt:
        if ca["last_ts"] is None or lt > ca["last_ts"]:
            ca["last_ts"] = lt

chains_csv_path = os.path.join(SCRATCH, "chains.csv")
with open(chains_csv_path, "w", newline="") as fh:
    fieldnames = ["chain", "project_dir", "slug_first", "links", "total_calls", "total_cost",
                  "total_cost_with_subagents", "sum_final_context_of_links", "sum_brief_bytes",
                  "max_link_calls", "first_ts", "last_ts"]
    w = csv.DictWriter(fh, fieldnames=fieldnames)
    w.writeheader()
    for chain, ca in chain_agg.items():
        w.writerow({
            "chain": chain,
            "project_dir": chain_proj.get(chain, ""),
            "slug_first": chain_slug_first.get(chain, ""),
            "links": ca["links"],
            "total_calls": ca["total_calls"],
            "total_cost": round(ca["total_cost"], 4),
            "total_cost_with_subagents": round(ca["total_cost_with_subagents"], 4),
            "sum_final_context_of_links": ca["sum_final_context_of_links"],
            "sum_brief_bytes": ca["sum_brief_bytes"],
            "max_link_calls": ca["max_link_calls"],
            "first_ts": ca["first_ts"] or "",
            "last_ts": ca["last_ts"] or "",
        })

# ---------------------------------------------------------------------------
# 9. Write chain_counterfactual.csv
#    Only for chained sessions (chain in ledger). global_position = chronological
#    order across the chain (by link n, then by call position within link).
# ---------------------------------------------------------------------------
cf_rows = []
# group calls_rows by chain for chained sessions only
by_chain_calls = defaultdict(list)
for row in calls_rows:
    if row["chain"] and row["cohort"] in ("chained", "chain_single"):
        by_chain_calls[row["chain"]].append(row)

for chain, rows in by_chain_calls.items():
    # sort by (n, position)
    def keyfn(r):
        try:
            nn = int(r["n"])
        except Exception:
            nn = 0
        return (nn, r["position"])
    rows_sorted = sorted(rows, key=keyfn)
    links_final_ctx = chain_link_final_context.get(chain, {})
    gpos = 0
    for r in rows_sorted:
        gpos += 1
        try:
            nn = int(r["n"])
        except Exception:
            nn = 0
        cf_extra_context = sum(v for k, v in links_final_ctx.items() if k < nn)
        actual_cache_read = r["cache_read"]
        actual_cost = r["cost"]
        cf_cache_read = actual_cache_read + cf_extra_context
        cf_cost = actual_cost + 0.1 * cf_extra_context
        cf_rows.append({
            "chain": chain,
            "n": r["n"],
            "position": r["position"],
            "global_position": gpos,
            "actual_cache_read": actual_cache_read,
            "actual_cost": actual_cost,
            "cf_extra_context": cf_extra_context,
            "cf_cache_read": cf_cache_read,
            "cf_cost": round(cf_cost, 4),
        })

cf_csv_path = os.path.join(SCRATCH, "chain_counterfactual.csv")
with open(cf_csv_path, "w", newline="") as fh:
    fieldnames = ["chain", "n", "position", "global_position", "actual_cache_read",
                  "actual_cost", "cf_extra_context", "cf_cache_read", "cf_cost"]
    w = csv.DictWriter(fh, fieldnames=fieldnames)
    w.writeheader()
    for row in cf_rows:
        w.writerow(row)

# ---------------------------------------------------------------------------
# 10. Print report
# ---------------------------------------------------------------------------
cohort_counts = Counter(row["cohort"] for row in session_agg.values())

all_first_ts = [row["first_ts"] for row in session_agg.values() if row["first_ts"]]
all_last_ts = [row["last_ts"] for row in session_agg.values() if row["last_ts"]]
date_min = min(all_first_ts) if all_first_ts else "N/A"
date_max = max(all_last_ts) if all_last_ts else "N/A"

print("=== TRANSCRIPTS ===")
print(f"transcripts_scanned (top-level .jsonl found across all project dirs): {transcripts_scanned}")
print(f"transcripts matched per cohort (sessions fully processed): {dict(cohort_counts)}")
print(f"total sessions fully processed: {len(session_agg)}")
print()
print("=== LEDGER ===")
print(f"ledger links total (unique sessions referenced in *.jsonl ledgers): {ledger_sessions_total}")
print(f"ledger links with NO transcript found: {len(ledger_links_no_transcript)}")
if ledger_links_no_transcript:
    print("  session ids with no transcript:")
    for s in ledger_links_no_transcript:
        print(f"    {s}")
print()
print("=== ASSISTANT LINES ===")
print(f"assistant lines read (had type=assistant and message.usage, non-sidechain, across all fully-processed sessions): {assistant_lines_read}")
print(f"lines dropped by dedupe (same message.id seen again): {lines_dropped_dedupe}")
print(f"sidechain lines skipped: {sidechain_lines_skipped}")
print()
print("=== SUBAGENTS ===")
if subagent_layouts_found:
    print(f"subagent layout(s) found: {sorted(subagent_layouts_found)}")
else:
    print("subagent layout found: NONE (no */subagents/*.jsonl paths located)")
total_subagent_files = sum(len(v) for v in subagent_files.values())
parents_with_subagents_processed = sum(1 for s in sessions_to_process if s in subagent_files)
print(f"subagent transcript files found total: {total_subagent_files} (across {len(subagent_files)} parent sessions)")
print(f"subagent files summed into fully-processed parent sessions: {sum(len(subagent_files.get(s, [])) for s in sessions_to_process)} (parents: {parents_with_subagents_processed})")
print()
print("=== BRIEFS ===")
print(f"sessions (among fully-processed) with a brief file found: {sessions_with_brief}")
print()
print("=== DATE RANGE ===")
print(f"date range covered (min first_ts .. max last_ts across fully-processed sessions): {date_min} .. {date_max}")
print()
print("=== BASELINE_OLD (5 largest transcripts by assistant-call count, first_ts in 2026-07-01..2026-08-18, unchained) ===")
for c, s in baseline_old_info:
    f, _ = ensure_ts(s) if s in first_ts_cache else (None, None)
    print(f"  session={s} calls={c} first_ts={first_ts_cache.get(s)}")
print()
print("=== OUTPUT FILES ===")
print(f"calls.csv: {calls_csv_path} ({len(calls_rows)} rows)")
print(f"sessions.csv: {sessions_csv_path} ({len(session_agg)} rows)")
print(f"chains.csv: {chains_csv_path} ({len(chain_agg)} rows)")
print(f"chain_counterfactual.csv: {cf_csv_path} ({len(cf_rows)} rows)")
