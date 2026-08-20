#!/usr/bin/env bash
# Test golden de l'agrégateur de suivis (règle 7 : outil obligatoire → test obligatoire).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# kit_guard_samples_unchanged non enregistré : cette suite lit ses propres fixtures sous
# tests/followups/, jamais samples/.
scratch=$(kit_scratch)

out="$(python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b --backlog docs/backlog.md)" || {
  echo "ÉCHEC : l'agrégateur a renvoyé un code non nul sur les fixtures — sortie :"; echo "$out"; exit 1; }

assert() { grep -qF "$1" <<<"$out" || { echo "ÉCHEC : « $1 » absent de la sortie"; exit 1; }; }
avant() { # avant A B : A doit apparaître avant B
  local ia ib
  ia=$(grep -nF "$1" <<<"$out" | head -1 | cut -d: -f1)
  ib=$(grep -nF "$2" <<<"$out" | head -1 | cut -d: -f1)
  [ -n "$ia" ] && [ -n "$ib" ] && [ "$ia" -lt "$ib" ] || {
    echo "ÉCHEC : « $1 » (l.$ia) devrait précéder « $2 » (l.$ib)"; exit 1; }
}

assert '2 décision(s) propriétaire · 3 tâche(s) · 2 différé(s)'
# Les décisions propriétaire d'abord — y compris sans effort chiffré :
avant 'Décision propriétaire A' 'Tâche quinze minutes'
avant 'Décision propriétaire B sans effort' 'Tâche quinze minutes'
# Tri des tâches par effort croissant, virgule française comprise (15 min < 0,5 h < 1 h) :
avant 'Tâche quinze minutes' 'Tâche demi-heure à virgule'
avant 'Tâche demi-heure à virgule' 'Tâche une heure'
# Backlog du kit et différés présents :
assert 'Synchronisation des artefacts'
assert 'Différé A'
assert 'Différé B'

# #143 : un chemin RELATIF introuvable nomme le chemin résolu ET la base contre laquelle il a été
# résolu (issue #49 -> #102 -> #143). `pwd -P` et pas le retour brut de `pwd`/`mktemp` : Python
# résout via `Path.cwd()` == `os.getcwd()`, qui rend TOUJOURS la forme physique — comparer à la
# forme logique casserait sur macOS (`/tmp` -> `/private/tmp`), cf. tests/report-dashboard/test.sh.
rel_repo_inexistant="tests/followups/repo-inexistant-relatif"
cwd_phys="$(pwd -P)"
if python3 scripts/followups.py "$rel_repo_inexistant" > "$scratch/err-rel.out" 2>&1; then
  echo "ÉCHEC : un repo relatif sans migration/report.json doit produire un code de sortie non nul"; exit 1
fi
grep -qF "$cwd_phys/$rel_repo_inexistant/migration/report.json introuvable" "$scratch/err-rel.out" || {
  echo "ÉCHEC : l'erreur ne nomme pas le chemin résolu :"; cat "$scratch/err-rel.out"; exit 1; }
grep -qF "chemin relatif résolu depuis $cwd_phys" "$scratch/err-rel.out" || {
  echo "ÉCHEC : l'erreur ne nomme pas la base de résolution :"; cat "$scratch/err-rel.out"; exit 1; }

# Repo sans rapport, chemin ABSOLU cette fois : erreur signalée, code de sortie non nul. Le chemin
# est un enfant de $scratch délibérément non créé, pour que « le repo n'existe pas » soit un fait
# établi plutôt qu'une supposition sur l'état de /tmp (#160).
repo_inexistant="$scratch/repo-inexistant"
if python3 scripts/followups.py "$repo_inexistant" > "$scratch/err.out" 2>&1; then
  echo "ÉCHEC : un repo sans migration/report.json doit produire un code de sortie non nul"; exit 1
fi
grep -q 'introuvable' "$scratch/err.out" || { echo "ÉCHEC : l'erreur doit nommer le rapport introuvable"; exit 1; }
# Assertée APRÈS la vraie erreur ci-dessus, pour que « la clause est absente » ne puisse pas passer
# sur un crash sans rapport (le piège documenté par #139) : un chemin ABSOLU n'a été résolu contre
# rien, la clause mentirait.
grep -q 'chemin relatif résolu' "$scratch/err.out" && {
  echo "ÉCHEC : un chemin absolu ne doit porter aucune clause de résolution : $(cat "$scratch/err.out")"; exit 1; }

# Régression : un repo atteint par un LIEN SYMBOLIQUE rapporte, comme `repo` dans le JSON (et donc
# comme provenance de chaque tâche/différé), le nom que l'appelant a TAPÉ — jamais le nom physique
# de la cible du lien. Même règle, même issue #143, que REPO_NAME dans audit-inventory.sh — un
# `.resolve().name` ici nommerait la cible plutôt que l'argument.
sym_dir="$scratch/symlinked"
mkdir -p "$sym_dir/vrai-nom/migration"
cat > "$sym_dir/vrai-nom/migration/report.json" <<'EOF'
{"next_steps": [{"text": "Tâche via lien", "effort": "~10 min", "owner": false}], "deferred": []}
EOF
ln -s vrai-nom "$sym_dir/lien-appelant"
python3 scripts/followups.py "$sym_dir/lien-appelant" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['tasks'][0]['repo'] == 'lien-appelant', \
    f\"'repo' doit nommer l'argument de l'appelant, pas la cible physique du lien : {d['tasks'][0]['repo']!r}\"
"

# Régression : `.` n'est pas un NOM, seulement une référence — `Path('.').name` vaut `''`, ce qui
# perdrait le vrai nom du répertoire. C'est le cas d'appel le plus courant de tous : un agent déjà
# `cd`-é dans le dépôt migré, lançant `followups.py .`.
dot_dir="$scratch/dot-arg/VraiNomDuDepot/migration"
mkdir -p "$dot_dir"
cat > "$dot_dir/report.json" <<'EOF'
{"next_steps": [{"text": "Tâche via point", "effort": "~10 min", "owner": false}], "deferred": []}
EOF
out_dot=$(cd "$scratch/dot-arg/VraiNomDuDepot" && python3 "$KIT/scripts/followups.py" . --json)
python3 - "$out_dot" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['tasks'][0]['repo'] == 'VraiNomDuDepot', \
    f"'repo' doit nommer le répertoire réel pour l'argument '.', pas le littéral '.' ou '' : {d['tasks'][0]['repo']!r}"
PY

# Sortie --json : structure valide et comptes cohérents.
python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d['ownerDecisions']) == 2 and len(d['tasks']) == 3 and len(d['deferred']) == 2, d
"

echo "OK test golden followups"
