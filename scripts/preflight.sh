#!/usr/bin/env bash
# preflight.sh — vérifie l'outillage requis/recommandé avant toute migration (phase 0).
# Sortie : table d'états, ou JSON structuré avec --json (à verser dans migration/report.json).
# Code retour 1 si un REQUIS manque, 0 sinon.
# Les capacités de session (skills frontend-design, dataviz…) ne sont pas vérifiables
# depuis bash : l'agent les confirme lui-même dans sa liste de skills (SKILL.md, phase 0, étape 2).
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

FAIL=0
RESULTS=()

record() { RESULTS+=("$1|$2|$3"); }
check() { # level(requis|recommande), name, test-command, hint
  if eval "$3" >/dev/null 2>&1; then record ok "$2" ""
  elif [ "$1" = requis ]; then record manquant "$2" "$4"; FAIL=1
  else record absent "$2" "$4"; fi
}

# SDK : comparaison numérique du major (>= 8) — pas d'énumération qui pourrit à chaque version .NET.
sdk_ok() {
  command -v dotnet >/dev/null 2>&1 &&
  dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>=8{f=1} END{exit f?0:1}'
}
# Un serveur MCP configuré mais mort ne compte pas : sa ligne d'état ne doit pas signaler d'échec.
mcp_ok() { claude mcp list 2>/dev/null | grep -i "$1" | grep -qivE 'fail|error|✗'; }

check requis "dotnet SDK >= 8" "sdk_ok" "installer un SDK .NET LTS"
check requis "git" "command -v git" "installer git"
check requis "python3" "command -v python3" "requis par les scripts du kit (inventaire, dashboard)"

if command -v claude >/dev/null 2>&1; then
  check requis "RoselineMCP connecté" "mcp_ok roseline" "claude mcp add roseline … (obligatoire pour l'analyse C#)"
  check recommande "context7 MCP connecté" "mcp_ok context7" "recommandé : docs à jour des frameworks cibles"
else
  record inconnu "MCP (roseline, context7)" "CLI claude absente (normal en CI) — à confirmer en session"
fi

check recommande "gh CLI authentifié" "gh auth status" "publication GitHub (repos, Pages, CI)"
check recommande "node / npx" "command -v npx" "Tailwind CSS (UI réécrites)"
check recommande "Chrome headless" "command -v google-chrome || command -v chromium || test -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'" "vérification visuelle des rendus"

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

echo "== ai-migration-kit préflight =="
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
