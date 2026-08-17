#!/usr/bin/env bash
# tests/_lib/py.sh — the kit's ONE importlib loader for test suites. SOURCED, never executed.
#
# Why this file exists (#42, then #51). Loading a kit script through importlib COMPILES it, so
# without PYTHONDONTWRITEBYTECODE=1 Python drops a __pycache__ directory beside the script. The
# xunit-v3 suite's exit guard scans `scripts/` and `tests/` for exactly that and fails the whole
# run — which means a missing prefix surfaces as a suite-wide failure naming a file the suite may
# never have touched.
#
# That prefix is load-bearing and invisible at the call site: nothing about `py_module foo.py`
# suggests that an environment variable is what keeps it from dirtying the repo. It is precisely
# the shape a copy-paste drops. #42 collapsed four hand-copied blocks in tests/xunit-v3/test.sh
# into one helper and asserted the count — but the assertion read that file alone, and
# tests/report-dashboard/test.sh carried a second, unasserted copy. Correct at the time, and
# exactly one edit away from stranding a __pycache__ under scripts/ whose failure would have been
# reported by the xunit suite. #51 moved the helper here and widened the assertion to tests/ and
# scripts/, so the claim is now about the kit rather than about one file.
#
# ---------------------------------------------------------------------------------- the contract
#
#   py_module <script-path> [args…] <<'PY'
#   …body…
#   PY
#
#       Run a Python snippet with a kit script already loaded as `mod`. Inside the body,
#       `sys.argv[1]` is <script-path> and `sys.argv[2:]` are the args. The body arrives on
#       stdin, so it must not also read stdin.
#
# ------------------------------------------------------------------------- why not tests/_lib.sh
#
# The kit's other shared preamble — scratch dirs, the EXIT trap, the samples/ guard, any_match —
# lives in tests/_lib.sh (#72), and one home per shared mechanism is the rule this repo works by.
# The loader is deliberately NOT folded in there, for a reason that is easy to lose:
# tests/lib/test.sh section 9 audits every `mktemp -d` in any suite whose text mentions `_lib.sh`,
# and tests/report-dashboard/test.sh manages four of its own. Sourcing _lib.sh purely to reach
# py_module would drag that suite into an audit it was explicitly measured out of — #72 recorded
# that converting those five suites is tidying rather than a fix, and deferred it on purpose.
#
# So: a separate file, and the two shared mechanisms stay separately adoptable. A suite takes the
# loader without taking the preamble. If those five suites are ever converted, merging this back
# into tests/_lib.sh becomes the obvious simplification.
#
# There is deliberately no `set -euo pipefail` here: the callers set it, and re-setting it in a
# sourced file would mean this file silently decides the shell options of every suite that loads
# it (the same reason tests/_lib.sh and skills/implement-issue/scripts/_assert-branch.sh give).

py_module() {
  # An EMPTY body is refused, loudly, rather than run as a no-op. Without this the helper exits 0
  # having asserted nothing: `py_module foo.py` with no heredoc reads stdin, gets EOF, compiles the
  # empty string and succeeds. Measured — `py_module scripts/report-dashboard.py < /dev/null`
  # returned 0. That matters because a GitHub Actions `run:` block is handed /dev/null on stdin, so
  # an edit that loses a `<<'PY'` terminator — or a future call site inside a `while read … done <
  # file`, which would swallow the file as the body — deletes a whole block of assertions and the
  # suite still reports OK. A suite whose checks silently vanished looks exactly like a suite that
  # passes, which is the failure scripts/ci-wiring-check.py exists for, one layer down.
  #
  # Checked in Python, not with `[ -t 0 ]` in the shell: under CI stdin is not a tty AND not a
  # heredoc, so a tty test would pass while the body was still empty. Only the bytes decide.
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import importlib.util, sys
if len(sys.argv) < 2:
    sys.exit("py_module: no script path given — usage: py_module <script> [args…] <<PY … PY")
body = sys.stdin.read()
if not body.strip():
    sys.exit(
        "py_module: empty body on stdin — nothing would have been asserted.\n"
        "  The heredoc is missing, its terminator was lost, or stdin was already consumed\n"
        "  (a CI `run:` step gets /dev/null). Refusing to exit 0 over an absent test body.")
spec = importlib.util.spec_from_file_location("kit_module", sys.argv[1])
if spec is None or spec.loader is None:
    sys.exit(f"py_module: cannot load {sys.argv[1]!r} as a module — is the path right?")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
exec(compile(body, "<py_module body>", "exec"), globals())
' "$@"
}
