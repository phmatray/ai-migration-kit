#!/usr/bin/env bash
# Test golden du générateur de rapport (règle 7 : outil obligatoire → test obligatoire).
# Fixture report.json + cobertura → HTML, puis assertions sur le contenu produit.
#
# Nécessite PyYAML : le cas « disposition documentée » (#104) lit templates/ci-dotnet.yml plutôt
# que d'en recopier la disposition. .github/workflows/ci.yml l'installe une fois pour tout le job,
# bien avant cette étape — comme pour tests/ci-template/test.sh, qui a la même dépendance.
set -euo pipefail
# Lancé depuis la racine du repo : prouve que les chemins du JSON (cobertura, capture)
# se résolvent relativement au JSON, pas au répertoire courant.
cd "$(dirname "$0")/../.."

KIT="$PWD"
# Les deux fichiers partagés du kit : le préambule (#72) puis le chargeur importlib (#51). Cette
# suite en portait une copie — correcte, mais que rien n'assertait. La section 8 de
# tests/xunit-v3/test.sh assure désormais l'invariant sur tests/ ET scripts/, donc une définition
# unique, ici partagée.
#
# Ce fichier portait un avertissement « ne pas écrire le nom du préambule partagé ici » : la
# section 9 de tests/lib/test.sh auditait alors les `mktemp -d` de toute suite dont le TEXTE
# contenait cette sous-chaîne, et cette suite en gère plusieurs. #128 a remplacé cette inférence
# par une déclaration — l'audit suit désormais un APPEL à kit_init — donc l'avertissement, la
# gymnastique d'écriture qu'il imposait, ET la raison de ne pas sourcer le préambule ont disparu
# ensemble. La première ligne est explicite (kit_source est défini dans le fichier qu'elle charge) ;
# la seconde est un appel.
#
# Chemin absolu via $KIT, car le `cd` ci-dessus a déjà eu lieu.
. "$KIT/tests/_lib.sh" || {
  echo "ÉCHEC : impossible de sourcer $KIT/tests/_lib.sh — refus de tourner sans garde"; exit 1; }
kit_source "$KIT/tests/_lib/py.sh"
kit_init "$KIT"

# ---------------------------------------------------------------------------
# Aucun __pycache__ laissé dans le kit (#51).
#
# CETTE suite doit porter sa propre garde. Le réflexe — « tests/xunit-v3 la porte déjà » — est
# faux dans l'ordre où CI exécute les choses : .github/workflows/ci.yml lance xunit-v3 AVANT ce
# fichier, dans le même job, donc la garde de sortie de xunit-v3 a déjà tourné quand ce script
# charge son premier module. Un __pycache__ déposé ici n'était rattrapé par rien en CI — seulement
# par quelqu'un qui relancerait xunit-v3 ensuite, en local. C'était le trou résiduel que #51
# prétendait fermer.
#
# Elle passe par first_match, l'unique implémentation de la recherche tolérante du kit :
# `find | grep -q` ferait tuer find par SIGPIPE sous le `set -o pipefail` de la ligne 4, et
# « trouvé » se lirait « rien trouvé » (#48). Cette suite recopiait la forme sûre à la main faute de
# sourcer tests/_lib.sh ; elle le source maintenant (#128), donc la copie disparaît.
#
# Enregistrée avec kit_guard plutôt qu'écrite en fin de fichier : elle tourne alors sur CHAQUE
# chemin de sortie, celui de l'échec compris. La forme précédente ne s'exécutait que si tout ce qui
# précède avait réussi — un run rouge ne disait donc jamais si le chargeur avait aussi sali le
# dépôt. Et l'enregistrement est ICI, avant le premier chargement de module : inscrite en fin de
# fichier, la garde n'existerait précisément pas sur les chemins où elle a un intérêt.
# (Ne pas réécrire ce paragraphe avec le mot t-r-a-p suivi d'E-X-I-T sur une même ligne : le motif
# de la section 8 de tests/lib est volontairement non ancré et ne distingue pas un commentaire d'un
# appel.)
# ---------------------------------------------------------------------------
pas_de_pycache() {
  local stray
  stray=$(first_match "$KIT/scripts" "$KIT/tests" -name '__pycache__' -type d)
  if [ -n "$stray" ]; then
    echo "ÉCHEC : un __pycache__ a été laissé dans le kit — le chargeur a perdu son"
    echo "        PYTHONDONTWRITEBYTECODE=1 : $stray"
    return 1
  fi
}
kit_guard pas_de_pycache

# Et la garde samples/, DÉCIDÉE plutôt que passée sous silence : le contrat de tests/_lib.sh demande
# à chaque suite convertie de trancher, pour que « oubliée » et « jugée hors sujet » cessent de se
# ressembler. Celle-ci écrit des rapports à partir de chemins qu'elle construit ; c'est exactement le
# genre de suite pour laquelle la garde existe — une régression de résolution de chemin écrirait
# ailleurs que dans son scratch, et la fixture gelée est ce qu'on veut voir intact en premier.
kit_guard kit_guard_samples_unchanged

