# Revue de code — ai-migration-kit (2026-07-23)

**main @ 2a3bef8**

Analyse produit : quelles approches d'Arbor (RUC-NLPIR) mériteraient d'entrer dans l'ai-migration-kit — et lesquelles refuser.

| Reviewer | Rating | Verdict |
|---|---|---|
| 🍎 Steve Jobs | 8/10 | Arbor cherche son chemin ; votre kit sait où il va — volez-lui ses ceintures de sécurité, jamais son volant. |

## Constats

### Majeur
- [x] **Pas de reprise explicite d'un /migrate interrompu (le --resume d'Arbor manque)** — `skills/legacy-upgrade/SKILL.md:66` (M)
  Au lancement, /migrate détecte un dossier migration/ existant et le dernier commit de gate vert (message nommant la phase, règle 4), annonce « migration en cours détectée — reprise en phase N » et ré-entre à la phase suivant le dernier gate vert. Documenter ce comportement dans SKILL.md (Scope variants) et commands/migrate.md.
- [x] **Phase 4 sans garde de convergence — la boucle de remédiation peut tourner à vide** — `skills/legacy-upgrade/SKILL.md:49` (S)
  Règle de convergence en phase 4 : si deux passes consécutives de remédiation ne réduisent pas le compte d'erreurs, stop — retour au dernier commit vert, la situation est consignée dans le rapport comme blocage avec les diagnostics restants groupés par id, et l'humain décide. Une ligne dans les hard rules + une entrée dans Common issues.

### Mineur
- [x] **Le chiffre-titre du kit (« 18 min ») est mesuré à la main, pas par l'outillage** — `README.md:18` (S)
  Horodater chaque phase dans migration/report.json (début, fin, durée par phase + total pipeline) au moment où le gate passe au vert ; report-dashboard.py affiche la ligne de temps par phase. La colonne du README devient un fait généré, cité depuis le rapport.
- [x] **La rétropropagation des leçons est une culture, pas un contrat de phase 7** — `skills/legacy-upgrade/SKILL.md:52` (S)
  Étape formelle en phase 7 (delivery-playbook) : la migration se conclut par une entrée « leçons » dans migration/report.json — soit un renvoi vers un diff appliqué au kit (ligne Common issues, playbook, garde de script), soit un « rien à apprendre de cette vague » explicite. Le rapport final l'affiche ; une vague sans entrée leçons est incomplète.

### Info
- [x] **L'audit de portefeuille est séquentiel — le dispatch parallèle d'Arbor s'y appliquerait** — `commands/migrate-audit.md:1` (M)
  Documenter le pattern fan-out dans /migrate-audit : un sous-agent par app cible exécute inventaire + rapport d'app en parallèle, l'orchestrateur ne garde pour lui que la synthèse (matrice valeur/effort, ordre de migration). Aucun changement de script requis.
- [x] **Consigner les non-adoptions : Idea Tree, modes d'interaction et novelty search sont hors périmètre** — `docs/backlog.md:1` (S)
  Entrée « non-adoptions » dans docs/backlog.md : Idea Tree / recherche multi-hypothèses, ui.interaction_mode, novelty search alphaXiv — refusés avec la justification (pipeline déterministe ≠ recherche exploratoire), pour que la décision survive à la session.

## Plan d'action

1. [x] Donner au kit son --resume : /migrate détecte une migration en cours et reprend au dernier gate vert (M)
2. [x] Emprunter la discipline de budget d'Arbor : garde de convergence en phase 4 + minutes par phase générées dans report.json (S)
3. [x] Contractualiser la rétropropagation (entrée « leçons » obligatoire en phase 7) et consigner les non-adoptions au backlog (S)

---
Généré depuis report.json par legends-review — les données vivent dans le JSON, le HTML est toujours régénéré, jamais édité à la main.
