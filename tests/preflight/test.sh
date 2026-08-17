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

# 5. An `mcps` entry may declare its OWN SDK floor (`requiresSdk`) — a server whose launcher needs a
#    newer SDK than the pipeline does. roseline is exactly that: `.mcp.json` starts it with `dnx`,
#    which ships only with the .NET 10 SDK, while the pipeline itself runs on `dotnet >= 8`. Below
#    the floor the server cannot start, so preflight must NAME it and the version it wants instead
#    of reporting the setup fine (#112). An entry WITHOUT the field is unaffected.
#
#    Driven against a SYNTHETIC kit root, not the real manifest: preflight resolves its manifest as
#    `$(dirname $0)/../requirements.json`, so a copy of the script beside a copy of a manifest is a
#    complete, isolated kit. The host's `dotnet` is stubbed for the same reason — the assertion has
#    to read the same on a .NET 10 machine and on a .NET 8 one.
tmp=$(mktemp -d)
mkdir -p "$tmp/scripts" "$tmp/bin"
cp ./scripts/preflight.sh "$tmp/scripts/preflight.sh"
cat > "$tmp/requirements.json" <<'JSON'
{
  "description": "synthetic manifest — the requiresSdk case",
  "tools": [
    { "name": "dotnet SDK >= 8", "level": "required", "test": "sdk_ok", "hint": "install an LTS .NET SDK" }
  ],
  "mcps": [
    { "name": "floored server", "match": "floored", "level": "required", "requiresSdk": "10", "hint": "launched with a newer-SDK launcher" },
    { "name": "unfloored server", "match": "unfloored", "level": "recommended", "hint": "no floor declared" }
  ],
  "sessionSkills": []
}
JSON
# A .NET 9 host: comfortably above the pipeline's own floor of 8, below the server's declared 10.
cat > "$tmp/bin/dotnet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--list-sdks" ] && echo "9.0.100 [/stub/sdk]"
exit 0
SH
chmod +x "$tmp/bin/dotnet"
# No `claude` on this PATH, so the live MCP probe cannot run — which is the CI case, and the one
# where an unstartable server would otherwise be reported as a shrug ("unknown, confirm in session").
for c in bash python3 dirname awk grep; do ln -s "$(command -v "$c")" "$tmp/bin/$c"; done
if ! out=$(PATH="$tmp/bin" bash "$tmp/scripts/preflight.sh" --json 2>/dev/null); then
  echo "an mcps floor the host misses is a documented degradation, not a phase-0 hard fail"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}

floored = checks["floored server"]
assert floored["status"] == "absent", \
    f"a server whose declared SDK floor is unmet must degrade loudly, got {floored['status']!r}"
assert "10" in floored["hint"], f"the report must name the required version: {floored['hint']!r}"
assert "9" in floored["hint"], f"...and what this host actually has: {floored['hint']!r}"

# No floor declared ⇒ byte-for-byte the behaviour that shipped before this field existed.
unfloored = checks["unfloored server"]
assert unfloored["status"] == "unknown", \
    f"an entry without requiresSdk must be unaffected, got {unfloored['status']!r}"
assert "claude CLI absent" in unfloored["hint"], \
    f"an entry without requiresSdk must keep its old hint: {unfloored['hint']!r}"
PY

# 6. The floor EXPLAINS an absence; it does not excuse one. Give the same host a `claude` that can
#    see the server is not there, and a `level: required` entry must still hard-fail phase 0 — only
#    now the message says which SDK it wanted. Softening that would trade one silent failure for
#    another: green on a host that cannot run it, for a pipeline started without the engine every
#    phase of it depends on.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/claude"   # a CLI that lists no servers at all
chmod +x "$tmp/bin/claude"
if PATH="$tmp/bin" bash "$tmp/scripts/preflight.sh" --json > "$tmp/seen.json" 2>/dev/null; then
  echo "a REQUIRED mcp the host can SEE is absent must still fail the preflight"; exit 1
fi
python3 - "$tmp/seen.json" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.load(open(sys.argv[1]))["checks"]}
floored = checks["floored server"]
assert floored["status"] == "missing", \
    f"an observed absence at level=required stays a hard fail, got {floored['status']!r}"
assert "10" in floored["hint"], f"...and still names the floor it wanted: {floored['hint']!r}"
PY
rm -rf "$tmp"

echo "preflight golden test OK"
