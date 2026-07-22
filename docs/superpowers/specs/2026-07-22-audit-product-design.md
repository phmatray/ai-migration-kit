# Audit Product — Design (WinRT → Blazor portfolio audit)

**Date:** 2026-07-22 · **Extends:** ai-migration-kit v1.0.0
**Direction produit (validée) :** faire de l'audit le produit d'entrée du kit, démontré sur un portefeuille réel d'apps WinRT/UWP/Windows Phone à moderniser vers Blazor.

## Problem

`/migrate-assess` parle aux développeurs (diagnostics, TFM). Celui qui décide d'un budget de migration a besoin d'autre chose : exposition au risque, effort chiffré en jours, cible recommandée, ordre de priorité sur un portefeuille. Et pour les apps à plateforme UI morte (WinRT/UWP/WP), la question n'est pas « bump de TFM » mais « réécriture UI + portage de la logique » — un audit différent.

## Decision

1. **Nouvelle commande `/migrate-audit [apps...]`** — audit exécutif, lecture seule. Une app → un rapport ; plusieurs apps → rapports + synthèse portefeuille.
2. **Nouveau guide `references/audit-executive.md`** — format du rapport, formule d'effort, correspondances API Windows → web, stratégie de dégradation d'analyse.
3. **Script `scripts/audit-inventory.sh`** — inventaire mesurable et reproductible d'un repo (JSON) : type de projet/ère, pages et contrôles XAML, LOC code-behind vs logique, clusters d'API `Windows.*`/`Microsoft.Phone`, packages, tests. Le script mesure ; l'agent interprète.
4. **Démonstration réelle** : audit de 6 apps du portefeuille GitHub de l'auteur (`fleurs-du-mal-winrt`, `winrt-sokoban`, `popcorn-time`, `pokedex`, `winrt-mobile-vikings`, `chords`), livré dans `docs/case-studies/winrt-portfolio/` + dashboard HTML (artifact privé).

## Rapport exécutif par app (sections)

1. **Carte d'identité** — ère technologique, taille, dernière activité, état.
2. **Surface UI** — pages, contrôles custom, LOC code-behind (tout est à réécrire en Razor/Tailwind).
3. **APIs plateforme** — clusters `Windows.*` détectés → équivalent web/Blazor → coût de remplacement.
4. **Extractibilité** — % LOC logique pure (modèles, services, algorithmes) réutilisable telle quelle en class library.
5. **Effort** — formule transparente, fourchette ±30 %.
6. **Cible recommandée** — Blazor WASM / Server / Hybrid, justifiée par le profil de l'app.
7. **Risques & coût de l'inaction** — plateforme morte, non-installable, dette de connaissance.

## Formule d'effort (jours)

- Base par app : **3 j** (socle Blazor + Tailwind, projet, CI, revue).
- Par page XAML : **1,5 j** · par contrôle custom : **1 j**.
- Par cluster d'API plateforme : **0,5–2 j** selon mappabilité (HttpClient → 0 ; storage → 0,5 ; notifications/tiles → 2 ; capteurs/média natif → 2 ou abandon de la fonctionnalité).
- Logique pure portée telle quelle : **0 j** (c'est l'argument de vente du portage).
- Aucun test existant : **+20 %** (tests de caractérisation sur la logique portée).

## Synthèse portefeuille

Matrice valeur/effort, ordre de migration recommandé (quick wins d'abord), totaux, et « première vague » proposée.

## Stratégie de dégradation d'analyse

RoselineMCP partout où le projet se charge dans Roslyn. Les csproj UAP/WP old-style ne se chargent pas hors Windows : l'audit **le constate explicitement** (tentative `analyze_solution` consignée) puis bascule sur l'inventaire structurel scripté. La limite est documentée dans le rapport — jamais silencieuse.

## Success criteria

- `/migrate-audit` et `audit-executive.md` dans le kit ; script d'inventaire exécutable et testé.
- 6 rapports d'app + 1 synthèse portefeuille, chiffres issus du script (pas d'estimations à main levée).
- Dashboard HTML publié (artifact privé) avec matrice valeur/effort.
