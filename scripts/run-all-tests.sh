#!/usr/bin/env bash
# run-all-tests.sh — one command that verifies what CI's `kit` job verifies (#170).
#
# The documented alternative — `for t in tests/*/test.sh; do "$t" || break; done` — verifies
# STRICTLY LESS than CI: `.github/workflows/ci.yml`'s `kit` job also runs a dozen structural gates
# (worktrees-ignored, ci-wiring-check, parse-sweep, pinned-literals-check, JSON/YAML validity, the
# fixture build...) that are not suites at all and therefore never appear in that loop. Passing the
# loop is not passing CI, and nothing said so.
#
# Exit 2 exists because of a measured incident: on a machine missing PyYAML — a dependency CI
# installs in a workflow step instead of declaring — the loop above and the structural gates each
# reported the absence in their own vocabulary, one of them (tests/ci-wiring) as 14 lines accusing
# its own fixtures of being buggy. Forty-plus failing lines, all one missing prerequisite. So this
# script checks prerequisites FIRST, via scripts/preflight.sh (which requirements.json now declares
# PyYAML to, #170 Task 1), and refuses with a distinct exit code and message before running anything
# whose failure would otherwise be misread as a real regression.
#
# Usage: scripts/run-all-tests.sh [--quick] [--with-network] [--list]
#   --quick        skip the dotnet fixture build/test (samples/LegacyShop) — everything else runs.
#   --with-network adds the renovate.json acceptance gate, which shells out to `npx` and needs
#                  network access; skipped by default so this script also runs offline.
#   --list         print the plan (one `gate <cmd>` / `suite <path>` line per item) and exit 0.
#                  Does not touch prerequisites, so it is cheap and always available — this is what
#                  tests/run-all-tests/test.sh's anti-drift case relies on.
#
# Exit codes:
#   0  everything CI checks passed locally (or --list printed the plan)
#   1  a real failure — the failing item is named, with its last ~25 lines of output
#   2  a prerequisite is missing — nothing was judged, see scripts/preflight.sh's own output
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(cd "$HERE/.." && pwd)"
cd "$KIT_DIR"

QUICK=0
WITH_NETWORK=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --with-network) WITH_NETWORK=1 ;;
    --list) LIST=1 ;;
    *) printf 'run-all-tests.sh: unknown flag %s\n' "$arg" >&2; exit 1 ;;
  esac
done

# --- The plan: two ordered lists, transcribed from .github/workflows/ci.yml's `kit` job in step
# order. A gate's displayed name is its command's OWN first line — never retyped separately — so
# the label shown by --list and the command actually executed can never drift from each other.
GATE_NAMES=()
GATE_CMDS=()
add_gate() {
  local cmd="$1" name
  name=$(printf '%s\n' "$cmd" | head -n 1)
  GATE_NAMES+=("$name")
  GATE_CMDS+=("$cmd")
}

SUITE_PATHS=()
add_suite() { SUITE_PATHS+=("$1"); }

DOTNET_CMD="dotnet test samples/LegacyShop --nologo"

# 1–4: the cheap structural gates, ahead of every suite that sources tests/_lib.sh.
add_gate "./scripts/worktrees-ignored.sh"
add_gate "python3 scripts/ci-wiring-check.py"
add_gate "./scripts/parse-sweep.sh"
add_gate "python3 scripts/pinned-literals-check.py"

add_suite "tests/lib/test.sh"
add_suite "tests/py-module/test.sh"
add_suite "tests/ci-wiring/test.sh"
add_suite "tests/parse-sweep/test.sh"
add_suite "tests/pinned-literals/test.sh"

# 5: the frozen fixture — must stay green AND legacy. Skipped by --quick.
[ "$QUICK" -eq 1 ] || add_gate "$DOTNET_CMD"

add_suite "tests/xunit-v3/test.sh"

# 6: JSON manifests are valid JSON.
add_gate "$(cat <<'EOF'
python3 -m json.tool .claude-plugin/plugin.json > /dev/null
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null
python3 -m json.tool requirements.json > /dev/null
python3 -m json.tool release-please-config.json > /dev/null
python3 -m json.tool .release-please-manifest.json > /dev/null
python3 -m json.tool renovate.json > /dev/null
EOF
)"

