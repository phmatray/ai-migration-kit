# Audit — popcorn-time

**Navigateur de films UWP (YTS / TheMovieDB)** · UWP · actif 2016-07 → dernier commit 2026-02

## Carte d'identité

| | |
|---|---|
| Ère | `uwp` (10.x — en fin de vie, plus d'évolutions) |
| Projets | 3 — `MovieTime.UwpApp`, **`Moviedb.Services` (couche services séparée)**, `Moviedb.TestUI` |
| Taille | 65 fichiers C# · 3 493 LOC (702 code-behind, 2 791 logique) |
| Tests | Présents (partiels) |

## Surface UI

**12 pages + 4 contrôles custom** : Shell, Main, Detail, Login, PassportRegister, UserSelection, Settings, Welcome… La plus grande surface UI du portefeuille après pokedex.

## APIs plateforme → web

| Cluster | Équivalent |
|---|---|
| Windows.UI (80) | Composants Razor (couvert par la réécriture) |
| Windows.ApplicationModel (18) | PWA — 1 j |
| Windows.Security (2) | Auth côté backend — 1 j |
| System.Net.Http (2) | `HttpClient` — 0 j, portable tel quel |
| Windows.Storage (1) | `localStorage` — 0,5 j |

## Extractibilité

80 % du code (2 791 / 3 493 LOC) : `Moviedb.Services` (clients API TMDb/YTS, modèles) se porte tel quel. Les clés d'API imposent un **backend proxy** léger côté Blazor WASM.

## Effort

3 + 12 × 1,5 + 4 × 1 + 2,5 = 27,5 j ≈ **28 j** (tests partiels : pas de majoration) → fourchette **20–36 j**

## Cible recommandée : **Blazor WASM + backend proxy minimal**

Le proxy protège les clés d'API (TMDb) et contourne CORS.

## Risques & coût de l'inaction

- ⚠️ **Risque légal/réputationnel : la source YTS est adjacente au piratage.** Recommandation : migrer en **démo technique privée** uniquement, ou basculer 100 % TMDb (légal) si publication.
- UWP est en maintenance ; chaque année rend le code plus étranger aux outils modernes.
- Valeur : vitrine technique (grosse UI, auth, API externes) — pas une vitrine publique en l'état.
