#!/usr/bin/env python3
"""host-adapters.py — build, and check, the files that carry one of the kit's sources to another host.

Why this exists (#525). The kit's routing text has one home, `AGENTS.md`. Hosts that read a rules
folder of their own — Cursor, Windsurf, Cline, Kiro, GitHub Copilot, Antigravity — each want a copy
at a path they choose, some behind front matter they require. Copies kept by hand drift, and the
drift is silent: every host still loads a rule, just yesterday's. ponytail, which ships the same
shape to twenty hosts, keeps its copies honest with a compare script
(dietrichgebert/ponytail, `scripts/check-rule-copies.js`). This is the kit's, with one difference:
`build` WRITES every copy from its source, and `check` computes the same bytes in memory and refuses
any file on disk that differs. A copy is never edited — only rebuilt — so it has exactly one author.

`generated(repo)` is the single list of what this script owns: `{relative path: text}`. A new
adapter that is derived from a source joins that function; nothing else needs to learn about it.

Line endings: a copy is compared after CRLF -> LF, so a Windows checkout is not drift; `build`
always writes LF, the repository's own convention (`.gitattributes`).

Usage:
  host-adapters.py [--repo <path>] build
  host-adapters.py [--repo <path>] check

Exit codes:
  0  build wrote every generated file · check found every one in step with its source
  1  REFUSE (check) — one line per generated file that is missing or differs, and the fix
  2  usage or plumbing — a source could not be read, so no verdict is possible. NOT a pass.
"""
import argparse
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


class NoVerdict(Exception):
    """A source is unreadable: exit 2, never a pass."""


def read_source(repo, rel):
    try:
        return (repo / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as exc:
        raise NoVerdict(f"{rel} is not UTF-8 ({exc.reason})") from exc
    except OSError as exc:
        raise NoVerdict(f"cannot read {rel}: {exc.strerror or exc}") from exc


def generated(repo):
    """Every file this script owns, computed from its source: {relative path: text}."""
    agents = read_source(repo, SOURCE)
    return {path: front + agents for path, front in RULE_COPIES}


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
    for line in refusals:
        print(line)
    if refusals:
        return 1
    print(f"host-adapters: {len(RULE_COPIES)} rule copies in step with {SOURCE}")
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
