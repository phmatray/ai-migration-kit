---
description: Audit exécutif lecture seule — effort chiffré, risques, cible recommandée ; multi-apps → synthèse portefeuille
argument-hint: [app-dir ...]
---

Invoque le skill `legacy-upgrade` et exécute un **audit exécutif** selon `references/audit-executive.md`.

Cibles : chaque répertoire passé dans `$ARGUMENTS` (sinon, le répertoire courant).

Discipline : lecture seule absolue sur les apps ; chiffres exclusivement issus de `scripts/audit-inventory.sh` ; tentative RoselineMCP `analyze_solution` consignée (succès ou échec de chargement) ; formule d'effort et correspondances API du guide appliquées uniformément. Plusieurs apps → un rapport par app + synthèse portefeuille (matrice valeur/effort, ordre de migration, première vague). Termine en présentant la synthèse.
