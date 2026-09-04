#!/usr/bin/env python3
"""Read-only census of Grok CLI session updates (turn_completed usage) + unified log inference_done."""
import os, sys, json, time, collections
ROOT = os.path.expanduser("~/.grok/sessions"); UNIFIED = os.path.expanduser("~/.grok/logs/unified.jsonl")
t0 = time.time()
files = 0; bytes_total = 0; lines_total = 0; sessions = 0; turn_completed = 0; sessions_with_usage = 0
by_model = collections.defaultdict(lambda: [0,0,0,0,0,0,0])  # turns, input, output, cachedRead, cacheCreation, reasoning, costTicks
by_day = collections.defaultdict(lambda: [0,0,0,0,0,0,0])
cumulative_evidence = {"turns_seen_multi": 0, "monotonic_sessions": 0, "non_monotonic_sessions": 0}
first_ts = None; last_ts = None; mtime_buckets = collections.Counter(); now = time.time()
for dirpath, dirnames, filenames in os.walk(ROOT):
    if "updates.jsonl" not in filenames: continue
    sessions += 1
    p = os.path.join(dirpath, "updates.jsonl")
    st = os.stat(p); files += 1; bytes_total += st.st_size
    age = now - st.st_mtime
    mtime_buckets["<1d" if age < 86400 else "<7d" if age < 7*86400 else "<30d" if age < 30*86400 else "older"] += 1
    turns = []
    with open(p, "rb") as f:
        for line in f:
            lines_total += 1
            if b'"turn_completed"' not in line or b'"usage"' not in line: continue
            try: obj = json.loads(line)
            except Exception: continue
            upd = ((obj.get("params") or {}).get("update") or {})
            if upd.get("sessionUpdate") != "turn_completed": continue
            usage = upd.get("usage") or {}
            ts = obj.get("timestamp")
            turns.append((ts, usage))
    if not turns: continue
    sessions_with_usage += 1; turn_completed += len(turns)
    if len(turns) > 1:
        cumulative_evidence["turns_seen_multi"] += 1
        tot = [u.get("totalTokens") or 0 for _, u in turns]
        if all(b >= a for a, b in zip(tot, tot[1:])): cumulative_evidence["monotonic_sessions"] += 1
        else: cumulative_evidence["non_monotonic_sessions"] += 1
    for ts, usage in turns:
        day = time.strftime("%Y-%m-%d", time.gmtime(ts)) if isinstance(ts, (int, float)) else "?"
        if isinstance(ts, (int,float)):
            first_ts = ts if first_ts is None else min(first_ts, ts); last_ts = ts if last_ts is None else max(last_ts, ts)
        mu = usage.get("modelUsage") or {"?": usage}
        for model, u in mu.items():
            vals = [1, u.get("inputTokens") or 0, u.get("outputTokens") or 0, u.get("cachedReadTokens") or 0, u.get("cacheCreationTokens") or 0, u.get("reasoningTokens") or 0, u.get("costUsdTicks") or 0]
            for agg in (by_model[model], by_day[day]):
                for i, v in enumerate(vals): agg[i] += v
# unified log cross-check
uni = collections.defaultdict(lambda: [0,0,0,0,0]); uni_first = None; uni_last = None; uni_lines = 0
if os.path.exists(UNIFIED):
    with open(UNIFIED, "rb") as f:
        for line in f:
            uni_lines += 1
            if b'"shell.turn.inference_done"' not in line: continue
            try: obj = json.loads(line)
            except Exception: continue
            ctx = obj.get("ctx") or {}; ts = obj.get("ts") or ""
            uni_first = ts if uni_first is None else min(uni_first, ts); uni_last = ts if uni_last is None else max(uni_last, ts)
            a = uni[ts[:10]]; a[0] += 1; a[1] += ctx.get("prompt_tokens") or 0; a[2] += ctx.get("cached_prompt_tokens") or 0; a[3] += ctx.get("completion_tokens") or 0; a[4] += ctx.get("reasoning_tokens") or 0
keys = ["turns","input","output","cachedRead","cacheCreation","reasoning","costUsdTicks"]
out = {"elapsed_s": round(time.time()-t0,1), "session_dirs": sessions, "updates_files": files, "bytes": bytes_total, "lines": lines_total,
  "sessions_with_usage": sessions_with_usage, "turn_completed_records": turn_completed, "cumulative_evidence": cumulative_evidence,
  "first_ts": first_ts, "last_ts": last_ts, "mtime_buckets": dict(mtime_buckets),
  "by_model": {k: dict(zip(keys, v)) for k,v in sorted(by_model.items())},
  "by_day": {k: dict(zip(keys, v)) for k,v in sorted(by_day.items())},
  "unified_log": {"lines": uni_lines, "first": uni_first, "last": uni_last, "by_day": {k: dict(zip(["calls","prompt","cached_prompt","completion","reasoning"], v)) for k,v in sorted(uni.items())}}}
json.dump(out, open(sys.argv[1], "w"), indent=1)
print(json.dumps({k:v for k,v in out.items() if k not in ("by_day",)}, indent=1))
