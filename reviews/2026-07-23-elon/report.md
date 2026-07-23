# Revue de code — ai-migration-kit (2026-07-23)

**main @ 2abab0b**

Audit de la suite de six skills du kit contre le guide officiel Anthropic « The Complete Guide to Building Skills for Claude ».

| Reviewer | Rating | Verdict |
|---|---|---|
| 🔥 Elon Musk | 7/10 | La charpente est celle que le guide enseigne — c'est la couche distribution qui manque : trois descriptions hors limite, zéro métadonnée, un seul skill testé au déclenchement. |

## Constats

### Majeur
- [x] **Trois descriptions dépassent la limite de 1024 caractères du standard** — `skills/implement-issue/SKILL.md:3` (M)
  Compresser les trois descriptions au format [Quoi] + [Quand] + [phrases de déclenchement] en ≤ 1024 caractères. Conserver les déclencheurs négatifs (« Does NOT apply to ») mais laconiques ; déplacer la nuance détaillée dans la section « What this does » du corps.
- [x] **Aucune métadonnée de distribution : compatibility, license, metadata.version absents des six skills** — `skills/legacy-upgrade/SKILL.md:2` (S)
  Ajouter aux six SKILL.md : compatibility (dérivé de requirements.json), metadata.version (aligné sur le CHANGELOG du kit), metadata.author, et license (décision MIT/Apache-2.0 au niveau repo, répercutée dans le frontmatter).
- [x] **Cinq skills sur six sans tests de déclenchement** (M)
  Créer tests/skills/<name>.triggers.md par skill : liste should-trigger (requêtes évidentes + paraphrases) et should-not-trigger (sujets adjacents). Les passer au banc skill-creator à chaque modification de description — la méthode déjà prouvée sur followups, généralisée.

### Mineur
- [x] **Duplication SKILL.md ↔ references dans implement-issue et merge-pr** — `skills/implement-issue/SKILL.md:94` (M)
  Un seul exemplaire par snippet : SKILL.md garde le contrat et le résultat attendu, references/ garde la recette complète, lien explicite entre les deux (le pattern « Reference bundled resources clearly » du guide).
- [x] **Pas de section Troubleshooting structurée (Erreur → Cause → Solution)** — `skills/legacy-upgrade/SKILL.md` (S)
  Ajouter un « Common issues » (Erreur → Cause → Solution) dans legacy-upgrade (préflight échoué, roseline absent, workload manquant, gate rouge) et consolider les gotchas des skills lifecycle sous le même format dans leurs references.
- [x] **Phrases de déclenchement monolingues selon le skill** — `skills/followups/SKILL.md:3` (S)
  Chaque description porte 2-3 phrases de déclenchement par langue (FR + EN), sans dépasser la limite des 1024 caractères (à faire en même temps que le finding 1).

## Plan d'action

1. [x] Compresser les 3 descriptions hors limite à ≤ 1024 caractères ([Quoi]+[Quand]+[déclencheurs], négatifs laconiques) (M)
2. [x] Ajouter compatibility + metadata.version (+ license) aux six skills — le miroir distribution de requirements.json (S)
3. [x] Créer les listes should/should-not par skill sous tests/skills/ et les passer au banc skill-creator (M)

---
Généré depuis report.json par legends-review — les données vivent dans le JSON, le HTML est toujours régénéré, jamais édité à la main.
