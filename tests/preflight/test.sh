#!/usr/bin/env bash
# Preflight golden test: requirements.json is the single source — the --json output is valid
# JSON, covers every manifest entry, and a missing REQUIRED item fails the run (exit 1).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# Registered rather than left unsaid: tests/_lib.sh's contract asks every converted suite to DECIDE
# about this guard, precisely so "forgot to call it" and "decided it does not apply" stop looking
# alike. This one runs kit scripts against the real repo, so it takes the check.
kit_guard kit_guard_samples_unchanged

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
#    The scratch comes from the shared helper, so it is removed on EVERY exit path (#128). The
#    inline `rm -rf` this replaced ran only if the two assertions below passed — a suite that
#    failed here left its directory behind, which is the half of the cost #72 measured away.
tmp=$(kit_scratch)
for c in bash python3 dirname; do ln -s "$(command -v "$c")" "$tmp/$c"; done
if PATH="$tmp" bash ./scripts/preflight.sh --json > "$tmp/out.json" 2>/dev/null; then
  echo "the preflight should have failed without the required tooling"; exit 1
fi
grep -q '"status": "missing"' "$tmp/out.json"

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
#    The synthetic root comes from kit_scratch, like section 4's: this suite joined the shared
#    library in #128, so a bare `mktemp -d` here would sit outside KIT_LIB_TMP and nothing would
#    reclaim it (tests/lib section 9 says so by name). #112 landed this block on main while the
#    conversion was in flight, so the two are reconciled here rather than either being dropped.
tmp=$(kit_scratch)
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
    { "name": "launched server", "match": "launched", "level": "recommended", "requiresSdk": "10", "launcher": "kit-stub-launcher", "hint": "its own launcher starts it" },
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

# The launcher is the VERDICT, the floor is the REMEDY — a host missing both must be told both, in
# that order. "kit-stub-launcher not on PATH" says the server cannot have started; "needs a .NET
# SDK >= 10, this host has 9" says what to install about it. Either alone leaves the reader stuck.
launched = checks["launched server"]
assert launched["status"] == "absent", \
    f"a declared launcher missing from PATH must degrade loudly, got {launched['status']!r}"
assert "kit-stub-launcher" in launched["hint"], \
    f"the report must name the launcher it probed: {launched['hint']!r}"
assert launched["hint"].index("kit-stub-launcher") < launched["hint"].index("10"), \
    f"the launcher verdict comes before the SDK remedy: {launched['hint']!r}"

# No floor declared ⇒ byte-for-byte the behaviour that shipped before this field existed.
unfloored = checks["unfloored server"]
assert unfloored["status"] == "unknown", \
    f"an entry without requiresSdk must be unaffected, got {unfloored['status']!r}"
assert "claude CLI absent" in unfloored["hint"], \
    f"an entry without requiresSdk must keep its old hint: {unfloored['hint']!r}"
PY

# 5b. The launcher probe on a host that CLEARS the floor — which is the case the floor cannot see,
#     and the reason `launcher` exists as a field of its own (#155). A .NET 10 SDK is present, so
#     `requiresSdk` is satisfied and says nothing; the only remaining question is whether the
#     executable that starts the server is on PATH, and preflight must answer it.
#
#     A second synthetic root rather than a second `dotnet` stub in the first: section 6 re-runs
#     against `$tmp` and asserts the .NET 9 floor note is still there, so raising that host's SDK
#     would quietly delete section 6's subject. Same manifest, copied — one source, two hosts.
tmp10=$(kit_scratch)
mkdir -p "$tmp10/scripts" "$tmp10/bin"
cp ./scripts/preflight.sh "$tmp10/scripts/preflight.sh"
cp "$tmp/requirements.json" "$tmp10/requirements.json"
cat > "$tmp10/bin/dotnet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--list-sdks" ] && echo "10.0.100 [/stub/sdk]"
exit 0
SH
chmod +x "$tmp10/bin/dotnet"
for c in bash python3 dirname awk grep; do ln -s "$(command -v "$c")" "$tmp10/bin/$c"; done

# `kit-stub-launcher` is a name no host has, so "absent" here is a measurement and not a bet on
# what the machine running the suite happens to have installed.
if ! out=$(PATH="$tmp10/bin" bash "$tmp10/scripts/preflight.sh" --json 2>/dev/null); then
  echo "a launcher the host misses is a documented degradation, not a phase-0 hard fail"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}

launched = checks["launched server"]
assert launched["status"] == "absent", \
    f"an SDK above the floor does not prove the launcher is on PATH, got {launched['status']!r}"
assert "kit-stub-launcher" in launched["hint"], \
    f"the report must name the launcher it probed: {launched['hint']!r}"
assert "this host has" not in launched["hint"], \
    f"the floor is met here, so it must not be offered as the remedy: {launched['hint']!r}"

# The floor's own entry declares no launcher, so on a host that clears the floor it is back to the
# shrug — proving 5b's `absent` came from the launcher probe and from nothing else.
floored = checks["floored server"]
assert floored["status"] == "unknown", \
    f"a met floor with no launcher declared must be unaffected, got {floored['status']!r}"
assert "claude CLI absent" in floored["hint"], f"...with its old hint: {floored['hint']!r}"

unfloored = checks["unfloored server"]
assert unfloored["status"] == "unknown", \
    f"an entry with neither field must be unaffected, got {unfloored['status']!r}"
PY

# ...and the companion: put that same launcher ON the PATH and the entry is byte-for-byte what it
# was before the field existed. Without this, "absent" above would be equally well explained by
# preflight reporting every entry that declares a launcher as absent.
printf '#!/bin/sh\nexit 0\n' > "$tmp10/bin/kit-stub-launcher"
chmod +x "$tmp10/bin/kit-stub-launcher"
if ! out=$(PATH="$tmp10/bin" bash "$tmp10/scripts/preflight.sh" --json 2>/dev/null); then
  echo "a launcher present on PATH must not fail the preflight"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}
launched = checks["launched server"]
assert launched["status"] == "unknown", \
    f"a launcher on PATH restores the prior behaviour, got {launched['status']!r}"
assert "claude CLI absent" in launched["hint"], \
    f"...including its hint, unprefixed: {launched['hint']!r}"
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

echo "preflight golden test OK"
