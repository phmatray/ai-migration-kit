# Code review — ai-migration-kit (2026-07-23)

**main @ a75be47**

Backlog prioritization: two dogfood triggers fired the same day (2026-07-23) and they are the two edges of one end-of-phase-1 verdict gate.

| Reviewer | Rating | Verdict |
|---|---|---|
| 🔥 Elon Musk | 8/10 | You already know what to build — two triggers fired the same day and they're the same change; stop writing it down and wire the phase-1 verdict. |

## Findings

### Major
- [ ] **/migrate produces nonsense on an already-modern target (no ALREADY_MODERN verdict)** — `skills/legacy-upgrade/references/phase-1-assess.md:13` (M)
  Add a modernity gate at the end of phase 1: if all TFMs are in {latest LTS, requested target} AND no out-of-support runtime AND no obsolete-API cluster (SYSLIB/packages.config/BinaryFormatter), set recommended target = 'none, already up to date', write verdict: ALREADY_MODERN into assessment.md, and have /migrate stop after phase 1 (like /migrate-assess). Route a modern-but-wants-a-report case explicitly to /migrate-verify (phase 6) — modern != clean; StaticWGen's only successful restore surfaced NU1903 (System.Security.Cryptography.Xml 9.0.0, high-severity transitive).
- [ ] **Phase 2 green-baseline gate blocks the exact repos the tool exists for (TFM lagging its packages)** — `skills/legacy-upgrade/references/phase-2-baseline.md:7` (M)
  Have phase 1/2 recognize the 'baseline red caused by a TFM lagging its packages' case (signature: NU1202 'package X supports netN.0' on a TFM netM.0 with M<N), set verdict: RED_BY_TFM_LAG, and establish the first green POST-retarget as the recorded baseline. Corollary (rules 5 + 9): making a long-broken build compile can expose large pre-existing, framework-unrelated breakage (DotnetChain: half-finished domain refactor, 536 CS errors) — the kit repairs everything verifiable and names the edges without inventing missing behavior.
- [ ] **Findings 1 and 2 are one end-of-phase-1 classifier, not two tickets** — `commands/migrate.md:10` (M)
  Wire ONE verdict field on assessment.md — verdict: {ALREADY_MODERN | RED_BY_TFM_LAG | NORMAL} — computed at the end of phase 1, and branch /migrate on it at exactly one place: ALREADY_MODERN -> stop (offer /migrate-verify), RED_BY_TFM_LAG -> retarget-then-baseline, NORMAL -> proceed to phase 2 unchanged. Update the SKILL.md pipeline table and Artifact contract to document the verdict. No new scope command.

### Minor
- [ ] **New verdict gate has no regression lock (dogfood cases will be forgotten)** — `docs/backlog.md:25` (S)
  Capture each dogfood case as a documented assessment fixture: the input signature (TFMs, package graph, diagnostics) and the expected verdict. Add them to the phase-1 reference (or a golden test alongside the other kit golden tests) so the verdict logic is covered the way followups (16/16) and the report generator already are.

### Info
- [ ] **The other five backlog items have unfired triggers — keep them unbuilt** — `docs/backlog.md:6` (S)
  Do nothing on these five this cycle. Leave them in the file with their triggers intact. Revisit each only when its named trigger actually fires.

## Action plan

1. [ ] Ship ONE end-of-phase-1 verdict gate covering both symptoms (ALREADY_MODERN stop + RED_BY_TFM_LAG retarget-then-baseline), NORMAL unchanged (M)
2. [ ] Pin StaticWGen and DotnetChain as documented regression cases for the verdict so it can't drift (S)
3. [ ] Leave the other five backlog items unbuilt until their triggers fire (S)

---
Generated from report.json by legends-review — data lives in the JSON, the HTML is always regenerated, never edited by hand.
