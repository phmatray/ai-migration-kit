#!/usr/bin/env bash
# Golden test for scripts/parse-sweep.sh — the guard that every suite PARSES under the bash the
# developer actually has (#131).
#
# Written fail-path-first, like tests/worktrees-ignored/test.sh and tests/release-title-gate/test.sh
# and for the same reason: a guard whose PASS path is the only one ever exercised proves nothing.
# Here that reason is sharper than usual, because the guard's own subject is invisible on CI —
# bash 5 parses the #131 construct happily, so the `bash -n` half of the sweep is a NO-OP on the
# runner. What CI enforces is the sweep's STATIC scan, and that is what the cases below drive.
#
# Every fixture is a measurement, not an intuition. Each one was run through bash 3.2.57 while this
# was written, and case `agreement` re-runs that comparison on any host that has such a bash, so
# the table in scripts/parse-sweep.sh cannot rot into folklore:
#
#     fixture              bash 3.2 -n   why it is here
#     hazard               FAILS         the #131 line verbatim
#     fixed                parses        the \x27 respelling — the positive control for `hazard`
#     top-level            parses        same body, heredoc NOT in a $( … ). The repo is full of
#                                        these; flagging one would be a false positive on CI
#     in-double-quotes     parses        an apostrophe that pairs inside a "…" string
#     comment-line         parses        an apostrophe in a # comment — bash sees the comment too
#     glued-hash           FAILS         a # with no blank before it is NOT a comment
#     herestring           parses        <<< must not be read as a heredoc opener
#     dash-heredoc         FAILS         <<- with a tab-indented terminator, hazard in the body
#     shift-operator       FAILS         arithmetic `<<` is a SHIFT; read as an opener it swallows
#                                        the rest of the file and the scan goes quiet (found in
#                                        review, and it had)
#
# The pair (hazard, fixed) is the point of the whole file: neither half alone rules out a scan that
# is right for the wrong reason.
set -euo pipefail
cd "$(dirname "$0")/../.."

GUARD="./scripts/parse-sweep.sh"
[ -x "$GUARD" ] || { echo "FAIL: $GUARD missing or not executable"; exit 1; }
KIT="$PWD"

