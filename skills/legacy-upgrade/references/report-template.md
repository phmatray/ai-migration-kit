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
   porte, jamais chronométrées à la main ; cf. phase-6-verify §6) · **Prochaines étapes** · Suivis
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

⚠ **La tuile KPI de couverture recopie le chiffre que le graphe calcule.** Le dashboard affiche
`Global : N % lignes` sous le graphe ; si la tuile KPI dit autre chose, la page se contredit.
Relire le HTML généré et aligner le KPI, ou le laisser à un autre indicateur.

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
