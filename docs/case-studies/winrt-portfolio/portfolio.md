# Synthèse portefeuille — WinRT/UWP/WP → Blazor

**Audit exécutif du 2026-07-22** · 6 applications · ai-migration-kit `/migrate-audit` · chiffres issus de `scripts/audit-inventory.sh` (JSON reproductibles)
**Dashboard interactif :** [dashboard.html](dashboard.html) (auto-contenu — ouvrez-le dans un navigateur)

## L'essentiel en trois phrases

Six applications sur plateformes mortes ou mourantes représentent **34 611 LOC, dont 89 % (30 854 LOC) de logique portable telle quelle** vers .NET 10 — seule l'UI XAML se réécrit (en Razor + Tailwind). L'effort total recommandé est de **101 jours ±30 %** en trois vagues, en commençant par deux quick wins de 13 jours chacun. Une application (`winrt-mobile-vikings`) ne doit **pas** être migrée en l'état : son API externe est probablement morte.

## Le portefeuille

| App | Ère | UI (pages+ctrl) | LOC | Portable | Effort (j) | Valeur | Cible |
|-----|-----|------|-----|----------|-----------|--------|-------|
| **winrt-sokoban** | WinRT 8.x | 4 | 2 129 | 77 % | **13** (9–17) | ⭐⭐⭐ démo jouable | WASM statique PWA |
| **chords** | Win Phone (+WPF) | 4 | 5 117 | **94 %** (lib testée xUnit) | **13** (9–17) | ⭐⭐⭐ synergie musique | WASM PWA mobile-first |
| **fleurs-du-mal-winrt** | WinRT 8.x | 7 | 3 608 | 75 % (archi en couches) | **18** (13–23) | ⭐⭐⭐ vitrine culturelle | WASM statique PWA |
| **pokedex** | UWP | 10+9 | 16 486 | **95 %** (backend AspNetCore conservé) | **29** (20–37) | ⭐⭐ démo fullstack | WASM + backend existant |
| **popcorn-time** | UWP | 12+4 | 3 493 | 80 % | **28** (20–36) | ⭐ démo privée (⚠️ YTS) | WASM + proxy |
| **winrt-mobile-vikings** | WinRT 8.x | 4 | 3 778 | 87 % *sur le papier* | (14) | ⛔ **ne pas migrer** | Vérifier l'API (0,5 j) puis archiver |

## Matrice valeur / effort — ordre recommandé

```
 Valeur
   ▲
 ⭐⭐⭐ │ sokoban(13)  chords(13)   fleurs-du-mal(18)
 ⭐⭐  │                            pokedex(29)
 ⭐   │                            popcorn-time(28)
 ⛔   │ mobile-vikings(hold)
      └────────────────────────────────────▶ Effort (jours)
        quick wins ◄──              ──► gros morceaux
```

1. **Vague 1 — quick wins (26 j)** : `winrt-sokoban` + `chords`. Deux livrables visibles (un jeu jouable dans le navigateur, une PWA mobile avec lib métier testée) qui valident la méthode et le socle commun Blazor/Tailwind.
   ✅ **`winrt-sokoban` : FAIT (2026-07-22, une session)** — moteur porté octet pour octet, 16 tests de caractérisation, PWA jouable (90 niveaux), captures dans `captures/`. Voir la fiche [winrt-sokoban](winrt-sokoban.md).
2. **Vague 2 (18 j)** : `fleurs-du-mal-winrt` — la vitrine publique.
3. **Vague 3 (29 j)** : `pokedex` — la démo fullstack (le backend AspNetCore existant est branché tel quel).
4. **Optionnel (28 j)** : `popcorn-time` en démo technique privée (risque YTS documenté).
5. **Hold** : `winrt-mobile-vikings` — 0,5 j de vérification d'API avant toute décision. Un portefeuille se gère aussi en décidant ce qu'on ne migre **pas**.

**Total recommandé (vagues 1–3) : 60 j ±30 %** · portefeuille complet hors hold : 101 j.

## Mutualisation (non chiffrée dans les fiches, à déduire)

Les vagues partagent : socle Blazor + Tailwind, service worker/PWA, patron MVVM → composants, mapping `Windows.Storage → localStorage`. Estimation prudente : **−15 à −20 % dès la vague 2** — la formule par app ne compte pas cette courbe d'apprentissage, les fourchettes hautes sont donc pessimistes.

## Méthode & limites (transparence)

- Chiffres : `scripts/audit-inventory.sh` sur clones du 2026-07-22 (LOC non vides, hors `obj/bin`, hors code généré).
- RoselineMCP `analyze_solution` tenté sur `fleurs-du-mal-winrt` : la solution se charge (7 projets) mais 2 924 erreurs de résolution — les assemblies de référence WinRT n'existent pas hors Windows. **Bascule documentée sur l'inventaire structurel** conformément à `audit-executive.md` ; sur un poste Windows, l'analyse Roslyn complète est possible.
- Formule d'effort : socle 3 j + 1,5 j/page + 1 j/contrôle + clusters d'API (0,5–2 j) + 20 % si aucun test — fourchette ±30 %. Le détail figure dans chaque fiche.
- « Portable tel quel » = LOC hors code-behind XAML ; la réécriture UI inclut l'accessibilité WCAG 2.1 AA.

## Coût de l'inaction (portefeuille)

Aucune de ces apps n'est installable par un utilisateur en 2026. 30 854 lignes de logique — moteurs de jeu, domaine musical testé, couches d'accès aux données, un backend complet — sont **des actifs dormants piégés dans des UI mortes**. Chaque année d'attente augmente la dette de connaissance (outillage, mémoire du code) sans réduire le coût de sortie.
