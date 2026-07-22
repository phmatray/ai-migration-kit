# Changelog

Toutes les évolutions notables du kit. Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/),
versionnage sémantique. La question à laquelle ce fichier répond : « qu'est-ce qui change si je mets à jour ? »

## [1.3.2] — 2026-07-23

Leçons de la vague 2 (fleurs-du-mal, migrée en ~30 min pour 18 j estimés).

### Ajouté
- **Protocole d'inventaire des assets binaires locaux** (rewrite-playbook) : regarder chaque
  asset embarqué avant de dessiner l'UI — le dessin original d'une artiste, cœur du design 2014,
  avait failli être perdu parce que les seules images *visibles* étaient des URLs externes mortes.
  Port octet pour octet + crédit d'artiste (décision propriétaire si le nom manque).

### Corrigé
- `report-dashboard.py` : les chemins du `report.json` (cobertura, capture) se résolvent
  **relativement au JSON**, plus au répertoire courant ; le test golden le prouve en tournant
  depuis la racine du repo.

## [1.3.1] — 2026-07-23

Durcissement issu de la review v1.3.0 : les outils rendus obligatoires par la règle 7 deviennent
infaillibles et testés.

### Ajouté
- **Test golden du générateur de rapport** (`tests/report-dashboard/`) : fixture `report.json` +
  cobertura → HTML, assertions sur les valeurs calculées (couverture par classe, exclusions,
  autonomie du document, thème sombre). Exécuté en CI ; remplace le simple `py_compile`.
- **`preflight.sh --json`** : sortie machine des checks, à verser dans `migration/report.json`
  sans recopie manuelle.
- **Garde-fous dans `templates/deploy-pages-blazor.yml`** : échec explicite si `BASE_PATH` reste
  le placeholder `/REPO_NAME/`, et vérification post-`sed` que le `<base href>` a réellement été
  réécrit — fini le déploiement vert avec page blanche en prod.
- **Validation YAML des templates** dans la CI du kit.
- Ce CHANGELOG.

### Modifié
- Préflight : le SDK .NET est vérifié par **comparaison numérique du major (>= 8)** au lieu de
  l'énumération `8|9|10` qui aurait bloqué à tort les SDK futurs (.NET 11+).
- Préflight : un serveur MCP **configuré mais non connecté ne passe plus** — l'état de santé de
  `claude mcp list` est vérifié, pas seulement la présence du nom.
- Template de déploiement : le `sed` du base href tolère les variantes du template Blazor
  (`<base href="/">`, `"/"/>`, `"/" />`) ; en-tête enrichi (409 Pages = déjà activé,
  `dotnet-version` à ajuster au TFM cible).
- Playbook de livraison : activation Pages documentée idempotente (`409` = succès, continuer).

### Supprimé
- Les « indices disque » de présence des skills dans le préflight : un check dont le script
  lui-même disait « la vérité est ailleurs » est du bruit. La responsabilité vit à l'étape 2 de
  la phase 0 (SKILL.md) : l'agent confirme ses capacités de session.

## [1.3.0] — 2026-07-22

Le pipeline devient déterministe et auto-vérifié.

### Ajouté
- **Phase 0 préflight** (`scripts/preflight.sh`) : requis bloquants (dotnet, git, python3,
  RoselineMCP), recommandés à dégradation bruyante (context7, gh, node, Chrome headless).
- **Phase 7 Deliver** + `references/delivery-playbook.md` : une migration n'est finie
  qu'en production vérifiée (branche par défaut, désarchivage, Pages, route profonde + capture).
- **`templates/deploy-pages-blazor.yml`** : déploiement Blazor WASM → GitHub Pages paramétré
  (SOLUTION, WEB_PROJECT, BASE_PATH), fallback SPA et `.nojekyll` intégrés.
- Règles 7 (« scripts et templates du kit obligatoires ») et 8 (« livrée = en production »).
- Protocoles vague 1 dans le rewrite-playbook : namespaces conservés, en-têtes RECONSTRUCTION,
  tests historiques jamais verts (skip documenté + wrapper + tests d'intention), `<NoWarn>` d'époque.

## [1.2.0] — 2026-07-22

Industrialisation post-vague 1.

### Ajouté
- **`scripts/report-dashboard.py`** : générateur du dashboard exécutif de migration
  (`report.json` + cobertura + capture → HTML autonome, thème clair/sombre, palette validée).
- **`templates/ci-dotnet.yml`** : CI réutilisable (tests + couverture), variable `SOLUTION`
  pour les repos à plusieurs `.sln` (leçon MSB1011 de chords).
- CI du kit (fixture LegacyShop, manifestes, invariants des guides de phase).
- Publication du repo (github.com/phmatray/ai-migration-kit) et cas d'étude portfolio WinRT
  avec deux migrations en production (sokoban, chords).

## [1.1.0] — 2026-07-22

### Ajouté
- **`/migrate-audit`** : audit exécutif lecture seule, chiffré (formule d'effort transparente,
  ±30 %), portfolio multi-apps avec matrice valeur/effort et première vague recommandée.
- `scripts/audit-inventory.sh` : inventaire JSON reproductible (ère technologique, surface XAML,
  clusters d'API plateforme, LOC logique vs code-behind).
- Rewrite-playbook (port-characterize-wrap) pour les plateformes mortes (WinRT/UWP → Blazor).
- Règle 6 : le livrable ne raconte jamais sa migration.

## [1.0.0] — 2026-07-22

### Ajouté
- Pipeline six phases porté par RoselineMCP : Assess, Baseline, Retarget, Remediate, Modernize,
  Verify — portes vertes obligatoires, mutations preview-first, branche `migration/<date>`.
- Commandes `/migrate`, `/migrate-assess`, `/migrate-verify`.
- Fixture `samples/LegacyShop` (net6.0, volontairement legacy) et démo vérifiée
  (`docs/demo-walkthrough.md`).
