#!/usr/bin/env python3
"""host-adapters.py — build, and check, the files that carry one of the kit's sources to another host.

Why this exists (#525, #526). The kit is written for Claude Code and reaches every other host through
adapters: rule copies of `AGENTS.md` for hosts that read a rules folder (Cursor, Windsurf, Cline,
Kiro, GitHub Copilot, Antigravity), and plugin manifests for hosts that install one (Codex, Copilot
CLI, Gemini CLI, Antigravity CLI, pi). Copies kept by hand drift, and the drift is silent: every
host still loads something, just yesterday's. ponytail, which ships the same shape to twenty hosts,
keeps its copies honest with a compare script (dietrichgebert/ponytail,
`scripts/check-rule-copies.js`). This is the kit's, with one difference: `build` WRITES every derived
file from its source, and `check` computes the same bytes in memory and refuses any file on disk
that differs — so a derived file is never edited, only rebuilt, and has exactly one author.

Two kinds of thing are checked:

  generated  `generated(repo)` returns {relative path: (source, text)} — the rule copies (from
             AGENTS.md), each `commands/<name>.toml` Gemini CLI reads (from `commands/<name>.md`),
             and `gemini-extension.json` (from `.claude-plugin/plugin.json` and `.mcp.json`).
  invariants what cannot be generated but must hold (`invariants(repo)`, one REFUSE line each): the
             Claude hooks map stays off `hooks/hooks.json`, the path Gemini CLI and Copilot CLI
             auto-load in formats of their own; every plugin manifest carries the release-please
             version and is one of its `extra-files`; every path a manifest names resolves; every
             adapter the host table (`docs/_data/hosts.yml`) names exists; and every install line
             of a `tier: plugin` host appears in README.md, so the front page never lags the table.

Line endings: text is compared after CRLF -> LF, so a Windows checkout is not drift; `build` always
writes LF, the repository's own convention (`.gitattributes`).

Usage:
  host-adapters.py [--repo <path>] build
  host-adapters.py [--repo <path>] check

Exit codes:
  0  build wrote every generated file · check found every file in step and every invariant holding
  1  REFUSE (check) — one line per drifted file or broken invariant, naming it and the fix
  2  usage or plumbing — a source could not be read or parsed, so no verdict is possible. NOT a pass.
"""
import argparse
import json
import pathlib
import sys

FIX = "run python3 scripts/host-adapters.py build"

# (path, front matter). Each front matter is that host's own contract for an always-on rule:
# Cursor's .mdc `alwaysApply`, Windsurf's `trigger`, Kiro's steering `inclusion`. The other three
# hosts read a plain Markdown file.
RULE_COPIES = (
    (".cursor/rules/ai-migration-kit.mdc",
     "---\n"
     "description: AI Migration Kit — which kit skill to use, how to load it, and its MCP servers\n"
     "alwaysApply: true\n"
     "---\n\n"),
    (".windsurf/rules/ai-migration-kit.md", "---\ntrigger: always_on\n---\n\n"),
    (".clinerules/ai-migration-kit.md", ""),
    (".kiro/steering/ai-migration-kit.md", "---\ninclusion: always\n---\n\n"),
    (".github/copilot-instructions.md", ""),
    (".agents/rules/ai-migration-kit.md", ""),
)

# Every plugin manifest that carries a version. release-please bumps each through `extra-files`;
# one missing from that list is a manifest that silently stays behind on the next release.
VERSIONED = (
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".github/plugin/plugin.json",
    "gemini-extension.json",
)

HOSTS = "docs/_data/hosts.yml"
OLD_HOOKS = "hooks/hooks.json"


class NoVerdict(Exception):
    """A source is unreadable or unparseable: exit 2, never a pass."""


