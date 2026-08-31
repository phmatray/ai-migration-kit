#!/usr/bin/env bash
# Golden test for scripts/recap-wiring-check.py — the guard that the kit's closing recap has ONE
# home, that every skill links it, and that ARCHITECTURE.md's dashed hand-off edges say the same
# thing as the hand-off table (#175).
#
# What this suite guards:
#   A. the happy path on THIS repo — the real skills/, the real ARCHITECTURE.md    -> exit 0
#   B. a table row naming a skill with no skills/<name>/ directory                 -> REFUSE, named
#   C. a real skill directory with no row in the table                             -> REFUSE, named
#   D. --repo pointing at a tree with no _shared/recap.md                          -> exit 2, NOT 1
#   E. a skill whose SKILL.md never links _shared/recap.md                         -> REFUSE, named
#   I. a Next-command cell naming a command that resolves to no skill               -> REFUSE
#   J. a duplicate row for one skill                                                -> REFUSE
#   K. a table with no rows at all                                                  -> exit 2, never
#      a vacuous "all wired"
#
# The refusal cases are the point: exit 1 is a VERDICT and exit 2 is the absence of one, and a guard
# that cannot tell them apart is the "silent green" shape #45 and #72 were written for. D and K are
# the two that must never come back as 1.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/recap-wiring-check.py"

# Scratch dir and EXIT trap come from the shared preamble (#72). Sourced via $REPO, never $PWD:
# this suite does not cd, so it runs from anywhere.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
# kit_guard decision, stated rather than left ambiguous: this suite builds its fixtures under
# kit_scratch and reads samples/ never — but registering the check costs nothing and "forgot to
# call it" must not look like "decided it does not apply".
kit_guard kit_guard_samples_unchanged

WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------- fixture scaffolding
#
# The fixtures are SYNTHETIC — a two-skill kit — rather than a copy of the real tree. A mutated copy
# of the real repo would refuse for whichever defect the mutation happened to introduce FIRST, which
# reads as a pass for the case under test; a two-skill fixture has exactly the defect it was built
# with. Case A is the only one that looks at the real repo, and it is the only one asserting a pass.

# scaffold <dir> — a minimal, CONSISTENT kit: two skills, both linking the reference, one hand-off
# edge (alpha -> beta) present in both the table and the graph. Every refusal fixture is this tree
# with exactly one thing broken.
scaffold() {
  local d="$1"
  mkdir -p "$d/skills/_shared" "$d/skills/alpha" "$d/skills/beta" "$d/commands"
  cat > "$d/skills/alpha/SKILL.md" <<'EOF'
# alpha
## Recap
Close with the shared shape — [`../_shared/recap.md`](../_shared/recap.md).
EOF
  cat > "$d/skills/beta/SKILL.md" <<'EOF'
# beta
## Recap
Close with the shared shape — [`../_shared/recap.md`](../_shared/recap.md).
EOF
  write_table "$d" \
    '| `alpha` | something happened | `/beta` |' \
    '| `beta` | something else happened | `—` |'
  write_arch "$d" '    A -. "next step: /beta" .-> B'
}

# write_table <dir> <row>… — replace the fixture's recap.md with exactly these rows.
write_table() {
  local d="$1"; shift
  {
    echo '# Recap'
    echo
    echo '| Skill | Ends with | Next command |'
    echo '|---|---|---|'
    local row
    for row in "$@"; do echo "$row"; done
  } > "$d/skills/_shared/recap.md"
}

# write_arch <dir> <edge-line>… — replace the fixture's ARCHITECTURE.md, keeping the node
# declarations the guard resolves ids through.
write_arch() {
  local d="$1"; shift
  {
    echo '# Architecture'
    echo
    echo '## Skill call graph — who calls whom'
    echo
    echo '```mermaid'
    echo 'graph TD'
    echo '    A[alpha]'
    echo '    B[beta]'
    echo '    X["not a skill"]'
    local edge
    for edge in "$@"; do echo "$edge"; done
    echo '```'
  } > "$d/ARCHITECTURE.md"
}

