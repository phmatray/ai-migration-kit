#!/usr/bin/env python3
"""harvest.py — the kit's failure signals, read out of previous sessions' transcripts (#397).

Read-only, stdlib-only, and it decides nothing: it walks the `.jsonl` transcripts under one or
more `~/.claude/projects/<dir>` directories — the top-level session files and every sub-agent
layout `skills/auto-dev/scripts/usage_report.py` discovers — and emits one record per SIGNAL,
attributed to the kit skill that was active at that point of the transcript. `review-sessions`
clusters the records, verifies them against the tree and applies the filing bar; this script only
reports what is there, the way `survey.sh` reports a queue and the supervisor decides.

Usage:
    python3 harvest.py [PROJECT_DIR ...] [--since YYYY-MM-DD] [--json | --markdown]
                       [--kit-name NAME] [--kit-root PATH]

  PROJECT_DIR   one or more ~/.claude/projects/<encoded-cwd> directories. Default: the directory
                encoding THIS cwd, plus its `--claude-worktrees-*` siblings (a worktree session
                writes to its own directory, and a review of "this repo's sessions" wants both).
  --since       keep only records stamped on or after that date (UTC date of the transcript line).
  --json        one JSON object per line (the record shape below). Default: the markdown tally.
  --kit-name    the plugin's name as it appears in skill ids and cache paths (default: ai-migration-kit).
  --kit-root    the kit's own checkout, used to read the never-wait phrase list the kit already
                pins in tests/auto-dev-never-wait/test.sh (default: three directories above this
                file; a built-in copy is used when the suite is not there, and the tally says so).

A record:
    {"kind", "skill", "session", "path", "ts", "excerpt", "tool", "detail", "count"}

kind ∈ tool-error      a tool_result flagged is_error whose tool_use named a kit path or script
       hook-deny       a PreToolUse deny from one of the kit's two gates (its reason prefix)
       forbidden-wait  an assistant turn in the never-wait shape a worker must never end on
       worker-report   a worker's final report line with STATUS PARTIAL | BLOCKED | FAILED
       suite-fail      a tool_result carrying a kit golden suite's FAIL: line
       guard-refusal   a guarded-*.sh / tick-plan.sh / make-worktree.sh refusal or ALERT
       harness-nudge   "[Request interrupted" or "[Your previous response had no visible output"

Exit 0 (records, or the explicit `no signals` line); 2 on a usage error or an unreadable directory
— never a traceback for a bad argument.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

KIT_SKILLS = (
    "auto-dev", "create-issue", "debug-issue", "deliver-issue", "implement-issue", "merge-pr",
    "migrate-legacy", "profile-repo", "review-followups", "review-sessions", "setup-repo",
    "triage-backlog",
)
# A slash command is a skill's other front door; its file is not named after the skill.
COMMAND_SKILL = {
    "migrate": "migrate-legacy", "migrate-assess": "migrate-legacy", "migrate-verify": "migrate-legacy",
    "migrate-audit": "migrate-legacy", "migrate-followups": "review-followups",
    "auto-dev-worker": "auto-dev", "auto-dev-merge": "auto-dev",
}
KIT_SCRIPTS = (
    "guarded-commit.sh", "guarded-push.sh", "guarded-merge.sh", "guarded-pr-merge.sh", "tick-plan.sh",
    "make-worktree.sh", "plan-freshness.sh", "wait-ci.sh", "survey.sh", "reconcile.sh", "repo-profile.sh",
    "repo-setup.sh", "preflight.sh", "followups.py", "decide.sh", "wire-edges.sh", "merge-verdict.sh",
    "base-run-verdict.sh", "remote-branch-teardown.sh", "parent-decision-note.sh", "audit-inventory.sh",
    "report-dashboard.py", "usage_report.py", "rejected-adrs.sh", "harvest.py",
)
KIT_DIRS_ANYWHERE = ("skills/", "hooks/", "commands/")
KIT_DIRS_IN_KIT = ("scripts/", "tests/", "evals/")
HOOK_DENY_PREFIXES = (
    "Blocked by the git write-gate",
    "Blocked by the roseline gate",
    "roseline-gate:",
)
HARNESS_REFUSAL_PREFIX = "This session is isolated in the worktree"
BUILTIN_NEVER_WAIT = (
    "I'll pause here and wait for",
    "I'll pick this back up automatically once it completes",
    "I'll stop issuing further tool calls now and wait",
)
NUDGES = ("[Request interrupted", "[Your previous response had no visible output")
WORKER_REPORT_RE = re.compile(r"\bSTATUS:\s*(PARTIAL|BLOCKED|FAILED)\b")
SUITE_FAIL_RE = re.compile(r"^FAIL[: \[].*", re.M)
GUARD_RE = re.compile(
    r"(guarded-(?:commit|push|merge|pr-merge)\.sh|tick-plan\.sh|make-worktree\.sh|plan-freshness\.sh)"
    r".{0,200}?(REFUSED|ALERT|exit(?:ed)? [2-9]|is NOT this HEAD|no verdict)", re.S)


def never_wait_phrases(kit_root):
    """The phrase list tests/auto-dev-never-wait/test.sh pins — read, never copied, when present."""
    suite = os.path.join(kit_root or "", "tests", "auto-dev-never-wait", "test.sh")
    try:
        with open(suite, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return list(BUILTIN_NEVER_WAIT), "builtin"
    found = re.findall(r'^\s*"(I\'ll [^"]+)"\s*$', text, re.M)
    return (found or list(BUILTIN_NEVER_WAIT)), ("kit" if found else "builtin")


def default_project_dirs(kit_name):
    home = os.path.expanduser("~")
    base = os.path.join(home, ".claude", "projects")
    enc = os.getcwd().replace("/", "-").replace(".", "-")
    # A worktree session encodes `<repo>--claude-worktrees-<name>`; strip our own suffix so the
    # repo directory and every worktree sibling are found from either kind of cwd.
    stem = enc.split("--claude-worktrees-")[0]
    cands = sorted(d for d in glob.glob(os.path.join(base, stem + "*")) if os.path.isdir(d))
    return cands


def discover_transcripts(proj):
    for p in sorted(glob.glob(os.path.join(proj, "*.jsonl"))):
        yield p, os.path.basename(p)[:-6]
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(p)))
        yield p, parent + "/" + os.path.basename(p)[:-6]
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "workflows", "wf_*", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(p)))))
        yield p, parent + "/" + os.path.basename(p)[:-6]


def text_of(content):
    """The text of a content field: a string, or the text blocks of a list."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str):
                parts.append(b["text"])
            elif isinstance(b, str):
                parts.append(b)
        return "\n".join(parts)
    return ""