# Le répertoire est CAPTURÉ, pas jeté : `out="$(mktemp -d)/report.html"` ne liait que le fichier,
# donc plus rien ne désignait son parent et aucun `rm -rf` ne pouvait le reprendre. Chaque run en
# laissait un derrière lui (#128), et la section 9 de tests/lib — écrite exactement pour ça — ne
# pouvait pas le voir, cette suite évitant délibérément la sous-chaîne sur laquelle elle keyait.
# Il vient maintenant de kit_scratch, comme tous les autres : supprimé sur CHAQUE chemin de sortie,
# celui de l'échec compris.
out_dir="$(kit_scratch)"
out="$out_dir/report.html"
python3 scripts/report-dashboard.py tests/report-dashboard/fixture-report.json -o "$out" 2>/dev/null

# Sans -o, la sortie atterrit À CÔTÉ du report.json — jamais dans le cwd (vague 3 : le
# dashboard de pokedexg s'était retrouvé à la racine du repo migré).
#
# Ce sont les DEUX seuls chemins hors scratch que cette suite peut se retrouver à écrire, et la
# disposition testée l'impose : le trap de kit_init ne peut donc reprendre ni l'un ni l'autre.
# `$defaut` était supprimé par un `rm -f` placé APRÈS les deux assertions ci-dessous —
# c'est-à-dire seulement sur le chemin vert. Mesuré : une panne entre la génération et ce `rm`
# laissait `tests/report-dashboard/report.html` non suivi dans l'arbre, un run rouge après l'autre.
# C'est la fuite que #104 décrit pour les arbres temporaires (#128 les a, elles, déjà mises sous
# trap), sur le dernier chemin qui y échappait.
#
# `$KIT/report.html` est nettoyé par la même garde : c'est le fichier dont la SECONDE assertion
# ci-dessous nie l'existence, donc le seul chemin où il apparaît est justement un run rouge — celui
# que la garde existe pour ne pas salir. Le nettoyer seulement sur le chemin vert aurait laissé
# ouverte, à la ligne suivante, exactement la fuite que ce bloc referme.
#
# La suppression est donc ENREGISTRÉE comme les autres gardes, pour tourner sur CHAQUE chemin de
# sortie ; `$KIT` et pas un chemin relatif, parce qu'un gestionnaire de sortie ne peut rien
# supposer du répertoire courant. Le `rm -f` du HAUT reste : il n'est pas un nettoyage mais une
# PRÉCONDITION — sans lui, le `[ -f ]` juste après pourrait être satisfait par le fichier d'un run
# précédent et n'assurerait plus que CE run l'a écrit.
defaut="tests/report-dashboard/report.html"
nettoie_sortie_par_defaut() { rm -f "$KIT/$defaut" "$KIT/report.html"; }
kit_guard nettoie_sortie_par_defaut
rm -f "$defaut"
python3 scripts/report-dashboard.py tests/report-dashboard/fixture-report.json 2>/dev/null
[ -f "$defaut" ] || { echo "ÉCHEC : sans -o, report.html doit être écrit à côté du report.json"; exit 1; }
[ ! -f report.html ] || { echo "ÉCHEC : sans -o, rien ne doit être écrit dans le cwd"; exit 1; }

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
multi_dir="$(kit_scratch)"
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

# La tuile KPI et la légende rendent la MÊME quantité, donc elles doivent dire la même chose (#50).
# C'est ce cas-ci qui les sépare : la fixture porte un KPI écrit à la main (70), et l'union des deux
# coberturas vaut 75. Une page qui publie les deux rend invérifiable la promesse « couverture
# mesurée, jamais estimée » — un lecteur ne peut pas dire laquelle des deux est la mesure. Assertion
# en Python et pas en sed : les tuiles sont concaténées sur une seule ligne.
python3 - "$multi" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
tiles = re.findall(r'<div class="tile"><div class="v">(.*?)</div><div class="l">(.*?)</div></div>', html)
# Le LIBELLÉ EXACT de la fixture, pas une re-implémentation du sélecteur de production. Chercher
# ici « couvertur » comme le fait kpi_source() ferait bouger le test avec le code : les deux
# seraient d'accord par construction, et le test ne prouverait plus QUELLE tuile aurait dû être
# choisie. La tuile « tests verts » est là pour la contrepartie : le remplacement ne doit pas
# déborder sur une tuile qui n'est pas une couverture.
par_libelle = {label: v for v, label in tiles}
assert "couverture mesurée (lignes)" in par_libelle, f"tuiles rendues : {list(par_libelle)}"
assert par_libelle.get("tests verts", "").strip() == "42", (
    f"la tuile « tests verts » a été réécrite : {par_libelle.get('tests verts')!r} — le "
    "remplacement doit viser la seule tuile de couverture")
# La valeur porte son unité dans un <small> imbriqué : on ne garde que le nombre.
tile = re.match(r"\s*(\d+)", re.sub(r"<[^>]*>", "", par_libelle["couverture mesurée (lignes)"]))
assert tile, "la tuile de couverture ne commence pas par un nombre"
tile = tile.group(1)
legende = re.search(r"Global : (\d+) % lignes", html)
assert legende, "la légende de couverture est absente du HTML"
assert tile == legende.group(1), (
    f"la page publie DEUX chiffres de couverture : tuile {tile} %, légende {legende.group(1)} %. "
    "Le KPI doit être la mesure, pas une transcription.")
