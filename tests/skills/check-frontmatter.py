#!/usr/bin/env python3
"""CI guard: every skill's frontmatter conforms to the Anthropic skills guide.

Checks for each skills/*/SKILL.md:
- name present, kebab-case, equal to the folder name;
- description present, <= 1024 characters, no XML tags;
- compatibility <= 500 characters when present;
- license present (kit requirement, not the guide's);
- metadata.author and metadata.suite present (stable facts about the skill);
- version ABSENT, at top level and under metadata: the plugin ships and is
  versioned as one unit, so the only version anyone can act on is
  .claude-plugin/plugin.json, which release-please bumps. A per-skill number is
  a claim nothing maintains (#16);
- a trigger list tests/skills/<name>.triggers.md exists, with both
  "Should trigger" and "Should NOT trigger" sections non-empty.

Cross-check against requirements.json (single source): every entry a skill
hard-requires (`requiredBy`) must be declared in that skill's `compatibility`
frontmatter via the entry's `token` — so the manifest and the distributed
metadata can never drift apart silently.

The frontmatter is PARSED as YAML rather than pattern-matched. Key presence is
not a text question: `version:`, `"version":`, `'version':`, `version :` and the
flow form `metadata: {version: 1}` are all the same key, and a substring test
also fires on prose inside a `>-` block scalar. Both mistakes shipped here
before (#16 review) — parsing removes the whole class.

Self-test: tests/skills/test.sh drives this file over fixtures that must FAIL,
so a guard that silently stops matching cannot pass CI.
"""
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is required by this check — install it before this step (pip install PyYAML)")

ROOT = Path(__file__).resolve().parents[2]
errors = []

skill_files = sorted(ROOT.glob("skills/*/SKILL.md"))
if not skill_files:
    sys.exit("no skills/*/SKILL.md found — wrong directory?")


def text_of(value) -> str:
    """Frontmatter scalar as one normalized line, so limits count what a reader sees."""
    return re.sub(r'\s+', ' ', str(value or "")).strip()


compat_by_skill = {}

for f in skill_files:
    skill = f.parent.name
    text = f.read_text(encoding="utf-8")
    m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
    if not m:
        errors.append(f"{skill}: YAML frontmatter absent or --- delimiters missing")
        continue
    fm = m.group(1)

    try:
        data = yaml.safe_load(fm)
    except yaml.YAMLError as exc:
        errors.append(f"{skill}: frontmatter is not valid YAML ({exc.__class__.__name__})")
        continue
    if not isinstance(data, dict):
        errors.append(f"{skill}: frontmatter must be a YAML mapping, got {type(data).__name__}")
        continue
    metadata = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}

    name = text_of(data.get("name"))
    if name != skill:
        errors.append(f"{skill}: name '{name}' != folder name")
    if not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', name or ""):
        errors.append(f"{skill}: name '{name}' is not kebab-case")

    desc = text_of(data.get("description"))
    if not desc:
        errors.append(f"{skill}: description missing")
    elif len(desc) > 1024:
        errors.append(f"{skill}: description is {len(desc)} characters (guide limit: 1024)")
    if re.search(r'<[^>]+>', fm):
        errors.append(f"{skill}: XML tag in the frontmatter (forbidden by the guide)")

    comp = text_of(data.get("compatibility"))
    compat_by_skill[skill] = comp
    if comp and len(comp) > 500:
        errors.append(f"{skill}: compatibility is {len(comp)} characters (guide limit: 500)")

    if not text_of(data.get("license")):
        errors.append(f"{skill}: license missing")
    for key in ("author", "suite"):
        if not text_of(metadata.get(key)):
            errors.append(f"{skill}: metadata.{key} missing")

    # A version claim is forbidden wherever it sits — top level or under metadata.
    for where, holder in (("version", data), ("metadata.version", metadata)):
        if "version" in holder:
            errors.append(
                f"{skill}: {where} is forbidden (#16) — the plugin is versioned as one unit "
                f"in .claude-plugin/plugin.json, bumped by release-please; a per-skill number "
                f"is a claim nothing maintains")

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
