# Template — `migration/report.md`

Toute migration (in place ou réécriture) livre ce fichier, committé dans le repo cible.
Sections obligatoires, dans cet ordre. Les « Prochaines étapes » sont une **checklist actionnable**
avec effort estimé — c'est la passation : la personne qui reprend le repo sait quoi faire sans lire l'historique.

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