PY

# La forme mono-chemin ne change pas : une chaîne nue et une liste d'un élément doivent rendre
# exactement le même objet. C'est la garantie de compatibilité des report.json déjà écrits.
#
# #50 avait extrait un `rd_python()` LOCAL ici, pour la même raison qu'il fallait deux appels ;
# #51 généralise ce geste au kit entier, donc le chargeur local disparaît au profit de py_module.
# Aucune assertion des deux côtés n'est perdue : seul le chargeur change, `rd` devient `mod`.
py_module "$KIT/scripts/report-dashboard.py" <<'PY'
a = "tests/report-dashboard/fixture-cobertura.xml"
b = "tests/report-dashboard/fixture-cobertura-b.xml"
seul, liste = mod.parse_cobertura(a, ["Fixture.Web"]), mod.parse_cobertura([a], ["Fixture.Web"])
assert seul == liste, f"chaîne nue et liste d'un élément divergent :\n  {seul}\n  {liste}"
assert seul["line_pct"] == 70 and seul["branch_pct"] == 67, seul
# L'union ne dépend pas de l'ordre des rapports : sinon « le dernier gagne » serait encore là,
# juste déplacé de la collecte vers la lecture.
assert mod.parse_cobertura([a, b], ["Fixture.Web"]) == mod.parse_cobertura([b, a], ["Fixture.Web"])
PY

# ---------------------------------------------------------------------------
# `coverage.cobertura` : répertoire et motif glob (issue #17).
#
# Sous MTP c'est le collecteur qui NOMME les rapports, avec un GUID neuf à chaque run. Un
# report.json versionné qui listerait ces chemins serait mort au run suivant : il doit pouvoir
# désigner le répertoire. Le nom des fixtures ne finit pas par `.cobertura.xml`, donc on en
# dépose des copies correctement nommées — c'est aussi ce que produit un vrai run.
# ---------------------------------------------------------------------------
# `pwd -P` et pas le retour brut de mktemp : sur macOS il rend un chemin sous `/var`, qui est un
# lien vers `/private/var`, alors que le script résout ses chemins avec `Path.resolve()` et affiche
# donc la forme physique. Sans normalisation, les assertions qui comparent un chemin AFFICHÉ à
# `$dir_case` seraient vertes sur le runner Linux de la CI et rouges sur la machine du mainteneur.
dir_case="$(cd "$(kit_scratch)" && pwd -P)"
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
# …et elle nomme la base de résolution, y compris pour la forme fichier : le chemin affiché est
# absolu alors que le report.json en portait un relatif, donc « d'où sort-il ? » se pose aussi ici.
case "$err" in
  *"chemin relatif résolu depuis $dir_case"*) : ;;
  *) echo "ÉCHEC : l'erreur d'un fichier manquant ne nomme pas la base : $err"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# L'erreur NOMME la base contre laquelle un chemin relatif a été résolu (issue #102).
#
# C'est la cause racine de #49, que #49 n'a fait que contourner. `"coverage"` écrit dans
# `migration/report.json` désigne `migration/coverage`, pas le `coverage/` de la racine ; le
# diagnostic disait seulement « rapport de couverture introuvable : …/migration/coverage » —
# un chemin que personne n'a tapé, sans un mot sur d'où il sort, et en appelant « rapport » un
# RÉPERTOIRE. Corriger la référence retirait la valeur fausse du jour ; nommer la base ferme la
# classe entière, tout champ relatif compris, y compris ceux ajoutés plus tard.
#
# La base est assertée via la clause explicative, jamais en cherchant le chemin de base seul : le
# chemin résolu la CONTIENT comme préfixe, donc un `case` sur « $b/migration » passerait sans que
# le message n'explique quoi que ce soit.
# ---------------------------------------------------------------------------
base_case="$(cd "$(kit_scratch)" && pwd -P)"   # cf. la note sur pwd -P au bloc précédent
mkdir -p "$base_case/migration"
python3 - "$base_case" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "coverage"}      # la valeur exacte de #49
pathlib.Path(sys.argv[1], "migration", "report.json").write_text(json.dumps(r))
PY
if err=$(python3 scripts/report-dashboard.py "$base_case/migration/report.json" \
           -o "$base_case/migration/report.html" 2>&1); then
  echo "ÉCHEC : un répertoire de couverture manquant doit faire échouer la génération"; exit 1
fi
case "$err" in
  *"$base_case/migration/coverage"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas le chemin résolu : $err"; exit 1 ;;
esac
case "$err" in
  *"chemin relatif résolu depuis $base_case/migration"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas la base de résolution : $err"; exit 1 ;;
esac
case "$err" in
  *"répertoire du report.json"*) : ;;
  *) echo "ÉCHEC : l'erreur ne dit pas ce qu'est cette base : $err"; exit 1 ;;
