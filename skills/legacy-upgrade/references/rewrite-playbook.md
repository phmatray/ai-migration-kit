# Réécriture de plateforme UI — playbook

Pipeline pour les apps dont la plateforme UI est morte (WinRT, UWP, Windows Phone, WPF → Blazor).
Complète les phases 1–6 (modernisation in place) ; validé sur la vague 1 du portefeuille WinRT (sokoban, 2026-07-22).

## Le patron central : porter, caractériser, envelopper

1. **Porter le cœur octet pour octet.** Copier moteur/domaine/services vers `src/<App>.Core` en ne changeant que namespace et usings. Ne PAS moderniser pendant le port — chaque « amélioration » simultanée détruit la preuve de non-régression.
2. **Caractériser par tests, bizarreries comprises.** Les quirks du legacy (état incohérent, règles absentes, effets de bord) sont fixés par des tests qui documentent le comportement RÉEL. Un quirk n'est pas un bug de test.
3. **Corriger par wrapper, jamais dans le legacy.** La sémantique manquante (validation, détection d'état, compteurs) vit dans une classe qui enveloppe le code porté. Le legacy reste intact et prouvé ; le neuf est testé séparément.
4. **Réécrire l'UI seulement ensuite**, sur un cœur déjà vert.

## Protocoles issus des vagues 1 et 2 (sokoban, chords, fleurs-du-mal)

- **Inventorier les assets binaires locaux AVANT de dessiner l'UI** (leçon vague 2 : le dessin
  original d'une artiste, `Assets/Background.png`, cœur du design 2014, avait failli être perdu).
  `find <app> -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.svg' -o -iname '*.mp3' \)`
  hors `bin/obj` — regarder chaque asset non trivial (> quelques Ko). Les illustrations embarquées
  (fonds, planches, œuvres signées) font partie de l'œuvre : elles se portent **octet pour octet**
  (shasum), avec crédit d'artiste (décision propriétaire si le nom n'est pas dans le code).
  Ne jamais conclure « pas d'images » sur la seule foi d'URLs externes mortes ; tout asset écarté
  est consigné dans le rapport avec la raison.
- **Contraste mesuré, jamais estimé à l'œil** : toute palette d'UI réécrite passe par
  `scripts/contrast-check.py "#encre:#fond:libellé" …` — toutes les paires texte/fond, thèmes
  clair **et** sombre, AA = 4,5:1 (texte normal), 3:1 (texte large/UI, `--min 3`). Leçon vague 2 :
  une encre atténuée « qui semblait lisible » mesurait 4,16:1.
- **Le hors-ligne d'une PWA se teste, jamais ne se déclare** : après déploiement, une session
  navigateur avec réseau coupé (profil ayant déjà visité la prod) doit rendre l'app — racine ET
  route profonde. Piège connu : un fallback `caches.match('index.html')` ne matche jamais si la
  racine a été mise en cache sous l'URL du répertoire ; utiliser `caches.match('./')` d'abord.

- **Namespaces : les conserver.** Le port le plus pur garde les namespaces d'origine (chords : 102
  fichiers, 0 ligne modifiée). Ne les changer que si un conflit réel l'impose.
- **Fichiers référencés mais jamais committés** (rot de repo — le csproj liste des fichiers absents) :
  reconstruire **le minimum utilisé** (YAGNI), dans un fichier portant un en-tête « RECONSTRUCTION »
  daté expliquant la provenance — jamais mélangé au code porté.
- **Tests historiques jamais verts** : ne pas les réécrire, ne pas les supprimer. Les marquer
  `Skip = "<bug legacy documenté + où l'intention est restaurée>"`, figer le comportement réel par
  tests de caractérisation, restaurer l'intention par wrapper, et prouver l'intention par de
  **nouveaux** tests qui reprennent les valeurs attendues d'origine.
- **Style de tests d'époque** (ex. `Assert.Equal(x == y, true)` → xUnit2000) : suppression par
  `<NoWarn>` commenté dans le csproj de tests — les fichiers restent verbatim.

## Règles apprises sur le terrain

- **Le livrable ne raconte pas sa migration.** Aucun bandeau, footer, meta description ou texte UI ne mentionne le portage, l'outillage ou le process : l'utilisateur final reçoit un produit, pas un cas d'étude. La provenance vit dans le README, `migration/report.md` et l'historique git. Exception : les commentaires de code qui encodent une contrainte de maintenance (« port verbatim — ne pas moderniser ce fichier ») restent, car ils protègent la preuve.
- **La nouvelle solution exclut le projet legacy.** `dotnet new sln` peut embarquer les csproj existants : vérifier avec `dotnet sln list` — un projet WinRT dans le graphe casse tout build hors Windows. L'app d'origine reste dans le repo comme référence, hors solution.
- **Les données d'origine sont des actifs, pas du code.** Embarquer les fichiers de données tels quels (ressource embarquée) sans conversion de format : zéro risque de régression de contenu, et le diff prouve l'identité.
- **Substitutions plateforme standard** : `Windows.Storage` → `localStorage` · `DispatcherTimer` → `PeriodicTimer` · cycle de vie → PWA (manifest + service worker) · XAML → Razor + Tailwind (utilitaires + petite couche CSS custom pour l'identité visuelle ; CSS généré versionné pour que `dotnet build` reste autonome sans Node).
- **Blazor WASM et les routes profondes** : l'hébergeur doit renvoyer `index.html` sur 404 (GitHub Pages : copie `404.html` ; dev : le devserver le fait ; un `python -m http.server` nu ne le fait PAS — piège de vérification).
- **Vérifier dans un vrai navigateur** : publier en Release, servir avec fallback SPA, capturer l'écran et le REGARDER (accueil + une route profonde). Les tests unitaires prouvent le moteur, pas le rendu.

## Porte de sortie

Comme la phase 6 : build 0 erreur / 0 warning, tous tests verts, captures navigateur vérifiées, `migration/report.md` écrit selon `report-template.md` — avec sa checklist **Prochaines étapes** (chemin critique vers la production) distincte des **Suivis différés**.
