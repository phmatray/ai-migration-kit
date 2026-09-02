# Revue du framework — ai-migration-kit (2026-09-02)

**main @ b4b8a3b (v2.0.0)** · 36 sessions précédentes relues (2026-08-17 → 2026-09-02, 54 Mo de
transcriptions) · 57 suites golden exécutées localement · 23 issues ouvertes · objectif énoncé :
« un framework aussi bien foutu que GSD, SpecKit ou BMAD ».

| Reviewer | Verdict |
|---|---|
| Claude (session `session_01VaApdmXx2hBnua7YaC4kHs`) | Les mécanismes sont là et vont au rouge ; ce qui manquait était la **porte d'entrée** (un guide, un routage, la forme « un item ») et la **boucle de retour** (rien ne relisait les transcriptions). Corrigé dans #395, #399 et les issues #397, #398, #400, #401. |

## Ce qui tient

- **Les gates sont réels.** `decision-check.py`, `recap-wiring-check.py`, `check-frontmatter.py`,
  `ci-wiring-check.py`, `check-untrusted-boundary.py` et 57 suites golden vont au rouge sur des
  fixtures qui doivent échouer — pas seulement sur le chemin heureux. 47 suites vertes en local
  avant tout changement ; les deux rouges (`wire-edges`, `renovate-config`) sont des défauts
  d'environnement macOS, traités ci-dessous.
- **RoselineMCP est expédié et imposé** (`.mcp.json`, `hooks/roseline-gate.sh`), pas seulement
  recommandé ; **AdrMcp** est consulté à quatre étapes avec une dégradation nommée.
- **Les décisions ont une maison** (`decisions/registry.json`, R1–R10), les ADRs existent (12),
  le vocabulaire est fixé (`CONTEXT.md`).
