#!/usr/bin/env bash
# tests/_lib.sh golden test.
#
# The helper exists so ten suites stop each carrying their own EXIT trap (#72). The invariant it
# centralises is one line — `local rc=$?` must be the FIRST statement in the handler — and getting
# it wrong turns a FAILING suite into a silent green. Every suite that sources this file now
# depends on that being right here, so it is driven for real rather than restated in a comment.
#
# What is asserted:
#   1. a failing suite still exits non-zero — the invariant, and the reason this file exists;
#   2. a passing suite exits zero, and its scratch directories are gone;
#   3. a registered guard that fails turns a PASSING suite red, and prints its own message;
#   4. a registered guard that passes leaves the status alone;
#   5. `kit_guard_samples_unchanged` catches a mutated samples/ and is silent otherwise;
#   6. `first_match`/`any_match` answer correctly, do NOT trip SIGPIPE with many matches (#48),
#      and tolerate a starting path that does not exist instead of aborting the caller (#98);
#   7. sourcing is loud when the helper is missing — a suite must never run unguarded;
#   8. no suite hand-rolls the EXIT trap again — the anti-recurrence check;
#   9. a suite that uses the helper takes its scratch from it, per occurrence.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
LIB="$KIT/tests/_lib.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

# Sourced for its functions, but WITHOUT kit_init — this suite must own its own EXIT trap, or it
# would be testing the handler while depending on it, and a broken handler could then hide its own
# failure. That is the one place in the kit where not using the helper is the point.
. "$LIB"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Run a throwaway suite that sources the real helper. $1 = body. Prints "<exit>|<output>".
run_suite() {
  local body="$1" f="$scratch/suite-$RANDOM.sh" out rc
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "cd '$KIT'"
    echo ". '$LIB'"
    echo 'kit_init "$PWD"'
    echo "$body"
  } > "$f"
  set +e
  out=$(bash "$f" 2>&1); rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

# ---------------------------------------------------------------------------
# 1. The invariant. A suite that fails must still report failure through the handler.
# ---------------------------------------------------------------------------
r=$(run_suite 's=$(kit_scratch); echo "SCRATCH:$s"; exit 3')
[ "${r%%|*}" = "3" ] || { echo "FAIL: a failing suite reported ${r%%|*}, not 3 — the handler ate the status"; exit 1; }
# …and the scratch dir is gone on the FAILURE path too. This is the whole advantage kit_scratch
# claims over an inline `rm -rf` at the end of a suite, and nothing else here drives it: section 2
# only inspects a passing run. Move the removal behind an `[ "$rc" -eq 0 ]` and every failing run
# of every converted suite would strand its tree, silently.
failed_dir=$(printf '%s' "${r#*|}" | sed -n 's/^SCRATCH://p')
[ -n "$failed_dir" ] || { echo "FAIL: could not read the scratch path back: ${r#*|}"; exit 1; }
[ -d "$failed_dir" ] && { echo "FAIL: a FAILING suite left its scratch dir behind: $failed_dir"; exit 1; }
# Backticks would be command substitution inside double quotes, so `set -e` would run as a command
# and the message would print with a blank subject — on the very assertion this file exists for.
r=$(run_suite 's=$(kit_scratch); false')
[ "${r%%|*}" = "1" ] || { echo 'FAIL: a `set -e` failure reported '"${r%%|*}"', not 1'; exit 1; }
echo "  [1] a failing suite exits non-zero, and its scratch dir is removed on that path too"

# ---------------------------------------------------------------------------
# 2. A passing suite exits 0 and leaves no scratch behind.
# ---------------------------------------------------------------------------
r=$(run_suite 'a=$(kit_scratch); b=$(kit_scratch); echo "$a" > "'"$scratch"'/dirs"; echo "$b" >> "'"$scratch"'/dirs"; :')
[ "${r%%|*}" = "0" ] || { echo "FAIL: a passing suite exited ${r%%|*}: ${r#*|}"; exit 1; }
while read -r d; do
  [ -d "$d" ] && { echo "FAIL: scratch dir survived the run: $d"; exit 1; }
done < "$scratch/dirs"
echo "  [2] a passing suite exits 0, and every scratch dir it took is removed"

# ---------------------------------------------------------------------------
# 3+4. A registered guard can fail a run that would otherwise have passed — and
#      must not disturb one that passes.
# ---------------------------------------------------------------------------
r=$(run_suite 'bad() { echo "FAIL: the extra assertion fired"; return 1; }; kit_guard bad; :')
[ "${r%%|*}" != "0" ] || { echo "FAIL: a failing guard left the run green: ${r#*|}"; exit 1; }
case "${r#*|}" in *"the extra assertion fired"*) : ;; *)
  echo "FAIL: the guard failed but its message never reached the output: ${r#*|}"; exit 1 ;;
