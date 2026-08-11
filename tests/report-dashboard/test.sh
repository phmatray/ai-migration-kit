#!/usr/bin/env bash
# Test golden du générateur de rapport (règle 7 : outil obligatoire → test obligatoire).
# Fixture report.json + cobertura → HTML, puis assertions sur le contenu produit.
set -euo pipefail
# Lancé depuis la racine du repo : prouve que les chemins du JSON (cobertura, capture)
# se résolvent relativement au JSON, pas au répertoire courant.
cd "$(dirname "$0")/../.."

out="$(mktemp -d)/report.html"
python3 scripts/report-dashboard.py tests/report-dashboard/fixture-report.json -o "$out" 2>/dev/null

# Sans -o, la sortie atterrit À CÔTÉ du report.json — jamais dans le cwd (vague 3 : le
# dashboard de pokedexg s'était retrouvé à la racine du repo migré).
defaut="tests/report-dashboard/report.html"
rm -f "$defaut"
python3 scripts/report-dashboard.py tests/report-dashboard/fixture-report.json 2>/dev/null
[ -f "$defaut" ] || { echo "ÉCHEC : sans -o, report.html doit être écrit à côté du report.json"; exit 1; }
[ ! -f report.html ] || { echo "ÉCHEC : sans -o, rien ne doit être écrit dans le cwd"; exit 1; }
rm -f "$defaut"

assert_in() { grep -qF "$2" "$1" || { echo "ÉCHEC : « $2 » absent du HTML généré ($1)"; exit 1; }; }
refuse_in() { ! grep -qF "$2" "$1" || { echo "ÉCHEC : « $2 » présent alors qu'il devrait être exclu ($1)"; exit 1; }; }
count_in() { grep -oF "$2" "$1" | wc -l | tr -d ' '; }
assert() { assert_in "$out" "$1"; }
refuse() { refuse_in "$out" "$1"; }

assert '<title>Migration FixtureApp — rapport exécutif</title>'
assert 'Migration de démonstration'
assert '✓ Vérifié'
assert 'migration/2026-01-01'
assert 'Déployer avec fallback SPA'
# La couverture vient du cobertura (calculée), jamais recopiée du JSON :
assert 'Engine : 3/4 lignes couvertes'
assert 'Wrapper : 1/2 lignes couvertes'
# Une classe partielle (Partial.cs + Partial.Designer.cs, 2 lignes chacun) donne UNE entrée de
# 4 lignes. Une fusion qui identifierait les lignes par leur seul numéro en compterait 2.
assert 'Partial : 3/4 lignes couvertes'
[ "$(count_in "$out" 'Partial : ')" = 1 ] || {
  echo "ÉCHEC : la classe partielle apparaît en double au lieu d'être fusionnée"; exit 1; }
# Le global est recalculé sur les lignes fusionnées (7/10) et sur les condition-coverage
# (8/12) — jamais lu dans l'attribut line-rate de la racine, qui compterait deux fois le
# produit dès qu'il y a plusieurs rapports (cf. parse_cobertura).
assert 'Global : 70 % lignes · 67 % branches'
# Le KPI affiché doit être CELUI qui vient d'être calculé : une tuile recopiée à la main à côté
# d'un graphe recalculé, c'est deux chiffres contradictoires sur la page que le kit donne en
# exemple de « couverture mesurée, jamais estimée ».
assert '<div class="v">70<small>%</small></div>'
# Le filtre d'exclusion fonctionne :
refuse 'ExcludedWeb'
# Chronologie du pipeline (phases[]) : minutes par phase + total calculé, jamais recopié :
assert 'Chronologie du pipeline'
assert '1. Assess'
assert '6 min'
assert 'Total : 10 min'
# Leçons de la vague (lessons) : rétropropagation rendue, avec sa référence kit :
assert 'Leçons de la vague'
assert 'Leçon de fixture.'
assert 'kit@0000000'
# Autonome et thémé : pas de ressource externe, thème sombre présent
refuse 'http://'
refuse 'https://'
assert 'data-theme="dark"'

# ---------------------------------------------------------------------------
# Plusieurs rapports cobertura (issue #17).
#
# Sous Microsoft Testing Platform, chaque projet de test écrit SON fichier : le dashboard doit
# donc savoir en lire plusieurs. Ce que ce bloc prouve, et que le cas mono-fichier ci-dessus ne
# peut pas prouver :
#   - l'union des classes (une classe vue par un seul rapport survit) ;
#   - une classe vue par les DEUX est comptée UNE fois, hits sommés ligne à ligne — pas deux
#     lignes dans le tableau, pas des pourcentages additionnés ;
#   - le global est recalculé sur l'union des lignes, donc STRICTEMENT meilleur que chacun des
#     deux rapports pris seul — c'est la propriété qu'un retour à « le dernier fichier gagne »
#     casserait immédiatement.
# ---------------------------------------------------------------------------
multi_dir="$(mktemp -d)"
python3 - "$multi_dir" <<'PY'
import json, pathlib, sys
src = pathlib.Path("tests/report-dashboard/fixture-report.json")
r = json.loads(src.read_text())
base = src.resolve().parent
# Chemins absolus : prouve au passage que la liste accepte des chemins déjà résolus.
r["coverage"]["cobertura"] = [str(base / "fixture-cobertura.xml"), str(base / "fixture-cobertura-b.xml")]
pathlib.Path(sys.argv[1], "report.json").write_text(json.dumps(r))
PY
multi="$multi_dir/report.html"
python3 scripts/report-dashboard.py "$multi_dir/report.json" -o "$multi" 2>/dev/null

