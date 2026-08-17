#!/usr/bin/env bash
# tests/_lib/py.sh golden test — the kit's shared importlib loader (#51).
#
# The helper exists so that every suite loading a kit script carries PYTHONDONTWRITEBYTECODE=1
# without anyone having to remember it (#42 for one file, #51 for the kit). Two things therefore
# have to be driven for real rather than restated in a comment: the prefix genuinely prevents the
# bytecode directory, and the helper REFUSES the shapes that would otherwise assert nothing.
#
# What is asserted:
#   1. the happy path — the target is bound as `mod` and the body actually runs;
#   2. argv indices — argv[1] is the script, argv[2:] are the caller's args;
#   3. an EMPTY body is refused, not run as a no-op (the /dev/null-stdin trap under CI);
#   4. a whitespace-only body is refused too — `strip()`, not `if body`;
#   5. a missing script path is refused with a usage line, not an IndexError traceback;
#   6. an unloadable path is refused by name;
#   7. loading through the helper leaves NO __pycache__ beside the target;
#   8. the control: the same load WITHOUT the prefix DOES leave one — so section 7 is a
#      measurement rather than a check that cannot fail.
#
# ⚠️ This file must never contain the loader literal that tests/xunit-v3/test.sh section 8 counts
# (`spec` + `_from_file_location`, written apart here on purpose). That assertion greps tests/ and
# scripts/ for it and requires exactly ONE across the kit, in tests/_lib/py.sh. A copy in this
# file — even inside a comment, since the grep is not comment-aware — would fail the xunit suite.
# Section 8's control below therefore reaches for sys.path + import, which writes bytecode without
# spelling the pattern.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
. "$KIT/tests/_lib/py.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib/py.sh — that is the file under test"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

# A throwaway module to load, so the assertions are about the LOADER and not about whichever kit
# script happened to be handy. It also gives section 7 a directory of its own to inspect.
scratch=$(kit_scratch)
target="$scratch/subject.py"
cat > "$target" <<'PY'
MARKER = "loaded-by-py-module"


def double(n):
    return n * 2
PY

# Run something expected to FAIL, capturing status and output without tripping `set -e`.
expect_fail() {
  local label="$1"; shift
  local out rc
  set +e
  out=$("$@" 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $label — expected a refusal, got exit 0. Output:"
    echo "$out"
    exit 1
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 1. The happy path: `mod` is bound to the loaded module, and the body runs.
# ---------------------------------------------------------------------------
got=$(py_module "$target" <<'PY'
assert mod.MARKER == "loaded-by-py-module", mod.MARKER
print(mod.double(21))
PY
)
[ "$got" = "42" ] || { echo "FAIL: the body did not run through the loaded module (got '$got')"; exit 1; }
echo "  [1] the target is bound as \`mod\` and the body runs"

# ---------------------------------------------------------------------------
# 2. argv indices — the contract the port of tests/report-dashboard depended on.
#
#    argv[1] is the script the helper loaded, argv[2:] the caller's own arguments. A body that
#    reads argv[1] expecting its FIRST argument would be off by one, silently.
# ---------------------------------------------------------------------------
got=$(py_module "$target" alpha beta <<'PY'
import sys
assert sys.argv[1].endswith("subject.py"), sys.argv[1]
print(",".join(sys.argv[2:]))
PY
)
[ "$got" = "alpha,beta" ] || { echo "FAIL: argv[2:] is not the caller's args (got '$got')"; exit 1; }
echo "  [2] argv[1] is the script, argv[2:] are the caller's args"

# ---------------------------------------------------------------------------
# 3. An empty body is REFUSED.
#
#    This is the finding that motivated the guard: without it the helper exits 0 having executed
#    nothing. A CI `run:` step hands each block /dev/null on stdin, so a lost `<<'PY'` terminator
#    deletes a whole assertion block while the suite still prints OK — checks that vanished look
#    exactly like checks that passed.
# ---------------------------------------------------------------------------
out=$(expect_fail "empty stdin" py_module "$target" < /dev/null)
case "$out" in
  *"empty body"*) : ;;
  *) echo "FAIL: the refusal does not name the empty body: $out"; exit 1 ;;
esac
echo "  [3] an empty body is refused instead of exiting 0 over nothing"

# ---------------------------------------------------------------------------
# 4. …and so is a body that is only whitespace — `strip()`, not a bare truthiness test.
# ---------------------------------------------------------------------------
out=$(printf '   \n\t\n' | expect_fail "whitespace-only stdin" py_module "$target")
case "$out" in
  *"empty body"*) : ;;
  *) echo "FAIL: a whitespace-only body was not refused: $out"; exit 1 ;;
esac
echo "  [4] a whitespace-only body is refused too"

# ---------------------------------------------------------------------------
# 5. No script path at all: a usage line, not an IndexError traceback.
# ---------------------------------------------------------------------------
out=$(expect_fail "no script path" py_module <<'PY'
print("never reached")
PY
)
case "$out" in
  *"no script path"*) : ;;
  *) echo "FAIL: a missing script path did not produce a usage line: $out"; exit 1 ;;
esac
echo "  [5] a missing script path is refused with a usage line"

# ---------------------------------------------------------------------------
# 6. An unloadable path is refused BY NAME — "lequel ?" is the whole question.
# ---------------------------------------------------------------------------
out=$(expect_fail "missing module" py_module "$scratch/absent.py" <<'PY'
print("never reached")
PY
)
case "$out" in
  *absent.py*) : ;;
  *) echo "FAIL: the refusal does not name the file it could not load: $out"; exit 1 ;;
esac
echo "  [6] an unloadable path is refused and named"

# ---------------------------------------------------------------------------
# 7. THE INVARIANT: loading through the helper leaves no __pycache__ beside the target.
# ---------------------------------------------------------------------------
py_module "$target" <<'PY'
assert mod.double(2) == 4
PY
if any_match "$scratch" -name '__pycache__' -type d; then
  echo "FAIL: py_module left a __pycache__ beside the module it loaded — the"
  echo "      PYTHONDONTWRITEBYTECODE=1 prefix is not doing its job."
  exit 1
fi
echo "  [7] loading through py_module leaves no __pycache__"

# ---------------------------------------------------------------------------
# 8. The control. Section 7 must be able to FAIL, or it proves nothing.
#
#    The same module, imported WITHOUT the prefix, must leave the directory section 7 looks for.
#    Run in a copy so the evidence does not contaminate the assertion above. Uses sys.path +
#    import rather than the importlib spelling section 8 of the xunit suite counts (see the
#    warning in this file's header) — which also demonstrates, in passing, that the kit's
#    one-loader assertion is scoped to one idiom and not to every way of writing bytecode.
# ---------------------------------------------------------------------------
control=$(kit_scratch)
cp "$target" "$control/subject.py"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import subject; assert subject.double(2) == 4' "$control"
if ! any_match "$control" -name '__pycache__' -type d; then
  echo "FAIL: the control import left NO __pycache__, so section 7 cannot distinguish a working"
  echo "      prefix from a broken probe. Either this interpreter never writes bytecode or the"
  echo "      check is looking in the wrong place — section 7 is worthless either way."
  exit 1
fi
echo "  [8] the control leaves one, so section 7 is a measurement and not a formality"

echo "tests/_lib/py.sh golden test OK"
