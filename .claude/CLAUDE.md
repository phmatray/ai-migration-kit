# Working on ai-migration-kit

This repo ships as a Claude Code plugin (bash + python + markdown skills, no build step). The
per-repo profile at [`.claude/skills/repo-profile.md`](skills/repo-profile.md) is the single
source of commit identity, build/test commands, CI gates, labels and conflict hot-spots — read it
first.

## Where each concern lives

- Prerequisites (runtime) → [`requirements.json`](../requirements.json), never a hard-coded list;
  `scripts/preflight.sh` reads it.
- Control-flow decisions → [`decisions/registry.json`](../decisions/registry.json) +
  [`docs/decisions.md`](../docs/decisions.md) — one id, one program, one home.
- Architectural decisions → the profile's `## ADRs` section (`.claude/skills/repo-profile.md`) — `docs/adr/`.
- Domain language → [`CONTEXT.md`](../CONTEXT.md).
- Trigger contracts → `evals/<skill>-trigger-eval.json`, the one home (#331); structure checked by `tests/skills/check-frontmatter.py`.
- Shared test preamble → `tests/_lib.sh` (`local rc=$?` must be the first statement in its trap).
- Shared skill procedures → `skills/_shared/`.
- Kit backlog (YAGNI debts) → [`docs/backlog.md`](../docs/backlog.md), hand-edited, read by
  `scripts/followups.py`.

## Adding a skill

- Frontmatter carries no `version` key — `tests/skills/check-frontmatter.py`.
- A trigger contract exists for it — `evals/<skill>-trigger-eval.json`, listed in `evals/run_all.py` and `evals/trigger_eval.py`.
- A golden suite is wired into CI — `scripts/ci-wiring-check.py`.
- A script that makes a decision is registered in `decisions/registry.json`, or named in that
  file's `not_decisions` map with a one-line reason.
- The skill is linked from `README.md` — `tests/skills/test.sh`.
- The PR title is releasable — `scripts/release-title-gate.sh`.

## The guard convention

A destructive operation gets a guard script under `skills/<skill>/scripts/`, a golden test that
exercises its **refusal** path (not just its happy one), and a CI step that runs it — never the raw
command. See the README's "Hardening a destructive operation".

## Releases

Squash-merge only; the PR title *is* the release commit release-please parses
(`scripts/release-title-gate.sh` gates it). Never bump `.claude-plugin/plugin.json` by hand.

## Commit identity

The profile's author line (`.claude/skills/repo-profile.md`) is canonical; this file sets none.
