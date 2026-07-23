#!/usr/bin/env python3
"""Garde CI : le frontmatter de chaque skill respecte le guide Anthropic des skills.

Vérifie pour chaque skills/*/SKILL.md :
- name présent, kebab-case, égal au nom du dossier ;
- description présente, ≤ 1024 caractères, sans balise XML ;
- compatibility ≤ 500 caractères si présent ;
- license et metadata.version présents (exigence du kit, pas du guide) ;
- une liste de déclenchement tests/skills/<name>.triggers.md existe, avec les
  deux sections « Should trigger » et « Should NOT trigger » non vides.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors = []

skill_files = sorted(ROOT.glob("skills/*/SKILL.md"))
if not skill_files:
    sys.exit("aucun skills/*/SKILL.md trouvé — mauvais répertoire ?")

def field(fm: str, name: str) -> str:
    m = re.search(rf'^{name}:\s*(>-?\n)?(.*?)(?=^\w|\Z)', fm, re.S | re.M)
    return re.sub(r'\s+', ' ', m.group(2)).strip() if m else ""

for f in skill_files:
    skill = f.parent.name
    text = f.read_text(encoding="utf-8")
    m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
    if not m:
        errors.append(f"{skill}: frontmatter YAML absent ou délimiteurs --- manquants")
        continue
    fm = m.group(1)

    name = field(fm, "name")
    if name != skill:
        errors.append(f"{skill}: name '{name}' ≠ nom du dossier")
    if not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', name or ""):
        errors.append(f"{skill}: name '{name}' n'est pas en kebab-case")

    desc = field(fm, "description")
    if not desc:
        errors.append(f"{skill}: description absente")
    elif len(desc) > 1024:
        errors.append(f"{skill}: description {len(desc)} caractères (limite du guide : 1024)")
    if re.search(r'<[^>]+>', fm):
        errors.append(f"{skill}: balise XML dans le frontmatter (interdit par le guide)")

    comp = field(fm, "compatibility")
    if comp and len(comp) > 500:
        errors.append(f"{skill}: compatibility {len(comp)} caractères (limite du guide : 500)")
    if "license:" not in fm:
        errors.append(f"{skill}: license manquant")
    if "version:" not in fm:
        errors.append(f"{skill}: metadata.version manquant")

    triggers = ROOT / "tests" / "skills" / f"{skill}.triggers.md"
    if not triggers.exists():
        errors.append(f"{skill}: liste de déclenchement absente ({triggers.relative_to(ROOT)})")
    else:
        t = triggers.read_text(encoding="utf-8")
        for section in ("## Should trigger", "## Should NOT trigger"):
            block = re.search(rf'{re.escape(section)}\n(.*?)(?=\n## |\Z)', t, re.S)
            if not block or not re.search(r'^- ', block.group(1), re.M):
                errors.append(f"{skill}: section « {section} » absente ou vide dans {triggers.name}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"frontmatter OK pour {len(skill_files)} skills (limites du guide + listes de déclenchement)")
