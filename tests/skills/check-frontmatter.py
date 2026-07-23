#!/usr/bin/env python3
"""CI guard: every skill's frontmatter conforms to the Anthropic skills guide.

Checks for each skills/*/SKILL.md:
- name present, kebab-case, equal to the folder name;
- description present, <= 1024 characters, no XML tags;
- compatibility <= 500 characters when present;
- license and metadata.version present (kit requirement, not the guide's);
- a trigger list tests/skills/<name>.triggers.md exists, with both
  "Should trigger" and "Should NOT trigger" sections non-empty.

Cross-check against requirements.json (single source): every entry a skill
hard-requires (`requiredBy`) must be declared in that skill's `compatibility`
frontmatter via the entry's `token` — so the manifest and the distributed
metadata can never drift apart silently.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors = []

skill_files = sorted(ROOT.glob("skills/*/SKILL.md"))
if not skill_files:
    sys.exit("no skills/*/SKILL.md found — wrong directory?")

def field(fm: str, name: str) -> str:
    m = re.search(rf'^{name}:\s*(>-?\n)?(.*?)(?=^\w|\Z)', fm, re.S | re.M)
    return re.sub(r'\s+', ' ', m.group(2)).strip() if m else ""

compat_by_skill = {}

for f in skill_files:
    skill = f.parent.name
    text = f.read_text(encoding="utf-8")
    m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
    if not m:
        errors.append(f"{skill}: YAML frontmatter absent or --- delimiters missing")
        continue
    fm = m.group(1)

    name = field(fm, "name")
    if name != skill:
        errors.append(f"{skill}: name '{name}' != folder name")
    if not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', name or ""):
        errors.append(f"{skill}: name '{name}' is not kebab-case")

    desc = field(fm, "description")
    if not desc:
        errors.append(f"{skill}: description missing")
    elif len(desc) > 1024:
        errors.append(f"{skill}: description is {len(desc)} characters (guide limit: 1024)")
    if re.search(r'<[^>]+>', fm):
        errors.append(f"{skill}: XML tag in the frontmatter (forbidden by the guide)")

    comp = field(fm, "compatibility")
    compat_by_skill[skill] = comp
    if comp and len(comp) > 500:
        errors.append(f"{skill}: compatibility is {len(comp)} characters (guide limit: 500)")
    if "license:" not in fm:
        errors.append(f"{skill}: license missing")
    if "version:" not in fm:
        errors.append(f"{skill}: metadata.version missing")

    triggers = ROOT / "tests" / "skills" / f"{skill}.triggers.md"
    if not triggers.exists():
        errors.append(f"{skill}: trigger list missing ({triggers.relative_to(ROOT)})")
    else:
        t = triggers.read_text(encoding="utf-8")
        for section in ("## Should trigger", "## Should NOT trigger"):
            block = re.search(rf'{re.escape(section)}\n(.*?)(?=\n## |\Z)', t, re.S)
            if not block or not re.search(r'^- ', block.group(1), re.M):
                errors.append(f"{skill}: section \"{section}\" absent or empty in {triggers.name}")

# requirements.json ↔ compatibility cross-check.
req = json.loads((ROOT / "requirements.json").read_text(encoding="utf-8"))
for entry in req.get("tools", []) + req.get("mcps", []) + req.get("sessionSkills", []):
    required_by = entry.get("requiredBy", [])
    if not required_by:
        continue
    token = entry.get("token", "")
    if not token:
        errors.append(f"requirements.json: entry '{entry['name']}' has requiredBy but no token")
        continue
    for skill in required_by:
        if skill not in compat_by_skill:
            errors.append(f"requirements.json: requiredBy of '{entry['name']}' names unknown skill '{skill}'")
        elif token not in compat_by_skill[skill]:
            errors.append(
                f"{skill}: compatibility does not mention '{token}' although "
                f"requirements.json marks '{entry['name']}' as hard-required by it")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"frontmatter OK for {len(skill_files)} skills (guide limits + trigger lists + requirements cross-check)")