def excerpt_of(text, needle=None, width=160):
    if needle:
        i = text.find(needle)
        if i >= 0:
            start = text.rfind("\n", 0, i) + 1
            text = text[start:]
    return " ".join(text.split())[:width]


def names_kit_path(s, in_kit_repo, kit_name):
    if not s:
        return False
    if kit_name and kit_name in s:
        return True
    for d in KIT_DIRS_ANYWHERE:
        if d in s:
            return True
    if in_kit_repo:
        for d in KIT_DIRS_IN_KIT:
            if d in s:
                return True
    return any(name in s for name in KIT_SCRIPTS)


def skill_from_tool_use(block, kit_name):
    """The kit skill a Skill tool_use names, or None."""
    if block.get("name") != "Skill":
        return None
    inp = block.get("input") or {}
    skill = inp.get("skill") if isinstance(inp, dict) else None
    if not isinstance(skill, str):
        return None
    bare = skill.split(":")[-1]
    prefix = skill.split(":")[0] if ":" in skill else None
    if prefix and prefix != kit_name:
        return None
    if bare in KIT_SKILLS:
        return bare
    return COMMAND_SKILL.get(bare)


def harvest_file(path, session, in_kit_repo, kit_name, phrases, since):
    records = []
    skipped = 0
    active = None
    tool_inputs = {}   # tool_use id → the string that names what it touched
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except Exception:
                skipped += 1
                continue
            if not isinstance(o, dict):
                skipped += 1
                continue
            t = o.get("type")
            if t not in ("user", "assistant"):
                continue
            ts = o.get("timestamp") or ""
            day = ts[:10]
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            content = msg.get("content")

            def emit(kind, excerpt, tool=None, detail=None):
                if since and day and day < since:
                    return
                records.append({
                    "kind": kind, "skill": active or "unattributed", "session": session,
                    "path": path, "ts": ts, "excerpt": excerpt, "tool": tool, "detail": detail,
                    "count": 1,
                })

            if t == "assistant" and isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        sk = skill_from_tool_use(b, kit_name)
                        if sk:
                            active = sk
                        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                        touched = " ".join(str(v) for v in inp.values() if isinstance(v, str))
                        tool_inputs[b.get("id")] = (b.get("name"), touched)
                    elif b.get("type") == "text" and isinstance(b.get("text"), str):
                        txt = b["text"]
                        for ph in phrases:
                            if ph in txt:
                                emit("forbidden-wait", excerpt_of(txt, ph), None, ph)
                                break
                        m = WORKER_REPORT_RE.search(txt)
                        if m:
                            emit("worker-report", excerpt_of(txt, "STATUS:"), None, m.group(1))
            elif t == "user":
                if isinstance(content, str):
                    for n in NUDGES:
                        if n in content:
                            emit("harness-nudge", excerpt_of(content, n), None, n)
                    continue
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text" and isinstance(b.get("text"), str):
                        for n in NUDGES:
                            if n in b["text"]:
                                emit("harness-nudge", excerpt_of(b["text"], n), None, n)
                        continue
                    if b.get("type") != "tool_result":
                        continue
                    body = text_of(b.get("content"))
                    tool, touched = tool_inputs.get(b.get("tool_use_id"), (None, ""))
                    if body.startswith(HARNESS_REFUSAL_PREFIX):
                        continue   # the harness's own worktree isolation, not the kit
                    if any(body.startswith(p) or ("\n" + p) in body for p in HOOK_DENY_PREFIXES):
                        emit("hook-deny", excerpt_of(body), tool, "gate")
                        continue
                    g = GUARD_RE.search(body)
                    if g:
                        emit("guard-refusal", excerpt_of(body, g.group(1)), tool, g.group(1))
                        continue
                    sf = SUITE_FAIL_RE.search(body)
                    if sf and names_kit_path(body, in_kit_repo, kit_name):
                        emit("suite-fail", excerpt_of(sf.group(0)), tool, "FAIL")
                        continue
                    if b.get("is_error") and names_kit_path(touched, in_kit_repo, kit_name):
                        emit("tool-error", excerpt_of(body), tool, excerpt_of(touched, width=100))
    # Collapse a polled command into one record with a count.
    collapsed = {}
    for r in records:
        key = (r["kind"], r["skill"], r["session"], r["excerpt"][:120])
        if key in collapsed:
            collapsed[key]["count"] += 1
        else:
            collapsed[key] = r
    return list(collapsed.values()), skipped