def read_source(repo, rel):
    try:
        return (repo / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as exc:
        raise NoVerdict(f"{rel} is not UTF-8 ({exc.reason})") from exc
    except OSError as exc:
        raise NoVerdict(f"cannot read {rel}: {exc.strerror or exc}") from exc


def read_json(repo, rel):
    try:
        return json.loads(read_source(repo, rel))
    except json.JSONDecodeError as exc:
        raise NoVerdict(f"{rel} is not valid JSON: {exc}") from exc


def toml_command(repo, md_rel):
    """A Claude Code command (`commands/<name>.md`) as the TOML command Gemini CLI reads."""
    text = read_source(repo, md_rel)
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        raise NoVerdict(f"{md_rel} has no front matter to read a description from")
    front, body = text[4:].split("\n---\n", 1)
    fields = dict(line.split(":", 1) for line in front.splitlines() if ":" in line)
    description = fields.get("description", "").strip()
    if not description:
        raise NoVerdict(f"{md_rel} front matter carries no description")
    # Claude Code fills `$ARGUMENTS` with the whole argument string and `$1` with the first; Gemini
    # has one placeholder, `{{args}}`. Every kit command takes a single argument, so both map to it
    # — and a command reading a second positional argument cannot be expressed at all.
    for n in "23456789":
        if f"${n}" in body:
            raise NoVerdict(f"{md_rel} reads ${n} — Gemini commands take one argument, {{{{args}}}}")
    prompt = body.lstrip("\n").replace("$ARGUMENTS", "{{args}}").replace("$1", "{{args}}")
    # A TOML literal string cannot contain its own closing delimiter, and nothing can escape it.
    if "'''" in prompt:
        raise NoVerdict(f"{md_rel} contains ''' — it cannot be written as a TOML literal string")
    return (f"# Generated from {md_rel} by scripts/host-adapters.py — edit the .md and rebuild.\n"
            f"description = {json.dumps(description, ensure_ascii=False)}\n"
            f"prompt = '''\n{prompt}'''\n")


def gemini_extension(repo):
    """gemini-extension.json: the plugin's identity, AGENTS.md as context, `.mcp.json`'s servers."""
    plugin = read_json(repo, ".claude-plugin/plugin.json")
    servers = read_json(repo, ".mcp.json").get("mcpServers", {})
    # Gemini's server entries have no `type` (it infers stdio from `command`), and an empty `env`
    # says nothing — both are dropped so the block holds only what Gemini reads.
    mcp = {name: {k: v for k, v in cfg.items() if k != "type" and not (k == "env" and not v)}
           for name, cfg in servers.items()}
    ext = {
        "name": plugin["name"],
        "version": plugin["version"],
        "description": plugin["description"],
        "contextFileName": "AGENTS.md",
        "mcpServers": mcp,
    }
    return json.dumps(ext, indent=2, ensure_ascii=False) + "\n"


def generated(repo):
    """Every file this script owns, computed from its source: {relative path: (source, text)}."""
    agents = read_source(repo, "AGENTS.md")
    files = {path: ("AGENTS.md", front + agents) for path, front in RULE_COPIES}
    for md in sorted((repo / "commands").glob("*.md")):
        md_rel = f"commands/{md.name}"
        files[f"commands/{md.stem}.toml"] = (md_rel, toml_command(repo, md_rel))
    files["gemini-extension.json"] = (".claude-plugin/plugin.json and .mcp.json", gemini_extension(repo))
    return files


def load_hosts(repo):
    try:
        import yaml  # PyYAML: a required prerequisite (requirements.json)
    except ImportError as exc:
        raise NoVerdict("PyYAML is not installed — see requirements.json") from exc
    try:
        hosts = yaml.safe_load(read_source(repo, HOSTS))
    except yaml.YAMLError as exc:
        raise NoVerdict(f"{HOSTS} is not valid YAML: {exc}") from exc
    if not isinstance(hosts, list):
        raise NoVerdict(f"{HOSTS} is not a list of hosts")
    return hosts


def invariants(repo):
    """Everything that must hold but is not generated — one REFUSE line per breach."""
    refusals = []
    if (repo / OLD_HOOKS).exists():
        refusals.append(f"REFUSE: {OLD_HOOKS} exists — Gemini CLI and Copilot CLI auto-load that path in "
                        f"formats of their own; the Claude map lives at hooks/claude-hooks.json")

    version = read_json(repo, ".release-please-manifest.json").get(".")
    extra = {entry.get("path") for entry in
             read_json(repo, "release-please-config.json")["packages"]["."].get("extra-files", [])}
    for rel in VERSIONED:
        manifest = read_json(repo, rel)
        if manifest.get("version") != version:
            refusals.append(f"REFUSE: {rel} is at version {manifest.get('version')!r}, the release-please "
                            f"manifest at {version!r} — never bump by hand; take the manifest's value")
        if rel not in extra:
            refusals.append(f"REFUSE: {rel} is not in release-please-config.json's extra-files — "
                            f"the next release would leave it behind")
    for rel in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json", ".github/plugin/plugin.json"):
        manifest = read_json(repo, rel)
        for key in ("skills", "hooks", "mcpServers"):
            target = manifest.get(key)
            if isinstance(target, str) and not (repo / target.removeprefix("./")).exists():
                refusals.append(f"REFUSE: {rel} names {key} {target!r}, which does not exist")

    # A TOML command outlives a deleted .md otherwise — build never touches it again, and Gemini keeps
    # offering a command the kit no longer has.
    for toml in sorted((repo / "commands").glob("*.toml")):
        if not toml.with_suffix(".md").exists():
            refusals.append(f"REFUSE: commands/{toml.name} has no commands/{toml.stem}.md to be built "
                            f"from — delete it")
    for target in read_json(repo, "package.json").get("pi", {}).get("skills", []):
        if not (repo / target.removeprefix("./")).exists():
            refusals.append(f"REFUSE: package.json names pi skills {target!r}, which does not exist")

    readme = read_source(repo, "README.md")
    for host in load_hosts(repo):
        hid = host.get("id", "?")
        adapter = host.get("adapter", "")
        if not adapter or not (repo / adapter).exists():
            refusals.append(f"REFUSE: {HOSTS} host {hid} names adapter {adapter!r}, which does not exist")
        if host.get("tier") == "plugin":
            for line in host.get("install", []):
                if line not in readme:
                    refusals.append(f"REFUSE: README.md does not carry {hid}'s install line: {line}")
    return refusals


def build(repo):
    for rel, (_source, text) in generated(repo).items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {rel}")
    return 0


def check(repo):
    refusals = []
    files = generated(repo)
    for rel, (source, want) in files.items():
        # A generated file that is missing or not UTF-8 is drift like any other — build rewrites it —
        # while a SOURCE that cannot be read is no verdict at all (read_source, exit 2).
        try:
            have = (repo / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
        except FileNotFoundError:
            refusals.append(f"REFUSE: {rel} is missing — {FIX}")
            continue
        except UnicodeDecodeError:
            refusals.append(f"REFUSE: {rel} is not UTF-8 — {FIX}")
            continue
        except OSError as exc:
            raise NoVerdict(f"cannot read {rel}: {exc.strerror or exc}") from exc
        if have != want:
            refusals.append(f"REFUSE: {rel} drifted from {source} — {FIX}")
    refusals.extend(invariants(repo))
    for line in refusals:
        print(line)
    if refusals:
        return 1
    print(f"host-adapters: {len(files)} generated files in step with their sources; every invariant holds")
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    ap.add_argument("command", choices=("build", "check"))
    args = ap.parse_args()  # a usage error exits 2 — argparse's code, and this script's
    repo = pathlib.Path(args.repo)
    if not repo.is_dir():
        print(f"host-adapters: no verdict — --repo {args.repo} is not a directory", file=sys.stderr)
        return 2
    try:
        return build(repo) if args.command == "build" else check(repo)
    except NoVerdict as exc:
        print(f"host-adapters: no verdict — {exc}", file=sys.stderr)
        return 2
    except (KeyError, TypeError, AttributeError) as exc:
        print(f"host-adapters: no verdict — a manifest is missing a field it must carry ({exc!r})",
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
