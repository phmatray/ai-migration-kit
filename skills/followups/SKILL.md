---
name: followups
description: Consolide et met à jour les suivis ouverts des migrations (next_steps/deferred des migration/report.json + backlog du kit). Use whenever the user asks what remains open, wants a status of pending decisions or follow-ups across migrated repos, says a follow-up item is done, or decides to close/abandon one — triggers on « fais le point », « qu'est-ce qui reste », « suivis », « follow-ups », « next steps », « c'est fait, coche-le », « on ne le fera pas », /migrate-followups. Also run it at the end of every migration (phase 7) so the open tail stays current.
---

# Suivis de migration — agrégation et mise à jour

Le pipeline livre des apps vérifiées **et** une queue de suivis : décisions qui n'appartiennent
qu'au propriétaire, tâches rapides, différés assumés. Cette queue vit déjà, structurée, dans le
`migration/report.json` de chaque repo migré (`next_steps`, `deferred`) — ce skill la fait
remonter et la met à jour **à la source**. Jamais de liste parallèle : un tracker séparé
divergerait des rapports, qui sont la vérité exécutive et l'entrée du dashboard.

## Faire le point

1. Déterminer les repos : ceux passés en argument, sinon les repos migrés connus de la
   conversation/mémoire, sinon demander. Ajouter `--backlog docs/backlog.md` si le repo du kit
   est accessible (dettes à déclencheur).
2. Exécuter l'outil du kit (obligatoire — règle 7, jamais d'agrégation manuelle) :
   ```bash
   python3 scripts/followups.py <repo1> <repo2> … --backlog docs/backlog.md
   ```
3. Présenter la sortie telle quelle (elle est déjà triée : décisions propriétaire d'abord,
   puis tâches par effort croissant) et proposer la suite : trancher une décision, exécuter
   une tâche rapide, ou clore par décision.

L'outil signale les repos sans `migration/report.json` — c'est une erreur à remonter, pas à
masquer (un repo migré sans rapport a un problème plus grave que ses suivis).

## Marquer un suivi « fait »

Un suivi terminé disparaît de `next_steps` — l'historique vit dans git, pas dans le JSON :

1. Dans le repo concerné : retirer l'entrée de `next_steps` dans `migration/report.json`.
2. Dans `migration/report.md`, cocher la ligne correspondante (`- [x] …`) — la trace lisible.
3. Régénérer le dashboard : `python3 scripts/report-dashboard.py migration/report.json`
   (chemin du kit ; la sortie atterrit à côté du report.json).
4. Committer dans ce repo : `chore: suivi clos — <résumé de l'item>`.

Si l'accomplissement mérite une preuve (ex. « PWA installée sur appareil »), la demander ou la
noter dans le message de commit — la doctrine du kit est « fait = vérifié ».

## Clore par décision (« on ne le fera pas »)

Abandonner un suivi est un état légitime et **documenté**, jamais une suppression muette :

1. Retirer l'entrée de `next_steps` et l'ajouter à `deferred` :
   ```json
   { "strong": "Non poursuivi par décision (AAAA-MM-JJ)", "text": "<l'item d'origine — et la raison si donnée>" }
   ```
2. Cocher/annoter la ligne dans `report.md` (`- [x] ~~…~~ — non poursuivi par décision`).
3. Régénérer le dashboard, committer : `chore: suivi clos par décision — <résumé>`.

Le précédent : popcorn-time, « non poursuivi par décision, pas par manque de capacité ».

## Ajouter un suivi découvert après coup

Ajouter à `next_steps` avec le format du rapport : `{ "text": …, "effort": "~N min", "owner": true }`
si la décision appartient au propriétaire — puis dashboard + commit, comme ci-dessus.

## Garde-fous

- **Toute mutation se fait dans le repo cible et s'y committe** — un suivi modifié sans commit
  n'existe pas.
- Le backlog du kit (`docs/backlog.md`) s'édite à la main (ses entrées portent leur déclencheur
  YAGNI) ; ce skill le lit, il ne le réécrit pas.
- Ne jamais inventer d'items : tout vient des rapports, du backlog, ou d'une demande explicite.