# Engine est dans les deux rapports : A couvre les lignes 1-3, B couvre la 4. Sommées, 4/4.
# Si les rapports étaient concaténés au lieu d'être fusionnés, on lirait 3/4 ET 1/4.
assert_in "$multi" 'Engine : 4/4 lignes couvertes'
[ "$(count_in "$multi" 'Engine : ')" = 1 ] || {
  echo "ÉCHEC : Engine apparaît $(count_in "$multi" 'Engine : ') fois — une classe vue par deux rapports doit être fusionnée"
  exit 1; }
# Une classe que seul l'un des deux rapports voit doit survivre à l'union, dans les deux sens.
assert_in "$multi" 'Wrapper : 1/2 lignes couvertes'
assert_in "$multi" 'Repository : 4/6 lignes couvertes'
# Le global est recalculé sur l'union : 12/16 lignes et 14/18 branches. Chaque rapport pris
#   seul vaut moins (70 %/67 % et 50 %/50 %) : un global qui ne monte pas au-dessus des deux
#   est le symptôme d'un fichier écrasé.
assert_in "$multi" 'Global : 75 % lignes · 78 % branches'
# L'exclusion s'applique à TOUS les rapports, pas seulement au premier.
refuse_in "$multi" 'ExcludedWeb'
rm -rf "$multi_dir"

# La forme mono-chemin ne change pas : une chaîne nue et une liste d'un élément doivent rendre
# exactement le même objet. C'est la garantie de compatibilité des report.json déjà écrits.
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("rd", "scripts/report-dashboard.py")
rd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rd)
a = "tests/report-dashboard/fixture-cobertura.xml"
b = "tests/report-dashboard/fixture-cobertura-b.xml"
seul, liste = rd.parse_cobertura(a, ["Fixture.Web"]), rd.parse_cobertura([a], ["Fixture.Web"])
assert seul == liste, f"chaîne nue et liste d'un élément divergent :\n  {seul}\n  {liste}"
assert seul["line_pct"] == 70 and seul["branch_pct"] == 67, seul
# L'union ne dépend pas de l'ordre des rapports : sinon « le dernier gagne » serait encore là,
# juste déplacé de la collecte vers la lecture.
assert rd.parse_cobertura([a, b], ["Fixture.Web"]) == rd.parse_cobertura([b, a], ["Fixture.Web"])
PY

# ---------------------------------------------------------------------------
# `coverage.cobertura` : répertoire et motif glob (issue #17).
#
# Sous MTP c'est le collecteur qui NOMME les rapports, avec un GUID neuf à chaque run. Un
# report.json versionné qui listerait ces chemins serait mort au run suivant : il doit pouvoir
# désigner le répertoire. Le nom des fixtures ne finit pas par `.cobertura.xml`, donc on en
# dépose des copies correctement nommées — c'est aussi ce que produit un vrai run.
# ---------------------------------------------------------------------------
dir_case="$(mktemp -d)"
cp tests/report-dashboard/fixture-cobertura.xml "$dir_case/projet-un.cobertura.xml"
cp tests/report-dashboard/fixture-cobertura-b.xml "$dir_case/projet-deux.cobertura.xml"

for forme in "." "*.cobertura.xml"; do
  python3 - "$dir_case" "$forme" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text())
r["coverage"]["cobertura"] = sys.argv[2]
pathlib.Path(sys.argv[1], "report.json").write_text(json.dumps(r))
PY
  python3 scripts/report-dashboard.py "$dir_case/report.json" -o "$dir_case/report.html" 2>/dev/null
  # Mêmes chiffres que la liste explicite : le répertoire et le glob désignent les deux rapports.
  assert_in "$dir_case/report.html" 'Global : 75 % lignes · 78 % branches'
  assert_in "$dir_case/report.html" 'Engine : 4/4 lignes couvertes'
done

# Un chemin littéral manquant doit NOMMER le fichier absent, pas cracher un FileNotFoundError
# d'ET.parse : sous MTP les noms changent à chaque run, donc « lequel ? » est toute la question.
python3 - "$dir_case" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text())
r["coverage"]["cobertura"] = ["projet-un.cobertura.xml", "disparu.cobertura.xml"]
pathlib.Path(sys.argv[1], "report.json").write_text(json.dumps(r))
PY
if err=$(python3 scripts/report-dashboard.py "$dir_case/report.json" -o "$dir_case/x.html" 2>&1); then
  echo "ÉCHEC : un rapport de couverture manquant doit faire échouer la génération"; exit 1