esac
# Et elle ne présente plus un répertoire comme un rapport. La clause ci-dessus contient le mot
# « répertoire », donc c'est le libellé FAUTIF qu'on interdit, pas le bon qu'on cherche.
case "$err" in
  *"rapport de couverture introuvable"*)
    echo "ÉCHEC : un répertoire manquant est annoncé comme un « rapport » : $err"; exit 1 ;;
esac

# Un chemin ABSOLU n'a été résolu contre rien : la clause serait un mensonge, donc elle est absente.
python3 - "$base_case" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": str(pathlib.Path(sys.argv[1], "absent", "rien.cobertura.xml"))}
pathlib.Path(sys.argv[1], "migration", "report.json").write_text(json.dumps(r))
PY
if err=$(python3 scripts/report-dashboard.py "$base_case/migration/report.json" \
           -o "$base_case/migration/report.html" 2>&1); then
  echo "ÉCHEC : un chemin absolu manquant doit faire échouer la génération"; exit 1
fi
# D'abord prouver que l'échec est bien CELUI-LÀ : sans cette assertion, n'importe quel plantage
# (une trace Python, un JSON invalide) satisferait « la clause est absente » et le cas resterait
# vert en n'ayant rien mesuré.
case "$err" in
  *"rapport de couverture introuvable : $base_case/absent/rien.cobertura.xml"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas le rapport absolu manquant : $err"; exit 1 ;;
esac
case "$err" in
  *"chemin relatif résolu depuis"*)
    echo "ÉCHEC : un chemin absolu n'est résolu contre aucune base : $err"; exit 1 ;;
esac

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
#
# Et la DISPOSITION non plus (#104). Le `coverage/` que ce cas construisait était écrit en dur,
# alors que son nom vient de l'autre moitié du couplage : le `--results-directory` de l'étape
# « Tests + couverture » de templates/ci-dotnet.yml. Renommer ce répertoire dans le template — ou
# poser un `working-directory:` sur cette étape — rendait « ../coverage » faux pour TOUS les
# consommateurs pendant que ce cas restait vert, en épinglant la référence contre une disposition
# que plus rien ne produisait. Les deux moitiés sont donc dérivées, jamais recopiées, et le bloc
# ci-dessous est le seul endroit qui les rapproche.
# ---------------------------------------------------------------------------
doc_case="$(kit_scratch)"

# Le bloc python MONTE la disposition lui-même — répertoire de couverture et fixtures compris —
# à partir du nom qu'il dérive. Écrire ici `mkdir -p "$doc_case/coverage"` remettrait la copie que
# ce cas existe pour supprimer.
#
# Et il la monte lui-même plutôt que de RENDRE ce nom sur sa sortie standard, ce qui obligeait à
# l'envelopper dans `$( … )`. C'est la forme que #131 traque : bash 3.2 (celui de macOS) analyse
# l'intérieur d'un `$( … )` sans honorer le quoting d'un heredoc, si bien que les apostrophes de la
# prose française ci-dessous devaient toutes s'apparier — par chance, elles s'appariaient. En
# ajouter ou en retirer UNE, dans un simple commentaire, rendait la suite entière inanalysable sur
# macOS (« unexpected EOF »). scripts/parse-sweep.sh existe pour interdire ce couplage : il ne
# fallait pas le réintroduire pour un aller-retour d'une seule valeur.
#
# Le nom dérivé revient donc par un fichier, lu plus bas SANS substitution de commande, et ne sert
# plus qu'au diagnostic du shell.
python3 - "$doc_case" <<'PY'
import json, pathlib, re, shutil, sys, yaml

# --- moitié « valeur » : le snippet documenté ------------------------------------------------
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

# --- moitié « disposition » : le répertoire où la CI écrit -------------------------------------
ETAPE = "Tests + couverture"
tpl = yaml.safe_load(pathlib.Path("templates/ci-dotnet.yml").read_text(encoding="utf-8"))
# Le job et sa liste d'étapes sont VÉRIFIÉS avant d'être indexés. `tpl["jobs"]["test"]["steps"]`
# lève un KeyError nu si le job est renommé — une trace qui ne nomme ni ce fichier ni le template,
# trois lignes au-dessus d'une assertion qui prend justement la peine d'expliquer ce renommage-là.
job = (tpl.get("jobs") or {}).get("test")
assert isinstance(job, dict) and isinstance(job.get("steps"), list), (
    "templates/ci-dotnet.yml n'a plus de job `test` porteur d'une liste `steps` — c'est lui qui "
    f"porte l'étape {ETAPE!r} produisant la couverture que le snippet documenté prétend lire ; "
    "renommer ici ET dans skills/legacy-upgrade/references/report-template.md")
etape = next((s for s in job["steps"] if s.get("name") == ETAPE), None)
assert etape is not None, (
    f"templates/ci-dotnet.yml n'a plus d'étape nommée {ETAPE!r} — c'est elle qui produit la "
    "couverture que le snippet documenté prétend lire ; renommer ici ET dans "
    "skills/legacy-upgrade/references/report-template.md")