- **Les échecs récurrents des sessions passées sont déjà corrigés** : workers qui « attendent »
  (#187), merge décidé sur un code de sortie (#178), threads `COMMENTED` ignorés (#294), `tick-plan`
  qui pend sur macOS (#135), backlog qui gonfle d'un suivi par merge (#176, la filing bar).

## Constats

### Majeur

- [x] **Rien ne route une demande vers un skill du kit — la première action de cette session a
  été un skill de `superpowers`.** `.claude/CLAUDE.md` ne disait pas quel skill répond à quoi ;
  aucun document ne lit la méthodologie de bout en bout. → routage dans `CLAUDE.md` (#395),
  `docs/methodology.md` (#398).
- [x] **`context7` est déclaré, dessiné, et jamais invoqué.** `requirements.json` (recommended),
  `ARCHITECTURE.md` (arête `LU -.-> C7`), phase 0 (« context7 before phases 3/5 ») — et aucune
  référence de phase 3 ni 5 ne l'appelle. → phases 3 et 5 l'invoquent avec le repli documenté (#395).
- [x] **Le gate git compare des orthographes, et son interrupteur ment** (#372, #373, haute
  priorité) : `GIT_GATE=off git …` était enjambé, `cd <repo sans garde> && git commit` refusé,
  `./`, `:/`, `-fq`, `-fd -- -note` acceptés, `--staged .` et `--dry-run` refusés ; A35 ne mesurait
  rien. 12 verdicts faux → 0, 91 lignes de suite (#395).
- [x] **Une suite golden était rouge sur tout checkout macOS depuis #344** : `wire-edges.sh`
  écrivait `"$PARENT←$child"` et bash 3.2 absorbe les octets UTF-8 de la flèche dans le nom de
  variable. Les deux sites sont accolés ; la classe est repliée dans #144 (#395).
- [x] **Une suite rapportait un échec qui n'avait pas eu lieu sur ~22 % des runs** (#391,
  SIGPIPE sous pipefail). Le site est converti en here-string ; le gate structurel reste dans #391.
- [x] **Pas de forme « un item, de l'idée à la PR mergée »** — la chaîne était tapée à la main
  treize fois en deux semaines dans les transcriptions. → `deliver-issue` (#396, PR #399 mergée).
- [x] **Rien ne relit les transcriptions** — chaque défaut du kit corrigé en août a été trouvé à
  la main, des jours après que la preuve était sur disque. → `review-sessions` (#397, PR #405
  mergée).

### Mineur

- [x] **Le profil dérive** : « Domain language: none » alors que `CONTEXT.md` existe (#313),
  « sept ADRs » pour douze, `decision-check.py` absent de la liste des gates (#388). Corrigé, avec
  un garde dans `tests/repo-profile/test.sh` (#395).
- [x] **ADR 0007 restait `proposed`** alors que #328 avait livré ce que ses Conséquences
  attendaient (#395).
- [x] **Deux H1 et trois ids mermaid périmés** par le renommage 2.0 (#393) ; la description de
  `triage-backlog` au-dessus du plafond souple (#392) ; T8/T9 mutaient les rosters par une
  sous-chaîne littérale devenue no-op (#394) ; `usage_report.py --main <sid>` lisait `<sid>` comme
  répertoire (#354) ; le paragraphe de coût disait « not yet counted » (#385). Tous dans #395.
- [x] **`run-all-tests.sh --quick` exécutait quand même la suite réseau** (`renovate-config`, RE2)
  — un prérequis manquant lu comme une suite en échec (#395).
- [x] **`implement-issue` ne nommait jamais RoselineMCP** alors que le gate refuse un `Read` sur
  un `.cs` (#395).
- [x] **`plan-freshness.sh` lit `**Files:** none expected.` comme un chemin** et déclare le plan
  STALE (mesuré sur #396 et #397 : « MISSING modify none expected (Task 4) »). Déposé : #403.
- [x] **`survey.sh --help` imprime la file au lieu de l'usage.** Mineur — consigné sur #395, non
  déposé (filing bar).
- [x] **`create-issue` relit un `--grill` / `--seed` écrit dans la phrase d'une idée comme le
  flag** (revue Standards de #399). Déposé : #404.

### Info

- [ ] **Hygiène git** : 24 branches locales `worktree-wf_*` et 2 worktrees (17–21 août), 14
  branches distantes jamais supprimées après merge (antérieures à #196). Signalé, non touché.
- [ ] **La description, les topics, la homepage et Pages du dépôt sont vides** — `setup-repo` ne
  couvre pas ces quatre surfaces (#400) ; `docs/` n'est pas un site (#401).
- [ ] **Fusionner `profile-repo` et `setup-repo` ?** Non pour ce majeur — ADR 0013 (`proposed`).
- [ ] **Le harnais et le kit isolent différemment** : une session isolée dans un worktree ne peut
  pas utiliser le worktree par issue de `make-worktree.sh` (le hook du harnais refuse tout `git -C
  <autre>`). Contourné en branchant dans le worktree de la session ; à documenter dans
  `implement-issue` si le cas se reproduit.

## Ce que disaient les 36 sessions précédentes

Relues par un sous-agent sur les 276 messages utilisateur : 9 relances « continue » le 17 août
(l'assistant terminait son tour sur une attente), 2 workers de phase 1 morts en attendant le 19
août, 6 misprises « code de sortie = merge », un `/goal` interrompu après que le backlog est passé
de 26 à 28 issues en 19 merges, un `tick-plan.sh` qui pend sur macOS. Chacun a produit une règle
qui va maintenant au rouge (`tests/auto-dev-never-wait`, `merge-verdict.sh`, `guarded-pr-merge.sh`,
la filing bar, `TICK_PLAN_PATCH_TIMEOUT`). La correction du 2 septembre est du même ordre :
« tu commences par appeler superpowers alors que tu aurais dû appeler un skill du kit ».

## Plan d'action

1. [x] Corrections en un lot — PR #395 (13 commits, une cause par commit), mergée `3d3a820` :
   #372 #373 #391(site) #392 #393 #394 #388 #385 #354, context7, Roseline dans implement-issue,
   ADR 0007, profil, `run-all-tests`, `CLAUDE.md`, `wire-edges.sh`. Follow-ups : #403
   (`plan-freshness.sh` lit « none expected » comme un chemin), deux observations consignées.
2. [x] `deliver-issue` — #396, PR #399 mergée `218e53a` (revue Spec + Standards appliquées ;
   follow-up #404 : la grammaire des flags de `create-issue`).
3. [x] `review-sessions` — #397, PR #405 mergée `9954d86` (harvest réel : 344 signaux sur 163
   sessions ; revue Spec appliquée, l'écart des fixtures consigné avec sa raison).
4. [ ] `docs/methodology.md` + ce rapport + ADR 0013 — #398.
5. [ ] `setup-repo` : description, homepage, topics, source Pages — #400.
6. [ ] `docs/` en site GitHub Pages centré sur le guide — #401.

Trouvé en chemin, hors périmètre du kit : le fork du skill `code-review` (plugin officiel) a
détaché HEAD deux fois dans le worktree de la session pendant la revue de #399 et n'a jamais
rendu son rapport ; la revue Standards de #405 a été faite en ligne sur la grille de smells de
`references/spec-review.md`. Consigné en mémoire de projet, pas comme une issue du kit.

---
Rédigé à la main dans cette session, à partir des commandes rouges citées ; il n'y a pas de
`report.json` — les données vivent dans les PR et issues nommées.
