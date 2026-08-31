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

# --questionnaire : rendu du gabarit "discovery questionnaire" (I-332, porté de
# mattpocock/skills productivity/to-questionnaire, MIT) sur les décisions propriétaire des
# fixtures — 2 au total, une par fixture.
q_out="$scratch/questionnaire.md"
python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b \
  --questionnaire "$q_out" > "$scratch/questionnaire.log"
q="$(cat "$q_out")"
assert_q() { grep -qF "$1" <<<"$q" || { echo "ÉCHEC (questionnaire) : « $1 » absent"; exit 1; }; }
assert_q '**Purpose:**'
assert_q '**From:**'
assert_q '## Context'
assert_q '## How to answer'
assert_q '## FixtureA'
assert_q '## FixtureB'
assert_q '### Décision propriétaire A'
assert_q '### Décision propriétaire B sans effort'
assert_q '## Anything else?'
# 2 décisions propriétaire -> 2 ids stables, un par fixture repo :
id_a=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('fixture-a','Décision propriétaire A'))")
id_b=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('fixture-b','Décision propriétaire B sans effort'))")
grep -qF "<!-- followup: fixture-a | $id_a -->" <<<"$q" || { echo "ÉCHEC : id followup fixture-a absent ou différent"; exit 1; }
grep -qF "<!-- followup: fixture-b | $id_b -->" <<<"$q" || { echo "ÉCHEC : id followup fixture-b absent ou différent"; exit 1; }
[ "$(grep -c '^### ' <<<"$q")" -eq 2 ] || { echo "ÉCHEC : attendu exactement 2 questions « ### », trouvé $(grep -c '^### ' <<<"$q")"; exit 1; }
# Les tâches (non owner) ne sont jamais des questions :
grep -qF 'Tâche quinze minutes' <<<"$q" && { echo "ÉCHEC : une tâche non-owner est apparue comme question"; exit 1; }

# --profile-todos : un thème "Repo profile" en plus, une question par marqueur TODO.
q_todo_out="$scratch/questionnaire-todos.md"
python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b \
  --questionnaire "$q_todo_out" --profile-todos tests/followups/fixture-profile.md \
  > "$scratch/questionnaire-todos.log"
q2="$(cat "$q_todo_out")"
grep -qF '## Repo profile' <<<"$q2" || { echo "ÉCHEC : thème « Repo profile » absent avec --profile-todos"; exit 1; }
[ "$(grep -c '^### ' <<<"$q2")" -eq 4 ] || { echo "ÉCHEC : attendu 4 questions (2 décisions + 2 TODO), trouvé $(grep -c '^### ' <<<"$q2")"; exit 1; }
grep -qF 'confirm the commit author identity' <<<"$q2" || { echo "ÉCHEC : premier TODO du profil absent"; exit 1; }
grep -qF 'link CONTEXT.md once the owner writes one' <<<"$q2" || { echo "ÉCHEC : second TODO du profil absent"; exit 1; }

# --ingest : applique les réponses SUR UNE COPIE SCRATCH des fixtures (#160, jamais les vraies).
ingest_dir="$scratch/ingest"
mkdir -p "$ingest_dir"
cp -R tests/followups/fixture-a "$ingest_dir/fixture-a"
cp -R tests/followups/fixture-b "$ingest_dir/fixture-b"

# Deux décisions propriétaire de plus, SEULEMENT sur la copie scratch, pour couvrir les deux
# chemins que "Décision propriétaire A" (done) et "B" (wont) ne couvrent pas : une réponse
# `later` (conservée, annotée) et un stub laissé VIDE (l'entrée ne doit pas bouger).
python3 -c "
import json
p = '$ingest_dir/fixture-a/migration/report.json'
r = json.load(open(p, encoding='utf-8'))
r['next_steps'].append({'text': 'Décision propriétaire C à trancher plus tard', 'effort': '~5 min', 'owner': True})
r['next_steps'].append({'text': 'Décision propriétaire D jamais répondue', 'effort': '~5 min', 'owner': True})
json.dump(r, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
"

# Le fichier de réponses est GÉNÉRÉ par un rendu réel (les ids ne peuvent pas dériver du schéma) :
# on rend depuis la copie scratch elle-même, puis on complète les stubs.
ingest_answered="$scratch/answered.md"
python3 scripts/followups.py "$ingest_dir/fixture-a" "$ingest_dir/fixture-b" \
  --questionnaire "$ingest_answered" > /dev/null
id_a=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('fixture-a','Décision propriétaire A'))")
id_b=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('fixture-b','Décision propriétaire B sans effort'))")
id_c=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('fixture-a','Décision propriétaire C à trancher plus tard'))")
id_stale="deadbeef"

# id_d (« Décision propriétaire D jamais répondue ») reste délibérément SANS réponse : son stub
# `>` généré par le rendu reste vide, exactement ce que produirait un propriétaire qui a sauté
# la question.
python3 - "$ingest_answered" "$id_a" "$id_b" "$id_c" "$id_stale" <<'PY'
import sys
path, id_a, id_b, id_c, id_stale = sys.argv[1:6]
text = open(path, encoding='utf-8').read()
text = text.replace(f"<!-- followup: fixture-a | {id_a} -->\n>",
                     f"<!-- followup: fixture-a | {id_a} -->\n> done")