# Un `working-directory:` déplace la racine d'exécution : `coverage/` cesse alors d'être à la
# racine du repo et « ../coverage » depuis migration/ ne le désigne plus. C'est le second
# demi-mouvement que #104 nomme, et il est INVISIBLE au `--results-directory` ci-dessous — d'où
# une assertion à part. Les trois portées possibles sont couvertes : GitHub applique
# `defaults.run.working-directory` du workflow, puis du job, puis celui de l'étape.
for ou, valeur in (
    ("l'étape " + ETAPE, etape.get("working-directory")),
    ("le job test", ((job.get("defaults") or {}).get("run") or {}).get("working-directory")),
    ("le workflow", ((tpl.get("defaults") or {}).get("run") or {}).get("working-directory")),
):
    assert valeur is None, (
        f"{ou} porte working-directory: {valeur!r} — la couverture n'est plus écrite à la racine "
        "du repo, donc le chemin relatif documenté ne la désigne plus. Corriger "
        "skills/legacy-upgrade/references/report-template.md avant ce test.")

# Les DEUX branches de l'étape (MTP et VSTest) passent un `--results-directory` ; un unique chemin
# relatif documenté ne peut être correct que si elles écrivent au même endroit.
#
# Les lignes de COMMENTAIRE du script shell sont écartées AVANT toute recherche. Le `run:` de cette
# étape en porte déjà deux qui nomment `--results-directory`, et elles ne passent à travers que
# parce qu'un backtick les suit : reformuler l'une d'elles — un changement sans le moindre effet
# sur la CI — ferait dériver un troisième répertoire de la prose et virer cette suite au rouge en
# prétendant que les branches divergent. Ce qui reste hors de portée : un commentaire de FIN de
# ligne, qu'aucune règle textuelle ne distingue d'un `#` en chaîne sans analyser le shell. C'est le
# bon sens de l'erreur — il rougit, il ne se tait pas.
script = "\n".join(
    l for l in (etape.get("run") or "").splitlines() if not l.lstrip().startswith("#"))

# Les DEUX orthographes du drapeau — `--results-directory VALEUR` et `--results-directory=VALEUR` —
# et la valeur éventuellement entre guillemets, auquel cas elle peut contenir une espace.
# N'accepter que la première laissait la seconde INVISIBLE : réécrite avec `=`, la branche VSTest
# sortait de la mesure sans rien rougir, et le cas restait vert pendant que la moitié des
# consommateurs écrivait ailleurs.
DRAPEAU = re.compile(r"""--results-directory(?:\s+|=)(?:"([^"]*)"|'([^']*)'|([^\s;&|]+))""")
bruts = [next(g for g in m.groups() if g is not None) for m in DRAPEAU.finditer(script)]

# Un COMPTE, pas une simple présence. `assert bruts` se contentait d'UNE branche : supprimer le
# drapeau de l'autre — coverlet retombe alors sur `TestResults/` — la faisait sortir de la mesure
# sans rien rougir, et le désaccord que ce bloc existe pour voir devenait invisible. Deux, parce
# que l'étape a exactement deux branches productrices de couverture ; une troisième serait une
# vraie évolution du template, à lire ici plutôt qu'à absorber en silence.
assert len(bruts) == 2, (
    f"l'étape {ETAPE!r} passe {len(bruts)} --results-directory ({bruts}) au lieu des 2 branches "
    "productrices attendues (MTP et VSTest) : ce test ne peut plus dériver la disposition que la "
    "CI produit, et le cas documenté ne pinnerait plus que lui-même")

def segment(valeur):
    # `"$PWD/coverage"` (branche MTP) et `coverage` (branche VSTest) désignent le même répertoire à
    # la racine du repo : on n'en garde que le nom. Toute autre forme — imbriquée, ou construite à
    # partir d'une variable — est REFUSÉE plutôt que devinée, sinon ce test construirait une
    # disposition que la CI ne produit pas, c'est-à-dire exactement le silence qu'il rompt.
    nom = re.sub(r"^\$\{?PWD\}?/", "", valeur)
    nom = re.sub(r"^\./", "", nom)
    nom = nom.rstrip("/")          # `coverage/` et `coverage` désignent le même répertoire
    # `.` et `..` passent `[A-Za-z0-9._-]+` tout en ne nommant AUCUN répertoire de couverture : le
    # premier ferait monter les rapports à la racine du fixture, le second au-dessus. Refusés
    # nommément, comme tout le reste de ce qui n'est pas un nom de répertoire.
    assert re.fullmatch(r"[A-Za-z0-9._-]+", nom) and nom not in (".", ".."), (
        f"--results-directory {valeur!r} n'est plus un simple répertoire à la racine du repo ; "
        "ce test ne peut plus en dériver la disposition documentée — l'adapter, et adapter "
        "skills/legacy-upgrade/references/report-template.md avec lui")
    return nom

repertoires = sorted({segment(v) for v in bruts})
assert len(repertoires) == 1, (
    f"les branches de l'étape {ETAPE!r} écrivent la couverture dans des répertoires différents "
    f"({repertoires}) ; un seul chemin relatif documenté ne peut pas désigner les deux")
ci_dir = repertoires[0]

