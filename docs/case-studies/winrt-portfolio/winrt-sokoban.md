# Audit — winrt-sokoban

**Jeu de puzzle Sokoban** · WinRT 8.x · actif 2014-02 → dernier commit 2026-02

## Carte d'identité

| | |
|---|---|
| Ère | `winrt-8x` (plateforme morte) |
| Projets | 1 (`Sokoban.Store`) |
| Taille | 17 fichiers C# · 2 129 LOC (497 code-behind, 1 632 logique) |
| Stack | MvvmLight |
| Tests | Aucun |

## Surface UI

4 pages (Hub, Section, Item, BasicPage1). UI de jeu simple — grille + déplacements.

## APIs plateforme → web

| Cluster | Équivalent |
|---|---|
| Windows.UI (36) | Composants Razor (couvert par la réécriture) |
| Windows.Storage (4) | `localStorage` (progression, scores) — 0,5 j |
| Windows.ApplicationModel (4) | PWA manifest — 1 j |

## Extractibilité

**77 % du code (1 632 / 2 129 LOC) est le moteur de jeu** (règles Sokoban, niveaux, détection de victoire) — portable tel quel. C'est un moteur pur : aucune dépendance plateforme dans la logique.

## Effort

3 + 4 × 1,5 + 1,5 = 10,5 j · +20 % (aucun test) = **12,6 j ≈ 13 j** → fourchette **9–17 j**

## Cible recommandée : **Blazor WebAssembly statique (PWA)**

Jeu 100 % client, clavier + tactile, installable, hors-ligne. Hébergement gratuit.

## Risques & coût de l'inaction

- App morte avec le Store 8.x ; le moteur de jeu — la partie qui a de la valeur — est invisible.
- **Quick win n°1 du portefeuille** : plus petite surface, effet démo maximal (un jeu jouable dans le navigateur).
