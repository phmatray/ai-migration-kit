# Audit — pokedex

**Pokédex UWP + web service ASP.NET Core** · UWP · actif 2016-09 → dernier commit 2026-03

## Carte d'identité

| | |
|---|---|
| Ère | `uwp` (frontend) + **backend ASP.NET Core / EF Core déjà moderne** |
| Projets | 3 audités côté UWP (`PokedexG.Uwp`, `PokedexG.Uwp.MainApp`, `PokedexG.UnitTestProject`) + stack backend (Kestrel, EFCore SqlServer, MVC) |
| Taille | **314 fichiers C# · 16 486 LOC** (862 code-behind, 15 624 logique/backend) |
| Tests | Présents (projet de tests unitaires) |

La plus grosse app du portefeuille — et paradoxalement l'une des mieux positionnées : l'essentiel du code n'est pas dans l'UI.

## Surface UI

10 pages + **9 contrôles custom** : Shell, Pokemons, PokemonDetails (×2), Types, TypeDetails, Machines, Gallery, News, Settings.

## APIs plateforme → web

| Cluster | Équivalent |
|---|---|
| Windows.UI (70) | Composants Razor (couvert par la réécriture) |
| Windows.ApplicationModel (16) | PWA — 1 j |
| Windows.Storage (7) | `localStorage` / backend — 0,5 j |

## Extractibilité — le chiffre qui compte

**95 % du code (15 624 / 16 486 LOC) est hors UI** : le web service ASP.NET Core + EF Core **se conserve tel quel** (il est déjà sur la bonne stack), les modèles et services clients se portent en l'état. On ne migre que la vitrine.

## Effort

3 + 10 × 1,5 + 9 × 1 + 1,5 = 28,5 j ≈ **29 j** (tests présents : pas de majoration) → fourchette **20–37 j**

## Cible recommandée : **Blazor WebAssembly branché sur le backend existant**

Le backend ASP.NET Core sert déjà du JSON ; Blazor WASM le consomme directement. Architecture cible full-stack .NET — la démo « fullstack » du portefeuille.

## Risques & coût de l'inaction

- Le backend moderne est **otage d'un frontend mort** : 95 % d'actif code inutilisable faute de vitrine.
- Contrôles custom (9) : le vrai poste de coût — à maquetter tôt.
- Marque Pokémon : usage démo/éducatif uniquement, pas de publication commerciale.
