#!/usr/bin/env bash
# preflight.sh — vérifie l'outillage requis/recommandé avant toute migration (phase 0).
# Sortie : table d'états. Code retour 1 si un REQUIS manque, 0 sinon.
# Les capacités de session (skills frontend-design, dataviz…) ne sont pas vérifiables
# depuis bash de façon fiable : l'agent doit les confirmer lui-même (cf. SKILL.md, phase 0).
set -uo pipefail

FAIL=0
row() { printf '%-11s %-28s %s\n' "$1" "$2" "$3"; }

check_required() { # name, test-command, hint
  if eval "$2" >/dev/null 2>&1; then row "OK" "$1" ""; else row "MANQUANT ✗" "$1" "$3"; FAIL=1; fi
}
check_recommended() {
  if eval "$2" >/dev/null 2>&1; then row "OK" "$1" ""; else row "absent" "$1" "$3"; fi
}

echo "== ai-migration-kit préflight =="
echo "-- Requis --"
check_required "dotnet SDK" "command -v dotnet && dotnet --list-sdks | grep -qE '^(8|9|10)\.'" "installer un SDK .NET LTS"
check_required "git" "command -v git" "installer git"
check_required "python3" "command -v python3" "requis par les scripts du kit (inventaire, dashboard)"

echo "-- MCP (vérifiables hors session uniquement via la CLI claude) --"
if command -v claude >/dev/null 2>&1; then
  check_required "RoselineMCP" "claude mcp list 2>/dev/null | grep -qi roseline" "claude mcp add roseline … (obligatoire pour l'analyse C#)"
  check_recommended "context7 MCP" "claude mcp list 2>/dev/null | grep -qi context7" "recommandé : docs à jour des frameworks cibles"
else
  row "inconnu" "MCP (roseline, context7)" "CLI claude absente (normal en CI) — à confirmer en session"
fi

echo "-- Recommandé --"
check_recommended "gh CLI authentifié" "gh auth status" "publication GitHub (repos, Pages, CI)"
check_recommended "node / npx" "command -v npx" "Tailwind CSS (UI réécrites)"
check_recommended "Chrome headless" "command -v google-chrome || command -v chromium || test -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'" "vérification visuelle des rendus"

echo "-- Skills (indice disque ; la vérité est la liste de skills de la session) --"
for s in superpowers frontend-design; do
  check_recommended "skill $s" "/bin/ls \"$HOME/.claude/plugins/cache\" 2>/dev/null | grep -qi $s || /bin/ls \"$HOME/.claude/plugins/cache/claude-plugins-official\" 2>/dev/null | grep -qi $s" "installer le plugin $s"
done

echo
if [ "$FAIL" -eq 1 ]; then
  echo "PRÉFLIGHT ÉCHOUÉ — corriger les éléments REQUIS avant la phase 1."
  exit 1
fi
echo "Préflight OK — les éléments 'absent/inconnu' dégradent le pipeline de façon documentée, jamais silencieuse."
