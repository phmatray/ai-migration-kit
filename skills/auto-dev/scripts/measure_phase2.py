#!/usr/bin/env python3
"""Baseline: what did the merge-pr phase actually COST inside the v1 single session?

Finds the turn where the worker invoked merge-pr, then sums cache_read from that
point on. That is exactly the work v2 moves into a fresh session, so it is a true
before-number for the split.
"""
import json, os, sys, glob

d = sys.argv[1]
rows = []
for path in glob.glob(os.path.join(d, "*.jsonl")):
    sid = os.path.basename(path)[:8]
    turns = []          # (cache_read,) in order
    split_at = None
    for line in open(path, errors="ignore"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        msg = e.get("message") or {}
        u = msg.get("usage") or {}
        cr = u.get("cache_read_input_tokens", 0)
        c = msg.get("content")
        # detect the merge-pr handoff
        if split_at is None and isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    blob = json.dumps(b.get("input", {}))
                    nm = b.get("name", "")
                    if (nm == "Skill" and "merge-pr" in blob) or \
                       (nm == "Bash" and "gh pr merge" in blob):
                        split_at = len(turns)
                        break
        if cr:
            turns.append(cr)
    if not turns or split_at is None or split_at >= len(turns):
        continue
    pre = turns[:split_at]
    post = turns[split_at:]
    rows.append((sid, len(pre), sum(pre), len(post), sum(post),
                 post[0] if post else 0))

rows.sort(key=lambda r: -r[4])
print(f"{'sess':8} {'impl_turns':>10} {'impl_cr':>9} {'merge_turns':>11} {'merge_cr':>9} {'ctx@merge_start':>15}")
tot_mt = tot_mc = tot_it = tot_ic = 0
for sid, it, ic, mt, mc, c0 in rows:
    print(f"{sid:8} {it:10} {ic/1e6:8.1f}M {mt:11} {mc/1e6:8.1f}M {c0/1000:14.0f}K")
    tot_it += it; tot_ic += ic; tot_mt += mt; tot_mc += mc
n = len(rows)
if n:
    print()
    print(f"sessions with a detectable merge phase: {n}")
    print(f"  implement phase: {tot_it} turns, {tot_ic/1e6:.0f}M cacheRead")
    print(f"  merge phase    : {tot_mt} turns, {tot_mc/1e6:.0f}M cacheRead"
          f"   ({tot_mc*100//max(1,tot_ic+tot_mc)}% of total)")
    print(f"  merge phase avg context/turn: {tot_mc/max(1,tot_mt)/1000:.0f}K")
    print()
    print("If those same merge turns ran in a FRESH session instead, they would start at ~30K")
    print("and grow, averaging roughly 30K + (turns/2 * ~1.0K) per turn:")
    est = 0
    for sid, it, ic, mt, mc, c0 in rows:
        est += sum(30000 + i * 1000 for i in range(mt))   # same growth slope, fresh start
    print(f"  estimated fresh-session cost for the SAME merge turns: {est/1e6:.0f}M")
    print(f"  saving on the merge phase alone: {(tot_mc-est)/1e6:.0f}M "
          f"({(tot_mc-est)*100//max(1,tot_mc)}% of merge, "
          f"{(tot_mc-est)*100//max(1,tot_ic+tot_mc)}% of ALL worker cacheRead)")
