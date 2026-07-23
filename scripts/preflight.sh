#!/usr/bin/env bash
# preflight.sh — vérifie l'outillage requis/recommandé avant toute migration (phase 0).
# La liste des prérequis vit dans requirements.json à la racine du kit (source unique) :
# ce script la lit et l'évalue, il n'embarque aucune liste en dur.
# Sortie : table d'états, ou JSON structuré avec --json (à verser dans migration/report.json).
# Code retour 1 si un REQUIS manque, 0 sinon.
# Les capacités de session (sessionSkills du manifest) ne sont pas vérifiables depuis bash :
# l'agent les confirme lui-même dans sa liste de skills (SKILL.md, phase 0, étape 2).
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$KIT_DIR/requirements.json"

# Amorçage : python3 lit le manifest — sans lui, rien d'autre n'est vérifiable.
if ! command -v python3 >/dev/null 2>&1; then
  echo "MANQUANT ✗  python3 — requis pour lire requirements.json (et par les scripts du kit)" >&2
  exit 1
fi
[ -f "$REQ" ] || { echo "ERR: manifest introuvable — $REQ" >&2; exit 2; }

FAIL=0
RESULTS=()

record() { RESULTS+=("$1|$2|$3"); }

# SDK : comparaison numérique du major (>= 8) — pas d'énumération qui pourrit à chaque version .NET.
sdk_ok() {
  command -v dotnet >/dev/null 2>&1 &&
  dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>=8{f=1} END{exit f?0:1}'
}
# Un serveur MCP configuré mais mort ne compte pas : sa ligne d'état ne doit pas signaler d'échec.
mcp_ok() { claude mcp list 2>/dev/null | grep -i "$1" | grep -qivE 'fail|error|✗'; }

# requirements.json → une ligne tabulée par entrée : kind, level, name, test/match, hint.
manifest() {
python3 - "$REQ" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
for t in req.get("tools", []):
    print("\t".join(["tool", t["level"], t["name"], t["test"], t.get("hint", "")]))
for m in req.get("mcps", []):
    print("\t".join(["mcp", m["level"], m["name"], m["match"], m.get("hint", "")]))
# "-" en 4e colonne : un champ vide serait avalé par read (tab = IFS whitespace en bash).
for s in req.get("sessionSkills", []):
    print("\t".join(["skill", s["level"], "skill " + s["name"], "-", s.get("when", "")]))
PY
}

CLAUDE_CLI=1
command -v claude >/dev/null 2>&1 || CLAUDE_CLI=0

while IFS=$'\t' read -r kind level name test hint; do
  case "$kind" in
    tool)
      if eval "$test" >/dev/null 2>&1; then record ok "$name" ""
      elif [ "$level" = requis ]; then record manquant "$name" "$hint"; FAIL=1
      else record absent "$name" "$hint"; fi
      ;;
    mcp)
      if [ "$CLAUDE_CLI" -eq 0 ]; then
        record inconnu "$name" "CLI claude absente (normal en CI) — à confirmer en session"
      elif mcp_ok "$test"; then record ok "$name" ""
      elif [ "$level" = requis ]; then record manquant "$name" "$hint"; FAIL=1
      else record absent "$name" "$hint"; fi
      ;;
    skill)
      record inconnu "$name" "capacité de session — à confirmer par l'agent ($hint)"
      ;;
  esac
done < <(manifest)

if [ "$JSON" -eq 1 ]; then
  printf '{"ok": %s, "checks": [' "$([ "$FAIL" -eq 0 ] && echo true || echo false)"
  sep=""
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r st name hint <<<"$r"
    printf '%s{"status": "%s", "name": "%s", "hint": "%s"}' "$sep" "$st" "$name" "$hint"
    sep=", "
  done
  printf ']}\n'
  exit "$FAIL"
fi

echo "== ai-migration-kit préflight (manifest : requirements.json) =="
for r in "${RESULTS[@]}"; do
  IFS='|' read -r st name hint <<<"$r"
  case "$st" in
    ok)       label="OK" ;;
    manquant) label="MANQUANT ✗" ;;
    absent)   label="absent" ;;
    inconnu)  label="inconnu" ;;
  esac
  printf '%-11s %-26s %s\n' "$label" "$name" "$hint"
done
echo
if [ "$FAIL" -eq 1 ]; then
  echo "PRÉFLIGHT ÉCHOUÉ — corriger les éléments REQUIS avant la phase 1."
  exit 1
fi
echo "Préflight OK — les éléments 'absent/inconnu' dégradent le pipeline de façon documentée, jamais silencieuse."
