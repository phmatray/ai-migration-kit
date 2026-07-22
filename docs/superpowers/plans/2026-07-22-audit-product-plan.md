# Audit Product Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Livrer le produit d'audit (`/migrate-audit`) et le démontrer sur 6 apps WinRT/UWP/WP réelles avec rapports + dashboard.

**Architecture:** Extension du plugin existant (commande + guide + script d'inventaire bash→JSON) ; exécution réelle en scratchpad sur clones shallow ; livrables versionnés dans `docs/case-studies/winrt-portfolio/`.

**Tech Stack:** bash + python3 (JSON), RoselineMCP (tentative de chargement consignée), HTML/CSS inline (dashboard, skills dataviz + artifact-design).

## Global Constraints

- Audit strictement lecture seule sur les apps cibles.
- Tous les chiffres des rapports proviennent du script d'inventaire (reproductible).
- La formule d'effort de la spec est appliquée uniformément aux 6 apps.
- Échec de chargement Roslyn = constaté et documenté, jamais silencieux.

### Task 1: Kit extension

- [ ] `scripts/audit-inventory.sh <repo-dir>` → JSON {era, projects, xamlPages, xamlControls, csFiles, locTotal, locCodeBehind, locLogic, windowsApiClusters{}, packages[], hasTests, lastCommit}
- [ ] Tester le script sur `samples/LegacyShop` (JSON valide, era "modern-sdk").
- [ ] `skills/legacy-upgrade/references/audit-executive.md` (format rapport, formule, mapping API→web, dégradation).
- [ ] `commands/migrate-audit.md` (frontmatter + invocation skill, 1..N apps, read-only).
- [ ] README : section « Produit d'audit ».
- [ ] Commit `feat: executive audit product (/migrate-audit)`.

### Task 2: Portfolio run (réel)

- [ ] `gh repo clone` shallow des 6 apps en scratchpad.
- [ ] Tentative RoselineMCP `analyze_solution` sur 1 app (consigner résultat).
- [ ] Script d'inventaire sur les 6 → `inventory/*.json`.
- [ ] 6 rapports `docs/case-studies/winrt-portfolio/<app>.md` + `portfolio.md` (matrice, ordre, totaux).
- [ ] Commit `docs: WinRT->Blazor portfolio audit (6 apps)`.

### Task 3: Dashboard

- [ ] Charger skills dataviz + artifact-design ; construire `docs/case-studies/winrt-portfolio/dashboard.html` (auto-contenu, light/dark, FR).
- [ ] Publier artifact privé (favicon 📊) ; lien dans portfolio.md et README.
- [ ] Commit `feat: portfolio audit dashboard`.