# --- le couplage lui-même ----------------------------------------------------------------------
# Asserté sur les deux moitiés DÉRIVÉES, jamais contre un littéral : un littéral serait une
# troisième copie du même fait, et c'est la copie qui dérive.
cobertura = documented["cobertura"]
assert isinstance(cobertura, str) and not cobertura.startswith("/"), (
    f"le snippet documenté porte {cobertura!r} ; ce cas teste la résolution d'un chemin RELATIF "
    "depuis migration/, qui est ce que la référence prescrit")
segments = []
for part in pathlib.PurePosixPath("migration", cobertura).parts:
    if part == "..":
        assert segments, (
            f"le snippet documenté ({cobertura!r}) remonte au-dessus de la racine du repo depuis "
            "migration/ ; aucune disposition produite par la CI ne peut y répondre")
        segments.pop()
    elif part != ".":
        segments.append(part)
assert segments == [ci_dir], (
    f"le snippet documenté ({cobertura!r}) désigne {'/'.join(segments) or '.'} depuis la racine du "
    f"repo, alors que templates/ci-dotnet.yml y écrit la couverture dans {ci_dir}/. Les deux "
    "moitiés du couplage ont divergé — corriger "
    "skills/legacy-upgrade/references/report-template.md, ou le template.")

# --- montage ------------------------------------------------------------------------------------
# encoding= explicite comme au-dessus : la fixture porte « démonstration », « Vérifié », « Leçon ».
# Sous un interpréteur dont locale.getpreferredencoding() n'est pas UTF-8, la lecture par défaut
# lève UnicodeDecodeError et le test meurt sur son propre montage plutôt que sur ce qu'il mesure.
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = documented          # tel quel, sans retouche : c'est le sujet du test
migration = pathlib.Path(sys.argv[1], "migration")
migration.mkdir(parents=True, exist_ok=True)
(migration / "report.json").write_text(json.dumps(r))

# La moitié « disposition » est montée ICI, à partir du nom dérivé — jamais recopiée en shell.
couverture = pathlib.Path(sys.argv[1], ci_dir)
couverture.mkdir(parents=True, exist_ok=True)
for source, cible in (
    ("tests/report-dashboard/fixture-cobertura.xml",   "projet-un.cobertura.xml"),
    ("tests/report-dashboard/fixture-cobertura-b.xml", "projet-deux.cobertura.xml"),
):
    shutil.copyfile(source, couverture / cible)

# Le nom dérivé, pour le seul diagnostic du shell. Par fichier et non par stdout : voir le
# commentaire au-dessus du heredoc — c'est ce qui garde ce bloc hors d'un `$( … )`, donc hors de
# la classe de danger bash 3.2 de #131.
pathlib.Path(sys.argv[1], ".repertoire-couverture").write_text(ci_dir + "\n", encoding="utf-8")
PY

# `read`, pas `$(cat …)` : aucune substitution de commande ici non plus.
IFS= read -r ci_cov_dir < "$doc_case/.repertoire-couverture"

if ! err=$(python3 scripts/report-dashboard.py "$doc_case/migration/report.json" \
             -o "$doc_case/migration/report.html" 2>&1); then
  echo "ÉCHEC : le snippet documenté ne résout pas depuis la disposition documentée."
  echo "        migration/report.json + $ci_cov_dir/ à la racine — le premier recopié depuis"
  echo "        skills/legacy-upgrade/references/report-template.md, le second dérivé du"
  echo "        --results-directory de templates/ci-dotnet.yml :"
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

# ---------------------------------------------------------------------------
# Une absence de donnée de branche n'est pas une mesure de 0 % (issue #50).
#
# `branch_pct` se dérivait uniquement des `condition-coverage` par ligne, avec un repli sur 0.
# Un producteur qui exprime ses branches à la RACINE — forme courante de la chaîne VSTest/coverlet
# que `templates/ci-dotnet.yml` supporte encore — rendait donc un « 0 % branches » péremptoire sur
# une application bien couverte, alors que le `branch-rate` racine portait le vrai chiffre. Seul le
# chemin MTP était protégé (tests/xunit-v3 assert branch_pct > 0), pas celui-ci.
# ---------------------------------------------------------------------------
py_module "$KIT/scripts/report-dashboard.py" <<'PY'
# 1. branch-rate racine, aucun condition-coverage -> on lit la racine, pas 0.
racine = mod.parse_cobertura("tests/report-dashboard/fixture-cobertura-rootbranch.xml", [])
assert racine["branch_pct"] == 60, (
    f"branch-rate racine 0.6 doit rendre 60 %, pas {racine['branch_pct']} % — "
    "une absence de condition-coverage n'est pas une absence de branches")

# 2. Ni l'un ni l'autre -> None, que le rendu affichera « n/d ». Surtout pas 0, qui est un chiffre
#    et se lit comme une mesure.
muet = mod.parse_cobertura("tests/report-dashboard/fixture-cobertura-nobranch.xml", [])
assert muet["branch_pct"] is None, (
    f"sans aucune donnée de branche, branch_pct doit être None, pas {muet['branch_pct']!r}")

