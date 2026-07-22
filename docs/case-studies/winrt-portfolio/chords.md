# Audit — chords

**Accords de guitare (Windows Phone + WPF desktop + lib)** · multi-ère · actif 2015-02 → dernier commit 2026-03

## Carte d'identité

| | |
|---|---|
| Ère | `windows-phone` (app principale) + WPF desktop + console + EF database — **8 projets** |
| Projets | `GuitarChords.Phone`, `Chords.UI.Desktop`, `GuitarChords.Controls`, **`GuitarChords.Lib` (+ 2 projets de tests xUnit)**, `GuitarChords.ConsoleApp`, `GuitarChords.Server.Database` |
| Taille | 128 fichiers C# · 5 117 LOC (305 code-behind, 4 812 logique) |
| Stack | MvvmLight, EntityFramework, xunit |
| Tests | **Oui — la lib métier est testée en xUnit** (cas unique du portefeuille) |

## Surface UI

4 pages/fenêtres (MainPage, BasicPage, MainWindow, Window1) réparties sur deux UI mortes ou vieillissantes (WP, WPF classique). Une seule UI Blazor les remplace toutes.

## APIs plateforme → web

| Cluster | Équivalent |
|---|---|
| System.Windows (29) + Windows.UI (28) | Composants Razor (couvert par la réécriture) |
| **Windows.Media (6)** | Lecture des accords → `<audio>` / **Web Audio API via JS interop** — 2 j (synergie : repo `WebAudioInterop` existant) |
| Windows.Storage (2) | `localStorage` — 0,5 j |
| Windows.ApplicationModel (3) | PWA — 1 j |

## Extractibilité

**94 % du code (4 812 / 5 117 LOC)** : le domaine musical (`GuitarChords.Lib` — accords, doigtés, théorie) est **testé et portable tel quel**. La base EF se réutilise côté serveur ou s'exporte en JSON statique.

## Effort

3 + 4 × 1,5 + 3,5 = 12,5 j ≈ **13 j** (tests présents : pas de majoration) → fourchette **9–17 j**

## Cible recommandée : **Blazor WASM PWA mobile-first**

L'héritière naturelle de l'app Windows Phone : installable sur mobile, hors-ligne, diagrammes d'accords en SVG, audio via Web Audio. Synergie directe avec l'écosystème musical existant (OpenJam, midiminuit, MusicTheory).

## Risques & coût de l'inaction

- Windows Phone est mort depuis 2017 : l'app n'a plus aucun utilisateur possible ; la lib testée — l'actif — dort.
- Trois UI à maintenir conceptuellement (WP, WPF, console) → une seule cible web les remplace.

## ✅ Résultat (migration exécutée le 2026-07-22, chronométrée : 18 min)

**En ligne : https://phmatray.github.io/chords/** — 17 qualités × 12 fondamentales × 33 accordages.

- 3 065 LOC portées **verbatim** (102 fichiers, namespaces conservés, 0 modifiée) ; l'audit « 94 % portable » tenu.
- **Archéologie** : 2 fichiers référencés par le csproj de 2015 jamais committés — le repo ne compilait plus depuis l'origine ; reconstruits (36 LOC) et marqués.
- **Bug d'épellation de 11 ans corrigé sans toucher à la lib** : les 12 tests historiques des tonalités bémolisées, jamais verts, passent via le wrapper `EnharmonicSpeller` ; originaux en skip documenté.
- 34 tests verts, build 0/0, code nouveau couvert à 94–100 %, CI + déploiement Pages livrés, rapport généré par `scripts/report-dashboard.py`.
- **18 minutes** au lieu des 13 j ±30 % estimés à la main : le process industrialisé (2e passage) écrase l'estimation de mutualisation.
