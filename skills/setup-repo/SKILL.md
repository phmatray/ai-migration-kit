---
name: setup-repo
description: >-
  Bring a GitHub repository to the configuration the issue/PR lifecycle skills assume — the label
  taxonomy (type, priority, effort, area), the issue forms under .github/ISSUE_TEMPLATE/, and the
  repository settings (delete-branch-on-merge, squash-only merges). Deterministic and idempotent:
  a declarative manifest, a read-only `plan` that prints the drift, and an `apply` that converges
  it. Use whenever a repo needs configuring for these skills or has drifted — "set up the labels",
  "create the issue templates", "turn on auto-delete merged branches", "configure this repo the
  way the kit expects", "why does auto-dev ignore my effort labels", « configure les labels du
  repo », « crée les templates d'issue », « supprime automatiquement les branches mergées ». It is
  the write half of get-repo-profile, which only READS a repo's conventions and reports what it
  could not find. Does NOT file issues, implement code, or merge PRs.
license: MIT
compatibility: >-
  Requires git, python3 with PyYAML, jq, and an authenticated gh CLI. Without gh the label and
  settings surfaces are reported as refused and the run exits 3 with the local issue-form copy
  still applied. The settings surface additionally needs a token with admin rights on the target
  repository; without one it is refused by name rather than silently skipped.
metadata:
  author: Philippe Matray
  suite: ai-migration-kit
---

# Configure a repository for the lifecycle skills

`create-issue`, `implement-issue`, `merge-pr` and `auto-dev` are generic workflows wrapped around a
thin layer of repo-specific facts. `get-repo-profile` records those facts — and when it finds none,
its only outlet is a `TODO:` line. That is the right answer for a fact it cannot read and the wrong
one for a **configuration the repo does not have**, which is what four of its TODOs always are:

| What the profile reports | What it actually means | What silently degrades |
|---|---|---|
| no `priority:` axis | the labels were never created | `create-issue` omits the axis |
| no `effort:` axis | the labels were never created | `auto-dev`'s "small first, then medium" ordering has nothing to sort on |
| no `area:` axis | the labels were never created | `auto-dev` cannot give parallel workers non-overlapping areas |
| no `.github/ISSUE_TEMPLATE/` | the directory was never created | `create-issue` has no form to obey |

This skill is the missing verb. It does not describe a repo; it makes one.

## Do this

A bundled script does the deterministic work. Run it from anywhere in the target repo (it anchors
to the git root). `<skill-dir>` is this skill's base directory — given when the skill loads:

```bash
bash "<skill-dir>/scripts/repo-setup.sh" plan
```

`plan` writes nothing, so it is safe against a repository you only read. Show the operator the
delta it prints, then converge:

```bash
bash "<skill-dir>/scripts/repo-setup.sh" apply
```

Read the exit code — it is the report, and each value means one thing:

| Exit | Meaning | What to do |
|---|---|---|
| 0 | converged | Say so. Nothing to do. |
| 1 | `plan` found drift | Show the delta, then run `apply` — **except** a `!TODO` line: `apply` never creates a placeholder, so fill it into the manifest instead (#198). |
| 2 | bad usage, or an unreadable/unparseable manifest | Fix the manifest; never partially apply. |
| 3 | a surface was refused | Relay **which** surface and why — the report names it. The rest did land. |
| 4 | not inside a git repository | Say so and stop. |

## The desired state

`templates/repo-setup.yml` in the kit is the shipped default. A consumer repo overrides it by
committing its own `.github/repo-setup.yml`, which `repo-setup.sh` prefers — so a consumer's
taxonomy survives a kit upgrade. `--manifest <path>` overrides both.

Four rules govern what `apply` will and will not do, and they are worth relaying to the operator
before the first run against a repo that already has labels:

- **Additive.** A live label the manifest does not declare is reported `!EXTRA` and **kept**. Only
  `--prune` deletes anything. A repo already running `P1`/`P2` must not have its taxonomy renamed
  out from under it.
- **`pruneKeep` outranks `--prune`.** Labels a *tool* owns look undeclared because no human
  declares them, and deleting them breaks the automation that reads them. The manifest's
  `pruneKeep` globs — seeded with release-please's `autorelease: *` and Renovate's `dependencies` —
  are reported `!KEEP` and never deleted. Add the repo's own bot labels there before running
  `--prune` on it.
- **Never clobber.** An issue form that already exists is reported `!SKIP`. A tuned form outranks
  the kit's default.
- **A name in angle brackets is a placeholder** — never created, and reported `!TODO` **and counted
  as drift** on every run (`plan` exits 1), so an unfilled axis stays visible instead of looking
  converged (#198). The `area:` axis ships this way because it names the consumer's code, not the
  kit's: fill it in before `auto-dev` runs a fleet — `apply` will not resolve this one for you.

## Autonomy contract

Run **hands-off**. `plan` is a read — no task list or precondition ceremony. Before `apply`, show
the delta and get a yes when the repo is not the user's own or the run includes `--prune`; a
straightforward `apply` on their own repo needs no gate.

Never invent a taxonomy. If the manifest lacks an axis the repo needs, edit the **manifest** and
re-run — an axis created by hand with `gh label create` is exactly the non-deterministic setup this
skill exists to replace. When a surface is refused, report it and move on: a partially configured
repo with a named gap beats an abort that leaves the operator guessing which half landed.

## Afterwards

Re-run `get-repo-profile --refresh`. The four TODOs are facts now, so the profile records the real
axes and the lifecycle skills start applying them.

`plan` exiting 1 on drift makes it usable as a CI step, if the repo wants configuration drift to go
red the way code drift does.