# 3. Le chemin par condition-coverage ne bouge pas.
conds = mod.parse_cobertura("tests/report-dashboard/fixture-cobertura.xml", ["Fixture.Web"])
assert conds["branch_pct"] == 67, conds["branch_pct"]
PY

# …et le rendu dit « n/d » plutôt que « 0 % ».
nd_dir="$(kit_scratch)"
python3 - "$nd_dir" <<'PY'
import json, pathlib, sys
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "fixture-cobertura-nobranch.xml"}
pathlib.Path(sys.argv[1], "report.json").write_text(json.dumps(r))
PY
cp tests/report-dashboard/fixture-cobertura-nobranch.xml "$nd_dir/"
python3 scripts/report-dashboard.py "$nd_dir/report.json" -o "$nd_dir/report.html" 2>/dev/null
assert_in "$nd_dir/report.html" 'branches n/d'
# La légende ENTIÈRE, pas le sous-texte « 0 % branches » : `grep -F` sur celui-ci matche aussi
# « 50 % branches », « 30 % branches »… Le jour où ce cas basculerait à tort sur le repli racine et
# rendrait « 60 % branches », l'assertion serait restée verte ; et si elle échouait, son message
# aurait désigné l'inverse du comportement réel.
assert_in "$nd_dir/report.html" 'Global : 50 % lignes · branches n/d'

# ---------------------------------------------------------------------------
# `screenshot.path` se résout contre la même base — et échoue de la même façon (issue #102).
#
# `main()` résout la capture contre le répertoire du report.json, exactement comme la couverture.
# Mais une capture absente n'avait aucune erreur nommée : `data_uri` laissait remonter un
# FileNotFoundError brut, donc une trace Python à la fin d'un long pipeline, sur l'artefact censé
# prouver le travail — pire que le cas couverture que #49 avait au moins rendu lisible.
#
# Les deux sens sont couverts : une capture PRÉSENTE doit toujours s'embarquer. Sans ce cas-là,
# une garde trop zélée casserait tous les report.json qui portent une capture sans qu'aucun test
# ne bouge — la fixture principale n'en déclare aucune.
# ---------------------------------------------------------------------------
shot_dir="$(cd "$(kit_scratch)" && pwd -P)"   # cf. la note sur pwd -P plus haut
mkdir -p "$shot_dir/migration"
cp tests/report-dashboard/fixture-cobertura.xml "$shot_dir/migration/"
python3 - "$shot_dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "fixture-cobertura.xml", "exclude": ["Fixture.Web"]}
# Libellés sans apostrophe : `esc()` échappe `'` en `&#x27;`, et une assertion `grep -F` sur le
# texte source échouerait pour une raison qui n'a rien à voir avec ce que ce bloc mesure.
r["screenshot"] = {"path": "captures/app.png", "caption": "Page de connexion migrée",
                   "alt": "Capture de la page de connexion"}
(d / "migration" / "report.json").write_text(json.dumps(r))
PY

if err=$(python3 scripts/report-dashboard.py "$shot_dir/migration/report.json" \
           -o "$shot_dir/migration/report.html" 2>&1); then
  echo "ÉCHEC : une capture manquante doit faire échouer la génération"; exit 1
fi
case "$err" in
  *Traceback*) echo "ÉCHEC : une capture manquante crache une trace Python : $err"; exit 1 ;;
esac
# Le libellé EXACT, pas un `*capture*` : le chemin résolu contient déjà « captures/app.png », donc
# un motif large serait satisfait par le chemin lui-même et resterait vert quel que soit ce que la
# phrase raconte — une assertion qui ne peut pas échouer.
case "$err" in
  *"capture introuvable :"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas la capture comme telle : $err"; exit 1 ;;
esac
case "$err" in
  *"$shot_dir/migration/captures/app.png"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas la capture résolue : $err"; exit 1 ;;
esac
case "$err" in
  *"chemin relatif résolu depuis $shot_dir/migration, le répertoire du report.json"*) : ;;
  *) echo "ÉCHEC : l'erreur de capture ne nomme pas la base de résolution : $err"; exit 1 ;;
esac

# Le cas passant : la capture existe, elle est embarquée en data URI (rien d'externe).
mkdir -p "$shot_dir/migration/captures"
python3 - "$shot_dir" <<'PY'
import base64, pathlib, sys
# PNG 1×1 valide — le plus petit fichier qui prouve que les octets sont bien lus et encodés.
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
pathlib.Path(sys.argv[1], "migration", "captures", "app.png").write_bytes(png)
PY
python3 scripts/report-dashboard.py "$shot_dir/migration/report.json" \
  -o "$shot_dir/migration/report.html" 2>/dev/null
assert_in "$shot_dir/migration/report.html" 'src="data:image/png;base64,'
assert_in "$shot_dir/migration/report.html" 'Page de connexion migrée'
assert_in "$shot_dir/migration/report.html" 'alt="Capture de la page de connexion"'

# Le chemin n'est plus affiché : il est supprimé à la sortie, et annoncer un artefact qui n'existe
# plus était la moitié visible de la fuite (#128).

