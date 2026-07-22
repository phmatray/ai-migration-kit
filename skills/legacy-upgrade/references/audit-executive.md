# Audit exécutif (`/migrate-audit`)

Produit d'entrée du kit : un audit **lecture seule** qui parle aux décideurs. Deux profils d'app :

- **Modernisation in place** (TFM obsolète, même plateforme UI) → l'audit prolonge `phase-1-assess.md` avec chiffrage et risques.
- **Réécriture de plateforme UI** (WinRT, UWP, Windows Phone, WPF → Blazor) → la plateforme cible n'existe plus ou ne porte pas vers le web ; on chiffre la réécriture de l'UI et le **portage tel quel de la logique**.

## Règles

1. **Lecture seule absolue** sur l'app cible (le rapport est écrit ailleurs).
2. **Chaque chiffre vient de `scripts/audit-inventory.sh`** (JSON reproductible). L'agent interprète, il n'invente pas de comptes.
3. **Analyse C# :** tenter RoselineMCP `analyze_solution` d'abord. Les projets old-style UAP/WP ne se chargent pas dans Roslyn hors Windows : **consigner l'échec dans le rapport** (une ligne) et poursuivre sur l'inventaire structurel. Jamais de dégradation silencieuse.
4. Plusieurs apps → un rapport par app **+ synthèse portefeuille**.

## Format du rapport par app

1. **Carte d'identité** — ère (`era` du script), période d'activité, projets, taille (fichiers/LOC), tests.
2. **Surface UI** — `xamlPages`, `xamlControls`, `locCodeBehind`. Tout est à réécrire (Razor + Tailwind, sémantique WCAG 2.1 AA).
3. **APIs plateforme** — `windowsApiClusters` → correspondance web (table ci-dessous) → coût.
4. **Extractibilité** — `locLogic` vs `locTotal` : la logique pure (modèles, services, algorithmes) se porte **telle quelle** en class library .NET moderne. C'est l'argument économique central du portage.
5. **Effort** (formule ci-dessous) + **cible recommandée** (WASM statique si contenu autonome ; WASM + backend proxy si APIs externes avec clés ; Server si état serveur fort ; Hybrid si besoin natif résiduel).
6. **Risques & coût de l'inaction** — plateforme non installable, distribution morte (Store), dette de connaissance, dépendances archivées.

## Formule d'effort (jours)

| Poste | Coût |
|-------|------|
| Socle par app (projet Blazor + Tailwind, CI, revue) | 3 j |
| Par page XAML | 1,5 j |
| Par contrôle custom | 1 j |
| Par cluster d'API plateforme | HttpClient : 0 · Storage → localStorage/IndexedDB : 0,5 j · ApplicationModel/UI chrome : 1 j · Notifications/tiles → Web Push : 2 j · Media/Devices natif : 2 j ou abandon assumé |
| Logique pure portée telle quelle | 0 j |
| Aucun test existant | +20 % (tests de caractérisation sur la logique portée) |

Fourchette affichée : **±30 %**. Toujours montrer le calcul.

**Double chiffrage obligatoire.** La formule ci-dessus produit des **jours-équipe-humaine** :
c'est le coût évité, pas le prix d'exécution. Le réalisé mesuré du pipeline est de l'ordre de la
**demi-heure par app** (chords : 18 min ; fleurs-du-mal : ~30 min). Tout audit affiche les deux
nombres côte à côte — « équivalent équipe : N j (±30 %) · exécution pipeline : ~M min, calibré
sur les vagues mesurées ». Un seul des deux serait soit du bruit (l'erreur systématique de trois
ordres de grandeur), soit invendable (des minutes sans référentiel).

**Projets-squelettes.** `audit-inventory.sh` marque `skeleton: true` les projets quasi vides
(≤ 1 fichier réel ou < 30 LOC) : ils ne comptent **jamais** dans la part de logique portable ni
dans le chiffrage — une « architecture en couches » peut n'être qu'un échafaudage.

## Correspondances API Windows → web

| Cluster | Équivalent Blazor/web |
|---------|----------------------|
| `Windows.UI.Xaml` / `System.Windows` | Composants Razor + Tailwind (réécriture) |
| `Windows.Storage` | `localStorage` / IndexedDB / API backend |
| `Windows.Networking` / `System.Net.Http` | `HttpClient` (souvent portable tel quel) |
| `Windows.ApplicationModel` (cycle de vie, tiles) | PWA (manifest, service worker) |
| `Windows.UI.Notifications` | Web Push / Notifications API |
| `Windows.Media` | `<audio>`/`<video>` + JS interop |
| `Windows.Devices` / capteurs | Web APIs (Geolocation, etc.) ou abandon assumé |
| `Microsoft.Phone.*` | Aucun équivalent direct — réécriture PWA mobile-first |

## Synthèse portefeuille

- Tableau : app · ère · pages · LOC logique réutilisable · effort (j) · cible · valeur.
- **Matrice valeur/effort** et ordre de migration : quick wins d'abord (petite surface UI, logique portable, valeur démonstrable).
- Totaux et proposition de première vague (2-3 apps).
