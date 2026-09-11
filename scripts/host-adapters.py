#!/usr/bin/env python3
"""host-adapters.py — build, and check, the files that carry one of the kit's sources to another host.

Why this exists (#525, #526). The kit is written for Claude Code and reaches every other host through
adapters. Copies kept by hand drift, and the drift is silent: every host still loads something, just
yesterday's. ponytail, which ships the same shape to twenty hosts, keeps its copies honest with a
compare script (dietrichgebert/ponytail, `scripts/check-rule-copies.js`). This is the kit's, with one
difference: `build` WRITES every derived file from its source, and `check` computes the same bytes in
memory and refuses any file on disk that differs — so a derived file is never edited, only rebuilt,
and has exactly one author.

Two kinds of thing are checked:

  generated  `generated(repo)` returns {relative path: text} — today the rule copies of `AGENTS.md`
             for the hosts that read a rules folder of their own (Cursor, Windsurf, Cline, Kiro,
             GitHub Copilot, Antigravity).
  invariants what cannot be generated but must hold (`invariants(repo)`, one REFUSE line each): the
             Claude hooks map stays off `hooks/hooks.json`, the path Gemini CLI and Copilot CLI
             auto-load in formats of their own; every path a manifest names resolves; and every
             plugin manifest carries the release-please version and is one of its `extra-files`,
             so a release can never leave one host a version behind.

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

SOURCE = "AGENTS.md"
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

# Where Claude Code's own hook map must NOT live: Gemini CLI and Copilot CLI auto-load this exact
# path from an installed extension or plugin, each in an event vocabulary of its own (#526).
OLD_HOOKS = "hooks/hooks.json"

# The plugin manifests: each names component paths (skills, hooks, mcpServers) that must resolve,
# and carries a version release-please must bump through `extra-files` — one missing from that list
# is a manifest that silently stays behind on the next release.
MANIFESTS = (
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".github/plugin/plugin.json",
)


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


def generated(repo):
    """Every file this script owns, computed from its source: {relative path: text}."""
    agents = read_source(repo, SOURCE)
    return {path: front + agents for path, front in RULE_COPIES}


def invariants(repo):
    """Everything that must hold but is not generated — one REFUSE line per breach."""
    refusals = []
    if (repo / OLD_HOOKS).exists():
        refusals.append(f"REFUSE: {OLD_HOOKS} exists — Gemini CLI and Copilot CLI auto-load that path in "
                        f"formats of their own; Claude Code's map lives at hooks/claude-hooks.json")

    version = read_json(repo, ".release-please-manifest.json").get(".")
    packages = read_json(repo, "release-please-config.json").get("packages", {})
    extra = {entry.get("path") for entry in packages.get(".", {}).get("extra-files", [])}
    for rel in MANIFESTS:
        manifest = read_json(repo, rel)
        for key in ("skills", "hooks", "mcpServers"):
            target = manifest.get(key)
            if isinstance(target, str) and not (repo / target.removeprefix("./")).exists():
                refusals.append(f"REFUSE: {rel} names {key} {target!r}, which does not exist")
        if manifest.get("version") != version:
            refusals.append(f"REFUSE: {rel} is at version {manifest.get('version')!r} but the release-please "
                            f"manifest is at {version!r} — take the manifest's value, never bump by hand")
        if rel not in extra:
            refusals.append(f"REFUSE: {rel} is not in release-please-config.json's extra-files — the next "
                            f"release would leave it a version behind")
    return refusals


def build(repo):
    for rel, text in generated(repo).items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {rel}")
    return 0


def check(repo):
    refusals = []
    for rel, want in generated(repo).items():
        # A copy that is missing or not UTF-8 is drift like any other — build rewrites it — while a
        # SOURCE that cannot be read is no verdict at all (read_source, exit 2).
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
            refusals.append(f"REFUSE: {rel} drifted from {SOURCE} — {FIX}")
    refusals.extend(invariants(repo))
    for line in refusals:
        print(line)
    if refusals:
        return 1
    print(f"host-adapters: {len(RULE_COPIES)} rule copies in step with {SOURCE}; every invariant holds")
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


if __name__ == "__main__":
    sys.exit(main())
