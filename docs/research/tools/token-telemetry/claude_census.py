#!/usr/bin/env python3
"""Read-only census of Claude Code transcripts for token-telemetry research."""
import os, sys, json, time, collections
ROOT = os.path.expanduser("~/.claude/projects")
PRUNE = {"tool-results"}
t0 = time.time()
files = 0; bytes_total = 0; lines_total = 0; assistant_records = 0
distinct_msgs = 0; inconsistent_usage_ids = 0; synthetic = 0; error_records = 0
no_id = 0; sidechain_msgs = 0; subagent_files = 0
by_model = collections.defaultdict(lambda: [0,0,0,0,0])  # msgs, in, out, cc, cr
by_day = collections.defaultdict(lambda: [0,0,0,0,0])
by_day_records = collections.Counter()
by_error = collections.Counter()
per_file_msgs = []
first_ts = None; last_ts = None
thinking_tokens = 0
naive_out = 0; naive_in = 0
mtime_buckets = collections.Counter()
now = time.time()
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in PRUNE]
    for fn in filenames:
        if not fn.endswith(".jsonl"): continue
        p = os.path.join(dirpath, fn)
        try: st = os.stat(p)
        except OSError: continue
        files += 1; bytes_total += st.st_size
        age = now - st.st_mtime
        mtime_buckets["<1d" if age < 86400 else "<7d" if age < 7*86400 else "<30d" if age < 30*86400 else "older"] += 1
        if "/subagents/" in p: subagent_files += 1
        msgs = {}  # id -> (model, usage tuple, ts, sidechain)
        inconsistent_local = set()
        with open(p, "rb") as f:
            for line in f:
                lines_total += 1
                if b'"type":"assistant"' not in line: continue
                try: obj = json.loads(line)
                except Exception: continue
                if obj.get("type") != "assistant": continue
                assistant_records += 1
                msg = obj.get("message") or {}
                model = msg.get("model") or "?"
                usage = msg.get("usage") or {}
                u = (usage.get("input_tokens") or 0, usage.get("output_tokens") or 0,
                     usage.get("cache_creation_input_tokens") or 0, usage.get("cache_read_input_tokens") or 0)
                naive_in += u[0] + u[2] + u[3]; naive_out += u[1]
                if obj.get("error"):
                    error_records += 1; by_error[obj.get("error")] += 1
                if model == "<synthetic>":
                    synthetic += 1; continue
                mid = msg.get("id") or obj.get("requestId")
                if not mid:
                    no_id += 1; mid = obj.get("uuid")
                ts = obj.get("timestamp") or ""
                th = ((usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0)
                prev = msgs.get(mid)
                if prev is None:
                    msgs[mid] = [model, u, ts, bool(obj.get("isSidechain")), th]
                else:
                    if prev[1] != u: inconsistent_local.add(mid)
                    if u[1] > prev[1][1]: prev[1] = u; prev[4] = th
        inconsistent_usage_ids += len(inconsistent_local)
        per_file_msgs.append(len(msgs))
        for mid, (model, u, ts, side, th) in msgs.items():
            distinct_msgs += 1
            if side: sidechain_msgs += 1
            thinking_tokens += th
            day = ts[:10]
            if ts:
                if first_ts is None or ts < first_ts: first_ts = ts
                if last_ts is None or ts > last_ts: last_ts = ts
            for agg in (by_model[model], by_day[day]):
                agg[0] += 1; agg[1] += u[0]; agg[2] += u[1]; agg[3] += u[2]; agg[4] += u[3]
elapsed = time.time() - t0
out = {
  "elapsed_s": round(elapsed,1), "files": files, "subagent_files": subagent_files, "bytes": bytes_total,
  "lines": lines_total, "assistant_records": assistant_records, "distinct_messages": distinct_msgs,
  "records_per_message": round(assistant_records/max(distinct_msgs,1),2),
  "ids_with_inconsistent_usage": inconsistent_usage_ids, "synthetic_records": synthetic,
  "error_records": error_records, "errors": dict(by_error), "no_id": no_id,
  "sidechain_messages": sidechain_msgs, "thinking_tokens": thinking_tokens,
  "naive_sum_input_all_kinds": naive_in, "naive_sum_output": naive_out,
  "first_ts": first_ts, "last_ts": last_ts, "mtime_buckets": dict(mtime_buckets),
  "per_file_msgs_max": max(per_file_msgs or [0]), "files_with_zero_msgs": sum(1 for x in per_file_msgs if x==0),
  "by_model": {k: dict(zip(["msgs","input","output","cache_creation","cache_read"], v)) for k,v in sorted(by_model.items())},
  "by_day": {k: dict(zip(["msgs","input","output","cache_creation","cache_read"], v)) for k,v in sorted(by_day.items())},
}
json.dump(out, open(sys.argv[1], "w"), indent=1)
print(json.dumps({k:v for k,v in out.items() if k not in ("by_day",)}, indent=1))
