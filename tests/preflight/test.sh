#!/usr/bin/env bash
# Preflight golden test: requirements.json is the single source — the --json output is valid
# JSON, covers every manifest entry, and a missing REQUIRED item fails the run (exit 1).
set -euo pipefail
cd "$(dirname "$0")/../.."

# 1. The --json output is valid JSON (the preflight may exit 0 or 1 depending on the machine).
out=$(./scripts/preflight.sh --json || true)
echo "$out" | python3 -m json.tool >/dev/null

# 2. Every manifest entry appears in the output — nothing is silently skipped.
python3 - "$out" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
req = json.load(open("requirements.json"))
names = {c["name"] for c in out["checks"]}
expected = [t["name"] for t in req["tools"]] + [m["name"] for m in req["mcps"]] \
         + ["skill " + s["name"] for s in req["sessionSkills"]]
missing = [n for n in expected if n not in names]
assert not missing, f"manifest entries absent from the output: {missing}"
# 3. requiredBy survives the round-trip (manifest → preflight → JSON).
by_name = {c["name"]: c for c in out["checks"]}
for entry in req["tools"] + req["mcps"] + req["sessionSkills"]:
    want = entry.get("requiredBy")
    if want:
        name = entry["name"] if entry in req["tools"] + req["mcps"] else "skill " + entry["name"]
        got = by_name[name].get("requiredBy")
        assert got == want, f"requiredBy mismatch for {name}: {got} != {want}"
PY

# 4. A missing REQUIRED item ⇒ exit 1 and status "missing". PATH reduced to the bare minimum
#    needed to read the manifest (bash + python3 + dirname): git/dotnet become unfindable.
tmp=$(mktemp -d)
for c in bash python3 dirname; do ln -s "$(command -v "$c")" "$tmp/$c"; done
if PATH="$tmp" bash ./scripts/preflight.sh --json > "$tmp/out.json" 2>/dev/null; then
  echo "the preflight should have failed without the required tooling"; exit 1
fi
grep -q '"status": "missing"' "$tmp/out.json"
rm -rf "$tmp"

echo "preflight golden test OK"