# run_check <repo> — echo the guard's combined output, return its status.
run_check() {
  python3 "$CHECK" --repo "$1" 2>&1
}

# expect <label> <expected-status> <repo> [needle…]
expect() {
  local label="$1" want="$2" repo="$3"; shift 3
  local out status
  out=$(run_check "$repo"); status=$?
  if [ "$status" -ne "$want" ]; then
    bad "$label — expected exit $want, got $status"
    printf '%s\n' "$out" | sed 's/^/          /'
    return 1
  fi
  local needle
  for needle in "$@"; do
    case "$out" in
      *"$needle"*) ;;
      *) bad "$label — exit $want as expected, but the output never mentions '$needle'"
         printf '%s\n' "$out" | sed 's/^/          /'
         return 1 ;;
    esac
  done
  ok "$label"
  return 0
}

# ------------------------------------------------------------------- A. the real repo is coherent
echo "A. the real repo"
expect "the shipped skills, table and ARCHITECTURE.md agree" 0 "$REPO"

# ------------------------------------------------------------ B. a row naming a nonexistent skill
echo "B. a table row for a skill that does not exist"
F="$WORK/b"; scaffold "$F"
write_table "$F" \
  '| `alpha` | something happened | `/beta` |' \
  '| `beta` | something else happened | `—` |' \
  '| `ghost` | never existed | `—` |'
expect "a row for skills/ghost/ is refused, naming it" 1 "$F" "REFUSE" "ghost"

# --------------------------------------------------------------- C. a real skill with no row
echo "C. a skill directory with no hand-off row"
F="$WORK/c"; scaffold "$F"
write_table "$F" '| `alpha` | something happened | `—` |'
write_arch "$F"
expect "the row-less skill is named" 1 "$F" "REFUSE" "beta"

# ----------------------------------------------------------- D. no recap.md at all -> no verdict
echo "D. --repo with no _shared/recap.md"
F="$WORK/d"; scaffold "$F"; rm -f "$F/skills/_shared/recap.md"
expect "a missing reference is a plumbing error, not a refusal" 2 "$F" "ERR"

# ------------------------------------------------------------ E. a skill that never links it
echo "E. a skill whose SKILL.md does not link the reference"
F="$WORK/e"; scaffold "$F"
cat > "$F/skills/beta/SKILL.md" <<'EOF'
# beta
## Recap
I invented my own ending and linked nothing.
EOF
expect "the unlinked skill is named" 1 "$F" "REFUSE" "beta"

# ------------------------------------------------------- I. a next command that resolves nowhere
echo "I. a Next command naming something that is not a skill or a command"
F="$WORK/i"; scaffold "$F"
write_table "$F" \
  '| `alpha` | something happened | `/nowhere` |' \
  '| `beta` | something else happened | `—` |'
expect "an unresolvable next command is refused, naming it" 1 "$F" "REFUSE" "/nowhere"

# ------------------------------------------------------------------------ J. two rows for one skill
echo "J. a duplicate row"
F="$WORK/j"; scaffold "$F"
write_table "$F" \
  '| `alpha` | something happened | `/beta` |' \
  '| `alpha` | said twice | `/beta` |' \
  '| `beta` | something else happened | `—` |'
expect "a skill with two rows is refused, naming it" 1 "$F" "REFUSE" "alpha"

# ------------------------------------------------------------- K. a table with no rows -> no verdict
echo "K. a reference whose table has no rows"
F="$WORK/k"; scaffold "$F"
write_table "$F"
expect "an empty table is a plumbing error, never a vacuous pass" 2 "$F" "ERR"

# ------------------------------------------------------------------------------------------ verdict
echo
if [ "$fails" -eq 0 ]; then
  echo "PASS — recap wiring guard behaves on every case"
  exit 0
fi
echo "FAIL — $fails case(s) failed"
exit 1
