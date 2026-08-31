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
#   F. a hand-off the table declares that ARCHITECTURE.md never draws               -> REFUSE, naming
#      the side that lacks it
#   G. a dashed edge ARCHITECTURE.md draws that the table never declares            -> REFUSE, naming
#      the other side
#   H. a SOLID edge between two skills with no row for it                           -> exit 0. Solid
#      means "invokes", not "hand-off": `MP --> CI` must not collide with merge-pr's own row, which
#      points at implement-issue
#   L. no ARCHITECTURE.md at all                                                    -> exit 2, NOT 1
#   M. a Next command that resolves through commands/<name>.md                      -> exit 0
#   N. a dashed edge to a declared node that is not a skill                         -> exit 0
#   O. the table's rows written inside a ``` fence (so there is no live table)      -> exit 2
#   P. an EMPTY hand-off table FOLLOWED by another table                            -> exit 2, never
#      the next table absorbed as hand-off rows
#   Q. a row naming no `/command` and not saying `—`                                -> REFUSE. This
#      is the whole point: a hand-off nobody wrote down must not look like a skill that has none
#   R. a dashed edge whose node ids are declared INLINE on the edge line            -> seen, not
#      silently dropped
#   S. a `%%`-commented dashed edge                                                 -> exit 0
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

# --------------------------------------------- F. the table declares an edge the graph never draws
echo "F. a hand-off ARCHITECTURE.md does not draw"
F="$WORK/f"; scaffold "$F"
write_arch "$F"
expect "the missing dashed edge names ARCHITECTURE.md as the side lacking it" 1 "$F" \
  "REFUSE" "alpha" "beta" "ARCHITECTURE.md"

# --------------------------------------------- G. the graph draws an edge the table never declares
echo "G. a dashed edge the table never declares"
F="$WORK/g"; scaffold "$F"
write_arch "$F" '    A -. "next step: /beta" .-> B' '    B -. "next step: /alpha" .-> A'
expect "the surplus dashed edge names the table as the side lacking it" 1 "$F" \
  "REFUSE" "beta" "alpha" "recap.md"

# ------------------------------------------------------------ H. a solid edge is not a hand-off
echo "H. a solid edge between two skills with no row for it"
F="$WORK/h"; scaffold "$F"
write_arch "$F" '    A -. "next step: /beta" .-> B' '    B -- "files deferred work" --> A'
expect "solid edges are invocations and are ignored" 0 "$F"

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

# --------------------------------------------------------- L. no ARCHITECTURE.md -> no verdict
echo "L. --repo with no ARCHITECTURE.md"
F="$WORK/l"; scaffold "$F"; rm -f "$F/ARCHITECTURE.md"
expect "a missing graph is a plumbing error, not a refusal" 2 "$F" "ERR"

# ------------------------------------------------ M. a next command that resolves via commands/
echo "M. a Next command that resolves through commands/<name>.md"
F="$WORK/m"; scaffold "$F"
printf 'Invoke the `beta` skill.\n' > "$F/commands/gamma.md"
write_table "$F" \
  '| `alpha` | something happened | `/gamma` |' \
  '| `beta` | something else happened | `—` |'
expect "the command's skill is what the hand-off lands on" 0 "$F"

# ------------------------------------------------------- N. an edge to a node that is not a skill
echo "N. a dashed edge to a declared non-skill node"
F="$WORK/n"; scaffold "$F"
write_arch "$F" '    A -. "next step: /beta" .-> B' '    A -. "see also" .-> X'
expect "an edge that does not join two skills is not a hand-off" 0 "$F"

# ------------------------------------------------------------ O. the table hidden in a code fence
echo "O. the table's rows sit inside a code fence"
F="$WORK/o"; scaffold "$F"
{
  echo '# Recap'
  echo
  echo 'The shape, as an example rather than as the live table:'
  echo
  echo '```markdown'
  echo '| Skill | Ends with | Next command |'
  echo '|---|---|---|'
  echo '| `alpha` | something happened | `/beta` |'
  echo '```'
} > "$F/skills/_shared/recap.md"
expect "a fenced example is not the hand-off table" 2 "$F" "ERR"

# ------------------------------------------------- P. an empty table followed by a second table
echo "P. an empty hand-off table with another table after it"
F="$WORK/p"; scaffold "$F"
{
  echo '# Recap'
  echo
  echo '| Skill | Ends with | Next command |'
  echo '|---|---|---|'
  echo
  echo '| Something | else | entirely |'
  echo '|---|---|---|'
  echo '| `alpha` | a row of a DIFFERENT table | `/beta` |'
} > "$F/skills/_shared/recap.md"
expect "the next table is not absorbed as hand-off rows" 2 "$F" "ERR"

# ----------------------------------------------------------- Q. a cell that says nothing at all
echo "Q. a row naming no command and not saying it is terminal"
F="$WORK/q"; scaffold "$F"
write_arch "$F"
write_table "$F" \
  '| `alpha` | something happened | still deciding |' \
  '| `beta` | something else happened | `—` |'
expect "an undeclared hand-off is refused, not read as terminal" 1 "$F" "REFUSE" "alpha"

# ------------------------------------------------------- R. node ids declared on the edge line
echo "R. a dashed edge whose nodes are declared inline"
F="$WORK/r"; scaffold "$F"
write_arch "$F" \
  '    A[alpha] -. "next step: /beta" .-> B[beta]' \
  '    B[beta] -. "next step: /alpha" .-> A[alpha]'
expect "an inline-declared edge is resolved, not dropped" 1 "$F" "REFUSE" "beta" "alpha" "recap.md"

# ------------------------------------------------------------------ S. a commented-out edge
echo "S. a %%-commented dashed edge"
F="$WORK/s"; scaffold "$F"
write_arch "$F" '    A -. "next step: /beta" .-> B' '    %% B -. "next step: /alpha" .-> A'
expect "a mermaid comment is not an edge" 0 "$F"

# ------------------------------------------------------------------------------------------ verdict
echo
if [ "$fails" -eq 0 ]; then
  echo "PASS — recap wiring guard behaves on every case"
  exit 0
fi
echo "FAIL — $fails case(s) failed"
exit 1
