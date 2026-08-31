#!/usr/bin/env python3
"""What does the merge phase COST, per issue — and what did it cost before the two-phase split?

Since 2.0 (#314) an auto-dev worker is TWO Agent-tool sub-agents per issue — phase 1
(`auto-dev-worker N`: implement up to a ready PR) and phase 2 (`auto-dev-merge PR`: land it
in a fresh context) — and each leaves its own transcript under
<proj>/<supervisor-session>/subagents/agent-*.jsonl. The two halves are paired by ISSUE
NUMBER, read from each transcript's final report line (the sub-agent's last message IS its
report, so it is always the last assistant text in the file):

    PHASE1 | ISSUE: N | PR: n | STATUS: …         -> the implement half of issue N
    ISSUE: N | PR: n | STATUS: MERGED|…            -> the merge half of issue N (no PHASE1 prefix)

Pre-2.0 transcripts — one top-level process session per issue, merge-pr invoked INSIDE it —
are still measured the way this script originally did: the turn where merge-pr was invoked
splits the session into an implement and a merge half. That before-number is what proved the
split (SKILL.md, lever 1); a 2.0 run shows the after-number directly in ctx@merge_start.

cache_read per turn ~= context size at that turn, so a half's cost is the sum of its turns'
cache_read, and ctx@merge_start is the merge half's first turn: ~30K for a fresh sub-agent,
~250K when the merge ran inside the implement context.
"""
import glob
import json
import os
import re
import sys

RE_PHASE1 = re.compile(r"^\s*PHASE1\s*\|\s*ISSUE:\s*(\d+)\s*\|", re.M)
RE_PHASE2 = re.compile(r"^\s*ISSUE:\s*(\d+)\s*\|\s*PR:", re.M)


def read_transcript(path):
    """-> (turns: [cache_read per assistant turn], handoff_at: index|None, report: last text|None)."""
    turns = []
    handoff_at = None
    report = None
    for line in open(path, errors="ignore"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        msg = e.get("message") or {}
        if not isinstance(msg, dict):
            continue
        u = msg.get("usage") or {}
        cr = u.get("cache_read_input_tokens", 0) or 0
        c = msg.get("content")
        is_assistant = e.get("type") == "assistant" or msg.get("role") == "assistant"
        if isinstance(c, list):
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and handoff_at is None:
                    # pre-2.0: the merge-pr handoff inside one session
                    blob = json.dumps(b.get("input", {}))
                    nm = b.get("name", "")
                    if (nm == "Skill" and "merge-pr" in blob) or \
                       (nm == "Bash" and "gh pr merge" in blob):
                        handoff_at = len(turns)
                elif b.get("type") == "text" and is_assistant and b.get("text"):
                    report = b["text"]
        elif isinstance(c, str) and is_assistant and c:
            report = c
        if cr:
            turns.append(cr)
    return turns, handoff_at, report


def discover(d):
    """Top-level sessions (orchestrator, pre-2.0 workers) then every sub-agent transcript."""
    yield from sorted(glob.glob(os.path.join(d, "*.jsonl")))
    yield from sorted(glob.glob(os.path.join(d, "*", "subagents", "*.jsonl")))


def main(d):
    phase1 = {}      # issue -> [cache_read turns], concatenated over re-dispatches (escalation)
    phase2 = {}
    rows = []        # (label, impl_turns, impl_cr, merge_turns, merge_cr, ctx_at_merge_start, legacy)
    for path in discover(d):
        turns, handoff_at, report = read_transcript(path)
        if not turns:
            continue
        m1 = RE_PHASE1.search(report or "")
        m2 = None if m1 else RE_PHASE2.search(report or "")
        if m1:
            phase1.setdefault(m1.group(1), []).extend(turns)
        elif m2:
            phase2.setdefault(m2.group(1), []).extend(turns)
        elif handoff_at is not None and handoff_at < len(turns):
            pre, post = turns[:handoff_at], turns[handoff_at:]
            rows.append((os.path.basename(path)[:8], len(pre), sum(pre), len(post), sum(post),
                         post[0], True))

    unpaired = sorted(set(phase1) ^ set(phase2), key=int)
    for issue in sorted(set(phase1) & set(phase2), key=int):
        pre, post = phase1[issue], phase2[issue]
        rows.append((f"#{issue}", len(pre), sum(pre), len(post), sum(post), post[0], False))

    rows.sort(key=lambda r: -r[4])
    print(f"{'issue/sess':10} {'impl_turns':>10} {'impl_cr':>9} {'merge_turns':>11} {'merge_cr':>9} {'ctx@merge_start':>15}")
    tot_mt = tot_mc = tot_it = tot_ic = 0
    for label, it, ic, mt, mc, c0, legacy in rows:
        tag = "   (pre-2.0: merge inside the implement session)" if legacy else ""
        print(f"{label:10} {it:10} {ic/1e6:8.1f}M {mt:11} {mc/1e6:8.1f}M {c0/1000:14.0f}K{tag}")
        tot_it += it; tot_ic += ic; tot_mt += mt; tot_mc += mc
    n = len(rows)
    if unpaired:
        print(f"\nunpaired: {len(unpaired)} issue(s) with only one half on disk "
              f"({', '.join('#' + i for i in unpaired)}) — still open, BLOCKED, or merged by takeover")
    if not n:
        return 0
    print()
    print(f"issues with both an implement and a merge half: {n}")
    print(f"  implement phase: {tot_it} turns, {tot_ic/1e6:.0f}M cacheRead")
    print(f"  merge phase    : {tot_mt} turns, {tot_mc/1e6:.0f}M cacheRead"
          f"   ({tot_mc*100//max(1,tot_ic+tot_mc)}% of total)")
    print(f"  merge phase avg context/turn: {tot_mc/max(1,tot_mt)/1000:.0f}K")
    legacy_rows = [r for r in rows if r[6]]
    if legacy_rows:
        # The v1 before-number: what the SAME merge turns would cost started fresh (~30K, growing
        # ~1K/turn) — the estimate lever 1 was adopted on, kept for pre-2.0 transcripts only; a 2.0
        # run measures it rather than estimating it.
        lmc = sum(r[4] for r in legacy_rows)
        lic = sum(r[2] for r in legacy_rows)
        est = sum(sum(30000 + i * 1000 for i in range(r[3])) for r in legacy_rows)
        print()
        print(f"pre-2.0 sessions ({len(legacy_rows)}): if their merge turns ran in a FRESH sub-agent "
              f"instead (~30K start, +~1.0K/turn):")
        print(f"  estimated fresh-context cost for the SAME merge turns: {est/1e6:.0f}M")
        print(f"  saving on the merge phase alone: {(lmc-est)/1e6:.0f}M "
              f"({(lmc-est)*100//max(1,lmc)}% of merge, "
              f"{(lmc-est)*100//max(1,lic+lmc)}% of ALL worker cacheRead)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: measure_phase2.py <project-transcript-dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
