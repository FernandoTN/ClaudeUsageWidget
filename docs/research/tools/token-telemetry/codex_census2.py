#!/usr/bin/env python3
"""Read-only census of Codex CLI rollout files (sessions + archived + isolated homes).
v2: per-key negative deltas are clamped to 0; only a DROP in total_tokens counts as a fresh counter."""
import os, sys, json, time, glob, collections
homes = [os.path.expanduser("~/.codex")] + sorted(glob.glob(os.path.expanduser("~/.codex-accounts/*")))
roots = []
for h in homes:
    for sub in ("sessions", "archived_sessions"):
        d = os.path.join(h, sub)
        if os.path.isdir(d): roots.append((h, sub, d))
t0 = time.time()
files = 0; bytes_total = 0; lines_total = 0; token_count_events = 0; events_with_info = 0
sessions_with_tokens = 0; total_drops = 0; delta_mismatch_sessions = 0
duplicate_total_events = 0; sessions_without_model = 0; multi_model_sessions = 0
neg_steps = collections.Counter()
KEYS = ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens")
by_model = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0])  # sessions, input, cached, output, reasoning, total
by_day = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0])
by_home = collections.Counter(); by_source = collections.Counter(); by_originator = collections.Counter()
first_ts = None; last_ts = None
mtime_buckets = collections.Counter(); now = time.time()
rate_limit_shapes = collections.Counter()
per_file_final = 0
for home, sub, root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".jsonl"): continue
            p = os.path.join(dirpath, fn)
            try: st = os.stat(p)
            except OSError: continue
            files += 1; bytes_total += st.st_size; by_home[os.path.basename(home) + "/" + sub] += 1
            age = now - st.st_mtime
            mtime_buckets["<1d" if age < 86400 else "<7d" if age < 7 * 86400 else "<30d" if age < 30 * 86400 else "older"] += 1
            models = []; cur_model = None
            totals = []
            with open(p, "rb") as f:
                for line in f:
                    lines_total += 1
                    if b'"token_count"' not in line and b'"session_meta"' not in line and b'"turn_context"' not in line: continue
                    try: obj = json.loads(line)
                    except Exception: continue
                    t = obj.get("type")
                    if t == "session_meta":
                        pl = obj.get("payload") or {}
                        by_source[str(pl.get("source") or "?")[:40]] += 1; by_originator[str(pl.get("originator") or "?")[:40]] += 1
                    elif t == "turn_context":
                        m = (obj.get("payload") or {}).get("model")
                        if m: cur_model = m; models.append(m)
                    elif t == "event_msg" and (obj.get("payload") or {}).get("type") == "token_count":
                        token_count_events += 1
                        info = obj["payload"].get("info") or None
                        rl = obj["payload"].get("rate_limits") or {}
                        if rl:
                            pw = (rl.get("primary") or {}).get("window_minutes"); sw = (rl.get("secondary") or {}).get("window_minutes")
                            rate_limit_shapes[f"primary={pw} secondary={sw}"] += 1
                        if not info: continue
                        events_with_info += 1
                        totals.append((obj.get("timestamp") or "", info.get("total_token_usage") or {}, info.get("last_token_usage") or {}, cur_model))
            if not totals: continue
            sessions_with_tokens += 1
            if not models: sessions_without_model += 1
            if len(set(models)) > 1: multi_model_sessions += 1
            per_file_final += max((tot.get("total_tokens") or 0) for _, tot, _, _ in totals)
            prev = None; sess_models = set()
            for ts, tot, last, m in totals:
                if prev is not None and (tot.get("total_tokens") or 0) == (prev.get("total_tokens") or 0):
                    duplicate_total_events += 1; continue
                d = {k: (tot.get(k) or 0) - ((prev or {}).get(k) or 0) for k in KEYS}
                if d["total_tokens"] < 0:
                    total_drops += 1
                    d = {k: (tot.get(k) or 0) for k in KEYS}
                else:
                    for k, v in d.items():
                        if v < 0: neg_steps[k] += 1
                    d = {k: max(0, v) for k, v in d.items()}
                prev = tot
                model = m or (models[0] if models else "?")
                sess_models.add(model)
                day = ts[:10]
                if ts:
                    if first_ts is None or ts < first_ts: first_ts = ts
                    if last_ts is None or ts > last_ts: last_ts = ts
                for agg in (by_model[model], by_day[day]):
                    agg[1] += d["input_tokens"]; agg[2] += d["cached_input_tokens"]; agg[3] += d["output_tokens"]; agg[4] += d["reasoning_output_tokens"]; agg[5] += d["total_tokens"]
            for m in sess_models: by_model[m][0] += 1
            sum_last = sum((l.get("total_tokens") or 0) for _, _, l, _ in totals)
            final_total = totals[-1][1].get("total_tokens") or 0
            if abs(sum_last - final_total) > max(1000, 0.02 * final_total): delta_mismatch_sessions += 1
elapsed = time.time() - t0
keys = ["sessions", "input", "cached_input", "output", "reasoning_output", "total"]
out = {"elapsed_s": round(elapsed, 1), "roots": [r[2] for r in roots], "files": files, "bytes": bytes_total, "lines": lines_total,
  "token_count_events": token_count_events, "events_with_info": events_with_info, "sessions_with_tokens": sessions_with_tokens,
  "total_counter_drops": total_drops, "negative_steps_by_key": dict(neg_steps),
  "sessions_where_sum_last_differs_from_final_total": delta_mismatch_sessions,
  "duplicate_total_events": duplicate_total_events, "sessions_without_model": sessions_without_model, "multi_model_sessions": multi_model_sessions,
  "sum_of_per_file_final_totals": per_file_final,
  "by_home": dict(by_home), "by_source": dict(by_source), "by_originator": dict(by_originator), "rate_limit_shapes": dict(rate_limit_shapes.most_common(6)),
  "first_ts": first_ts, "last_ts": last_ts, "mtime_buckets": dict(mtime_buckets),
  "by_model": {k: dict(zip(keys, v)) for k, v in sorted(by_model.items())},
  "by_day": {k: dict(zip(keys, v)) for k, v in sorted(by_day.items())}}
json.dump(out, open(sys.argv[1], "w"), indent=1)
summary = {k: v for k, v in out.items() if k != "by_day"}
print(json.dumps(summary, indent=1))
bd = out["by_day"]; days = sorted(k for k in bd if k)
def tot(ks): return {f: round(sum(bd[k][f] for k in ks) / 1e6, 1) for f in ("input", "cached_input", "output", "reasoning_output", "total")}
print("days:", len(days), days[0], "->", days[-1]); print("all(M):", tot(days)); print("last7(M):", tot(days[-7:])); print("last30(M):", tot(days[-30:]))
import statistics
print("median/day total: %.1fM" % (statistics.median([bd[k]["total"] for k in days]) / 1e6))
print("top days:", sorted([(k, round(v["total"] / 1e9, 2)) for k, v in bd.items()], key=lambda x: -x[1])[:4])
