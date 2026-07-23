# Backlog du kit

Décisions notées, pas encore justifiées par l'échelle — chaque entrée dit le déclencheur qui la
rendra rentable (YAGNI sinon).

- **Synchronisation des artefacts copiés dans les repos migrés** (`sw.js`, workflows) : le bug du
  fallback hors-ligne a dû être corrigé trois fois (sokoban, chords, fleurs-du-mal).
  Déclencheur : ~5 repos migrés → script `sync-artifacts` qui compare les copies aux templates
  et ouvre les correctifs.
- **Timeout sur `claude mcp list` dans le préflight** : un CLI qui bloque (auth expirée) gèle la
  phase 0. Déclencheur : premier gel constaté.
- **Banc de déclenchement sur les 6 skills** : les listes `tests/skills/*.triggers.md` sont des
  contrats statiques — la CI garde leur présence (check-frontmatter.py), pas la cible ≥ 90 % ;
  seul `followups` a jamais vu le banc (16/16, v1.5.0). Déclencheur : prochaine modification
  d'une `description` → passer la liste du skill touché au banc skill-creator.
- **Traduction anglaise des 4 references françaises de `legacy-upgrade`** (audit-executive,
  delivery-playbook, report-template, rewrite-playbook) : la surface distribuée est anglaise
  depuis v1.7.0 (SKILL.md, commandes), ces references restent françaises. Déclencheur : premier
  utilisateur non francophone du kit, ou première retouche de fond d'une de ces references.
- **Optimisation du déclenchement du skill `followups`** : la boucle skill-creator (5 itérations,
  20 requêtes, 3 mesures chacune) n'a départagé aucune variante — en sonde headless sans contexte
  de repo, le skill ne se déclenche presque jamais (positifs ≈ 0/3), donc la mesure est au
  plancher ; seul signal fiable : zéro sur-déclenchement sur les 10 quasi-pièges. Description
  d'origine conservée. Déclencheur : premier sous-déclenchement constaté en session réelle.
- **Verdict « déjà moderne → stop » absent du pipeline** : `/migrate` confond « migrer une app
  dépassée » et « il y a du travail à faire ». `phase-1-assess.md` étape 6 recommande *toujours*
  « latest LTS TFM », même quand l'app y est déjà (net10.0 → net10.0), et rien n'empêche `/migrate`
  d'enchaîner sur une phase 3 (retarget) à vide, une phase 5 (idiomes déjà modernes) à vide, puis
  une phase 7 qui déploie du Blazor sur Pages… pour un outil CLI sans cible web. `audit-executive.md`
  ne définit que deux profils (« TFM obsolète », « réécriture UI ») — aucun profil « sain, rien à
  migrer », alors même que la leçon vague 3 y vit déjà à l'envers (« un robot de mise à jour n'est
  pas un signe de vie » vise le faux-moderne : TFM ancien arrosé par Renovate ; le vrai-moderne
  n'a pas de verdict). Correctif proposé : une **porte de modernité** en fin de phase 1 — si tous
  les TFM ∈ {dernière LTS, cible demandée} ET aucun runtime hors-support ET aucun cluster d'API
  obsolète (SYSLIB/packages.config/BinaryFormatter), alors cible recommandée = « aucune, déjà à
  jour », `assessment.md` porte `verdict: ALREADY_MODERN`, et `/migrate` s'arrête après la phase 1
  (comme `/migrate-assess`) au lieu d'entrer en phase 3. Router explicitement vers `/migrate-verify`
  (porte qualité phase 6) le cas d'une app moderne qui veut quand même un rapport : moderne ≠ propre
  — le seul `dotnet restore` qui a abouti sur StaticWGen a remonté une dépendance transitive à
  vulnérabilité haute (NU1903, `System.Security.Cryptography.Xml` 9.0.0, dans `_build`). La
  plomberie existe déjà (les variantes `/migrate-assess` = phase 1 seule et `/migrate-verify` =
  phase 6 seule sont en place) ; seul manque le branchement du verdict. Déclencheur : premier
  `/migrate` visant une cible déjà à jour — **atteint le 2026-07-23** (dogfood sur
  `Atypical-Consulting/StaticWGen` : net10.0 partout, SDK épinglé 10.0.302 `rollForward:
  latestFeature`, paquets à jour tenus par Renovate).

## Non-adoptions (décisions fermées)

Évaluées et **refusées** — consignées pour que la décision survive aux sessions. Source : revue
jobs du 2026-07-23 (`reviews/2026-07-23-jobs/`), lentille Arbor (RUC-NLPIR) — le kit a adopté les
ceintures de sécurité d'Arbor (reprise, garde de convergence, chronologie mesurée, rétropropagation
contractuelle, v1.8.0), et refuse son volant :

- **Arbre d'hypothèses / recherche multi-hypothèses (Idea Tree)** : Arbor explore un espace ouvert
  (métrique à maximiser, meilleure solution inconnue) ; le kit exécute un chemin connu vers une
  destination binaire (build vert, tests verts, prod vérifiée). Greffer l'exploration détruirait la
  propriété qui fait sa valeur — déterministe, reproductible, minutes mesurées.
- **Modes d'interaction (`ui.interaction_mode` auto/direction/review/collaborative)** : les
  variantes de portée du kit (`/migrate-assess` lecture seule, `/migrate`, `/migrate-verify`)
  couvrent déjà le besoin sans concept supplémentaire.
- **Recherche de nouveauté (novelty search alphaXiv)** : un verdict de nouveauté académique
  n'améliore aucune migration.

Réouverture : uniquement si le kit change de nature (optimisation d'une métrique ouverte — perfs,
taille de bundle — où l'exploration paie), jamais pour une migration.
