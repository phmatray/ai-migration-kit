# Changelog

Toutes les évolutions notables du kit. Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/),
versionnage sémantique. La question à laquelle ce fichier répond : « qu'est-ce qui change si je mets à jour ? »

## [1.8.0] — 2026-07-23

Implémentation intégrale de la revue jobs du jour (`reviews/2026-07-23-jobs/`, lentille Arbor :
quelles disciplines du framework de recherche RUC-NLPIR/Arbor méritent d'entrer dans un pipeline
déterministe — et lesquelles refuser) : les 6 findings résolus. En une ligne : le kit adopte les
ceintures de sécurité d'Arbor (reprise, convergence, temps mesuré, rétropropagation), et refuse
son volant (l'exploration arborescente).

### Ajouté
- **Reprise d'un `/migrate` interrompu** (le `--resume` d'Arbor) : le pipeline détecte le dossier
  `migration/` et les commits de porte (leur message nomme la phase — règle 4, les artefacts
  confirment), annonce le point de reprise et ré-entre à la phase qui suit la dernière porte
  verte ; une phase verte n'est jamais rejouée (SKILL.md Scope variants + Common issues,
  commande `/migrate`).
- **Règle 9 — la remédiation doit converger** (la politique de budget d'Arbor) : deux passes de
  phase 4 consécutives sans baisse du compte d'erreurs = stop, retour à la dernière porte verte,
  blocage consigné au rapport (diagnostics restants groupés par id), décision au propriétaire
  (SKILL.md + phase-4-remediate + Common issues).
- **Chronologie du pipeline mesurée** : `migration/report.json` porte `phases[]` (début/fin/minutes
  par phase), **dérivée des commits de porte** (`git log` de la branche de migration, phase-6-verify
  §6) — le « temps pipeline mesuré » du README devient un fait généré, jamais un chronomètre
  humain ; `report-dashboard.py` rend la carte « Chronologie du pipeline » avec le total calculé
  (test golden étendu).
- **La rétropropagation devient un contrat** (le backpropagate d'Arbor) : la phase 7 se clôt par
  une entrée `lessons` dans `report.json` — référence du changement appliqué au kit ou « rien à
  apprendre de cette vague » explicite ; une vague sans entrée leçons est incomplète (règle 8,
  delivery-playbook étape 9, report-template) ; le dashboard rend la carte « Leçons de la vague »
  (test golden étendu).
- **Audit de portefeuille en éventail** : `/migrate-audit` multi-apps documente le fan-out — un
  sous-agent par app (les inventaires sont indépendants par construction), l'orchestrateur ne
  garde que la synthèse portefeuille. Aucun script modifié.
- **Non-adoptions consignées** (docs/backlog.md, section « décisions fermées ») : arbre
  d'hypothèses / Idea Tree, modes d'interaction, novelty search — refusés avec justification
  (pipeline déterministe ≠ recherche exploratoire) et condition de réouverture, pour que la
  décision survive aux sessions.

## [1.7.0] — 2026-07-23

Implémentation intégrale de la seconde revue elon du jour (`reviews/2026-07-23-elon-2/`, lentille
cohérence / workflow prédictif / déterminisme) : les 9 findings résolus.

### Modifié
- **Le pipeline finit en production, partout** : `/migrate` couvre officiellement les phases 1–7
  (la contradiction commande « 1–6 » / règle 8 « livrée = en production » est tranchée) ; la marque
  « six-phase » corrigée en « seven-phase » (README, plugin.json, description du skill) ; une app
  sans cible de production clôt la phase 7 par la décision propriétaire consignée — documentée,
  jamais silencieuse.
- **Ancrage `<kit>` des scripts et templates** : `legacy-upgrade` et `followups` résolvent
  désormais tout chemin du kit depuis `<skill-dir>/../..` (comme `get-repo-profile` le faisait
  déjà), jamais depuis le CWD — une installation marketplace fonctionne à froid. Verrouillé en CI
  par un step « foreign working directory » (préflight, inventaire, followups, repo-profile
  exécutés depuis un répertoire étranger).
- **`requirements.json` exprime la requiredness par skill** : champ `requiredBy` (+ `token`) sur
  gh CLI (create-issue, implement-issue, merge-pr), superpowers (create-issue, implement-issue)
  et code-review (implement-issue) — la contradiction littérale « level: recommande / when:
  requis » est éliminée. Le préflight affiche `[hard-required by: …]` et émet `requiredBy` en
  JSON ; cross-check manifest ↔ frontmatter `compatibility` en CI (check-frontmatter.py).
- **Le préflight émet son JSON via python3** (échappement réel, plus de printf artisanal ni de
  séparateur `|` collisionnable — la dette backlog « échappement JSON des hints » est levée) ;
  sortie et statuts en anglais (`ok`/`missing`/`absent`/`unknown`, niveaux
  `required`/`recommended`).
- **Anglais sur la surface distribuée** : SKILL.md `followups` et `legacy-upgrade` unifiés en
  anglais (fini le FR/EN au milieu du fichier), commandes `migrate-audit` et `migrate-followups`
  traduites. Restent français par décision : CHANGELOG, études de cas, sortie de `followups.py`
  (elle alimente les rapports français) et 4 references de `legacy-upgrade` (dette backloguée
  avec déclencheur).
- `create-issue` ne prépare plus l'identité de commit (il ne committe jamais) ; `plugin.json`
  n'énumère plus les phases (une string marketing qui répète le README dérive).

### Ajouté
- **`tests/repo-profile/test.sh`** : golden test du seul script du kit qui n'en avait pas —
  `show` (profil présent / NO_PROFILE exit 3), `detect` hors git (exit 4), et le contrat TODO
  sur un repo minimal (sections présentes + fallbacks réellement déclenchés).
- **`implement-issue` : réconciliation du miroir PR à la reprise** — le PATCH de l'issue et
  l'édition du corps de la PR ne sont pas atomiques ; la boucle du Step 6 resynchronise
  désormais la liste `### Plan` depuis l'état canonique de l'issue avant de reprendre.
- Note d'honnêteté dans les 6 listes `tests/skills/*.triggers.md` : la CI garde la présence,
  le banc lui-même est manuel (entrée backlog avec déclencheur : prochaine modification de
  description).

### Corrigé
- **`repo-profile.sh` : fallbacks TODO morts** — `grep … | head || echo TODO` ne peut jamais
  tirer (head sort à 0 sur entrée vide) ; toutes les sondes passent par `emit_or_todo()` (une
  seule convention, `probe()` supprimée) et le contrat « champ indétectable ⇒ ligne TODO » est
  tenu (gardé par le nouveau golden test).

## [1.6.0] — 2026-07-23

Solution unifiée : le kit intègre les skills issue/PR génériques, et les prérequis ont une
source unique.

### Ajouté
- **`requirements.json`** : source unique des prérequis (outils, MCP requis/recommandés, skills de
  session — y compris les dépendances des skills issue/PR : gh, superpowers, code-review).
  `scripts/preflight.sh` la lit désormais au lieu d'embarquer sa propre liste ; README et la
  phase 0 du SKILL.md y pointent au lieu de dupliquer l'énumération (trois copies → une).
  Testé en CI (`tests/preflight/test.sh` : JSON valide, couverture intégrale du manifest, échec
  réel sur REQUIS manquant).
- **Quatre skills issue/PR génériques intégrés au kit** — `skills/create-issue` (issue semée
  brainstorm → spec → plan cochable), `skills/implement-issue` (plan → PR draft → ready, un commit
  par tâche), `skills/merge-pr` (attente CI, boucle de corrections, squash-merge, suivis),
  `skills/get-repo-profile` (générateur du profil par repo) + `skills/_shared`. Importés d'un autre
  projet puis **dé-spécifiés** : descriptions, numéros d'issues CI, liens ADR, taxonomie de labels
  et fichiers temporaires propres au repo d'origine retirés — tout fait spécifique au repo vit dans
  le repo-profile (`.claude/skills/repo-profile.md`), comme l'abstraction le promettait. Le restant
  de l'import (orchestrateur de flotte, lanceur d'IDE, profil du repo d'origine, settings.json aux
  hooks inexistants) n'a pas été retenu.
- **Pont `followups` → `create-issue`** : un suivi qui mérite un ticket se convertit en issue
  GitHub via le skill du kit ; l'entrée du `report.json` garde l'URL de l'issue — jamais de liste
  parallèle (SKILL.md `followups` + règle 8).
- **Conformité au guide Anthropic des skills** (revue elon du 2026-07-23, rapport dans
  `reviews/2026-07-23-elon/`) : les 6 descriptions tiennent sous la limite de 1024 caractères du
  standard (3 compressées) et portent des déclencheurs bilingues FR/EN ; frontmatter complété sur
  les 6 skills (`license: MIT`, `compatibility` — miroir distribution de `requirements.json` —,
  `metadata.author/version/suite`) ; fichier `LICENSE` (MIT) ; **tests de déclenchement par skill**
  (`tests/skills/<name>.triggers.md`, listes should / should-not en anglais) gardés en CI par
  `tests/skills/check-frontmatter.py` (limites du guide + listes présentes) ; dédoublonnage
  SKILL.md ↔ references sur `implement-issue` et `merge-pr` (les recettes gh/jq vivent une seule
  fois, dans les references) ; sections **Troubleshooting** (erreur → cause → solution) dans
  `legacy-upgrade` et les references lifecycle.
- **`ARCHITECTURE.md`** : graphe d'appels des skills (mermaid, rendu par GitHub), graphe des
  dépendances externes (MCP, plugins, outils), matrice de dépendances par skill et table des
  sources uniques par préoccupation.

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