text = text.replace(f"<!-- followup: fixture-b | {id_b} -->\n>",
                     f"<!-- followup: fixture-b | {id_b} -->\n> wont — too costly")
text = text.replace(f"<!-- followup: fixture-a | {id_c} -->\n>",
                     f"<!-- followup: fixture-a | {id_c} -->\n> later, ask me in Q4")
# Un id fabriqué, sur un repo réellement passé : doit être signalé PÉRIMÉ, jamais planté.
text += f"\n### Fabricated stale question\n<!-- followup: fixture-a | {id_stale} -->\n> later, ask me in Q4\n"
open(path, 'w', encoding='utf-8').write(text)
PY

# --dry-run : ne doit RIEN écrire (byte-identique avant/après).
before_json_a=$(cat "$ingest_dir/fixture-a/migration/report.json")
before_md_a=$(cat "$ingest_dir/fixture-a/migration/report.md")
ingest_out_dry="$(python3 scripts/followups.py "$ingest_dir/fixture-a" "$ingest_dir/fixture-b" --ingest "$ingest_answered" --dry-run)"
after_json_a=$(cat "$ingest_dir/fixture-a/migration/report.json")
after_md_a=$(cat "$ingest_dir/fixture-a/migration/report.md")
[ "$before_json_a" = "$after_json_a" ] || { echo "ÉCHEC : --dry-run a modifié report.json"; exit 1; }
[ "$before_md_a" = "$after_md_a" ] || { echo "ÉCHEC : --dry-run a modifié report.md"; exit 1; }
grep -qF '1 done · 0 not pursued' <<<"$ingest_out_dry" || { echo "ÉCHEC (dry-run) : compte fixture-a inattendu : $ingest_out_dry"; exit 1; }
grep -qF "stale id $id_stale in fixture-a" <<<"$ingest_out_dry" || { echo "ÉCHEC (dry-run) : id fabriqué non signalé périmé"; exit 1; }

# Ingestion réelle.
ingest_out="$(python3 scripts/followups.py "$ingest_dir/fixture-a" "$ingest_dir/fixture-b" --ingest "$ingest_answered")"
grep -qF '1 done · 0 not pursued' <<<"$ingest_out" || { echo "ÉCHEC (ingest) : compte fixture-a inattendu : $ingest_out"; exit 1; }
grep -qF '0 done · 1 not pursued' <<<"$ingest_out" || { echo "ÉCHEC (ingest) : compte fixture-b inattendu : $ingest_out"; exit 1; }

# report.json : "done" retiré de next_steps ; "wont" déplacé vers deferred avec la raison, et
# strike la ligne de report.md ; "done" coche la ligne de report.md.
python3 -c "
import json
r = json.load(open('$ingest_dir/fixture-a/migration/report.json', encoding='utf-8'))
assert not any(s.get('text') == 'Décision propriétaire A' for s in r['next_steps']), r['next_steps']
# 'later' : conservée, annotée answer/answered — jamais retirée.
c = next(s for s in r['next_steps'] if s.get('text') == 'Décision propriétaire C à trancher plus tard')
assert c.get('answer', '').startswith('later'), c
assert c.get('answered'), c
# Stub laissé vide : l'entrée n'a RIEN reçu — ni answer, ni answered, ni suppression.
d = next(s for s in r['next_steps'] if s.get('text') == 'Décision propriétaire D jamais répondue')
assert 'answer' not in d and 'answered' not in d, d
assert len(r['next_steps']) == 4, r['next_steps']  # une tâche + une demi-heure + C + D
"
python3 -c "
import json
r = json.load(open('$ingest_dir/fixture-b/migration/report.json', encoding='utf-8'))
assert not any(s.get('text') == 'Décision propriétaire B sans effort' for s in r['next_steps']), r['next_steps']
deferred_texts = [d['text'] for d in r['deferred']]
assert any('Décision propriétaire B sans effort' in t and 'too costly' in t for t in deferred_texts), deferred_texts
assert any(d['strong'].startswith('Not pursued by decision (') for d in r['deferred']), r['deferred']
"
grep -qF -- '- [x] Décision propriétaire A' "$ingest_dir/fixture-a/migration/report.md" || {
  echo "ÉCHEC : report.md de fixture-a n'a pas coché la décision « done »"; exit 1; }
grep -qF -- '- [x] ~~Décision propriétaire B sans effort~~ — not pursued by decision' "$ingest_dir/fixture-b/migration/report.md" || {
  echo "ÉCHEC : report.md de fixture-b n'a pas barré la décision « wont »"; exit 1; }

# L'id fabriqué reste signalé périmé sur l'ingestion réelle aussi (jamais planté, jamais appliqué).
grep -qF "stale id $id_stale in fixture-a" <<<"$ingest_out" || { echo "ÉCHEC : id fabriqué non signalé périmé (réel)"; exit 1; }

