# Audit — fleurs-du-mal-winrt

> **✅ MIGRÉE ET DÉPLOYÉE (2026-07-23)** — https://phmatray.github.io/fleurs-du-mal-winrt/ ·
> ~30 min réalisées pour 18 j estimés · 35 tests, couverture 91 % · rapport : `migration/report.html` du repo.
> Note d'audit corrigée sur le terrain : l'« architecture en couches » (5 projets Business/DataAccess)
> était un échafaudage vide — la vraie valeur portable était le corpus JSON, les modèles du projet
> principal et **le dessin original d'une artiste** (`Assets/Background.png`), repris octet pour octet.

**Lecture des *Fleurs du Mal* de Baudelaire** · WinRT 8.x · actif 2014-02 → dernier commit 2026-02

## Carte d'identité

| | |
|---|---|
| Ère | `winrt-8x` (Windows Store 8.1 — plateforme morte) |
| Projets | 7 — dont une **vraie architecture en couches** : `Business`, `Business.Entities`, `Business.Interfaces`, `DataAccess`, `DataAccess.Interfaces` |
| Taille | 35 fichiers C# · 3 608 LOC (918 code-behind, 2 690 logique) |
| Stack | MvvmLight, Newtonsoft.Json, WinRT XAML Toolkit |
| Tests | Aucun |

RoselineMCP `analyze_solution` : la solution se charge (7 projets) mais 2 924 erreurs de résolution — assemblies WinRT indisponibles hors Windows → audit structurel (cf. synthèse).

## Surface UI (à réécrire en Razor + Tailwind)

7 pages : Hub, Gallery, GroupedPoems, GroupPoem, Section, Item, PoemDetail. Navigation type hub/section/détail — se transpose naturellement en routes Blazor + layouts.

## APIs plateforme → web

| Cluster (occurrences) | Équivalent |
|---|---|
| Windows.UI (99) | Composants Razor (couvert par la réécriture des pages) |
| Windows.Storage (6) | `localStorage` (préférences de lecture) — 0,5 j |
| Windows.ApplicationModel (6) | PWA manifest — 1 j |

## Extractibilité — l'argument économique

**75 % du code (2 690 / 3 608 LOC) est de la logique en couches, portable telle quelle** en class library .NET 10 : entités (poèmes, sections), accès aux données, interfaces. Le contenu (l'œuvre) est un actif pur. Seul le code-behind XAML (25 %) est jeté.

## Effort

3 (socle) + 7 × 1,5 (pages) + 1,5 (clusters) = 15 j · +20 % (aucun test) = **18 j** → fourchette **13–23 j**

## Cible recommandée : **Blazor WebAssembly statique (PWA)**

Contenu autonome, zéro backend, hébergement gratuit (GitHub Pages). Lecture hors-ligne via service worker — mieux que l'app d'origine.

## Risques & coût de l'inaction

- Plateforme **non installable** depuis Windows 11 : l'app est déjà morte pour ses utilisateurs.
- Le contenu (curation de l'œuvre) est piégé dans un format sans avenir.
- Valeur vitrine élevée : app culturelle, visuelle, parfaite en démo publique de portage.
