# Livraison — playbook

Une migration n'est finie que **déployée et vérifiée en production**. Étapes déterministes ;
les templates du kit sont **obligatoires** (pas de workflow artisanal).

## Étapes

1. **Découvrir la branche par défaut** (elle varie : `main`, `dev`…) :
   `gh api repos/<o>/<r> --jq .default_branch` — c'est la cible du merge et le déclencheur des workflows.
2. **Vérifier l'état du repo distant** : s'il est **archivé** (lecture seule), le désarchiver avant tout push :
   `gh api repos/<o>/<r> -X PATCH -f archived=false` — le signaler à l'utilisateur (réversible).
3. **Déposer les workflows depuis les templates** :
   - `templates/ci-dotnet.yml` → `.github/workflows/ci.yml` — **renseigner `SOLUTION`** si l'ancienne
     solution legacy coexiste à la racine (sinon MSB1011).
   - `templates/deploy-pages-blazor.yml` → `.github/workflows/deploy-pages.yml` — renseigner
     `SOLUTION`, `WEB_PROJECT`, `BASE_PATH=/<repo>/`, et `branches:` = la branche par défaut.
4. **Pousser la branche de migration, merger** (`--no-ff`) dans la branche par défaut, pousser.
5. **Activer Pages en mode workflow** : `gh api repos/<o>/<r>/pages -X POST -f build_type=workflow`
   — idempotent : un `409` signifie « déjà activé », c'est un succès, continuer.
   (Fonctionne aussi depuis un repo privé si le plan le permet — l'URL retournée fait foi.)
6. **Attendre la conclusion des runs** (`gh run list`) — un échec de CI se corrige avant de continuer,
   même si le déploiement a réussi.
7. **Vérifier la production** : `curl` la racine **et une route profonde** (le fallback SPA est le
   piège n° 1). ⚠ Avec le fallback 404.html de GitHub Pages, la route profonde répond
   **statut HTTP 404 mais contenu = l'app** : vérifier le contenu (`grep` du shell de l'app),
   jamais le seul code de statut. Puis capture navigateur de la route profonde — la regarder,
   pas seulement la produire.
8. **Boucler le rapport** : cocher les étapes livrées dans `migration/report.json`, régénérer le
   dashboard (`scripts/report-dashboard.py`), committer.
9. **Rétropropager les leçons (contrat de phase 7, règle 8)** : la migration se clôt par une entrée
   `lessons` dans `migration/report.json` — soit la référence du changement appliqué au kit
   (commit/PR : ligne Common issues, protocole de playbook, garde de script), soit un
   « rien à apprendre de cette vague » explicite. Schéma :
   `"lessons": [{ "strong": "<titre>.", "text": "<la leçon>", "ref": "kit@<commit> (optionnel)" }]`.
   Le dashboard rend la carte « Leçons de la vague » ; une vague sans entrée `lessons` est
   incomplète — le pipeline ne quitte pas le repo sans elle.

## Pièges connus (tous rencontrés en vague 1)

| Piège | Symptôme | Parade |
|-------|----------|--------|
| Branche par défaut ≠ `main` | workflows jamais déclenchés | étape 1 |
| Repo archivé | `403` au push | étape 2 |
| Deux `.sln` à la racine | `MSB1011` en CI | `SOLUTION` explicite |
| Pas de fallback SPA | routes profondes en 404 (un `http.server` nu ne le fait pas non plus en local) | template (404.html) + vérif étape 7 |
| `<base href>` non ajusté | page blanche sous /repo/ | `BASE_PATH` du template (garde-fou intégré : placeholder refusé, réécriture vérifiée) |
| Pages déjà activées | `409` sur le POST | idempotent — continuer (étape 5) |
| Fallback 404.html | route profonde « 404 » au curl alors que tout marche | vérifier le contenu et la capture, pas le statut (étape 7) |
