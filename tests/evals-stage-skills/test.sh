#!/usr/bin/env bash
# Golden test for evals/run_all.py's skill staging (#624).
#
# WHAT THIS PINS. The bench stages every skill under test into `<project>/.claude/skills/` so that
# detection measures the REPO's own SKILL.md rather than whatever version this machine's plugin
# cache happens to carry — a stale cache collapses recall to ~0.11 and looks exactly like a weak
# description. That staging used `Path.symlink_to`, which on Windows needs the SeCreateSymbolicLink
# privilege (Developer Mode or elevation). Most machines do not grant it, so the call raised
# `OSError: [WinError 1314]` and the run died before one trigger contract had been measured.
#
# #619 removed the same assumption from the two plugin trees by copying rather than linking
# (ADR 0017); this suite pins the runtime caller that was left.
#
# The staging contract has three halves, and the teardown's own promise is the subtle one: "Only
# links this created are removed. A real directory, or a link somebody else put there, is left
# exactly as found." A copy-based teardown that forgot it would delete a contributor's real
# .claude/skills/<name>, so that promise is asserted here rather than trusted.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

command -v python3 > /dev/null 2>&1 || { echo "FAIL: python3 is missing"; exit 1; }

WORK=$(kit_scratch)
python3 - "$KIT_ROOT" "$WORK" <<'PY'
import sys, pathlib, importlib.util

kit_root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# run_all.py imports its sibling `trigger_eval`, so evals/ has to be importable before it loads.
sys.path.insert(0, str(kit_root / "evals"))
spec = importlib.util.spec_from_file_location("run_all", kit_root / "evals" / "run_all.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fails = []
def ok(label):  print(f"  ok: {label}")
def bad(label): print(f"FAIL: {label}"); fails.append(label)

# A minimal project: one skill to stage, one pre-existing real directory that must survive.
proj = work / "proj"
(proj / "skills" / "demo-skill").mkdir(parents=True)
(proj / "skills" / "demo-skill" / "SKILL.md").write_text("# demo\n", encoding="utf-8")
(proj / "skills" / "kept-skill").mkdir(parents=True)
(proj / "skills" / "kept-skill" / "SKILL.md").write_text("# kept\n", encoding="utf-8")
(proj / ".claude" / "skills" / "kept-skill").mkdir(parents=True)
(proj / ".claude" / "skills" / "kept-skill" / "SKILL.md").write_text("MINE — do not touch\n", encoding="utf-8")

staged = proj / ".claude" / "skills" / "demo-skill"
kept   = proj / ".claude" / "skills" / "kept-skill" / "SKILL.md"

with mod.skills_visible(str(proj), ["demo-skill", "kept-skill"]):
    # 1. the staged skill is READABLE through .claude/skills — the whole point of staging
    try:
        body = (staged / "SKILL.md").read_text(encoding="utf-8")
        ok("the staged skill's SKILL.md is readable inside the context") if body.strip() == "# demo" \
            else bad(f"the staged SKILL.md has the wrong content: {body!r}")
    except OSError as exc:
        bad(f"the staged skill is not readable: {exc!r}")
    # 2. a pre-existing real directory is left exactly as found
    if kept.read_text(encoding="utf-8").startswith("MINE"):
        ok("a pre-existing .claude/skills entry is left exactly as found")
    else:
        bad("a pre-existing .claude/skills entry was overwritten by staging")

# 3. teardown removes what staging created, and NOTHING else
if staged.exists():
    bad(f"the staged skill outlived the context: {staged}")
else:
    ok("the staged skill is gone once the context exits")
if kept.exists() and kept.read_text(encoding="utf-8").startswith("MINE"):
    ok("the pre-existing entry survives teardown")
else:
    bad("teardown deleted a pre-existing .claude/skills entry it did not create")

sys.exit(1 if fails else 0)
PY
echo "evals-stage-skills: OK — skills stage readably and tear down without touching what they did not create."
