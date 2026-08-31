# Architectural Decision Records

> **When an ADR is warranted.** All three must hold: the decision is **hard to reverse**, it is
> **surprising without context**, and it involved a **real trade-off**. A decision that fails any of
> the three belongs in the code or in the file it governs, not here. (Ported from
> [mattpocock/skills](https://github.com/mattpocock/skills), `domain-modeling/ADR-FORMAT.md`, MIT.)
>
> Files are MADR 4.0: `NNNN-<kebab-title>.md`, YAML frontmatter (`id`, `title`, `status`, `date`,
> `tags`, optional `links` and `code_refs`), body sections `Context and Problem Statement` /
> `Considered Options` / `Decision Outcome` / `Consequences`. Keep the **Decision Outcome to one
> paragraph**. Numbering is the highest existing id + 1 — `create_adr` does this for you.
>
> Author and amend these through the `adr` MCP server (`create_adr`, `validate_adr`, `set_status`,
> `supersede_adr`, `render_index`); `python3 tests/adr/check-adrs.py` is CI's structural mirror of
> `validate_adr`, since a runner cannot start the server. The table below is exactly what
> `render_index` emits — re-running it with `previewOnly: false` rewrites the whole file, so put this
> preamble back afterwards.

| ID | Title | Status | Date |
| --- | --- | --- | --- |
| 0001 | [The repo profile is committed data, not a skill](0001-the-repo-profile-is-committed-data-not-a-skill.md) | accepted | 2026-08-31 |
| 0002 | [The roseline gate fails open, always](0002-the-roseline-gate-fails-open-always.md) | accepted | 2026-08-31 |
| 0003 | [One plugin version; no per-skill version](0003-one-plugin-version-no-per-skill-version.md) | accepted | 2026-08-31 |
| 0004 | [Squash-only merges: the PR title is the release commit](0004-squash-only-merges-the-pr-title-is-the-release-commit.md) | accepted | 2026-08-31 |
| 0005 | [The lifecycle skills run hands-off; triage-backlog does not](0005-the-lifecycle-skills-run-hands-off-triage-backlog-does-not.md) | accepted | 2026-08-31 |
| 0006 | [The kit targets Claude Code only](0006-the-kit-targets-claude-code-only.md) | accepted | 2026-08-31 |
| 0007 | [Workers are in-process sub-agents, never claude -p](0007-workers-are-in-process-sub-agents-never-claude-p.md) | proposed | 2026-08-31 |
| 0008 | [Idea-tree search](0008-idea-tree-search.md) | rejected | 2026-07-23 |
| 0009 | [Interaction modes](0009-interaction-modes.md) | rejected | 2026-07-23 |
| 0010 | [Novelty search](0010-novelty-search.md) | rejected | 2026-07-23 |
| 0011 | [Hook gates are recorded rather than registered decisions](0011-hook-gates-are-recorded-rather-than-registered-decisions.md) | accepted | 2026-08-31 |
