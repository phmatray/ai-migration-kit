# Changelog

Toutes les évolutions notables du kit. Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/),
versionnage sémantique. La question à laquelle ce fichier répond : « qu'est-ce qui change si je mets à jour ? »

## [1.5.0] — 2026-07-23

Le pipeline rend compte de sa queue : suivis consolidés et mis à jour à la source.

### Ajouté
- **Skill `followups` + commande `/migrate-followups`** : consolide les suivis ouverts de tous
  les repos migrés (`next_steps`/`deferred` des `migration/report.json` + backlog du kit) —
  décisions propriétaire d'abord, tâches par effort croissant — et définit les protocoles de
  mise à jour **à la source** : « fait » (retrait + coche + dashboard + commit), « clos par
  décision » (bascule en `deferred` datée), ajout a posteriori. Jamais de liste parallèle.
- **`scripts/followups.py`** : l'agrégateur (lecture seule), sortie markdown triée ou `--json` ;
  testé en CI (tri avec virgule française « ~0,5 h », owner-first, backlog, chemin d'erreur).
- La phase 7 se conclut par un passage de `followups` (SKILL.md règle 8).

Validé au banc skill-creator : 3 cas (consolidation, marquer fait, clore par décision) en
double aveugle avec/sans skill — **16/16 assertions avec le skill contre 12/16 sans** (la
référence invente un tableau `closed` hors schéma, oublie le dashboard, réinvente le tri) ;
puis test réel en lecture seule sur winrt-sokoban-blazor.

## [1.4.1] — 2026-07-23

Leçons de la vague 3 (pokedexg : UWP 2016 + « backend » netcoreapp1.0 → Blazor WASM + API statique).

### Ajouté
- **Détection des projets zombies** dans `audit-inventory.sh` : `projectDetails[].targetFramework`
  (lu du csproj) et `zombie: true` quand un TFM ancien (netcoreapp1/2, netstandard1, PCL, UAP)
  reçoit des paquets 10+ — un robot de mise à jour n'est pas un signe de vie. L'audit de pokedexg
  avait pris un webservice netcoreapp1.0 arrosé par Renovate pour un « backend déjà moderne ».
- **Prémisses vérifiées, jamais déduites** (audit-executive.md) : TFM lus des csproj, tests
  prouvés par attributs (jamais par un nom de projet dans une .sln — référence pendante chez
  pokedexg), flux de données prouvé par l'appelant (HttpClient) avant d'écrire « branché ».
- **Cinq protocoles vague 3** (rewrite-playbook) : SQL legacy sur SQLite moderne (ON réordonné,
  RECONSTRUCTION) ; assets hors projet copiés par cible MSBuild — jamais `Content Link`
  (servi 200/0 octet) — et build avant publish ; cascade Tailwind (`@layer base`) ; précache
  service worker = contrat d'une app installée ; hors-ligne prouvé en tuant le serveur quand
  la production n'existe pas encore.

### Corrigé
- **`report-dashboard.py` écrit sa sortie à côté du report.json** (plus jamais dans le cwd —
  le dashboard de la vague 3 avait atterri à la racine du repo migré) ; test golden étendu.

## [1.4.0] — 2026-07-23

Le pipeline vérifie désormais ses promesses (review post-vague 2).

### Ajouté
- **`scripts/contrast-check.py`** : contraste WCAG 2.1 mesuré (jamais estimé à l'œil) pour toutes
  les paires encre/fond, thèmes clair et sombre — obligatoire avant de livrer une UI réécrite
  (rewrite-playbook) ; testé en CI (chemins succès ET échec).
- **Job `verify` dans `templates/deploy-pages-blazor.yml`** : smoke test post-déploiement — la
  racine et une route profonde doivent servir le CONTENU de l'app (`SMOKE_MARKER`,
  `SMOKE_DEEP_ROUTE`), jamais le seul code HTTP ; `SMOKE_MARKER` vide = garde-fou bloquant.
- **Détection des projets-squelettes** dans `audit-inventory.sh` (`projectDetails`,
  `skeletonProjects`) : un échafaudage vide ne compte plus dans la logique portable — leçon
  vague 2 (5 projets « en couches » vides avaient gonflé l'audit).
- **Double chiffrage obligatoire** dans l'audit (audit-executive.md) : jours-équipe-humaine
  (coût évité) **et** minutes-pipeline (prix réel, calibré sur les vagues mesurées).
- **Protocole hors-ligne PWA** (rewrite-playbook) : le hors-ligne se teste réseau coupé, jamais
  ne se déclare ; piège `caches.match('index.html')` → utiliser `caches.match('./')` d'abord.
- `docs/backlog.md` : dettes notées avec leur déclencheur (sync des artefacts copiés, timeout
  préflight, échappement JSON).

## [1.3.2] — 2026-07-23

Leçons de la vague 2 (fleurs-du-mal, migrée en ~30 min pour 18 j estimés).

### Ajouté
- **Protocole d'inventaire des assets binaires locaux** (rewrite-playbook) : regarder chaque
  asset embarqué avant de dessiner l'UI — le dessin original d'une artiste, cœur du design 2014,
  avait failli être perdu parce que les seules images *visibles* étaient des URLs externes mortes.
  Port octet pour octet + crédit d'artiste (décision propriétaire si le nom manque).

### Corrigé
- `report-dashboard.py` : les chemins du `report.json` (cobertura, capture) se résolvent
  **relativement au JSON**, plus au répertoire courant ; le test golden le prouve en tournant
  depuis la racine du repo.
- Playbook de livraison : la vérification de la route profonde teste le **contenu**, pas le code
  HTTP — le fallback 404.html de GitHub Pages sert l'app avec un statut 404 (faux négatif sinon).

## [1.3.1] — 2026-07-23

Durcissement issu de la review v1.3.0 : les outils rendus obligatoires par la règle 7 deviennent
infaillibles et testés.

### Ajouté
- **Test golden du générateur de rapport** (`tests/report-dashboard/`) : fixture `report.json` +
  cobertura → HTML, assertions sur les valeurs calculées (couverture par classe, exclusions,
  autonomie du document, thème sombre). Exécuté en CI ; remplace le simple `py_compile`.
- **`preflight.sh --json`** : sortie machine des checks, à verser dans `migration/report.json`
  sans recopie manuelle.
- **Garde-fous dans `templates/deploy-pages-blazor.yml`** : échec explicite si `BASE_PATH` reste
  le placeholder `/REPO_NAME/`, et vérification post-`sed` que le `<base href>` a réellement été
  réécrit — fini le déploiement vert avec page blanche en prod.
- **Validation YAML des templates** dans la CI du kit.
- Ce CHANGELOG.

### Modifié
- Préflight : le SDK .NET est vérifié par **comparaison numérique du major (>= 8)** au lieu de
  l'énumération `8|9|10` qui aurait bloqué à tort les SDK futurs (.NET 11+).
- Préflight : un serveur MCP **configuré mais non connecté ne passe plus** — l'état de santé de
  `claude mcp list` est vérifié, pas seulement la présence du nom.
- Template de déploiement : le `sed` du base href tolère les variantes du template Blazor
  (`<base href="/">`, `"/"/>`, `"/" />`) ; en-tête enrichi (409 Pages = déjà activé,
  `dotnet-version` à ajuster au TFM cible).
- Playbook de livraison : activation Pages documentée idempotente (`409` = succès, continuer).

### Supprimé
- Les « indices disque » de présence des skills dans le préflight : un check dont le script
  lui-même disait « la vérité est ailleurs » est du bruit. La responsabilité vit à l'étape 2 de
  la phase 0 (SKILL.md) : l'agent confirme ses capacités de session.

## [1.3.0] — 2026-07-22

Le pipeline devient déterministe et auto-vérifié.

### Ajouté
- **Phase 0 préflight** (`scripts/preflight.sh`) : requis bloquants (dotnet, git, python3,
  RoselineMCP), recommandés à dégradation bruyante (context7, gh, node, Chrome headless).
- **Phase 7 Deliver** + `references/delivery-playbook.md` : une migration n'est finie
  qu'en production vérifiée (branche par défaut, désarchivage, Pages, route profonde + capture).
- **`templates/deploy-pages-blazor.yml`** : déploiement Blazor WASM → GitHub Pages paramétré
  (SOLUTION, WEB_PROJECT, BASE_PATH), fallback SPA et `.nojekyll` intégrés.
- Règles 7 (« scripts et templates du kit obligatoires ») et 8 (« livrée = en production »).
- Protocoles vague 1 dans le rewrite-playbook : namespaces conservés, en-têtes RECONSTRUCTION,
  tests historiques jamais verts (skip documenté + wrapper + tests d'intention), `<NoWarn>` d'époque.

## [1.2.0] — 2026-07-22

Industrialisation post-vague 1.

### Ajouté
- **`scripts/report-dashboard.py`** : générateur du dashboard exécutif de migration
  (`report.json` + cobertura + capture → HTML autonome, thème clair/sombre, palette validée).
- **`templates/ci-dotnet.yml`** : CI réutilisable (tests + couverture), variable `SOLUTION`
  pour les repos à plusieurs `.sln` (leçon MSB1011 de chords).
- CI du kit (fixture LegacyShop, manifestes, invariants des guides de phase).
- Publication du repo (github.com/phmatray/ai-migration-kit) et cas d'étude portfolio WinRT
  avec deux migrations en production (sokoban, chords).

## [1.1.0] — 2026-07-22

### Ajouté
- **`/migrate-audit`** : audit exécutif lecture seule, chiffré (formule d'effort transparente,
  ±30 %), portfolio multi-apps avec matrice valeur/effort et première vague recommandée.
- `scripts/audit-inventory.sh` : inventaire JSON reproductible (ère technologique, surface XAML,
  clusters d'API plateforme, LOC logique vs code-behind).
- Rewrite-playbook (port-characterize-wrap) pour les plateformes mortes (WinRT/UWP → Blazor).
- Règle 6 : le livrable ne raconte jamais sa migration.

## [1.0.0] — 2026-07-22

### Ajouté
- Pipeline six phases porté par RoselineMCP : Assess, Baseline, Retarget, Remediate, Modernize,
  Verify — portes vertes obligatoires, mutations preview-first, branche `migration/<date>`.
- Commandes `/migrate`, `/migrate-assess`, `/migrate-verify`.
- Fixture `samples/LegacyShop` (net6.0, volontairement legacy) et démo vérifiée
  (`docs/demo-walkthrough.md`).
