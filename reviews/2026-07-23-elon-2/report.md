# Code review — ai-migration-kit (2026-07-23)

**main @ 2a3bef8**

Revue de v1.6.0 (solution unifiée : skills lifecycle intégrés, requirements.json source unique) sous la lentille demandée : cohérence des skills, workflow prédictif, déterminisme.

| Reviewer | Rating | Verdict |
|---|---|---|
| 🔥 Elon Musk | 7.5/10 | L'usine est réelle et la discipline est réelle — mais un kit qui vend du déterminisme ne peut pas avoir trois réponses à « où finit /migrate » et des scripts introuvables dès qu'on l'installe sans son auteur. |

## Findings

### Major
- [x] **Où finit /migrate ? Trois contrats contradictoires autour de la phase 7** — `skills/legacy-upgrade/SKILL.md:67` (S)
  Trancher : soit /migrate couvre 1–7 (mettre à jour commands/migrate.md et la marque « six-phase » partout : README, plugin.json, intro du SKILL.md), soit la livraison devient une commande explicite (/migrate-deliver) et la règle 8 est reformulée comme contrat de cette commande. Une seule réponse, répétée sur toutes les surfaces.
- [x] **Chemins des scripts du kit indéfinis en installation plugin — deux conventions, une casse** — `skills/legacy-upgrade/SKILL.md:27` (M)
  Ancrer chaque appel de script sur <skill-dir> (ou une résolution KIT_DIR documentée en tête de chaque SKILL.md), comme get-repo-profile. Ajouter un test CI qui exécute preflight.sh et followups.py depuis un répertoire de travail étranger au kit pour verrouiller la convention.
- [x] **requirements.json aplatit les niveaux par suite — « level: recommande / when: requis » dans la même entrée** — `requirements.json:19` (M)
  Étendre le schéma du manifest avec la requiredness par suite (ex. requiredBy: ["lifecycle"] vs ["migration"]) ; le préflight affiche le niveau par suite. Ajouter un test golden croisant requirements.json ↔ le frontmatter compatibility de chaque skill, pour que la prochaine divergence casse la CI et non l'utilisateur.

### Minor
- [x] **repo-profile.sh detect : les fallbacks TODO après pipeline sont du code mort** — `skills/get-repo-profile/scripts/repo-profile.sh:72` (S)
  Faire passer toutes les sondes par probe() (qui teste la vacuité de la sortie), ou capturer la sortie dans une variable et tester [ -n ] avant d'imprimer le fallback TODO. Une seule convention dans le script.
- [x] **repo-profile.sh est le seul script du kit sans test — jamais exécuté en CI** — `skills/get-repo-profile/scripts/repo-profile.sh:1` (M)
  Golden test en CI : « show » sur un répertoire sans profil (attend NO_PROFILE, exit 3) et avec profil fixture ; « detect » sur un repo fixture (samples/LegacyShop convient) en vérifiant les sections attendues ET la présence des lignes TODO sur les champs indétectables — ce qui aurait attrapé le finding 4.
- [x] **preflight --json : JSON fabriqué au printf sans échappement, séparateur interne « | »** — `scripts/preflight.sh:76` (S)
  Émettre le JSON via python3 (json.dumps) à partir des résultats — le script paie déjà le coût de python3 ; supprimer l'émetteur printf et le séparateur « | » au profit d'un format sans collision (tab, déjà utilisé pour le manifest).
- [x] **Les listes de déclenchement sont des données statiques — la cible ≥ 90 % n'est exécutée nulle part** — `tests/skills/check-frontmatter.py:58` (M)
  Passer les six listes au banc skill-creator une première fois (baseline), puis instituer la règle déjà écrite : re-bencher à chaque modification de description. Si le banc reste manuel, renommer honnêtement (contracts/ plutôt que tests/) ou documenter dans le fichier que la garde CI ne couvre que la présence.

### Info
- [x] **Patchwork linguistique : FR, EN, et FR/EN mélangés dans le même fichier** — `skills/legacy-upgrade/SKILL.md:25` (M)
  Une langue par surface : l'anglais pour tout ce qui est distribué (SKILL.md, references, README technique), le français là où l'audience est délibérément francophone (case studies). Au minimum, unifier legacy-upgrade en un seul fichier monolingue.
- [x] **implement-issue : un crash entre le PATCH de l'issue et l'édition de la PR laisse le miroir périmé pour toujours** — `skills/implement-issue/SKILL.md:199` (S)
  Ajouter une réconciliation au démarrage du Step 6 (reprise) ou au Step 9 : régénérer la liste ### Plan de la PR depuis l'état canonique de l'issue — une passe idempotente et bon marché.

## Action plan

1. [x] Trancher le contrat de phase 7 (/migrate jusqu'à la production, ou une commande de livraison explicite) et corriger la marque « six phases » partout (S)
2. [x] Ancrer tous les appels de scripts du kit sur <skill-dir> comme get-repo-profile, prouvé par un test CI depuis un CWD étranger (M)
3. [x] requirements.json : requiredness par suite + test golden manifest ↔ compatibility ; tester repo-profile.sh, émettre le JSON du préflight via python3 (M)

---
Generated from report.json by legends-review — data lives in the JSON, the HTML is always regenerated, never edited by hand.
