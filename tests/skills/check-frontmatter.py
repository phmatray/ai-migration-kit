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
- a trigger eval set evals/<name>-trigger-eval.json exists, is a JSON list of
  {query, should_trigger, note?} objects with no duplicate query, and carries
  both polarities (#331). That file is the ONE home for a skill's triggering
  contract: `evals/trigger_eval.py` runs it against the installed description,
  so the rule now guards the artefact a tool executes rather than the
  tests/skills/<name>.triggers.md bullet list nothing ever read.

Cross-check against requirements.json (single source): every entry a skill
hard-requires (`requiredBy`) must be declared in that skill's `compatibility`
frontmatter via the entry's `token` — so the manifest and the distributed
metadata can never drift apart silently.

Cross-check against the bench's own rosters: `evals/run_all.py`'s SKILLS and
`evals/trigger_eval.py`'s DEFAULT_KNOWN must each list exactly the skills/*/
folders (#331). Without this, a skill added with a valid eval set passes the
rule above while `run_all.py` never runs it — which is precisely the "half the
kit unmeasured while CI reports every contract present" failure #331 closed.

The frontmatter is PARSED as YAML rather than pattern-matched. Key presence is
not a text question: `version:`, `"version":`, `'version':`, `version :` and the
flow form `metadata: {version: 1}` are all the same key, and a substring test
also fires on prose inside a `>-` block scalar. Both mistakes shipped here
before (#16 review) — parsing removes the whole class.

Self-test: tests/skills/test.sh drives this file over fixtures that must FAIL,
so a guard that silently stops matching cannot pass CI.
"""
import ast
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


EVAL_KEYS = {"query", "should_trigger", "note"}


def check_trigger_eval_set(skill: str) -> list:
    """The skill's triggering contract, validated where a tool can actually run it (#331).

    Structural only — CI must never spend a bench run (`evals/run_all.py` spawns a real
    `claude -p` per query). What it proves is that the set exists, parses, uses the runner's
    key names, and pins BOTH polarities, so a typo fails here rather than after the tokens
    are spent. Errors accumulate: one malformed entry does not hide the next.
    """
    path = ROOT / "evals" / f"{skill}-trigger-eval.json"
    rel = path.relative_to(ROOT)
    if not path.exists():
        return [f"{skill}: trigger eval set missing ({rel}) — create it as a JSON list of "
                f"{{query, should_trigger, note?}} objects"]

    try:
        entries = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"{skill}: {rel} is not valid JSON ({exc})"]

    if not isinstance(entries, list) or not entries:
        return [f"{skill}: {rel} must be a non-empty JSON list of "
                f"{{query, should_trigger, note?}} objects"]

    found = []
    polarities = set()
    seen = {}
    for i, entry in enumerate(entries):
        where = f"{rel}[{i}]"
        if not isinstance(entry, dict):
            found.append(f"{skill}: {where} is not an object "
                         f"(got {type(entry).__name__})")
            continue
        stray = sorted(set(entry) - EVAL_KEYS)
        if stray:
            found.append(f"{skill}: {where} has unexpected key "
                         f"{', '.join(repr(k) for k in stray)} "
                         f"(allowed: query, should_trigger, note)")
        note = entry.get("note")
        if note is not None and not isinstance(note, str):
            found.append(f"{skill}: {where} has a non-string 'note' "
                         f"(got {type(note).__name__})")
        query = entry.get("query")
        if not isinstance(query, str) or not query.strip():
            found.append(f"{skill}: {where} has a missing or empty 'query'")
        else:
            # Keyed on the NORMALIZED form: to the bench, "File an issue" and "file an issue "
            # are one query asked twice, however differently they are spelled here.
            key = " ".join(query.split()).casefold()
            if key in seen:
                found.append(f"{skill}: {where} is a duplicate query of {rel}[{seen[key]}] "
                             f"— a duplicated query inflates recall for free")
            else:
                seen[key] = i
        should_trigger = entry.get("should_trigger")
        if not isinstance(should_trigger, bool):
            found.append(f"{skill}: {where} has a missing or non-boolean 'should_trigger'")
        else:
            polarities.add(should_trigger)

    for polarity in (True, False):
        if polarity not in polarities:
            found.append(f"{skill}: {rel} has no should_trigger: "
                         f"{str(polarity).lower()} entry")
    return found


compat_by_skill = {}


def read_name_list(rel_path: str, var: str):
    """A module-level list literal, read WITHOUT importing the module.

    Importing `evals/trigger_eval.py` would drag in the runner's dependencies and
    argparse surface for the sake of one literal, so this parses instead.
    Returns (names, error); exactly one is None.
    """
    path = ROOT / rel_path
    if not path.exists():
        return None, f"{rel_path}: missing — it declares {var}, the roster the bench runs"
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except SyntaxError as exc:
        return None, f"{rel_path}: is not valid Python ({exc})"
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(tgt, ast.Name) and tgt.id == var for tgt in node.targets):
            try:
                return list(ast.literal_eval(node.value)), None
            except (ValueError, TypeError):
                return None, f"{rel_path}: {var} is not a literal list of skill names"
    return None, f"{rel_path}: {var} is not declared at module level"


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

    errors.extend(check_trigger_eval_set(skill))

# The ten-skill roster ↔ the bench's own lists (#331).
skill_names = {f.parent.name for f in skill_files}
for rel_path, var in (("evals/run_all.py", "SKILLS"), ("evals/trigger_eval.py", "DEFAULT_KNOWN")):
    listed, err = read_name_list(rel_path, var)
    if err:
        errors.append(err)
        continue
    missing = sorted(skill_names - set(listed))
    unknown = sorted(set(listed) - skill_names)
    if missing:
        errors.append(f"{rel_path}: {var} must list every skill — missing "
                      f"{', '.join(missing)}; a skill absent here keeps an eval set CI accepts "
                      f"and a bench that never runs it")
    if unknown:
        errors.append(f"{rel_path}: {var} must list every skill — {', '.join(unknown)} "
                      f"names no skills/*/ folder")

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
print(f"frontmatter OK for {len(skill_files)} skills (guide limits + evals/<skill>-trigger-eval.json + requirements cross-check)")
