# Backlog du kit

Décisions notées, pas encore justifiées par l'échelle — chaque entrée dit le déclencheur qui la
rendra rentable (YAGNI sinon).

- **Synchronisation des artefacts copiés dans les repos migrés** (`sw.js`, workflows) : le bug du
  fallback hors-ligne a dû être corrigé trois fois (sokoban, chords, fleurs-du-mal).
  Déclencheur : ~5 repos migrés → script `sync-artifacts` qui compare les copies aux templates
  et ouvre les correctifs.
- **Timeout sur `claude mcp list` dans le préflight** : un CLI qui bloque (auth expirée) gèle la
  phase 0. Déclencheur : premier gel constaté.
- **Banc de déclenchement sur les 6 skills** : les listes `tests/skills/*.triggers.md` sont des
  contrats statiques — la CI garde leur présence (check-frontmatter.py), pas la cible ≥ 90 % ;
  seul `followups` a jamais vu le banc (16/16, v1.5.0). Déclencheur : prochaine modification
  d'une `description` → passer la liste du skill touché au banc skill-creator.
- **Traduction anglaise des 4 references françaises de `legacy-upgrade`** (audit-executive,
  delivery-playbook, report-template, rewrite-playbook) : la surface distribuée est anglaise
  depuis v1.7.0 (SKILL.md, commandes), ces references restent françaises. Déclencheur : premier
  utilisateur non francophone du kit, ou première retouche de fond d'une de ces references.
- **Optimisation du déclenchement du skill `followups`** : la boucle skill-creator (5 itérations,
  20 requêtes, 3 mesures chacune) n'a départagé aucune variante — en sonde headless sans contexte
  de repo, le skill ne se déclenche presque jamais (positifs ≈ 0/3), donc la mesure est au
  plancher ; seul signal fiable : zéro sur-déclenchement sur les 10 quasi-pièges. Description
  d'origine conservée. Déclencheur : premier sous-déclenchement constaté en session réelle.