# Every assertion below invokes the guard as `bash <guard>`, so the parser it measures is the `bash`
# on PATH — which need not be the one running THIS file (a Homebrew bash 5 can perfectly well run a
# suite whose PATH still finds /bin/bash 3.2). The version-dependent cases therefore ask that same
# binary rather than reading $BASH_VERSINFO here, or they would answer about the wrong parser and
# assert the wrong note.
SWEEP_BASH=$(command -v bash)
SWEEP_MAJOR=$("$SWEEP_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"')

# Scratch dir and EXIT trap come from the shared preamble (#72).
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# This suite only writes into its own scratch directory, but it writes a lot of it — so it says so
# rather than leaving "decided it does not apply" looking like "forgot" (#72).
kit_guard "kit_guard_samples_unchanged"
WORK=$(kit_scratch)
FIX="$WORK/fixtures"
mkdir -p "$FIX"

# --------------------------------------------------------------------------------- the fixtures
#
# Written with plain top-level heredocs. That matters: a heredoc opened inside a $( … ) is the very
# construct under test, so building these fixtures that way would make THIS file unparseable on the
# bash it exists to protect.

cat > "$FIX/hazard.sh" <<'FIXTURE'
#!/usr/bin/env bash
PIN=$(python3 - <<'PY'
import re
m = re.search(r'RENOVATE_VALIDATOR_VERSION:\s*["\']?([0-9]+)["\']?', "RENOVATE_VALIDATOR_VERSION: 44")
print(m.group(1) if m else "")
PY
)
echo "$PIN"
FIXTURE

cat > "$FIX/fixed.sh" <<'FIXTURE'
#!/usr/bin/env bash
PIN=$(python3 - <<'PY'
import re
m = re.search(r'RENOVATE_VALIDATOR_VERSION:\s*["\x27]?([0-9]+)["\x27]?', "RENOVATE_VALIDATOR_VERSION: 44")
print(m.group(1) if m else "")
PY
)
echo "$PIN"
FIXTURE

cat > "$FIX/top-level.sh" <<'FIXTURE'
#!/usr/bin/env bash
python3 - <<'PY'
import re
m = re.search(r'X:\s*["\']?([0-9]+)["\']?', "X: 42")
print(m.group(1) if m else "")
PY
echo done
FIXTURE

cat > "$FIX/in-double-quotes.sh" <<'FIXTURE'
#!/usr/bin/env bash
A=$(python3 - <<'PY'
print("it's fine, isn't it")
PY
)
echo "$A"
FIXTURE

cat > "$FIX/comment-line.sh" <<'FIXTURE'
#!/usr/bin/env bash
A=$(python3 - <<'PY'
# it's a comment, and bash 3.2 treats it as one
print(42)  # so is this one, isn't it
PY
)
echo "$A"
FIXTURE

cat > "$FIX/glued-hash.sh" <<'FIXTURE'
#!/usr/bin/env bash
A=$(python3 - <<'PY'
x = "a"+"b"#it's glued to the token, so it is not a comment
print(x)
PY
)
echo "$A"
FIXTURE

cat > "$FIX/herestring.sh" <<'FIXTURE'
#!/usr/bin/env bash
A=$(grep -c . <<<"it's a herestring, not a heredoc")
echo "$A"
FIXTURE

# `<<-` strips leading TABS from its terminator, so this fixture NEEDS real tab characters. They are
# written as `@` here and substituted below: a literal tab in a source file is exactly the thing an
# editor, a diff viewer or a copy-paste turns into spaces, and if that happened the terminator would
# stop matching, the body would swallow the rest of the file, and the case would go quietly green.
TAB=$(printf 'x\t'); TAB=${TAB#x}
cat > "$WORK/dash-heredoc.tmpl" <<'FIXTURE'
#!/usr/bin/env bash
A=$(python3 - <<-'PY'
@import re
@m = re.search(r'X:\s*["\']?([0-9]+)["\']?', "X: 42")
@print(m.group(1) if m else "")
@PY
)
echo "$A"
FIXTURE
tr '@' "$TAB" < "$WORK/dash-heredoc.tmpl" > "$FIX/dash-heredoc.sh"
grep -q "$TAB" "$FIX/dash-heredoc.sh" \
  || { echo "FAIL [fixture]: dash-heredoc.sh carries no tab — the <<- case would prove nothing"; exit 1; }

cat > "$FIX/plain-syntax-error.sh" <<'FIXTURE'
#!/usr/bin/env bash
if [ 1 -eq 1 ]; then
  echo "never closed"
FIXTURE

# THE regression fixture (found in review). `<<` inside arithmetic is a left SHIFT. Read as a
# heredoc operator it opens a body delimited by `3`, no such terminator ever arrives, and the rest
# of the file — including the real hazard below — is swallowed as body and never examined. This
# file genuinely fails on bash 3.2, and the scan called it clean.
cat > "$FIX/shift-operator.sh" <<'FIXTURE'
#!/usr/bin/env bash
mask=$(( 1 << 3 ))
(( mask = mask << 1 ))
echo "$mask"
A=$(python3 - <<'PY'
import re
m = re.search(r'X:\s*["\']?([0-9]+)["\']?', "X: 42")
print(m.group(1) if m else "")
PY
)
echo "$A"
FIXTURE

# The net under every remaining way an opener can be mis-read: a heredoc that is never terminated.
cat > "$FIX/unterminated.sh" <<'FIXTURE'
#!/usr/bin/env bash
A=$(python3 - <<'PY'
print(42)
echo "$A"
FIXTURE

# ----------------------------------------------------------------------------------- assertions

# Runs the guard over one fixture and asserts the exit code, plus (optionally) a substring.
verdict() {
  local name="$1" want_rc="$2" want_msg="$3" file="$4"
  local out rc=0
  out=$(bash "$KIT/$GUARD" "$file" 2>&1) || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL [$name]: expected exit $want_rc, got $rc"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ] && ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "FAIL [$name]: output did not mention '$want_msg':"; echo "$out"; exit 1
  fi
  echo "  ok: $name"
}

# THE marker of the static scan. Asserting on it — rather than merely on a non-zero exit — is what
# makes the red cases meaningful on CI: on bash 5 the `bash -n` half sees nothing, so an exit of 1
# alone would not prove which half spoke.
STATIC='opened INSIDE a $( … ) command substitution'

# ------------------------------------------------------------- 1. the construct, both spellings

# 1. The #131 line verbatim. Both the refusal AND the static marker, because that marker is the
#    only half of the sweep that works on the runner this test also has to pass on.
verdict hazard 1 "$STATIC" "$FIX/hazard.sh"

# 2. The positive control. Same file, apostrophe respelled \x27 — the fix that shipped in
#    tests/renovate-config/test.sh. Without this case, `hazard` could be passing because the scan
#    flags every heredoc in a command substitution, which would redden the whole repo.
verdict fixed 0 '' "$FIX/fixed.sh"

# 3. The static scan must name the OPENER, not the end of the file. bash's own message points at
#    the last line, which is what makes this class of failure hard to locate.
out=$(bash "$KIT/$GUARD" "$FIX/hazard.sh" 2>&1) || true
printf '%s' "$out" | grep -qF -- "hazard.sh:2" \
  || { echo "FAIL [opener-line]: the report does not point at line 2 (the $( … ) opener):"; echo "$out"; exit 1; }
echo "  ok: opener-line — the report points at the heredoc opener, not at the end of the file"

# ----------------------------------------------------- 4-7. the false-positive controls, measured

# 4. THE control that keeps this guard usable. `python3 - <<'PY'` at the top level, with the exact
#    same body, parses fine on bash 3.2 — the hazard is the command substitution, not the heredoc.
#    This repo has such blocks in most suites; flagging them would fail CI on correct code.
verdict top-level 0 '' "$FIX/top-level.sh"

# 5. An apostrophe that pairs inside a "…" string in the body. Measured: parses. A scan that merely
#    counted apostrophes would refuse it.
verdict in-double-quotes 0 '' "$FIX/in-double-quotes.sh"

# 6. An apostrophe inside a `#` comment in the body — bash 3.2's scanner honours comments too, at
#    the start of a line and after a blank. Measured: parses. This is why the scan models comments
#    rather than raw quote characters.
verdict comment-line 0 '' "$FIX/comment-line.sh"

# 7. …and the boundary that proves case 6 is not just "ignore everything after a #": a `#` glued to
#    the previous token starts no comment, and the apostrophe behind it is live. Measured: FAILS.
verdict glued-hash 1 "$STATIC" "$FIX/glued-hash.sh"

# --------------------------------------------------------------- 8-9. the operator's other shapes

# 8. `<<<` is a herestring. Read as a heredoc opener, the scan would wait for a terminator that
#    never comes, swallow the rest of the file, and report nothing at all — a guard that has gone
#    quiet, which is the failure mode this whole issue is about.
verdict herestring 0 '' "$FIX/herestring.sh"

# 9. `<<-` allows a TAB-indented terminator. A scan that compared the terminator line literally
#    would never close the body, with the same silent result as case 8 — so the hazard in this
#    fixture must still be found.
verdict dash-heredoc 1 "$STATIC" "$FIX/dash-heredoc.sh"

# ----------------------------------------------- 9b-9c. the scan must not stop looking, silently

# 9b. THE review regression. Arithmetic `<<` is a left shift, not a heredoc operator. Before this
#     case the scan read `$(( 1 << 3 ))` as a heredoc delimited by `3`, waited for a terminator
#     that never came, and reported this file — which really does fail on bash 3.2 — as CLEAN.
#     A guard that has quietly stopped looking is the failure #131 itself is about, so the
#     assertion is on the STATIC marker: the hazard further down the file must still be found.
verdict shift-operator 1 "$STATIC" "$FIX/shift-operator.sh"

# 9c. …and the net under every remaining way an opener could be mis-read. A heredoc still open at
#     end of file means the scan covered nothing past it, which must be a refusal rather than a
#     silent pass — the distinct message tells the reader whether to fix the file or the scanner.
verdict unterminated 1 'the scan could not complete' "$FIX/unterminated.sh"

# ------------------------------------------------------------------ 10. the version-blind half

# 10. An ordinary syntax error, which every bash rejects. This is the half of the sweep that does
#     the same work on the runner as on a Mac.
verdict plain-syntax-error 1 'does not parse under' "$FIX/plain-syntax-error.sh"

# --------------------------------------------------------- 11. this repository actually passes

# 11. The call CI makes. After #131 the whole tree parses on bash 3.2, so the default sweep is
#     green — and that is also the regression test for the renovate-config fix itself.
out=$(bash "$KIT/$GUARD" -C "$KIT" 2>&1) || {
  echo "FAIL [repo]: the shipped suites do not pass the sweep:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF 'file(s) parse under this bash' \
  || { echo "FAIL [repo]: no summary line:"; echo "$out"; exit 1; }
echo "  ok: repo — every tests/*/test.sh in this checkout passes the sweep"

# ------------------------------------------------- 12. the banner, and the no-op it has to admit

# 12. The version is REPORTED. A green run says nothing about bash 3.2 unless the reader can see
#     which parser produced it — the spec's "a colleague on stock macOS does not" edge.
printf '%s' "$out" | grep -qF "$("$SWEEP_BASH" --version | head -1)" \
  || { echo "FAIL [banner]: the sweep does not name the bash it ran under:"; echo "$out"; exit 1; }
echo "  ok: banner — the running bash version is on the report"

# 13. …and on a bash that cannot see the hazard, the sweep must SAY the `bash -n` half is a no-op,
#     so a green CI run is not mistaken for coverage of bash 3.2.
if [ "$SWEEP_MAJOR" -le 3 ]; then
  printf '%s' "$out" | grep -qF 'this IS the bash #131 is about' \
    || { echo "FAIL [note]: bash 3.x did not get the meaningful-here note:"; echo "$out"; exit 1; }
  echo "  ok: note — bash 3.x is told the parse half is meaningful here"
else
  printf '%s' "$out" | grep -qF 'NOT proof about bash 3.2' \
    || { echo "FAIL [note]: bash >= 4 did not get the no-op warning:"; echo "$out"; exit 1; }
  echo "  ok: note — bash >= 4 is told the parse half is a no-op for #131 here"
fi

# ----------------------------------------- 14. the corroboration, on a host that can give it

# 14. On bash 3.x, the static scan and the real parser must AGREE on every fixture above. That
#     agreement is the evidence behind the table in the guard's header; on any other bash it
#     cannot be produced, and the run says so instead of quietly skipping it.
if [ "$SWEEP_MAJOR" -le 3 ]; then
  for f in hazard fixed top-level in-double-quotes comment-line glued-hash herestring dash-heredoc shift-operator; do
    pn=0; "$SWEEP_BASH" -n "$FIX/$f.sh" >/dev/null 2>&1 || pn=1
    sn=0; "$SWEEP_BASH" "$KIT/$GUARD" "$FIX/$f.sh" >/dev/null 2>&1 || sn=1
    [ "$pn" -eq "$sn" ] || {
      echo "FAIL [agreement]: $f — bash -n says $pn, the sweep says $sn"; exit 1; }
  done
  echo "  ok: agreement — on this bash 3.x host the static scan matches the real parser, fixture by fixture"
else
  echo "  note: agreement — skipped, the bash on PATH is major $SWEEP_MAJOR. The fixtures above were"
  echo "        measured against bash 3.2.57; only a bash 3.x host can re-measure them."
fi

# --------------------------------------------------- 15+. plumbing must fail closed, never open

# 15. A tests/ directory with no suites in it. Reporting "all parse" over an empty set is the #45
#     failure — an absent check looks exactly like a passing one — so it is exit 2, not 0.
empty="$WORK/empty"
mkdir -p "$empty/tests"
rc=0; bash "$KIT/$GUARD" -C "$empty" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [empty-set]: expected exit 2, got $rc"; exit 1; }
echo "  ok: empty-set — refuses to report clean over nothing"

# 16. No tests/ directory at all — same reasoning, distinct message.
nodir="$WORK/nodir"
mkdir -p "$nodir"
rc=0; bash "$KIT/$GUARD" -C "$nodir" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-tests-dir]: expected exit 2, got $rc"; exit 1; }
echo "  ok: no-tests-dir — exit 2, not a pass"

# 17. -C without a value must not silently sweep the current directory.
rc=0; bash "$KIT/$GUARD" -C >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [dangling-C]: expected exit 2, got $rc"; exit 1; }
echo "  ok: dangling-C — exit 2"

# 18. An unrecognised option is refused rather than swallowed as a filename.
rc=0; bash "$KIT/$GUARD" --repo /tmp >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [bad-arg]: expected exit 2, got $rc"; exit 1; }
echo "  ok: bad-arg — exit 2"

# 19. A target that cannot be read is plumbing, not a verdict.
rc=0; bash "$KIT/$GUARD" "$WORK/does-not-exist.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [unreadable]: expected exit 2, got $rc"; exit 1; }
echo "  ok: unreadable-target — exit 2"

# 20. --help documents the exit codes, matching every other guard in this kit and the shape ci.yml
#     greps for in its plugin-install simulation.
bash "$KIT/$GUARD" --help 2>&1 | grep -q 'Exit codes:' \
  || { echo "FAIL [help]: --help does not document the exit codes"; exit 1; }
echo "  ok: help — documents the exit codes"

# 21. The verdict follows -C, never the ambient working directory: the kit is installed as a plugin
#     and runs from someone else's checkout.
( cd "$WORK" && bash "$KIT/$GUARD" -C "$empty" >/dev/null 2>&1 ) \
  && { echo "FAIL [foreign-cwd]: an empty tests/ passed from another directory"; exit 1; }
( cd / && bash "$KIT/$GUARD" -C "$KIT" >/dev/null 2>&1 ) \
  || { echo "FAIL [foreign-cwd]: this repo was refused from another directory — control invalid"; exit 1; }
echo "  ok: foreign cwd — the verdict follows -C, not the ambient directory"

# 22. Several targets at once, only one of them broken: the sweep must report THAT one and still
#     refuse. A loop that stopped at the first file would leave the rest unmeasured, and one that
#     forgot to latch `failed` would exit 0 having printed a refusal.
out=$(bash "$KIT/$GUARD" "$FIX/fixed.sh" "$FIX/hazard.sh" "$FIX/top-level.sh" 2>&1) && {
  echo "FAIL [multi]: a batch containing a broken file exited 0"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF 'hazard.sh:2' \
  || { echo "FAIL [multi]: the broken file in the batch was not named:"; echo "$out"; exit 1; }
echo "  ok: multi — one bad file among good ones is named, and the batch refuses"

echo "parse-sweep golden test OK"
