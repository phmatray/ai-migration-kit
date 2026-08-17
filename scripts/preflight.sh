#!/usr/bin/env bash
# preflight.sh — verifies the required/recommended tooling before any migration (phase 0).
# The prerequisite list lives in requirements.json at the kit root (single source):
# this script reads and evaluates it, it embeds no hard-coded list.
# Output: a status table, or structured JSON with --json (to store in migration/report.json).
# Exit code 1 if a REQUIRED item is missing, 0 otherwise.
# Session capabilities (the manifest's sessionSkills) cannot be checked from bash:
# the agent confirms them itself against its skill list (SKILL.md, phase 0, step 2).
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$KIT_DIR/requirements.json"

# Bootstrap: python3 reads the manifest — without it, nothing else is checkable.
if ! command -v python3 >/dev/null 2>&1; then
  echo "MISSING ✗  python3 — required to read requirements.json (and by the kit's scripts)" >&2
  exit 1
fi
[ -f "$REQ" ] || { echo "ERR: manifest not found — $REQ" >&2; exit 2; }

FAIL=0
RESULTS=()
TAB=$'\t'

# status, name, requiredBy ("-" if none), hint — tab-separated (manifest values carry no tabs).
record() { RESULTS+=("$1$TAB$2$TAB$3$TAB$4"); }

# SDK: numeric comparison of the major (>= 8) — no version enumeration that rots with every .NET release.
sdk_ok() {
  command -v dotnet >/dev/null 2>&1 &&
  dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>=8{f=1} END{exit f?0:1}'
}
# A configured-but-dead MCP server does not count: its status line must not report a failure.
mcp_ok() { claude mcp list 2>/dev/null | grep -i "$1" | grep -qivE 'fail|error|✗'; }

# The highest installed SDK major, or empty when dotnet is absent or unreadable. Computed ONCE:
# the requiresSdk check below runs per mcps entry and `dotnet --list-sdks` is a process spawn.
SDK_MAJOR=$(command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>m{m=$1+0} END{if(m>0) print m}')

# An mcps entry may declare `requiresSdk`: the SDK major ITS OWN launcher needs, which can sit above
# the pipeline's floor — roseline is started with `dnx` (.NET 10) while the pipeline accepts >= 8, so
# a .NET 8/9 host used to pass phase 0 with a server that could never start (#112).
# Answers "can this host run it at all", so every uncertain case answers no: an absent field is not
# "floor 0", an unparseable floor is not a verdict, and an unreadable SDK is already reported by the
# tools row above. Saying nothing leaves the entry's behaviour exactly as it was before the field.
sdk_below_floor() {
  local floor="$1"
  [ "$floor" != "-" ] || return 1
  case "$floor" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$SDK_MAJOR" ] || return 1
  [ "$SDK_MAJOR" -lt "$floor" ]
}

# Where the floor is unmet, this is WHY — prefixed to the entry's own hint, so every status line
# that names the server also names the version it wanted. Empty otherwise.
# It changes the MESSAGE, never the VERDICT of an observed absence: a `level: required` server the
# claude CLI can see is not running still hard-fails phase 0. Softening that would swap one silent
# failure for another — green on a host that cannot run it, for a pipeline started without the
# engine every phase of it depends on.
floor_note() {
  sdk_below_floor "$1" || return 0
  printf 'needs a .NET SDK >= %s to start, this host has %s — ' "$1" "$SDK_MAJOR"
}

# requirements.json → one tab-separated line per entry: kind, level, name, test/match, requiredBy,
# requiresSdk, hint. "-" placeholder where a field is empty: an empty field would be swallowed by
# read (tab = IFS whitespace). hint stays LAST because `read` gives the trailing field the remainder.
manifest() {
python3 - "$REQ" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
def reqby(e): return ", ".join(e.get("requiredBy", [])) or "-"
for t in req.get("tools", []):
    print("\t".join(["tool", t["level"], t["name"], t["test"], reqby(t), "-", t.get("hint", "")]))
for m in req.get("mcps", []):
    print("\t".join(["mcp", m["level"], m["name"], m["match"], reqby(m),
                     str(m.get("requiresSdk") or "-"), m.get("hint", "")]))
for s in req.get("sessionSkills", []):
    print("\t".join(["skill", s["level"], "skill " + s["name"], "-", reqby(s), "-", s.get("when", "")]))
PY
}

CLAUDE_CLI=1
command -v claude >/dev/null 2>&1 || CLAUDE_CLI=0

while IFS=$'\t' read -r kind level name test reqby floor hint; do
  case "$kind" in
    tool)
      if eval "$test" >/dev/null 2>&1; then record ok "$name" "$reqby" ""
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$hint"; FAIL=1
      else record absent "$name" "$reqby" "$hint"; fi
      ;;
    mcp)
      # A live server is checked FIRST, so an observed connection always beats the floor: the floor
      # is a proxy for "the shipped launcher cannot start it", and a server the user brought up by
      # some other route is running whatever this host's SDK says.
      note=$(floor_note "$floor")
      if [ "$CLAUDE_CLI" -eq 1 ] && mcp_ok "$test"; then record ok "$name" "$reqby" ""
      elif [ "$CLAUDE_CLI" -eq 0 ]; then
        # Nothing can be observed here — but "unknown, confirm in session" is the wrong answer to a
        # question this host has already settled: below the launcher's floor the server cannot
        # start, whoever confirms it. That is the silent pass #112 filed, so name it instead.
        if [ -n "$note" ]; then record absent "$name" "$reqby" "$note$hint"
        else record unknown "$name" "$reqby" "claude CLI absent (normal in CI) — confirm in session"; fi
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$note$hint"; FAIL=1
      else record absent "$name" "$reqby" "$note$hint"; fi
      ;;
    skill)
      record unknown "$name" "$reqby" "session capability — the agent confirms it itself ($hint)"
      ;;
  esac
done < <(manifest)

if [ "$JSON" -eq 1 ]; then
  # JSON is emitted by python3 (real escaping) — never hand-assembled with printf.
  # Results travel as argv (the heredoc already owns stdin for the program itself).
  python3 - "$FAIL" "${RESULTS[@]}" <<'PY'
import json, sys
fail = sys.argv[1] != "0"
checks = []
for line in sys.argv[2:]:
    st, name, reqby, hint = (line.split("\t", 3) + ["", "", ""])[:4]
    check = {"status": st, "name": name, "hint": hint}
    if reqby != "-":
        check["requiredBy"] = [s.strip() for s in reqby.split(",")]
    checks.append(check)
print(json.dumps({"ok": not fail, "checks": checks}, ensure_ascii=False))
PY
  exit "$FAIL"
fi

echo "== ai-migration-kit preflight (manifest: requirements.json) =="
for r in "${RESULTS[@]}"; do
  IFS=$'\t' read -r st name reqby hint <<<"$r"
  case "$st" in
    ok)      label="OK" ;;
    missing) label="MISSING ✗" ;;
    absent)  label="absent" ;;
    unknown) label="unknown" ;;
  esac
  extra=""
  [ "$reqby" != "-" ] && [ "$st" != ok ] && extra=" [hard-required by: $reqby]"
  printf '%-11s %-28s %s%s\n' "$label" "$name" "$hint" "$extra"
done
echo
if [ "$FAIL" -eq 1 ]; then
  echo "PREFLIGHT FAILED — fix the REQUIRED items before phase 1."
  exit 1
fi
echo "Preflight OK — 'absent/unknown' items degrade the pipeline in a documented way, never silently."
