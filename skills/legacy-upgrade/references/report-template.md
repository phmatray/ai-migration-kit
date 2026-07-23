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

Les « Prochaines étapes » sont une **checklist actionnable** avec effort estimé — c'est la
passation : la personne qui reprend le repo sait quoi faire sans lire l'historique.
Structure du résumé markdown :

```markdown
# Rapport de migration — <app> (<origine> → <cible>)

**Date :** <yyyy-mm-dd> · **Pipeline :** ai-migration-kit <commande> · **Branche :** migration/<date>

## Avant / après
| | Avant | Après |
(plateforme/TFM, packages, diagnostics, tests, points notables — chiffres mesurés uniquement)

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