# ---------------------------------------------------------------------------
# Une extension de capture non supportée sort une phrase nommée, pas un KeyError (#142).
#
# Avant #142, `data_uri` indexait le dict MIME par une subscript sans repli : toute extension hors
# des quatre connues (png/jpg/jpeg/svg) faisait planter le rendu avec un KeyError trois frames plus
# loin — alors que #139 venait tout juste de garantir que la capture EXISTE. `.webp`/`.gif` sont des
# formats de capture légitimes qu'un navigateur ou un outil devtools écrit par défaut (#102) ; ce cas
# prouve qu'une extension encore non supportée (`.bmp`) échoue proprement, avant tout rendu.
# ---------------------------------------------------------------------------
bad_ext_dir="$(cd "$(kit_scratch)" && pwd -P)"   # cf. la note sur pwd -P plus haut
mkdir -p "$bad_ext_dir/migration/captures"
cp tests/report-dashboard/fixture-cobertura.xml "$bad_ext_dir/migration/"
python3 - "$bad_ext_dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "fixture-cobertura.xml", "exclude": ["Fixture.Web"]}
r["screenshot"] = {"path": "captures/app.bmp", "caption": "Page de connexion migrée",
                   "alt": "Capture de la page de connexion"}
(d / "migration" / "report.json").write_text(json.dumps(r))
PY
: > "$bad_ext_dir/migration/captures/app.bmp"
if err=$(python3 scripts/report-dashboard.py "$bad_ext_dir/migration/report.json" \
           -o "$bad_ext_dir/migration/report.html" 2>&1); then
  echo "ÉCHEC : une extension de capture non supportée doit faire échouer la génération"; exit 1
fi
case "$err" in
  *Traceback*) echo "ÉCHEC : une extension non supportée crache une trace Python : $err"; exit 1 ;;
esac
case "$err" in
  *'format « .bmp » non supporté'*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas le format comme non supporté : $err"; exit 1 ;;
esac
case "$err" in
  *"$bad_ext_dir/migration/captures/app.bmp"*) : ;;
  *) echo "ÉCHEC : l'erreur ne nomme pas la capture résolue : $err"; exit 1 ;;
esac
# La validation précède le rendu : un report.json invalide ne doit jamais produire de report.html
# partiel, même incomplet (#142 — la même invariance que #128 pour la couverture).
if [ -e "$bad_ext_dir/migration/report.html" ]; then
  echo "ÉCHEC : un report.json invalide a quand même produit un report.html"; exit 1
fi

# ---------------------------------------------------------------------------
# `.webp` et `.gif` s'embarquent comme `.png` (#142) — formats légitimes, pas seulement tolérés.
# ---------------------------------------------------------------------------
webp_gif_dir="$(cd "$(kit_scratch)" && pwd -P)"
mkdir -p "$webp_gif_dir/migration/captures"
cp tests/report-dashboard/fixture-cobertura.xml "$webp_gif_dir/migration/"
python3 - "$webp_gif_dir" <<'PY'
import base64, json, pathlib, sys
d = pathlib.Path(sys.argv[1])
r = json.loads(pathlib.Path("tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "fixture-cobertura.xml", "exclude": ["Fixture.Web"]}
r["screenshot"] = {"path": "captures/app.webp", "caption": "Page de connexion migrée",
                   "alt": "Capture de la page de connexion"}
(d / "migration" / "report.json").write_text(json.dumps(r))
# WEBP 1x1 valide (lossless, VP8L) — le plus petit fichier qui prouve que les octets sont lus.
webp = base64.b64decode(
    "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAAAAAAAAAAAWlA4IAgAAAAwAQCdASoBAAEAAA"
    "AAJaQAA3AA/vFAAAA=".replace("\n", ""))
(d / "migration" / "captures" / "app.webp").write_bytes(webp)
gif = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBTAA7")
(d / "migration" / "captures" / "app.gif").write_bytes(gif)
PY
python3 scripts/report-dashboard.py "$webp_gif_dir/migration/report.json" \
  -o "$webp_gif_dir/migration/report.html" 2>/dev/null
assert_in "$webp_gif_dir/migration/report.html" 'src="data:image/webp;base64,'
assert_in "$webp_gif_dir/migration/report.html" 'Page de connexion migrée'
assert_in "$webp_gif_dir/migration/report.html" 'alt="Capture de la page de connexion"'
python3 - "$webp_gif_dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
r = json.loads(pathlib.Path(d, "migration", "report.json").read_text(encoding="utf-8"))
r["screenshot"]["path"] = "captures/app.gif"
pathlib.Path(d, "migration", "report.json").write_text(json.dumps(r))
PY
python3 scripts/report-dashboard.py "$webp_gif_dir/migration/report.json" \
  -o "$webp_gif_dir/migration/report.html" 2>/dev/null
assert_in "$webp_gif_dir/migration/report.html" 'src="data:image/gif;base64,'
assert_in "$webp_gif_dir/migration/report.html" 'Page de connexion migrée'
assert_in "$webp_gif_dir/migration/report.html" 'alt="Capture de la page de connexion"'

echo "OK test golden report-dashboard"
