# Audit — pokedex

> **✅ MIGRÉE (vague 3, 2026-07-23)** — Blazor WASM + API statique générée depuis le SQLite
> veekun (requêtes 2014 verbatim). 53 tests, Roslyn 0/0, hors-ligne prouvé serveur coupé.
> Chronométrée : **~1 h** pour 29 j estimés. Publication Pages en attente de la décision
> propriétaire (repo privé).
>
> **L'audit ci-dessous s'était trompé deux fois** (leçons codifiées kit v1.4.1) :
> le « backend ASP.NET Core moderne » cible **netcoreapp1.0** (2016), exige SQL Server et
> n'a **jamais été branché au frontend** (aucun HttpClient) — Renovate y poussait des paquets
> 10.x, d'où l'illusion (détection `zombie` ajoutée à l'inventaire) ; et les « tests présents »
> étaient une référence pendante dans une .sln de sauvegarde. La vraie source de données est un
> **SQLite veekun de 49 Mo embarqué** + 15 requêtes SQL artisanales + 2 713 assets locaux.

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