# 7: renovate.json is a config Renovate actually accepts — needs network (npx). Opt-in only.
if [ "$WITH_NETWORK" -eq 1 ]; then
  add_gate "$(cat <<'EOF'
export RENOVATE_VALIDATOR_VERSION=44.29.4
validator_output=$(mktemp)
set +e
npx --yes --package "renovate@$RENOVATE_VALIDATOR_VERSION" -- \
  renovate-config-validator --no-global --strict renovate.json 2>&1 | tee "$validator_output"
validator_status=${PIPESTATUS[0]}
set -e
if grep -q 'RE2 not usable' "$validator_output"; then
  if [ "$validator_status" -eq 0 ]; then
    echo "::error::renovate-config-validator's RE2 engine did not load, so this run validated renovate.json on JS RegExp instead of RE2 — the validator's own success is only trustworthy on RE2, and a matchStrings pattern only RE2 would reject could have passed here silently. See #130."
  else
    echo "::error::renovate-config-validator's RE2 engine did not load, on top of it already rejecting renovate.json for a reason of its own (see the output above) — fix that failure first; regex validation cannot be trusted on JS RegExp alone until RE2 loads. See #130."
  fi
  exit 1
fi
exit "$validator_status"
EOF
)"
fi

add_suite "tests/renovate-config/test.sh"

# 8: plugin.json's version must match the release-please manifest.
add_gate "$(cat <<'EOF'
plugin=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])")
manifest=$(python3 -c "import json; print(json.load(open('.release-please-manifest.json'))['.'])")
if [ "$plugin" != "$manifest" ]; then
  echo "plugin.json is $plugin but .release-please-manifest.json is $manifest"; exit 1
fi
EOF
)"

# 9: every legacy-upgrade phase guide names its RoselineMCP tools.
add_gate "$(cat <<'EOF'
bad=$(grep -L 'analyze_solution\|list_diagnostics\|apply_fixes\|edit_member\|rename_symbol\|find_references\|get_call_graph\|get_symbol_at_position\|search_symbols' skills/legacy-upgrade/references/phase-*.md || true)
if [ -n "$bad" ]; then echo "Phase guides missing tool names: $bad"; exit 1; fi
EOF
)"

# 10–11: preflight.sh exercised as a regular gate (plain and --json), mirroring ci.yml's own two
# steps. This is IN ADDITION to the exit-2 bootstrap below — that bootstrap is new behaviour this
# script adds on top of what CI does; CI never runs preflight before its other steps, because a
# GitHub-hosted runner already carries every declared prerequisite. Running preflight three times
# in a full local pass (bootstrap + these two) is deliberate fidelity to ci.yml, not an oversight.
add_gate "./scripts/preflight.sh"
add_gate "./scripts/preflight.sh --json | python3 -m json.tool > /dev/null"

add_suite "tests/preflight/test.sh"
add_suite "tests/repo-profile/test.sh"
add_suite "tests/repo-setup/test.sh"

# 12: kit scripts run correctly from a foreign working directory (plugin-install simulation).
add_gate "$(cat <<'EOF'
KIT="$PWD"
cd "$(mktemp -d)"
bash "$KIT/scripts/preflight.sh" --json | python3 -m json.tool > /dev/null
bash "$KIT/scripts/audit-inventory.sh" "$KIT/samples/LegacyShop" | python3 -m json.tool > /dev/null
python3 "$KIT/scripts/followups.py" "$KIT/tests/followups/fixture-a" --backlog "$KIT/docs/backlog.md" > /dev/null
out=$(bash "$KIT/skills/get-repo-profile/scripts/repo-profile.sh" show "$KIT")
[ "$out" = "$(cat "$KIT/.claude/skills/repo-profile.md")" ]
rc=0
out=$(bash "$KIT/skills/get-repo-profile/scripts/repo-profile.sh" show "$PWD") || rc=$?
[ "$rc" = 3 ] && [ "$out" = "NO_PROFILE" ]
for g in guarded-commit guarded-push guarded-merge; do
  script="$KIT/skills/implement-issue/scripts/$g.sh"
  bash "$script" --help | grep -q 'Exit codes:'
  if bash "$script" -C "$PWD" no-such-branch -- -m x 2>/dev/null; then
    echo "$g.sh accepted a path that is not a git repository"; exit 1
  fi