# Un re-rendu APRÈS ingestion rappelle la réponse « later » déjà donnée — sinon le propriétaire
# se voit reposer la même question sans jamais voir sa propre note précédente.
q_after="$scratch/questionnaire-after.md"
python3 scripts/followups.py "$ingest_dir/fixture-a" "$ingest_dir/fixture-b" \
  --questionnaire "$q_after" > /dev/null
grep -qF 'Previously answered' "$q_after" || {
  echo "ÉCHEC : le re-rendu ne rappelle pas la réponse « later » déjà donnée"; exit 1; }
grep -qF 'later, ask me in Q4' "$q_after" || {
  echo "ÉCHEC : le re-rendu ne cite pas la réponse exacte déjà donnée"; exit 1; }

# --profile-todos collision : le même profil passé deux fois -> mêmes ids -> avertissement, comme
# pour une décision propriétaire dupliquée (même mécanisme, même message).
q_dup_todo="$scratch/questionnaire-dup-todo.md"
dup_todo_out="$(python3 scripts/followups.py tests/followups/fixture-a tests/followups/fixture-b \
  --questionnaire "$q_dup_todo" \
  --profile-todos tests/followups/fixture-profile.md tests/followups/fixture-profile.md)"
grep -qF 'collision:' <<<"$dup_todo_out" || {
  echo "ÉCHEC : un profil TODO dupliqué doit être signalé en collision : $dup_todo_out"; exit 1; }

# Régression report.md : une entrée dont le texte est un PRÉFIXE littéral d'une autre ne doit
# jamais faire cocher/barrer la MAUVAISE ligne (un test par sous-chaîne le ferait).
prefix_dir="$scratch/prefix-regression"
mkdir -p "$prefix_dir/migration"
cat > "$prefix_dir/migration/report.json" <<'EOF'
{
  "next_steps": [
    {"text": "Update SDK", "effort": "~10 min", "owner": false},
    {"text": "Update SDK version pin in csproj", "effort": "~10 min", "owner": true}
  ],
  "deferred": []
}
EOF
cat > "$prefix_dir/migration/report.md" <<'EOF'
## Prochaines étapes
- [ ] Update SDK
- [ ] Update SDK version pin in csproj
EOF
prefix_answered="$scratch/prefix-answered.md"
python3 scripts/followups.py "$prefix_dir" --questionnaire "$prefix_answered" > /dev/null
id_prefix=$(python3 -B -c "import sys; sys.path.insert(0,'scripts'); import followups as f; print(f.entry_id('prefix-regression','Update SDK version pin in csproj'))")
python3 - "$prefix_answered" "$id_prefix" <<'PY'
import sys
path, eid = sys.argv[1:3]
text = open(path, encoding='utf-8').read()
text = text.replace(f"<!-- followup: prefix-regression | {eid} -->\n>",
                     f"<!-- followup: prefix-regression | {eid} -->\n> done")
open(path, 'w', encoding='utf-8').write(text)
PY
python3 scripts/followups.py "$prefix_dir" --ingest "$prefix_answered" > /dev/null
grep -qxF -- '- [ ] Update SDK' "$prefix_dir/migration/report.md" || {
  echo "ÉCHEC (régression préfixe) : « Update SDK » (tâche non répondue) a été touché à tort :"
  cat "$prefix_dir/migration/report.md"; exit 1; }
grep -qxF -- '- [x] Update SDK version pin in csproj' "$prefix_dir/migration/report.md" || {
  echo "ÉCHEC (régression préfixe) : la vraie décision répondue n'a pas été cochée :"
  cat "$prefix_dir/migration/report.md"; exit 1; }

# Idempotence : une seconde ingestion sur les MÊMES fichiers ne refait rien pour les ids déjà traités.
ingest_out2="$(python3 scripts/followups.py "$ingest_dir/fixture-a" "$ingest_dir/fixture-b" --ingest "$ingest_answered")"
grep -qF '0 done · 0 not pursued' <<<"$ingest_out2" || { echo "ÉCHEC : la seconde ingestion n'est pas un no-op : $ingest_out2"; exit 1; }

# Un fichier de réponses vide/introuvable est un fichier MALFORMÉ (exit 2), pas une erreur repo.
empty_answered="$scratch/empty-answered.md"
: > "$empty_answered"
if python3 scripts/followups.py "$ingest_dir/fixture-a" --ingest "$empty_answered" > "$scratch/empty.out" 2>&1; then
  rc=0
else
  rc=$?
fi
[ "$rc" -eq 2 ] || { echo "ÉCHEC : un answered.md vide doit sortir en code 2, a rendu $rc : $(cat "$scratch/empty.out")"; exit 1; }

# La doc du skill nomme les deux flags — sinon le loop questionnaire -> ingest n'est documenté
# nulle part et personne ne sait qu'il existe.
grep -qF -- '--questionnaire' skills/review-followups/SKILL.md || {
  echo "ÉCHEC : skills/review-followups/SKILL.md ne mentionne pas --questionnaire"; exit 1; }
grep -qF -- '--ingest' skills/review-followups/SKILL.md || {
  echo "ÉCHEC : skills/review-followups/SKILL.md ne mentionne pas --ingest"; exit 1; }

echo "OK test golden followups"
