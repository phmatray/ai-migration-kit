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

# requirements.json → one tab-separated line per entry: kind, level, name, test/match, requiredBy, hint.
# "-" placeholder where a field is empty: an empty field would be swallowed by read (tab = IFS whitespace).
manifest() {
python3 - "$REQ" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
def reqby(e): return ", ".join(e.get("requiredBy", [])) or "-"
for t in req.get("tools", []):
    print("\t".join(["tool", t["level"], t["name"], t["test"], reqby(t), t.get("hint", "")]))
for m in req.get("mcps", []):
    print("\t".join(["mcp", m["level"], m["name"], m["match"], reqby(m), m.get("hint", "")]))
for s in req.get("sessionSkills", []):
    print("\t".join(["skill", s["level"], "skill " + s["name"], "-", reqby(s), s.get("when", "")]))
PY
}

CLAUDE_CLI=1
command -v claude >/dev/null 2>&1 || CLAUDE_CLI=0

while IFS=$'\t' read -r kind level name test reqby hint; do
  case "$kind" in
    tool)
      if eval "$test" >/dev/null 2>&1; then record ok "$name" "$reqby" ""
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$hint"; FAIL=1
      else record absent "$name" "$reqby" "$hint"; fi
      ;;
    mcp)
      if [ "$CLAUDE_CLI" -eq 0 ]; then
        record unknown "$name" "$reqby" "claude CLI absent (normal in CI) — confirm in session"
      elif mcp_ok "$test"; then record ok "$name" "$reqby" ""
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$hint"; FAIL=1
      else record absent "$name" "$reqby" "$hint"; fi
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
