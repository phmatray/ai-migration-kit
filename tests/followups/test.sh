#!/usr/bin/env bash
# Test golden de l'agrégateur de suivis (règle 7 : outil obligatoire → test obligatoire).
set -euo pipefail
cd "$(dirname "$0")/../.."

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

# Repo sans rapport : erreur signalée, code de sortie non nul.
if python3 scripts/followups.py /tmp/repo-inexistant-followups > /tmp/followups-err.out 2>&1; then
  echo "ÉCHEC : un repo sans migration/report.json doit produire un code de sortie non nul"; exit 1
fi
grep -q 'introuvable' /tmp/followups-err.out || { echo "ÉCHEC : l'erreur doit nommer le rapport introuvable"; exit 1; }

# Sortie --json : structure valide et comptes cohérents.
python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d['ownerDecisions']) == 2 and len(d['tasks']) == 3 and len(d['deferred']) == 2, d
"

echo "OK test golden followups"
