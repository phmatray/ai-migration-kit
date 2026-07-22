# Audit — winrt-mobile-vikings

**Client de compte Mobile Vikings** · WinRT 8.x · actif 2014-02 → dernier commit 2026-02

## Carte d'identité

| | |
|---|---|
| Ère | `winrt-8x` (plateforme morte) |
| Projets | 1 (`AppMobileVikings.UI.Store`) |
| Taille | 43 fichiers C# · 3 778 LOC (473 code-behind, 3 305 logique) |
| Stack | MvvmLight, Newtonsoft.Json |
| Tests | Aucun |

## Surface UI

4 pages (Hub, Section, Item, BasicPage1).

## APIs plateforme → web

| Cluster | Équivalent |
|---|---|
| Windows.UI (57) | Composants Razor |
| Windows.Storage (13) | `localStorage` — 0,5 j |
| Windows.Security (2) | Auth backend — 1 j |
| Windows.ApplicationModel (3) | PWA — 1 j |
| System.Net.Http (2) | `HttpClient` — 0 j |

## Extractibilité

87 % du code (3 305 / 3 778 LOC) : client API + modèles, techniquement portables tels quels.

## Effort (si migration)

3 + 4 × 1,5 + 2,5 = 11,5 j · +20 % (aucun test) = **13,8 j ≈ 14 j** → fourchette **10–18 j**

## Recommandation : **NE PAS migrer maintenant** ⛔

L'app dépend de l'**API historique Mobile Vikings (VikingCo, ère 2014)** dont la disponibilité est plus qu'incertaine — l'opérateur a changé de mains et de plateforme. Migrer une UI vers une API morte produit un portage réussi d'une app inutilisable.

**Décision recommandée :** vérifier en 0,5 j si une API publique actuelle existe. Si oui → re-chiffrer (le client API sera à réécrire : l'extractibilité tombe). Si non → **archiver** et réinvestir les ~14 j sur les quick wins du portefeuille.

## Coût de l'inaction

Nul — c'est précisément pourquoi l'audit la déprioritise. Un portefeuille se gère aussi en décidant ce qu'on ne migre pas.