esac
r=$(run_suite 'ok() { return 0; }; kit_guard ok; :')
[ "${r%%|*}" = "0" ] || { echo "FAIL: a passing guard changed the status to ${r%%|*}"; exit 1; }
echo "  [3-4] a registered guard can fail the run, and a passing one leaves it alone"

# ---------------------------------------------------------------------------
# 5. The samples/ guard: catches a mutation, silent otherwise.
#
#    Driven on a scratch git repo, never on the kit's own samples/ — a test that had to dirty the
#    real fixture to prove the guard works would be the very accident the guard prevents.
# ---------------------------------------------------------------------------
repo="$scratch/fixture-repo"
mkdir -p "$repo/samples/Frozen"
git init -q "$repo"
echo "original" > "$repo/samples/Frozen/file.txt"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init

check_guard() { ( set +e; . "$LIB"; KIT_LIB_ROOT="$repo"; kit_guard_samples_unchanged; echo "rc=$?" ); }
[ "$(check_guard | tail -1)" = "rc=0" ] || { echo "FAIL: the guard fired on an untouched fixture"; exit 1; }
echo "mutated" > "$repo/samples/Frozen/file.txt"
out=$(check_guard)
case "$out" in *"rc=1"*) : ;; *) echo "FAIL: the guard missed a mutated fixture: $out"; exit 1 ;; esac
case "$out" in *"samples/Frozen/file.txt"*) : ;; *)
  echo "FAIL: the guard fired but never named the file: $out"; exit 1 ;; esac
echo "  [5] the samples/ guard catches a mutation, names it, and is silent otherwise"

# ---------------------------------------------------------------------------
# 6. first_match / any_match: correct answers, no SIGPIPE at scale, no abort on a missing path.
#
#    The bug it replaces (#48) is a RACE — `find … | grep -q .` only returns 141 when find is still
#    writing as grep exits — so the negative case needs enough matches to provoke it, not one.
# ---------------------------------------------------------------------------
many="$scratch/many"
# One process, not 301. This suite is a prerequisite of ten others and pays this on every run.
mkdir -p "$many"/d{1..300}/__pycache__
if ! any_match "$many" -name '__pycache__' -type d; then
  echo "FAIL: any_match said 'nothing found' with 300 matches present — the SIGPIPE bug is back"
  exit 1
fi
empty="$scratch/empty"; mkdir -p "$empty"
if any_match "$empty" -name '__pycache__' -type d; then
  echo "FAIL: any_match found something in an empty tree"; exit 1
fi
# A path that does not exist must answer "no", not explode the caller under `set -e`.
if any_match "$scratch/does-not-exist" -name '*' 2>/dev/null; then
  echo "FAIL: any_match found something under a nonexistent path"; exit 1
fi

# first_match is the half any_match is now built on, so its own contract is driven HERE, beside the
# file that declares it, rather than only downstream in the heaviest suite in the matrix (#98).
# The `if !` IS the assertion, not a style choice: errexit is suppressed for an `if` condition, so a
# probe that reports failure is caught and named here instead of aborting this suite — which is
# precisely what it used to do at its two former call sites, taking their diagnostics down with it.
if ! first_hit=$(first_match "$scratch/does-not-exist" -name '*'); then
  echo "FAIL: first_match reported failure on a path that does not exist. A bare assignment from"
  echo "      it then aborts its caller under 'set -e', before the caller's own '…but it was"
  echo "      empty' diagnostic — the thing that explains the failure — can run."
  exit 1
fi
[ -z "$first_hit" ] || {
  echo "FAIL: first_match returned '$first_hit' under a path that does not exist"; exit 1; }
