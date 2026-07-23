#!/usr/bin/env bash
# Golden test du préflight : requirements.json est la source unique — la sortie --json est du
# JSON valide, couvre chaque entrée du manifest, et un REQUIS introuvable fait échouer (exit 1).
set -euo pipefail
cd "$(dirname "$0")/../.."

# 1. La sortie --json est du JSON valide (le préflight peut sortir 0 ou 1 selon la machine).
out=$(./scripts/preflight.sh --json || true)
echo "$out" | python3 -m json.tool >/dev/null

# 2. Chaque entrée du manifest apparaît dans la sortie — rien n'est silencieusement ignoré.
python3 - "$out" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
req = json.load(open("requirements.json"))
names = {c["name"] for c in out["checks"]}
expected = [t["name"] for t in req["tools"]] + [m["name"] for m in req["mcps"]] \
         + ["skill " + s["name"] for s in req["sessionSkills"]]
missing = [n for n in expected if n not in names]
assert not missing, f"entrées du manifest absentes de la sortie: {missing}"
PY

# 3. Un REQUIS introuvable ⇒ exit 1 et statut « manquant ». PATH réduit au strict nécessaire
#    pour lire le manifest (bash + python3 + dirname) : git/dotnet deviennent introuvables.
tmp=$(mktemp -d)
for c in bash python3 dirname; do ln -s "$(command -v "$c")" "$tmp/$c"; done
if PATH="$tmp" bash ./scripts/preflight.sh --json > "$tmp/out.json" 2>/dev/null; then
  echo "le préflight aurait dû échouer sans l'outillage requis"; exit 1
fi
grep -q '"status": "manquant"' "$tmp/out.json"
rm -rf "$tmp"

echo "preflight golden test OK"
