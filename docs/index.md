---
title: Home
nav_order: 1
---

# AI Migration Kit

A Claude Code plugin with two loops: a **gate-verified pipeline** that takes a legacy .NET
application from a read-only assessment to verified production, with RoselineMCP doing every C#
analysis and transformation — and a **hands-off GitHub issue → PR lifecycle** (`create-issue`,
`implement-issue`, `merge-pr`, a fleet supervisor above them, an outlet that prunes the queue, a
retro that learns from the transcripts) that runs on any repository through one committed profile.

**Start with [the methodology](methodology.html)** — the two loops, when to call which skill, one
page per skill, the machinery, where each MCP server is used, and how it compares to GSD, SpecKit
and BMAD.

## Which command?

| Situation | Reach for |
|---|---|
| An idea to track | `create-issue` |
| An issue with a plan | `implement-issue #N` |
| A PR to land | `merge-pr #N` |
| One idea or issue to a merged PR, hands-off | `deliver-issue <idea>` or `#N` |
| A queue that never shrinks | `triage-backlog` |
| Many issues, hands-off | `auto-dev` |
| What went wrong in my last sessions | `review-sessions` |
| A legacy .NET app | `/migrate-assess`, then `/migrate` |
| A migrated app to re-verify | `/migrate-verify` |
| A portfolio to cost | `/migrate-audit` |
| Open follow-ups across migrated repos | `/migrate-followups` |
| A new repo for these skills | `profile-repo`, then `setup-repo` |
| Something is already broken | `debug-issue` fires on its own |

## The rest of the site

- [Decisions](decisions.html) — control-flow decisions have one program and one home.
- [Architectural Decision Records](adr/) — the decisions that are hard to reverse, and the ones declined.
- [The roseline gate](roseline-gate.html) · [The bundle gate](bundle-gate.html)
- [Demo walkthrough](demo-walkthrough.html) — a real pipeline run on the bundled legacy fixture.
- [Case studies](case-studies/winrt-portfolio/portfolio.html) — four dead-platform apps migrated and verified live.
- [Kit backlog](backlog.html) — the YAGNI debts, each with the trigger that makes it worth paying.

On GitHub: [README](https://github.com/phmatray/ai-migration-kit#readme) ·
[ARCHITECTURE.md](https://github.com/phmatray/ai-migration-kit/blob/main/ARCHITECTURE.md) ·
[CONTEXT.md](https://github.com/phmatray/ai-migration-kit/blob/main/CONTEXT.md) ·
[CHANGELOG](https://github.com/phmatray/ai-migration-kit/blob/main/CHANGELOG.md)

```bash
claude plugin marketplace add phmatray/ai-migration-kit
claude plugin install ai-migration-kit
```