# …and it must actually return the match when there IS one, or the emptiness above proves nothing.
first_hit=$(first_match "$many" -name '__pycache__' -type d)
case "$first_hit" in
  "$many"/*/__pycache__) : ;;
  *) echo "FAIL: first_match returned '$first_hit', not a matching path under $many"; exit 1 ;;
esac
echo "  [6] first_match/any_match: correct at 300 matches, on empty, and on a missing path"

# ---------------------------------------------------------------------------
# 7. A suite whose helper is missing must FAIL, not run unguarded.
#
#    The opposite choice to skills/implement-issue/scripts/_assert-branch.sh, deliberately: those
#    guards fail open because a guard that cannot start must not block a commit. A test that cannot
#    load its assertions has nothing to offer, and a green one would be a lie.
# ---------------------------------------------------------------------------
f="$scratch/orphan.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo ". '$scratch/no-such-lib.sh'"
  echo 'echo "the suite kept going"'
} > "$f"
set +e
out=$(bash "$f" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: a suite with no helper exited 0: $out"; exit 1; }
case "$out" in *"the suite kept going"*)
  echo "FAIL: the suite ran its body without the helper: $out"; exit 1 ;; esac
echo "  [7] a missing helper stops the suite instead of letting it run unguarded"

# ---------------------------------------------------------------------------
# 8. No suite hand-rolls the trap again.
#
#    Extraction removes today's duplication; this is what stops tomorrow's. The count reached four
#    before anyone noticed, and the fourth (tests/renovate-config) was written by the same author
#    who had just read the other three — copy-paste is not a thing people decide to do.
#
#    Enumerated from the filesystem, never from a list in this file: a hardcoded roster is the
#    stale-inventory failure #45 filed, where the README named three suites and CI ran eight.
# ---------------------------------------------------------------------------
#    The patterns are UNANCHORED on purpose. The first version keyed on `^trap .* EXIT` and shipped
#    blind to the two live copies already in the tree — `tests/worktrees-ignored` and
#    `tests/release-title-gate` both write `WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT`, where
#    the trap is not at column 0. A guard whose whole job is catching a ninth copy could not see
#    the eighth.
offenders=""
for f in tests/*/test.sh; do
  # This suite is the documented exception — it owns its trap so it can test the shared one.
  [ "$f" = "tests/lib/test.sh" ] && continue
  if grep -qE '(^|[[:space:];])(cleanup|function cleanup)[[:space:]]*(\(\))?[[:space:]]*\{' "$f" \
     || grep -qE '(^|[[:space:];])trap[[:space:]].*EXIT' "$f"; then
    offenders="$offenders $f"
  fi
done
if [ -n "$offenders" ]; then
  echo "FAIL: these suites define their own EXIT trap instead of using tests/_lib.sh:$offenders"
  echo "      That is how the ten copies this helper replaced came to diverge — one lost the"
  echo "      samples/ check entirely. Use kit_init + kit_guard, or add a documented exception."
  exit 1
fi
echo "  [8] no suite hand-rolls the EXIT trap (tests/lib is the documented exception)"

# ---------------------------------------------------------------------------
# 9. A suite that USES the helper must take its scratch from it.
#
#    Membership is DECLARED BY BEHAVIOUR: a suite is audited when it CALLS kit_init, the thing that
#    actually arms the handler. It used to be inferred from whether the text of the file happened to
#    contain the string `_lib.sh` (#128). That was cheap while there was one shared file with one
#    obvious name; #51 added tests/_lib/py.sh, whose name differs by one character in a position
#    nobody reads, and the audit's reach then depended on spelling. Both halves were wrong, and both
#    were measured:
#
#      * appending the comment `# voir tests/_lib.sh` to a suite that manages its own scratch turned
#        THIS file red — four offenders — for a reason unrelated to the edit;
#      * tests/report-dashboard/test.sh deliberately avoided the substring, and sat in the audit's
#        blind spot while leaking a directory on every run. §9 exists to catch exactly that, and by
#        construction never could. That leak is fixed in the same change.
#
#    A suite may legitimately want py_module without the preamble, so sourcing tests/_lib/py.sh is
#    NOT membership — another distinction a filename match cannot draw.
#
#    Not every suite is a member. Those that manage their own scratch with an inline `rm -rf` are
#    out of scope here; the real difference, for whoever converts one, is that an inline `rm -rf` at
#    the end runs only on the success path, so a suite that fails midway leaves its directory
#    behind, whereas kit_scratch's is removed on every exit path. Worth doing; the audit does not
#    fail over it.
#
#    Within a member suite, though, a stray `mktemp -d` IS a leak — kit_cleanup only removes what
#    lives under its own parent directory.
#
#    Checked PER OCCURRENCE, not per file. Exempting a whole file the moment it mentions
#    `kit_scratch` anywhere is the opposite of the leak described above, and it had a live
#    instance: tests/audit-inventory ran `( cd "$(mktemp -d)" && … )` for its foreign-cwd case, a
#    directory outside KIT_LIB_TMP that nothing removes, in a suite this change converted.
#
#    Both halves are FUNCTIONS so the fixtures below can drive them directly. The real tree cannot
#    tell a right rule from a wrong one here: every live suite answers the same way under either,
#    which is precisely how a wrong rule survived (#128).

