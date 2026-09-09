#!/usr/bin/env python3
"""CI guard: every file reference in a shipped prompt resolves.

Scans skills/**/*.md and commands/*.md for two reference shapes and refuses when the target does not
exist: a markdown link `[text](path)`, resolved from the file that carries it; and a backticked path
`dir/file.ext` whose first segment is a kit directory (or `./`, `../`), resolved from the carrying
file, the skill root, the repo root, then under skills/ (so `_shared/x.md` and a command's
`references/x.md` shorthand resolve). Fenced code blocks are blanked, not removed, so line
numbers stay true. Paths carrying `{`, `$`, `<`, `*`, or starting with `/` or `~` are prose or
placeholders, never checked.

Why the first-segment allowlist: a prompt also names paths in the TARGET repository
(`.github/workflows/ci.yml`), which cannot resolve here and are not the kit's to check.

check-shared-refs.py guards one class (skills/_shared/ consumers, both directions); this guards the
rest. Measured before it existed: 448 references, one dead — `tests/_lib/py_module.py`, a file that
never existed — invisible to CI. Pattern borrowed from BMAD-METHOD's tools/validate_file_refs.py (MIT).

Usage: check-file-refs.py [root]   (root defaults to the kit root; a scratch root is a complete world)
"""
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
KIT_DIRS = {"skills", "scripts", "tests", "hooks", "commands", "docs", "templates", "evals", "references", "_shared"}
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
TICK = re.compile(r"`((?:\.\.?/)?[\w./-]+/[\w.-]+\.(?:md|sh|py|json|ya?ml|txt|toml))`")
FENCE = re.compile(r"^(`{3,}|~{3,})")


def blank_fences(lines):
    out, fence = [], None
    for line in lines:
        m = FENCE.match(line)
        if fence is None and m:
            fence = m.group(1)
            out.append("")
        elif fence is not None and line.startswith(fence):
            fence = None
            out.append("")
        else:
            out.append("" if fence is not None else line)
    return out


def skill_root(path):
    rel = path.relative_to(ROOT).parts
    return ROOT / rel[0] / rel[1] if rel[0] == "skills" and len(rel) > 2 else path.parent


def resolves(path, target):
    # `_shared/x.md` from a skill and `references/x.md` from a command are shorthand for a path
    # under skills/ — resolve them there too rather than teach every prompt a longer spelling.
    bases = [path.parent, skill_root(path), ROOT, ROOT / "skills", *sorted(ROOT.glob("skills/*/"))]
    return any((base / target).exists() for base in bases)


dead = []
files = sorted(ROOT.glob("skills/**/*.md")) + sorted(ROOT.glob("commands/*.md"))
for path in files:
    for n, line in enumerate(blank_fences(path.read_text(encoding="utf-8").splitlines()), 1):
        for m in LINK.finditer(line):
            target = m.group(1).split("#", 1)[0]
            if not target or target.startswith(("http", "mailto:", "{", "$", "<")):
                continue
            if not (path.parent / target).exists():
                dead.append((path, n, m.group(1)))
        for m in TICK.finditer(line):
            target = m.group(1)
            if target.startswith(("/", "~")) or "*" in target:
                continue
            if not target.startswith(("./", "../")) and target.split("/", 1)[0] not in KIT_DIRS:
                continue
            if not resolves(path, target):
                dead.append((path, n, target))

for path, n, target in dead:
    print(f"DEAD REF: {path.relative_to(ROOT)}:{n} -> {target}")
if not files:
    sys.exit("no skills/**/*.md found — wrong directory?")
if dead:
    sys.exit(1)
print(f"file refs: {len(files)} files, 0 dead")
