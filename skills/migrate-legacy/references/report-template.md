# Template — rapport de migration

Toute migration (in place ou réécriture) livre **deux fichiers** committés dans le repo cible :

1. **`migration/report.html` — le rapport, sous forme de dashboard exécutif.** **Généré
   obligatoirement par `scripts/report-dashboard.py`** depuis un `migration/report.json` versionné
   (données) + le cobertura (couverture mesurée) — l'écriture manuelle du HTML est interdite
   (règle 7 du skill : déterminisme). Document HTML **autonome** (doctype complet, CSS/JS inline,
   captures embarquées en data URI — double-cliquable, envoyable par mail à un décideur). Thème clair/sombre, palette validée (cf. méthode dataviz du
   dashboard d'audit). Sections dans l'ordre : bandeau résultat + badge Vérifié · tuiles KPI (tests,
   **couverture mesurée** — coverlet/cobertura, jamais estimée —, erreurs/warnings, chiffre métier,
   estimation vs réalisé) · **valeur business** (ce que la migration change : actif réactivé, risque
   éteint par preuve, coût de maintenance, réutilisabilité) · capture du produit · couverture par
   classe (graphique) · avant/après · code porté vs écrit vs testé · portes franchies (une par
   commit) · **chronologie du pipeline** (`phases[]` — minutes par phase, dérivées des commits de
   porte, jamais chronométrées à la main ; cf. phase-6-verify §7) · **Prochaines étapes** · Suivis
   différés · **leçons de la vague** (`lessons` — rétropropagées au kit ou « rien à apprendre »
   explicite ; cf. delivery-playbook §9) · méthode et limites.
2. **`migration/report.md` — le résumé diffable** (grep/diff-friendly) : mêmes chiffres condensés,
   lien vers le dashboard.

⚠ **`coverage.cobertura` doit désigner un RÉPERTOIRE, pas un fichier.** Sous
Microsoft Testing Platform, chaque projet de test écrit son propre rapport et c'est le
collecteur qui le nomme, avec un identifiant neuf à chaque run :

```json
"coverage": { "cobertura": "../coverage", "exclude": ["MonApp.Web"] }
```

⚠ **Un chemin relatif se résout contre le répertoire du `report.json`, pas contre la racine du
repo.** Le rapport vit dans `migration/` et `templates/ci-dotnet.yml` écrit ses rapports dans le
`coverage/` de la **racine** : le chemin correct remonte donc d'un cran, `"../coverage"`. Écrire
`"coverage"` désignerait `migration/coverage`, où rien n'écrit jamais.

Cette résolution rend `migration/` autonome pour tout ce qu'il contient — mais `../coverage` sort
précisément du dossier, donc **déplacer `migration/` ailleurs casse la regénération du rapport**.
C'est le prix assumé de lire la couverture là où la CI l'écrit ; le HTML produit, lui, reste
autonome (CSS/JS inline, captures en data URI) et se déplace sans rien casser.

Le champ accepte aussi un fichier, une liste de fichiers ou un motif glob, mais un chemin
littéral écrit dans un `report.json` versionné sera périmé au run suivant. Et en choisir **un**
parmi plusieurs republierait la couverture d'un seul projet comme celle de l'app — exactement
le défaut que la collecte par projet corrige. `report-dashboard.py` agrège les rapports qu'il
trouve (union des lignes, jamais une somme de pourcentages).

⚠ **La tuile KPI de couverture est CALCULÉE, pas recopiée.** `report-dashboard.py` remplace la valeur
écrite dans `kpis` par la mesure — la même que celle du `Global : N %` sous le graphe. Écrire un
chiffre à la main dans cette tuile est donc sans effet : la page ne peut plus publier deux couvertures
contradictoires.

La tuile peut déclarer ce qu'elle rend, et c'est la forme à préférer :

```json
{ "v": "0", "unit": "%", "label": "couverture mesurée (lignes)", "source": "line_pct" }
```

`source` vaut `line_pct` ou `branch_pct`. Sans lui — le cas de tous les `report.json` écrits avant —
la tuile est reconnue à son libellé : unité `%` et un libellé parlant de *couverture*, qui rend les
lignes, ou les branches si le libellé parle de branches. Une tuile qui n'est pas une couverture
(`tests verts`, un chiffre métier) n'est jamais touchée.

⚠ **Une grandeur non mesurée s'affiche `n/d`, jamais `0 %`.** Un zéro est un chiffre, et sur cette
page un chiffre se lit comme une mesure. Deux cas :

- **Branches.** Le taux vient des `condition-coverage` par ligne quand tous les rapports en portent ;
  à défaut du `branch-rate` racine, mais seulement pour un rapport **unique et non filtré** — c'est
  un taux global, il ignore `exclude`/`include`, et le moyenner sur plusieurs rapports n'aurait pas
  de sens. Hors de là : `branches n/d`.
- **Lignes.** Si `exclude`/`include` filtrent jusqu'à ne plus rien laisser — un `include` portant un
  nom de classe périmé après un renommage, typiquement — la légende dit `lignes n/d` au lieu de
  `0 %`. La tuile garde alors la valeur écrite, faute de mesure : c'est le signe qu'il faut corriger
  le filtre.

⚠ Le champ `coverage` reste **obligatoire** : le rapport est généré depuis un cobertura, et un
`report.json` sans lui ne se génère pas du tout. La tuile écrite à la main n'est pas une porte de
sortie pour publier une couverture non mesurée.

Les « Prochaines étapes » sont une **checklist actionnable** avec effort estimé — c'est la
passation : la personne qui reprend le repo sait quoi faire sans lire l'historique.
Structure du résumé markdown :

```markdown
# Rapport de migration — <app> (<origine> → <cible>)

**Date :** <yyyy-mm-dd> · **Pipeline :** ai-migration-kit <commande> · **Branche :** migration/<date>

## Avant / après
| | Avant | Après |
(plateforme/TFM, packages, diagnostics, tests, points notables — chiffres mesurés uniquement)

## Tests
**Plateforme de test :** <VSTest | Microsoft Testing Platform> · **Tests exécutés :** <n> (baseline <n>)
(l'item phase 5 « xunit v2 → v3 » : appliqué, non demandé, ou `deferred: <blocage nommé>`)

## Portes franchies
(une entrée par porte verte = par commit : ce qui a été fait, preuve à l'appui)

## Vérification
(build, tests, diagnostics vs baseline, smoke test runtime — résultats réels)

## Estimation vs réalisé
(chiffre de l'audit, réalisé, écart expliqué)

## Santé des dépendances
**Statut :** <ok | findings> · **Vérifié le :** <ISO 8601> (bloc `dependencyHealth` de
`migration/report.json`, produit par `scripts/dependency-health.sh` — phase-6-verify §4)

| Paquet | Version | Type | Sévérité | Avis |
|---|---|---|---|---|
| <id> | <résolue> | vulnérable / déprécié, et **top-level ou transitive** (champ `transitive`) | <low\|moderate\|high\|critical> ou n/d | <URL de l'avis> ou <paquet alternatif> |

(« aucune » quand les deux listes sont vides — la section reste, car le lecteur doit pouvoir
distinguer *mesuré, rien trouvé* de *jamais mesuré*.)

⚠ Cette section est obligatoire dans **`report.md`**, et seulement là pour l'instant :
`report-dashboard.py` ne connaît pas encore `dependencyHealth`, et l'écriture manuelle du HTML est
interdite (règle 7). L'inscrire à la liste des sections de `report.html` ci-dessus rendrait
obligatoire une carte que le générateur ne produit pas — une exigence que rien ne peut satisfaire.
La carte du dashboard est un non-objectif explicite de #267 (« worth doing; not this issue ») ; la
liste des sections de `report.html` ne bouge qu'avec elle.

Chaque ligne ci-dessus a son pendant en **Prochaines étapes** (décision du propriétaire : monter de
version, accepter le risque, remplacer par l'alternative nommée) ou en **Suivis différés** avec le
POURQUOI du report. Une trouvaille qui n'apparaît que dans ce tableau n'a pas de propriétaire.

Ce tableau est une **photo à la date de livraison**, pas une surveillance : le complément continu
est Renovate/Dependabot activé sur le repo livré (phase 7, CI) — c'est lui qui verra la CVE publiée
la semaine prochaine.

## Prochaines étapes
- [ ] <action concrète, ordonnée, avec effort estimé> (ex. : merger la branche, déployer avec
      fallback SPA, brancher la CI sur les tests, décisions en attente du propriétaire)

## Suivis différés
(quirks documentés non corrigés, modernisations écartées, idées v2 — avec le POURQUOI du report)
```

Règles :
- **Prochaines étapes ≠ Suivis.** Les premières sont le chemin critique vers la mise en production
  (à faire, ordonnées) ; les seconds sont des opportunités (facultatives, datées, justifiées).
- Chaque affirmation chiffrée du rapport doit être reproductible (commande ou test qui la vérifie).
- Le rapport vit dans `migration/`, jamais dans l'UI du produit (règle 6 du skill).
