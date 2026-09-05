---
title: Home
nav_order: 1
---

# AI Migration Kit

<section class="kit-hero">
<p class="kit-hero-lead">A Claude Code plugin with two loops. One takes a legacy .NET application to verified production, with RoselineMCP doing every C# analysis and transformation. The other takes a GitHub issue to a merged pull request, hands-off. Every step of both runs behind a gate that refuses by name.</p>
<div class="kit-loop">
<p class="kit-loop-name">Migrate a legacy .NET application</p>
<ol class="kit-stages"><li>assess</li><li>baseline</li><li>retarget</li><li>remediate</li><li>modernize</li><li>verify</li><li>deliver</li></ol>
</div>
<div class="kit-loop">
<p class="kit-loop-name">Take an issue to a merged pull request</p>
<ol class="kit-stages"><li>create-issue</li><li>implement-issue</li><li>merge-pr</li></ol>
</div>
</section>

**Start with [the methodology](methodology.md)** — the two loops in full, when to call which
skill, one page per skill, the machinery, where each MCP server is used, and how the kit compares
to GSD, SpecKit and BMAD.

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

- [Decisions](decisions.md) — control-flow decisions have one program and one home.
- [Architectural Decision Records](adr/README.md) — the decisions that are hard to reverse, and the ones declined.
- [The roseline gate](roseline-gate.md) — why every C# read and write goes through RoselineMCP.
- [The bundle gate](bundle-gate.md) — the opt-in drift gate for committed bundles.
- [Demo walkthrough](demo-walkthrough.md) — a real pipeline run on the bundled legacy fixture.
- [Case studies](case-studies/winrt-portfolio/portfolio.md) — four dead-platform apps migrated and verified live.
- [Journal](journal/index.md) — one article per release: why it happened, what got cut, what bit us.

## On GitHub

- [README](https://github.com/phmatray/ai-migration-kit#readme) — install, the skill table, how a destructive operation is hardened.
- [ARCHITECTURE.md](https://github.com/phmatray/ai-migration-kit/blob/main/ARCHITECTURE.md) — the dependency graph and the compatibility matrix.
- [CONTEXT.md](https://github.com/phmatray/ai-migration-kit/blob/main/CONTEXT.md) — the domain language.
- [CHANGELOG](https://github.com/phmatray/ai-migration-kit/blob/main/CHANGELOG.md) — every release.

## Install

```bash
claude plugin marketplace add phmatray/ai-migration-kit
claude plugin install ai-migration-kit
```
