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
#    Scoped to the suites that source `_lib.sh`, deliberately — not to every suite that calls
#    `mktemp -d`. Five others (preflight, release-title-gate, repo-profile, report-dashboard,
#    worktrees-ignored) manage their own with an inline `rm -rf`, and measured, they do not leak.
#    Converting them is tidying, not a fix, and #72 is about the duplicated PREAMBLE rather than
#    about every temp directory. Reproduce that measurement — a number kept without the command
#    that produced it is not a measurement:
#
#      before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' | wc -l)
#      for s in preflight repo-profile worktrees-ignored; do bash "tests/$s/test.sh" >/dev/null; done
#      after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' | wc -l)
#      echo "$before -> $after"      # observed 234 -> 234 when this was written
#
#    The real difference, for whoever does convert them: an inline `rm -rf` at the end runs only on
#    the success path, so a suite that fails midway leaves its directory behind. kit_scratch's is
#    removed on every exit path. Worth doing; not worth failing this check over.
#
#    Within a converted suite, though, a stray `mktemp -d` IS a leak — kit_cleanup only removes
#    what lives under its own parent directory.
# ---------------------------------------------------------------------------
#    Checked PER OCCURRENCE, not per file. Exempting a whole file the moment it mentions
#    `kit_scratch` anywhere is the opposite of the leak described above, and it had a live
#    instance: tests/audit-inventory ran `( cd "$(mktemp -d)" && … )` for its foreign-cwd case, a
#    directory outside KIT_LIB_TMP that nothing removes, in a suite this change converted.
leaky=""
for f in tests/*/test.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  grep -q '_lib\.sh' "$f" || continue
  # A `mktemp -d` rooted under a kit_scratch result is fine — that IS inside KIT_LIB_TMP.
  while IFS= read -r line; do
    # `<n>:<text>` from grep -n; a comment line is prose about mktemp, not a call.
    case "${line#*:}" in [[:space:]]*\#*|\#*) continue ;; esac
    case "$line" in
      *kit_scratch*|*'$WORK'*|*'$scratch'*) continue ;;
      *) leaky="$leaky
    $f: $line" ;;
    esac
  done < <(grep -n 'mktemp -d' "$f")
done
if [ -n "$leaky" ]; then
  echo "FAIL: these mktemp -d calls sit outside kit_scratch's tree, so kit_cleanup cannot remove"
  echo "      what they take:$leaky"
  exit 1
fi
echo "  [9] a suite that uses the helper takes its scratch from it"

echo "tests/_lib.sh golden test OK"
