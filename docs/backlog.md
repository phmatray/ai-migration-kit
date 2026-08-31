# Backlog du kit

Décisions notées, pas encore justifiées par l'échelle — chaque entrée dit le déclencheur qui la
rendra rentable (YAGNI sinon).

- **Synchronisation des artefacts copiés dans les repos migrés** (`sw.js`, workflows) : le bug du
  fallback hors-ligne a dû être corrigé trois fois (sokoban, chords, fleurs-du-mal).
  Déclencheur : ~5 repos migrés → script `sync-artifacts` qui compare les copies aux templates
  et ouvre les correctifs.
- **Timeout sur `claude mcp list` dans le préflight** : un CLI qui bloque (auth expirée) gèle la
  phase 0. Déclencheur : premier gel constaté.
- **Banc de déclenchement sur les 10 skills — ✅ fait (2026-08-31, #331).** L'entrée disait
  « listes statiques, CI garde la présence, pas la cible » : c'était vrai des
  `tests/skills/*.triggers.md`, et faux depuis que `evals/` existe. Le banc est réel
  (`evals/trigger_eval.py` mesure la `description` *installée* avec un vrai `claude -p` ;
  `evals/run_all.py` rafraîchit `evals/results/baseline.json`), et le contrat n'a plus qu'une
  maison : `evals/<skill>-trigger-eval.json`, une par skill, pour les **dix** skills. Les dix
  listes markdown — un cache d'un contrat que rien n'exécutait — sont retirées, et
  `check-frontmatter.py` valide désormais le jeu d'évals (JSON valide, clés du runner, pas de
  requête dupliquée, les deux polarités présentes) au lieu du markdown.
  Le banc reste **manuel** : il lance un `claude -p` par requête, il coûte des tokens et il tue
  de vrais skills en cours de flux (`evals/README.md` §Safety) — la CI garde la structure, la
  mesure se déclenche à la demande. Déclencheur permanent : une modification de `description`
  → `python3 evals/run_all.py --skills <skill>` et comparaison au `baseline.json` committé.
  `followups` reste attendu au plancher en sonde headless (positifs ≈ 0/3 sans contexte de repo,
  cf. l'entrée « Optimisation du déclenchement du skill `followups` » ci-dessous) : ce chiffre
  mesuré *est* sa ligne de base, pas une cible à atteindre.
- **Traduction anglaise des 4 references françaises de `legacy-upgrade`** (audit-executive,
  delivery-playbook, report-template, rewrite-playbook) : la surface distribuée est anglaise
  depuis v1.7.0 (SKILL.md, commandes), ces references restent françaises. Déclencheur : premier
  utilisateur non francophone du kit, ou première retouche de fond d'une de ces references.
- **Optimisation du déclenchement du skill `followups`** : la boucle skill-creator (5 itérations,
  20 requêtes, 3 mesures chacune) n'a départagé aucune variante — en sonde headless sans contexte
  de repo, le skill ne se déclenche presque jamais (positifs ≈ 0/3), donc la mesure est au
  plancher ; seul signal fiable : zéro sur-déclenchement sur les 10 quasi-pièges. Description
  d'origine conservée. Déclencheur : premier sous-déclenchement constaté en session réelle.
- **Élargir `scripts/parse-sweep.sh` au-delà de `tests/*/test.sh`** (#131) : `scripts/*.sh`,
  `hooks/*.sh` et `skills/**/scripts/*.sh` partent chez les mêmes développeurs macOS et courent le
  même risque — un `$( … )` avec un heredoc dont les quotes ne s'apparient pas, invisible pour la
  CI en bash 5. Le balayage est déjà paramétré par fichier (`parse-sweep.sh <fichier>…`), donc
  c'est une ligne de plus dans la cible par défaut. Non fait ici pour rester dans le périmètre de
  l'issue. Déclencheur : premier script hors `tests/` qui ne parse pas sous bash 3.2 — ou la
  prochaine retouche de `parse-sweep.sh`.
> **Implémentés en v1.9.0 (2026-07-23) — sortis du backlog.** La **porte de verdict de fin de phase 1**
> (`verdict: ALREADY_MODERN | RED_BY_TFM_LAG | NORMAL`) couvre les deux items dont le déclencheur a
> sauté ce jour-là : « déjà moderne → stop » (dogfood `Atypical-Consulting/StaticWGen`) et « le
> retarget est le fix du baseline » (vague `phmatray/DotnetChain`, PR #64). C'étaient les deux bords
> d'un même classifieur (même étape, symptômes inverses), livrés comme un seul changement. Détails :
> `CHANGELOG.md` [1.9.0], cases de régression dans `phase-1-assess.md` (« Verdict fixtures »).

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
