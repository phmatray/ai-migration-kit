---
name: get-repo-profile
description: >-
  Generate or load the per-repo profile (`.claude/skills/repo-profile.md`) that the issue/PR
  lifecycle skills — `create-issue`, `implement-issue`, `merge-pr` — read for the repo-specific
  facts they would otherwise hardcode: commit identity, build/test/format commands, label taxonomy,
  merge style, conflict hot-spots, issue templates, architecture grain. Use when no profile exists
  yet, to PORT the lifecycle skills to a new repository, or to refresh after the toolchain, labels
  or CI changed — "set up the repo profile", "make these skills work in my other repo", "regenerate
  the profile", « configure le profil du repo », « fais marcher create-issue dans ce repo ». First
  call inspects the repo (build system, CI, labels, templates, merge style) and writes the profile;
  later calls just read it back. Does NOT file issues, implement code, or merge PRs — it only
  produces the config those skills consume.
license: MIT
compatibility: >-
  Requires git and bash. An authenticated gh CLI is needed for the label / branch-protection /
  identity probes — without it the profile is generated with flagged TODOs instead.
metadata:
  author: Philippe Matray
  version: 1.8.0
  suite: ai-migration-kit
---

# Resolve the repo profile (config for the issue/PR lifecycle skills)

`create-issue`, `implement-issue`, and `merge-pr` are generic *workflows* wrapped around a thin layer of
**repo-specific facts** — the commit author line, how to build and test, which label means "high
priority", whether the repo squashes or rebases, which files conflict and how to resolve them. Hardcoding
those welds the skills to one repo. This skill lifts them into a single committed file,
**`.claude/skills/repo-profile.md`**, that the three skills read at their preconditions step. Drop the
four skills into a new repo, run this once, and the lifecycle skills speak that repo's language.

The profile is **data, not a skill** — plain markdown with no `SKILL.md`, so the loader ignores it; being
committed, it travels with the repo. Because it exists, the lifecycle skills read it with a plain `cat`
and only fall back to this skill when it's missing — so most of the time this skill isn't even invoked.

## Do this

A bundled script does the deterministic work so you spend tokens on judgement, not probing. Run it
from anywhere in the repo (it anchors to the git root). `<skill-dir>` is this skill's base directory
— given when the skill loads:

```bash
bash "<skill-dir>/scripts/repo-profile.sh" show
```

- **It printed the profile** (and no `--refresh` was asked) → **you're done.** Relay the headline values
  (repo slug, commit identity, build/test/format commands, integration style) so the caller sees what's
  in force. Don't regenerate.
- **It printed `NO_PROFILE`** (exit 3), or the user asked to **`--refresh`** / "set up" / "regenerate" →
  this is the rare generation path. **Read `references/generating.md` and follow it.** In short: run
  `scripts/repo-profile.sh detect`, fill `references/profile-template.md` from the facts it emits, write
  the result to `.claude/skills/repo-profile.md`, and report what you wrote + every TODO you left.

## Autonomy contract

Run **hands-off**. The `show` path is a file read — no need for a task list or precondition ceremony. The
generation path is best-effort inference, not interrogation: fill what `detect` proves, and for anything
it couldn't (a `TODO:` line in its output) write a clearly-marked `<!-- TODO: ... -->` placeholder and
flag it in the report rather than stopping. A profile with a few honest TODOs beats no profile; never
invent a value you couldn't verify — a wrong build command or commit identity is worse than a flagged
blank. Stop only for a real blocker: not inside a git repo (nothing to profile — `detect` exits 4), or
`gh` unauthenticated *and* the gh-only facts can't be read another way (tell the user to run
`! gh auth login -h github.com`).

## Inputs

- **`--refresh`** — regenerate even if a profile exists (re-detect everything; preserve any human-edited
  TODO answers you can still see in the current file).
- A path argument — profile a repo other than the current directory (pass it as the `[dir]` arg to the
  script: `repo-profile.sh show /path/to/repo`).