def tally_markdown(records, sessions, skipped, source):
    if not records:
        return f"no signals across {sessions} session(s)  (skipped {skipped} unparseable line(s); never-wait phrases: {source})\n"
    out = []
    by_skill = {}
    for r in records:
        by_skill.setdefault(r["skill"], {}).setdefault(r["kind"], []).append(r)
    for skill in sorted(by_skill):
        out.append(f"## {skill}\n")
        out.append("| kind | count | first | last | excerpt |")
        out.append("|---|---:|---|---|---|")
        for kind in sorted(by_skill[skill]):
            rs = by_skill[skill][kind]
            n = sum(r["count"] for r in rs)
            tss = sorted(r["ts"] for r in rs if r["ts"])
            first = tss[0][:19] if tss else "-"
            last = tss[-1][:19] if tss else "-"
            ex = rs[0]["excerpt"].replace("|", "\\|")
            out.append(f"| {kind} | {n} | {first} | {last} | {ex} |")
        out.append("")
    total = sum(r["count"] for r in records)
    out.append(f"signals: {total} across {sessions} sessions  (skipped {skipped} unparseable line(s); never-wait phrases: {source})")
    return "\n".join(out) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description="the kit's failure signals, out of past transcripts", add_help=True)
    ap.add_argument("project_dirs", nargs="*")
    ap.add_argument("--since")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--kit-name", default="ai-migration-kit")
    ap.add_argument("--kit-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    except Exception:
        pass
    if args.since:
        try:
            dt.date.fromisoformat(args.since)
        except ValueError:
            print(f"usage: --since takes YYYY-MM-DD, got {args.since!r}", file=sys.stderr)
            return 2
    dirs = args.project_dirs or default_project_dirs(args.kit_name)
    if not dirs:
        print("usage: no PROJECT_DIR given and none detected for this cwd under ~/.claude/projects", file=sys.stderr)
        return 2
    for d in dirs:
        if not os.path.isdir(d):
            print(f"unreadable project dir: {d}", file=sys.stderr)
            return 2
    phrases, source = never_wait_phrases(args.kit_root)
    records, skipped, sessions = [], 0, 0
    for d in dirs:
        in_kit_repo = args.kit_name in os.path.basename(os.path.abspath(d))
        for path, session in discover_transcripts(d):
            sessions += 1
            rs, sk = harvest_file(path, session, in_kit_repo, args.kit_name, phrases, args.since)
            records.extend(rs)
            skipped += sk
    records.sort(key=lambda r: (r["skill"], r["kind"], r["ts"]))
    if args.json and not args.markdown:
        for r in records:
            print(json.dumps(r, ensure_ascii=False))
        if not records:
            print(f"no signals across {sessions} session(s)", file=sys.stderr)
        return 0
    sys.stdout.write(tally_markdown(records, sessions, skipped, source))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