done
EOF
)"

# 13: skill frontmatter conforms to the guide (requirements.json cross-check included).
add_gate "python3 tests/skills/check-frontmatter.py"

add_suite "tests/skills/test.sh"

# 14: the inventory script runs and emits valid JSON.
add_gate "./scripts/audit-inventory.sh samples/LegacyShop | python3 -m json.tool > /dev/null"

add_suite "tests/audit-inventory/test.sh"

# 15: every template under templates/ is valid YAML.
add_gate "python3 -c \"import yaml, glob; [yaml.safe_load(open(f)) for f in glob.glob('templates/**/*.yml', recursive=True)]\""

add_suite "tests/ci-template/test.sh"
add_suite "tests/report-dashboard/test.sh"
add_suite "tests/followups/test.sh"
add_suite "tests/tick-plan/test.sh"
add_suite "tests/guarded-git/test.sh"
add_suite "tests/merge-gate/test.sh"
add_suite "tests/merge-freshness/test.sh"
add_suite "tests/guarded-pr-merge/test.sh"
add_suite "tests/remote-branch-teardown/test.sh"
add_suite "tests/release-title-gate/test.sh"
add_suite "tests/worktrees-ignored/test.sh"
add_suite "tests/roseline/test.sh"
add_suite "tests/auto-dev-never-wait/test.sh"
add_suite "tests/survey/test.sh"

# 16: the contrast checker itself, pass AND fail paths.
add_gate "$(cat <<'EOF'
python3 scripts/contrast-check.py "#000000:#ffffff:sanité"
if python3 scripts/contrast-check.py "#777777:#888888" >/dev/null 2>&1; then
  echo "contrast-check aurait dû échouer sur une paire illisible"; exit 1
fi
EOF
)"

# --- One-line notes for anything the flags left out of the plan above, naming the flag that would
# bring it back in. Printed in both --list and normal-run mode, so the plan is never silently
# smaller than the full CI job without saying why.
[ "$QUICK" -eq 1 ] && printf 'note: skipping "%s" — omit --quick to include it\n' "$DOTNET_CMD" >&2
[ "$WITH_NETWORK" -eq 1 ] || printf 'note: skipping the network-dependent renovate.json acceptance gate — pass --with-network to include it\n' >&2

# --- --list: print the plan and exit 0. No prerequisite check — this must stay cheap and always
# available, since tests/run-all-tests/test.sh's anti-drift case calls it on every run.
if [ "$LIST" -eq 1 ]; then
  for name in "${GATE_NAMES[@]}"; do
    printf 'gate %s\n' "$name"
  done
  for path in "${SUITE_PATHS[@]}"; do
    printf 'suite %s\n' "$path"
  done
  exit 0
fi

# --- The prerequisite guard: refuse before any gate or suite runs. A missing prerequisite is not a
# test failure and must never be reported as one (the incident this whole script exists for).
if ! preflight_out=$("$HERE/preflight.sh" 2>&1); then
  printf 'PREREQUISITE — nothing was judged. %s\n' "$HERE/preflight.sh reported:" >&2
  printf '%s\n' "$preflight_out" >&2
  exit 2
fi

# --- Run every gate, then every suite, in plan order. Fail-fast: the first failure stops the run
# and decides the exit code, the same way a GitHub Actions job stops at its first red step.
run_item() {
  local name="$1" cmd="$2" out rc
  out=$(bash -c "$cmd" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok   %s\n' "$name"
    return 0
  fi
  printf 'FAIL %s\n' "$name"
  printf '%s\n' "$out" | tail -n 25
  return 1
}

gate_count=0
for i in "${!GATE_NAMES[@]}"; do
  gate_count=$((gate_count + 1))
  run_item "${GATE_NAMES[$i]}" "${GATE_CMDS[$i]}" || exit 1
done

suite_count=0
for path in "${SUITE_PATHS[@]}"; do
  suite_count=$((suite_count + 1))
  run_item "$path" "./$path" || exit 1
done

printf 'ok  %d gates, %d suites\n' "$gate_count" "$suite_count"
exit 0
