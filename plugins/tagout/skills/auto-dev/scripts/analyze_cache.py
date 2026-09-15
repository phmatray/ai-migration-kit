#!/usr/bin/env python3
"""Where do auto-dev worker cache-read tokens actually go?

cache_read per turn ~= context size at that turn, so total cost = sum over turns of
context size. This breaks that down: turns per session, context growth, and which
tool results are inflating the context (they get re-read every subsequent turn).

Since 2.0 (#314) every worker is an Agent-tool sub-agent whose transcript sits under
<proj>/<supervisor-session>/subagents/agent-*.jsonl, so discovery goes through
usage_report.discover_transcripts — the one home for both layouts (#281) — rather than a
top-level-only glob that would show the orchestrator alone and call the fleet cheap.
"""
import json, os, sys
from collections import defaultdict

sys.dont_write_bytecode = True                      # no __pycache__ beside a kit script (#42/#51)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from usage_report import discover_transcripts       # noqa: E402

d = sys.argv[1]
sessions = {}
tool_bytes = defaultdict(int)
tool_calls = defaultdict(int)
tool_max = defaultdict(int)

for path, kind, _parent in discover_transcripts(d):
    sid = os.path.basename(path)[:-len(".jsonl")][:14]   # 8 chars of a uuid; agent-<id> whole
    turns, cr_first, cr_last, cr_sum, out = 0, None, 0, 0, 0
    pending = {}
    for line in open(path, errors="ignore"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        msg = e.get("message") or {}
        u = msg.get("usage") or {}
        if u:
            cr = u.get("cache_read_input_tokens", 0)
            if cr:
                turns += 1
                if cr_first is None:
                    cr_first = cr
                cr_last = max(cr_last, cr)
                cr_sum += cr
            out += u.get("output_tokens", 0)
        # tool calls (assistant) -> remember id->name
        c = msg.get("content")
        if isinstance(c, list):
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    pending[b.get("id")] = b.get("name", "?")
                elif b.get("type") == "tool_result":
                    name = pending.get(b.get("tool_use_id"), "?")
                    body = b.get("content")
                    n = len(json.dumps(body)) if not isinstance(body, str) else len(body)
                    tool_bytes[name] += n
                    tool_calls[name] += 1
                    tool_max[name] = max(tool_max[name], n)
    if turns:
        sessions[sid] = (turns, cr_first or 0, cr_last, cr_sum, out)

tot_turns = sum(s[0] for s in sessions.values())
tot_cr = sum(s[3] for s in sessions.values())
print(f"sessions={len(sessions)}  turns={tot_turns}  cacheRead={tot_cr/1e6:.0f}M")
print(f"avg turns/session={tot_turns/max(1,len(sessions)):.0f}  avg context/turn={tot_cr/max(1,tot_turns)/1000:.0f}K")
print()
print(f"{'sess':14} {'turns':>6} {'ctx@start':>10} {'ctx@peak':>9} {'cacheRead':>10}")
for sid, (t, f, l, s, o) in sorted(sessions.items(), key=lambda x: -x[1][3])[:12]:
    print(f"{sid:14} {t:6} {f/1000:9.0f}K {l/1000:8.0f}K {s/1e6:9.1f}M")
print()
print("=== tool_result payload volume (chars; these persist and are re-read every later turn) ===")
print(f"{'tool':32} {'calls':>6} {'total_chars':>13} {'avg':>9} {'max':>10}")
for name, b in sorted(tool_bytes.items(), key=lambda x: -x[1])[:14]:
    c = tool_calls[name]
    print(f"{name[:32]:32} {c:6} {b:13,} {b//max(1,c):9,} {tool_max[name]:10,}")