# Is $1 a member of the shared library — i.e. does it CALL kit_init?
#
# A call, never a mention. Whole-line comments are dropped first and the name must sit at a command
# position, so prose about the helper — this file is full of it, and so are the suites — cannot
# decide who gets audited. That is the defect class #128 is about, so reproducing it here would be
# a poor joke.
#
# Pipe-free on purpose. `grep -v … | grep -q …` lets the reader exit on the first hit; under the
# `set -o pipefail` at the top of this file the writer's SIGPIPE (141) becomes the pipeline's
# status, and "found it" reads back as "not a member" (#48). An audit is the last place that should
# go unnoticed: the failure mode is a silently empty roster, which looks exactly like a clean run.
suite_is_member() {
  local body
  body=$(grep -vE '^[[:space:]]*#' "$1" || true)
  grep -qE '(^|[[:space:];&|(){}])kit_init([[:space:]]|$)' <<<"$body"
}

# The `mktemp -d` calls in $1 that sit outside kit_scratch's tree, one "    <file>: <n>:<text>"
# line each. A `mktemp -d` rooted under a kit_scratch result is fine — that IS inside KIT_LIB_TMP.
stray_scratch() {
  local line
  while IFS= read -r line; do
    # `<n>:<text>` from grep -n; a comment line is prose about mktemp, not a call.
    case "${line#*:}" in [[:space:]]*\#*|\#*) continue ;; esac
    case "$line" in
      *kit_scratch*|*'$WORK'*|*'$scratch'*) continue ;;
      *) printf '%s\n' "    $1: $line" ;;
    esac
  done < <(grep -n 'mktemp -d' "$1" || true)
}

# --- the predicate, driven on fixtures rather than on the tree ---------------
# Each of these two fails under a substring rule, in OPPOSITE directions — which is what makes
# them worth writing: one is dragged in by prose, the other is invisible despite being a member.
mentions_only="$scratch/mentions-only.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# Prose naming tests/_lib.sh and kit_init, calling neither. A comment is not a call.'
  echo 'd=$(mktemp -d); rm -rf "$d"'
} > "$mentions_only"

# Sources the helper through a VARIABLE, so its filename never appears literally: a real member
# that a substring rule cannot see. That is the shape the leak §9 exists to catch was hiding in.
calls_it="$scratch/calls-kit-init.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'lib="$KIT/tests/$helper"'
  echo '. "$lib"'
  echo 'kit_init "$PWD"'
  echo 'd=$(mktemp -d)'
} > "$calls_it"

uses_helper="$scratch/uses-kit-scratch.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'kit_init "$PWD"'
  echo 'd=$(kit_scratch)'
} > "$uses_helper"

if suite_is_member "$mentions_only"; then
  echo "FAIL: a suite that only MENTIONS the shared helper was enrolled in the scratch audit."
  echo "      Membership must follow a kit_init CALL; a filename in the text is not a declaration,"
  echo "      and keying on one turns an unrelated comment into a red run."
  exit 1
fi
if ! suite_is_member "$calls_it"; then
  echo "FAIL: a suite that CALLS kit_init was left out of the scratch audit — the blind spot a"
  echo "      leaking directory sat in for as long as its file avoided spelling the helper's name."
  exit 1
fi
[ -n "$(stray_scratch "$calls_it")" ] || {
  echo "FAIL: the per-occurrence audit missed a bare 'mktemp -d'"; exit 1; }
[ -z "$(stray_scratch "$uses_helper")" ] || {
  echo "FAIL: the per-occurrence audit flagged a directory taken from kit_scratch"; exit 1; }

# --- and now the tree -------------------------------------------------------
leaky=""
for f in tests/*/test.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  suite_is_member "$f" || continue
  # Command substitution eats trailing newlines, so the separator is added here rather than
  # relying on one surviving the capture — otherwise two offenders would print on one line.
  hits=$(stray_scratch "$f")
  [ -n "$hits" ] && leaky="$leaky
$hits"
done
if [ -n "$leaky" ]; then
  echo "FAIL: these mktemp -d calls sit outside kit_scratch's tree, so kit_cleanup cannot remove"
  echo "      what they take:$leaky"
  exit 1
fi
echo "  [9] a suite that uses the helper takes its scratch from it"

echo "tests/_lib.sh golden test OK"
