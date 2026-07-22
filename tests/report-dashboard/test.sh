#!/usr/bin/env bash
# Test golden du générateur de rapport (règle 7 : outil obligatoire → test obligatoire).
# Fixture report.json + cobertura → HTML, puis assertions sur le contenu produit.
set -euo pipefail
# Lancé depuis la racine du repo : prouve que les chemins du JSON (cobertura, capture)
# se résolvent relativement au JSON, pas au répertoire courant.
cd "$(dirname "$0")/../.."

out="$(mktemp -d)/report.html"
python3 scripts/report-dashboard.py tests/report-dashboard/fixture-report.json -o "$out" 2>/dev/null

assert() { grep -qF "$1" "$out" || { echo "ÉCHEC : « $1 » absent du HTML généré ($out)"; exit 1; }; }
refuse() { ! grep -qF "$1" "$out" || { echo "ÉCHEC : « $1 » présent alors qu'il devrait être exclu ($out)"; exit 1; }; }

assert '<title>Migration FixtureApp — rapport exécutif</title>'
assert 'Migration de démonstration'
assert '✓ Vérifié'
assert 'migration/2026-01-01'
assert 'Déployer avec fallback SPA'
# La couverture vient du cobertura (calculée), jamais recopiée du JSON :
assert 'Engine : 3/4 lignes couvertes'
assert 'Wrapper : 1/2 lignes couvertes'
assert 'Global : 85 % lignes · 70 % branches'
# Le filtre d'exclusion fonctionne :
refuse 'ExcludedWeb'
# Autonome et thémé : pas de ressource externe, thème sombre présent
refuse 'http://'
refuse 'https://'
assert 'data-theme="dark"'

echo "OK test golden report-dashboard ($out)"