fi
case "$err" in
  *disparu.cobertura.xml*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas le fichier manquant : $err"; exit 1 ;;
esac
rm -rf "$dir_case"

# ---------------------------------------------------------------------------
# Le snippet DOCUMENTÉ, exécuté contre la disposition DOCUMENTÉE (issue #49).
#
# `report-template.md` impose `migration/report.json`, et `report-dashboard.py` résout un chemin
# cobertura relatif contre le répertoire du report.json (`base = Path(args.report_json).parent`).
# Les deux règles sont bonnes ; leur combinaison rend le `"coverage"` évident FAUX — il désigne
# `migration/coverage`, alors que `templates/ci-dotnet.yml` écrit dans le `coverage/` de la racine.
# Recopié tel quel — ce à quoi sert une référence — il meurt sur « rapport de couverture
# introuvable », à la fin d'un long pipeline, sur l'artefact censé prouver le travail.
#
# La valeur n'est donc PAS écrite en dur ici : elle est EXTRAITE du fichier de référence. Une
# référence qu'on se contente de lire dérive — c'est exactement comme ça qu'on en est arrivé là.
# ---------------------------------------------------------------------------
doc_case="$(mktemp -d)"
mkdir -p "$doc_case/migration" "$doc_case/coverage"
cp tests/report-dashboard/fixture-cobertura.xml   "$doc_case/coverage/projet-un.cobertura.xml"
cp tests/report-dashboard/fixture-cobertura-b.xml "$doc_case/coverage/projet-deux.cobertura.xml"

python3 - "$doc_case" <<'PY'
import json, pathlib, re, sys

# Le bloc ```json de report-template.md qui porte "cobertura". C'est un FRAGMENT d'objet, donc on
# l'enveloppe avant de le parser — si le fragment cesse d'être du JSON valide, ça casse ici, ce qui
# est le bon endroit.
doc = pathlib.Path("skills/legacy-upgrade/references/report-template.md").read_text(encoding="utf-8")
blocks = [b for b in re.findall(r"```json\n(.*?)```", doc, re.S) if '"cobertura"' in b]
# EXACTEMENT un. Zéro = la référence ne documente plus rien ; deux = ce test en épinglerait un au
# hasard et laisserait l'autre dériver — or `docs/backlog.md` programme une traduction anglaise de
# ce fichier, dont une issue plausible est justement deux snippets côte à côte.
assert len(blocks) == 1, (
    f"report-template.md documente {len(blocks)} snippets coverage.cobertura ; "
    "ce test ne peut en épingler qu'un — adapter l'extraction avant d'en ajouter un second")
documented = json.loads("{" + blocks[0].strip().rstrip(",") + "}")["coverage"]

# encoding= explicite comme au-dessus : la fixture porte « démonstration », « Vérifié », « Leçon ».
# Sous un interpréteur dont locale.getpreferredencoding() n'est pas UTF-8, la lecture par défaut
# lève UnicodeDecodeError et le test meurt sur son propre montage plutôt que sur ce qu'il mesure.
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = documented          # tel quel, sans retouche : c'est le sujet du test
pathlib.Path(sys.argv[1], "migration", "report.json").write_text(json.dumps(r))
PY

if ! err=$(python3 scripts/report-dashboard.py "$doc_case/migration/report.json" \
             -o "$doc_case/migration/report.html" 2>&1); then
  echo "ÉCHEC : le snippet documenté ne résout pas depuis la disposition documentée."
  echo "        migration/report.json + coverage/ à la racine, recopié depuis"
  echo "        skills/legacy-upgrade/references/report-template.md :"
  echo "        $err"
  exit 1
fi
# Résolu ne suffit pas : il faut que la couverture soit réellement LUE. Un 0 % passerait un simple
# test d'existence tout en republiant un rapport vide.
#
# Le taux exact n'est PAS figé ici : le snippet documenté porte son propre `exclude`
# (`MonApp.Web`), qui n'est pas celui de la fixture, donc un nombre en dur coupleraient ce cas à une
# liste d'exclusion qui n'a rien à voir avec ce qu'il teste — la résolution du chemin. Le contrat
# est « la couverture a été lue », et c'est ce qui est asserté. Les autres blocs de ce fichier
# vérifient déjà les chiffres eux-mêmes.
#
# `sed`, jamais `grep -o … | head -1` : sous le `set -o pipefail` de la ligne 4, la sortie anticipée
# de head tuerait grep par SIGPIPE et le statut du tube ferait échouer l'assignation (#48).
pct=$(sed -n 's/.*Global : \([0-9]*\) % lignes.*/\1/p' "$doc_case/migration/report.html" | sed -n '1p')
if [ -z "$pct" ] || [ "$pct" -le 0 ]; then
  echo "ÉCHEC : le chemin documenté se résout mais la couverture lue vaut « ${pct:-<absente>} » %."
  echo "        Un rapport vide passerait un simple test d'existence du répertoire."
  exit 1
fi
rm -rf "$doc_case"

echo "OK test golden report-dashboard ($out)"
