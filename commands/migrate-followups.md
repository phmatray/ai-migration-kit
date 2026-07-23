---
description: Consolide les suivis ouverts des repos migrés (décisions propriétaire, tâches, différés) et les met à jour à la source
argument-hint: [repo-dir ...]
---

Invoque le skill `followups`.

Cibles : chaque répertoire passé dans `$ARGUMENTS` (sinon, les repos migrés connus de la
session/mémoire ; sinon, demander). Ajouter le backlog du kit si accessible.

Discipline : agrégation exclusivement via `scripts/followups.py` (règle 7) ; toute mise à jour
(fait / clos par décision / ajout) s'applique dans le `migration/report.json` du repo concerné,
avec dashboard régénéré et commit — jamais de liste parallèle. Termine en présentant la vue
consolidée et les actions possibles.
