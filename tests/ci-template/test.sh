#!/usr/bin/env bash
# templates/ci-dotnet.yml — the OPT-IN committed-bundle drift gate.
#
# The hazard, measured on Ninjadog (2026-07-26): `Ninjadog.CLI.csproj` embeds `WebUI/dist/**` as an
# EmbeddedResource, `dist/` is committed, and no MSBuild target calls npm. Bumping the vulnerable
# JS dependency therefore changed the lockfile and NOT ONE BYTE of the shipped binary — while the
# PR closed and the Dependency Dashboard showed the advisory as fixed. That is worse than leaving
# it unfixed: it manufactures a FALSE REMEDIATION.
#
# The steps ship INERT, and that is a measured decision, not timidity (issue #32): across 193 local
# .NET repos, exactly 3 commit build output and exactly 1 has it consumed by the .NET build. A step
# that RAN by default on the other 192 would be deleted or `continue-on-error`'d, which teaches a
# team to ignore a red step — strictly worse than absent.
#
# Inert used to mean "commented out". Since #70 it means `if: ${{ vars.BUNDLE_DIST != '' }}` on
# live YAML, because a comment cost more than it saved: Renovate's github-actions manager cannot
# see a commented action reference. Measured with its own extractor — 5 dependencies from this
# file with the block as text, 7 with it live, the two extra being `actions/setup-node` and
# `node 26.5.0`. The gate's second precondition is a PINNED toolchain (Tailwind v4 and
# lightningcss ship per-platform native binaries), so leaving that pin unmaintainable undercut the
# very guarantee the step exists to provide. Going live also deleted this file's sentinel slicer
# and un-commenter: the steps are now read the way GitHub reads them.
#
# What is asserted:
#   1. three live steps — setup-node, rebuild, guard — in that order, each gated on the variable,
#      with Node pinned to an EXACT version;
#   2. the guard FAILS on a bundle that no longer matches its sources;
#   3. it fails on the content-hash rename (delete + UNTRACKED add), and 3b on the real-world
#      shape where the bundle dir is gitignored and force-added — both invisible to plain
#      `--porcelain`/`git diff`, which is why `--porcelain --ignored` is mandatory;
#   4. the guard PASSES on a bundle that does match — a gate that always fails is not a gate;
#  5b. a misconfigured path is REFUSED rather than passing quietly on nothing, and 5c a directory
#      that exists but holds no tracked file likewise;
#   5. as shipped all three are inert, by a condition that is false when the variable is unset —
#      and nothing outside the gate references the variable;
#  6-9. the coverage artifact step (pre-existing assertions, unrelated to the bundle gate).
#
# Needs PyYAML, which ci.yml installs before every test step.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
TEMPLATE="$KIT/templates/ci-dotnet.yml"

# The template must come out of this run byte-identical. Compared against a hash taken HERE, not
# against git HEAD: the PR that adds or edits this test may also edit the template, so a
# `git status` check would report the author's own work as damage and fail every run of a correct
# test.
TEMPLATE_BEFORE=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
template_unchanged() {
  local after
  after=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
  if [ "$after" != "$TEMPLATE_BEFORE" ]; then
    echo "FAIL: this test modified templates/ci-dotnet.yml — it must only read it."
    return 1
  fi
}

. "$KIT/tests/_lib.sh"
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged
kit_guard template_unchanged

scratch=$(kit_scratch)

# The three opt-in steps are LIVE YAML now, so they are read the way GitHub reads them — no
# sentinel slicer, no un-commenter, no "every line inside the markers must be a comment" check.
# #70 measured why the text form had to go: a commented action reference is INVISIBLE to
# Renovate's github-actions manager. Running its own extractor over this file found 5 dependencies
# and no setup-node; with the step live it finds 7, including `node 26.5.0`. The gate depends on a
# pinned toolchain (per-platform native binaries in Tailwind v4 / lightningcss), and that pin could
# never be maintained while it lived in a comment.
step_named() {
  python3 - "$TEMPLATE" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
step = next((s for s in doc["jobs"]["test"]["steps"] if s.get("name") == sys.argv[2]), None)
if step is None:
    sys.exit(f"templates/ci-dotnet.yml has no step named {sys.argv[2]!r}")
sys.stdout.write(step.get("run") or "")
PY
}

# ---------------------------------------------------------------------------
# 1. The three steps are present, ordered, and inert by default.
#
#    Order is load-bearing: setup-node, then rebuild, then guard. A guard that ran before the
#    rebuild would measure a tree nothing regenerated and pass on a stale bundle — the exact
#    failure it exists to catch.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]
names = [s.get("name") for s in steps]
want = ["Setup Node (bundle front committé)",
        "Reconstruire le bundle front committé",
        "Garde — le bundle front committé correspond toujours à ses sources"]
# Index by POSITION, never by name: a duplicated step name would silently collapse in a
# name->step dict, so the assertions below would inspect the last copy while `names.index()`
# still found the first — an ungated duplicate could pass every check here.
named = [n for n in names if n is not None]   # `uses:`-only steps carry no name; that is fine
assert len(named) == len(set(named)), \
    f"duplicate step names make these assertions unsound: {names}"
for w in want:
    assert w in names, f"missing step {w!r}: {names}"
idx = [names.index(w) for w in want]
assert idx == sorted(idx), f"setup-node -> rebuild -> guard is out of order: {idx}"
by = {names[i]: steps[i] for i in idx}
for w in want:
    cond = str(by[w].get("if", ""))
    assert "vars.BUNDLE_DIST" in cond, (
        f"step {w!r} is not gated on the repo variable — it would RUN on every repo that takes "
        f"this template, including the ones with no bundle at all: if={cond!r}")
# The pinned action and the exact Node version are precisely what Renovate can now maintain.
node = by["Setup Node (bundle front committé)"]
assert str(node.get("uses", "")).startswith("actions/setup-node@"), node
ver = str((node.get("with") or {}).get("node-version", ""))
# `N.N.N` of digits and nothing else. A looser check (first char a digit, two dots) accepts
# `26.5.x`, `26.5.*` and `26.5.0 - 26.9.0` — every one of which lets setup-node resolve a
# different patch per run, which is exactly the drift the pin exists to remove.
assert re.fullmatch(r"\d+\.\d+\.\d+", ver), (
    f"node-version must be an EXACT N.N.N, not a range: {ver!r}. Precondition 2 of this gate — "
    f"per-platform native binaries in the front-end toolchain — collapses if Node floats.")
# The rebuild must be driven by the SAME configuration as the guard. A hardcoded
# working-directory beside a variable-driven guard is two sources of truth: point them at
# different trees and npm rebuilds one while the guard inspects the other, so the step goes
# GREEN over a stale bundle — the false remediation this whole gate exists to prevent.
wd = str(by["Reconstruire le bundle front committé"].get("working-directory", ""))
assert "vars.BUNDLE_SRC" in wd, (
    f"the rebuild's working-directory must come from the same repo configuration as the guard, "
    f"not be hardcoded in the template: {wd!r}")
PY
echo "  [1] three live steps, ordered, gated, Node pinned N.N.N, rebuild driven by the variable"

# ---------------------------------------------------------------------------
# 1b. The plumbing itself — `env: BUNDLE_DIST: ${{ vars.BUNDLE_DIST }}` — is the SUBJECT of this
#     design, and every other section injects the variable itself, so nothing would notice if the
#     wiring were deleted or misspelled. Then the one repo that opted in gets a guard that either
#     reds out on every run or silently measures the wrong directory.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
guard = next(s for s in doc["jobs"]["test"]["steps"]
             if s.get("name") == "Garde — le bundle front committé correspond toujours à ses sources")
env = guard.get("env") or {}
for var in ("BUNDLE_DIST", "BUNDLE_SRC"):
    assert var in env, f"the guard does not receive {var} from the repo variables: env={env}"
    assert f"vars.{var}" in str(env[var]), \
        f"{var} is not wired to the repo variable: {env[var]!r}"
PY
echo "  [1b] the guard receives both paths from the repo variables, by name"

step_named "Garde — le bundle front committé correspond toujours à ses sources" > "$scratch/guard.sh"
[ -s "$scratch/guard.sh" ] || { echo "FAIL: the guard step has an empty run: body"; exit 1; }
bash -n "$scratch/guard.sh" || { echo "FAIL: the guard body is not valid bash"; exit 1; }

# A scratch git repo carrying a committed bundle. `$1` = path, `$2` = asset filename.
mk_repo() {
  local root="$1" asset="$2"
  mkdir -p "$root/web/dist/assets"
  git -C "$root" init -q 2>/dev/null || git init -q "$root"
  printf 'console.log(1)\n' > "$root/web/dist/assets/$asset"
  printf '<script src="/assets/%s"></script>\n' "$asset" > "$root/web/dist/index.html"
  git -C "$root" add -A
  # `commit.gpgsign=false` is not decoration: with signing on globally and no usable key in this
  # shell, the commit fails, `set -e` aborts, and every section below reports as broken with a gpg
  # error rather than a template defect. CI never sees it, which is what makes it a local-only
  # trap. tests/guarded-git/test.sh already solved this the same way.
  git -C "$root" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
      commit -qm "commit the bundle"
}

# ---------------------------------------------------------------------------
# 2. The content-hash rename: the old asset disappears and a differently-named one
#    appears UNTRACKED. `git diff` is not blind here — a deleted TRACKED file is a
#    diff — but it reports only the disappearance and never names the replacement,
#    so nothing diff-based can tell "the build dropped a file" from "the build
#    produced a different bundle". The guard must fail, and must name the new file.
# ---------------------------------------------------------------------------
D="$scratch/renamed"
mk_repo "$D" "index-AAAAAAAA.js"
rm "$D/web/dist/assets/index-AAAAAAAA.js"
printf 'console.log(2)\n' > "$D/web/dist/assets/index-BBBBBBBB.js"

if git -C "$D" diff --stat -- web/dist | grep -q 'index-BBBBBBBB'; then
  echo "FAIL: git diff named the untracked replacement; the template's rationale is stale"
  exit 1
fi
set +e
( cd "$D" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-renamed.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a renamed bundle — it would ship the stale one:"
  cat "$scratch/out-renamed.txt"; exit 1
fi
grep -q 'index-BBBBBBBB' "$scratch/out-renamed.txt" || {
  echo "FAIL: the guard failed but never named the replacement — git diff's exact weakness:"
  cat "$scratch/out-renamed.txt"; exit 1; }
echo "  [2] fails on a content-hash rename, and names the replacement git diff never shows"

# ---------------------------------------------------------------------------
# 3. The actual blind spot: a rebuild that only ADDS. A new code-split chunk, or a
#    newly imported asset, while every existing file keeps its name and content.
#    Nothing tracked changed, so `git diff` reports the tree CLEAN — a diff-based
#    gate goes green on a bundle that is genuinely out of date. Only --porcelain,
#    which covers untracked files, sees it.
#
#    This is the case that makes --porcelain mandatory rather than merely tidier,
#    so it is asserted separately from the rename above.
# ---------------------------------------------------------------------------
A="$scratch/added-only"
mk_repo "$A" "index-CCCCCCCC.js"
printf 'console.log(3)\n' > "$A/web/dist/assets/chunk-DDDDDDDD.js"

git -C "$A" diff --quiet -- web/dist || {
  echo "FAIL: the premise no longer holds — git diff saw a pure untracked addition."
  echo "      If git changed, the porcelain rationale in the template needs rewriting."
  exit 1; }
set +e
( cd "$A" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-added.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a bundle with an untracked new chunk — this is exactly"
  echo "      the drift git diff cannot see, and the reason --porcelain is required:"
  cat "$scratch/out-added.txt"; exit 1
fi
echo "  [3] fails on a pure untracked addition — the drift git diff reports as clean"

# ---------------------------------------------------------------------------
# 3b. The same drift, in the shape real repos actually have: `dist/` listed in
#     .gitignore and force-added. That is the NORMAL way a built bundle gets
#     committed — you ignore the output directory, then `git add -f` the artefact.
#
#     A new chunk is then not merely untracked but IGNORED, and plain
#     `--porcelain` omits ignored files: it prints nothing, both preconditions
#     pass, and the guard reports "à jour" on a stale bundle. Measured before this
#     case was written — `git check-ignore` confirms the file is ignored, and only
#     `--porcelain --ignored` surfaces it.
#
#     This is the one that would have shipped a green gate over a false remediation.
# ---------------------------------------------------------------------------
I="$scratch/gitignored"
mkdir -p "$I/web/dist/assets"
git init -q "$I"
printf 'dist/\n' > "$I/.gitignore"
printf 'console.log(1)\n' > "$I/web/dist/assets/index-FFFFFFFF.js"
git -C "$I" add -f web/dist .gitignore
git -C "$I" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    commit -qm "commit an ignored-but-force-added bundle"
printf 'console.log(9)\n' > "$I/web/dist/assets/chunk-GGGGGGGG.js"

git -C "$I" check-ignore -q web/dist/assets/chunk-GGGGGGGG.js || {
  echo "FAIL: the premise no longer holds — the new chunk is not ignored here."; exit 1; }
set +e
( cd "$I" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-ignored.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a stale bundle whose new chunk is GITIGNORED."
  echo "      Plain --porcelain omits ignored files, so this is a green gate over a"
  echo "      false remediation — the exact outcome the step exists to prevent:"
  cat "$scratch/out-ignored.txt"
  exit 1
fi
grep -q 'chunk-GGGGGGGG' "$scratch/out-ignored.txt" || {
  echo "FAIL: failed, but never named the ignored file:"; cat "$scratch/out-ignored.txt"; exit 1; }
echo "  [3b] fails when the bundle dir is gitignored and force-added — the real-world shape"

# ---------------------------------------------------------------------------
# 4. A matching bundle passes. Without this, "always red" would score as a pass.
# ---------------------------------------------------------------------------
M="$scratch/matching"
mk_repo "$M" "index-CCCCCCCC.js"
set +e
( cd "$M" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-match.txt" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: the guard failed on a bundle that matches its sources:"
  cat "$scratch/out-match.txt"
  exit 1
fi
echo "  [4] passes on a bundle that matches its sources"

# ---------------------------------------------------------------------------
# 5b. A MISCONFIGURED guard must fail loudly, never pass quietly.
#
#     `git status --porcelain -- does/not/exist` exits 0 with EMPTY output. So a consumer who
#     enables the block but leaves the placeholder path — or renames the bundle directory later —
#     gets a step that is green on every run while checking nothing at all. That is the exact
#     "looks tended, measures nothing" failure this whole issue is about, reproduced inside its
#     own fix, and it is invisible precisely because green is the expected colour.
#
#     Measured, not assumed: the bare `git status` behaviour above was probed before this guard
#     clause was written.
# ---------------------------------------------------------------------------
for bad in "" "does/not/exist"; do
  B="$scratch/misconfigured-$(echo "$bad" | tr -c 'a-z' '-')"
  mk_repo "$B" "index-EEEEEEEE.js"
  set +e
  ( cd "$B" && BUNDLE_SRC="$bad" BUNDLE_DIST="$bad" bash "$scratch/guard.sh" ) > "$scratch/out-bad.txt" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard PASSED with BUNDLE_DIST='$bad' — it would be green forever while"
    echo "      measuring nothing, which is the failure this issue exists to prevent:"
    cat "$scratch/out-bad.txt"
    exit 1
  fi
done
echo "  [5b] refuses a misconfigured path instead of passing quietly on nothing"

# ---------------------------------------------------------------------------
# 5c. The third misconfiguration: the directory EXISTS but git tracks nothing in it.
#
#     Both cases above short-circuit on the `-z` / `-d` clauses, so the guard's
#     `git ls-files --error-unmatch` precondition was never actually executed by the
#     suite whose whole purpose is that this block cannot rot untested. This drives it.
#
#     The shape is real: a bundle directory present on the runner (built, or left by a
#     cache restore) that nobody ever committed. The guard must refuse rather than
#     compare a committed bundle that does not exist.
# ---------------------------------------------------------------------------
U="$scratch/untracked-dist"
mk_repo "$U" "index-HHHHHHHH.js"
mkdir -p "$U/other/dist"
printf 'x\n' > "$U/other/dist/nothing-committed.js"
set +e
( cd "$U" && BUNDLE_SRC=other BUNDLE_DIST=other/dist bash "$scratch/guard.sh" ) > "$scratch/out-untracked.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard accepted a directory git tracks nothing in — it would compare a"
  echo "      committed bundle that does not exist, and stay green forever:"
  cat "$scratch/out-untracked.txt"
  exit 1
fi
echo "  [5c] refuses a directory that exists but holds no tracked file"

# ---------------------------------------------------------------------------
# 5d. The two variables must describe the SAME tree.
#
#     Splitting the configuration in two created a way for the gate to certify a bundle nothing
#     rebuilt: point BUNDLE_SRC at one project and BUNDLE_DIST at another's output, and npm
#     regenerates the first while the guard inspects the second, finds it unchanged, and reports
#     "à jour" on a stale bundle — the false remediation this whole step exists to prevent,
#     produced by the step. Cheap to get wrong, too: two settings edited months apart.
# ---------------------------------------------------------------------------
X="$scratch/mismatched"
mk_repo "$X" "index-JJJJJJJJ.js"
mkdir -p "$X/docs-site"
: > "$X/docs-site/package.json"
set +e
( cd "$X" && BUNDLE_SRC=docs-site BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) \
  > "$scratch/out-mismatch.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard accepted BUNDLE_DIST outside BUNDLE_SRC. npm rebuilt one tree while the"
  echo "      guard inspected another — it would go green on a bundle nothing regenerated:"
  cat "$scratch/out-mismatch.txt"
  exit 1
fi
grep -q "BUNDLE_SRC" "$scratch/out-mismatch.txt" || {
  echo "FAIL: refused, but never named the mismatch:"; cat "$scratch/out-mismatch.txt"; exit 1; }
echo "  [5d] refuses when BUNDLE_DIST is not under BUNDLE_SRC — the two-sources-of-truth trap"

# ---------------------------------------------------------------------------
# 5. As shipped the three steps are PRESENT but INERT — and inert by the one mechanism GitHub
#    actually evaluates, not by being text.
#
#    The measurement that forces this: of 193 local .NET repos, 3 commit build output and 1 has it
#    consumed by the build. A step that RAN by default on the other 192 would be deleted or
#    `continue-on-error`'d, which teaches a team to ignore a red step — worse than absent.
#
#    So "inert" is now checked as: every one of the three carries a condition that is false when
#    the repo variable is unset, and none of them is `if: always()`-style unconditional. This is
#    the assertion that replaces "the step must not appear in the parsed YAML", which was only
#    ever a proxy for it.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
raw = open(sys.argv[1], encoding="utf-8").read()
doc = yaml.safe_load(raw)
steps = doc["jobs"]["test"]["steps"]
gated = [i for i, s in enumerate(steps) if "BUNDLE_DIST" in str(s.get("if", ""))]
assert len(gated) == 3, f"expected exactly 3 bundle steps gated on the variable, got {len(gated)}"
for i in gated:
    cond = str(steps[i]["if"])
    # The gate must test the variable for emptiness. `if: ${{ vars.BUNDLE_DIST }}` would also work
    # in GitHub, but `!= ''` says the intent out loud and cannot be misread as a boolean flag.
    assert "!= ''" in cond or '!= ""' in cond, \
        f"the gate must compare BUNDLE_DIST to empty, so an unset variable is plainly false: {cond}"
    assert "always()" not in cond, f"an always() gate would defeat the opt-in entirely: {cond}"
# Nothing OUTSIDE those three steps may depend on the variables — a repo that never sets them must
# get exactly the run it gets today. Checked against the whole document, not just `steps`: the
# workflow already keeps `SOLUTION` in a top-level `env:`, and `jobs.test.env`, `defaults.run` and
# a second job are all places a reference could hide from a steps-only scan.
rest = dict(doc)
rest["jobs"] = {k: (dict(v, steps=[s for i, s in enumerate(v["steps"]) if i not in gated])
                    if k == "test" else v)
               for k, v in doc["jobs"].items()}
leaked = [ln for ln in yaml.safe_dump(rest, allow_unicode=True).splitlines()
          if "BUNDLE_DIST" in ln or "BUNDLE_SRC" in ln]
assert not leaked, f"a bundle variable is referenced outside the three gated steps: {leaked}"
PY
echo "  [5] shipped inert — three gated steps, and nothing outside them references the variables"

# ---------------------------------------------------------------------------
# 6. The coverage artifact is uploaded on the FAILURE path too (issue #74).
#
#    Every step in this job runs under the implicit `success()` condition, so the upload step is
#    skipped the moment an earlier step fails. `Tests + couverture` runs under `set -euo pipefail`,
#    so a test host that exits non-zero ends the job there — and the artifact that would carry the
#    diagnostic is never produced. The artifact therefore existed only for runs where nothing went
#    wrong, which is precisely when nobody needs it.
#
#    Asserted on the SHIPPED template (the artifact step is active, not part of the opt-in block).
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]
want = "Publier la couverture en artefact de build"
step = next((s for s in steps if s.get("name") == want), None)
assert step is not None, f"no step named {want!r}: {[s.get('name') for s in steps]}"

cond = step.get("if")
assert cond is not None, (
    "the coverage artifact step carries no `if:`, so GitHub applies the implicit success() and "
    "skips it whenever an earlier step failed. The one run whose artifact matters — the failed "
    "one — therefore uploads nothing (issue #74)."
)
# A WHITELIST, not a blacklist. This step has to run on BOTH paths, and the two ways to get that
# wrong are symmetric: `success()` (implicit or written) drops the failed run — the hole #74 is
# about — while `failure()` drops every GREEN run, which is where the dashboard's coverage
# actually comes from. An earlier version of this assertion only rejected the first, so editing
# the template to `if: failure()` passed the whole suite while silently ending coverage
# publication on success. Naming the accepted spellings makes a future change deliberate.
ALLOWED = {"always()", "${{always()}}", "!cancelled()", "${{!cancelled()}}"}
normalised = str(cond).replace(" ", "")
assert normalised in ALLOWED, (
    f"the artifact step's condition is `if: {cond}`, which is not one of the conditions known to "
    f"run on BOTH the success and the failure path: {sorted(ALLOWED)}.\n"
    "  `success()` (or no `if:` at all) skips the failed run — that is issue #74.\n"
    "  `failure()` skips every green run — that is the same defect mirrored, and it would stop\n"
    "  publishing the coverage the dashboard is built from.\n"
    "  If you mean a new spelling, add it here deliberately rather than widening the test."
)
PY
echo "  [6] the coverage artifact step runs on both the success and the failure path"

# ---------------------------------------------------------------------------
# 7. The artifact patterns cover the log's FALLBACK location (issue #74).
#
#    MTP writes the log that explains a failure next to its results. `--results-directory` is what
#    puts that under coverage/ — but it is passed in the SAME argument list as `--coverage`, so a
#    project without Microsoft.Testing.Extensions.CodeCoverage has BOTH refused, and the log falls
#    back under `<proj>/bin/<config>/<tfm>/TestResults/`. Measured in #31/#60. The console names
#    that file and nothing else, so if the patterns miss it the failure is undiagnosable remotely.
#
#    The patterns are EXECUTED against representative paths, not eyeballed: a `path:` list is a
#    glob, and "it looks like it covers that" is how #17 shipped a pattern that matched nothing.
#    The translator is itself self-tested first — a wrong one would make every assertion below
#    vacuous, and the failure would be invisible because the expected colour is green.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import re, sys, yaml

def glob_to_regex(pattern):
    """Translate an @actions/glob pattern: `**` spans zero or more path segments, `*` stays
    inside one segment. Python's fnmatch is unusable here — its `*` crosses `/`, which would
    make `coverage/*.log` appear to match a nested path and turn this whole section green."""
    out, i, n = [], 0, len(pattern)
    while i < n:
        if pattern.startswith("**/", i):
            out.append("(?:[^/]*/)*")          # zero or more segments
            i += 3
        elif pattern.startswith("**", i) and i + 2 == n:
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")

# --- the translator must be right before it can judge anything ---------------
for pat, path, expected in [
    ("coverage/**/*.log", "coverage/a.log", True),            # ** matches ZERO segments
    ("coverage/**/*.log", "coverage/x/y/a.log", True),        # ...and more than one
    ("coverage/**/*.log", "other/a.log", False),
    ("coverage/*.log", "coverage/a/b.log", False),            # * must not cross '/'
    ("**/TestResults/*.log", "a/b/TestResults/c.log", True),
    ("**/TestResults/*.log", "a/b/TestResults/c/d.log", False),
]:
    got = bool(glob_to_regex(pat).match(path))
    assert got is expected, f"glob translator wrong: {pat!r} vs {path!r} -> {got}, want {expected}"

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]


def patterns_of(step_name):
    step = next((s for s in steps if s.get("name") == step_name), None)
    assert step is not None, f"no step named {step_name!r}: {[s.get('name') for s in steps]}"
    pats = [p.strip() for p in str(step["with"]["path"]).splitlines() if p.strip()]
    assert pats, f"{step_name!r} declares no path patterns"
    return pats


cov = patterns_of("Publier la couverture en artefact de build")
fallback_step = "Publier les logs MTP restés sous bin/ (diagnostic d'échec)"
logs = patterns_of(fallback_step)

# --- the coverage artifact's SHAPE is part of its contract ------------------
# upload-artifact roots the archive at the least common ancestor of everything it matches. While
# every pattern lives under coverage/, entries land flat (`X.cobertura.xml`); the moment one
# matches outside it, the root becomes the workspace and the same reports arrive as
# `coverage/X.cobertura.xml`. That would break a consumer running
# `reportgenerator -reports:*.cobertura.xml`, and — because the fallback log only exists on some
# runs — it would break it INTERMITTENTLY. Hence the second artifact, and hence this assertion.
for p in cov:
    assert p.startswith("coverage/"), (
        f"the coverage artifact matches {p!r}, outside coverage/. That moves the artifact's root "
        "to the workspace and re-shapes every cobertura entry, conditionally on whether the "
        "out-of-tree file happens to exist. Put such paths in their own artifact instead."
    )

# --- the case this issue is about: --coverage refused, --results-directory refused with it ---
fallback = ("tests/LegacyShop.Catalog.Tests/bin/Debug/net10.0/TestResults/"
            "LegacyShop.Catalog.Tests_net10.0_arm64.log")
assert any(glob_to_regex(p).match(fallback) for p in logs), (
    f"no pattern of {fallback_step!r} matches the log's fallback location:\n"
    f"    {fallback}\n"
    f"  patterns: {logs}\n"
    "  That file carries `Unknown option '--coverage'` — the only explanation of the failure — and\n"
    "  the console prints nothing but its path. Uncollected, a CI-only failure of this kind cannot\n"
    "  be diagnosed without pushing commits to bisect it (issue #74)."
)
# ...and it must stay anchored under bin/, so a TestResults/ a legacy repo COMMITTED in its
# sources is never swept into the artifact (nor deleted by the cleanup that mirrors this pattern).
tracked = "tests/LegacyShop.Tests/TestResults/committed_by_the_repo.log"
assert not any(glob_to_regex(p).match(tracked) for p in logs), (
    f"the fallback pattern also matches a repo-tracked path ({tracked!r}): {logs}. Anchor it "
    "under */bin/* so it only ever collects build output."
)

# --- positive controls: what already worked must keep working ---------------
for control in ("coverage/LegacyShop.Empty.Tests_net10.0_arm64.log",
                "coverage/4f276e85-4f13-4ee4-8809-4d67dc0cd80a.cobertura.xml",
                "coverage/abc-guid/coverage.cobertura.xml"):
    assert any(glob_to_regex(p).match(control) for p in cov), \
        f"a coverage pattern that used to cover {control!r} no longer does: {cov}"
PY
echo "  [7] coverage artifact stays coverage-rooted; the bin/ fallback has its own, bin-anchored"

# ---------------------------------------------------------------------------
# 8. The artifact step warns that those logs are UTF-16 (issue #74).
#
#    Collecting the log is only half of it. Measured: MTP writes them UTF-16-LE with a BOM, in
#    BOTH locations — so `grep "Unknown option" <log>` on the downloaded artifact returns nothing.
#    Not "the log is empty": a UTF-8 reader sees no text in it. That failure mode LOOKS like an
#    empty file, so without a warning the reader concludes the log is worthless and goes back to
#    bisecting by pushing commits — the cost this whole issue exists to remove.
#
#    A comment is the only place that warning can live (a workflow cannot annotate an artifact),
#    so this asserts it is present — comments are exactly what a later tidy-up drops silently.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines)
              if l.strip() == "- name: Publier la couverture en artefact de build"), None)
assert start is not None, "the artifact step is gone — section 6 should have caught this first"
# The step's own block, and ONLY it — bounded by INDENT, not by the next `- name:`.
# Both of the obvious boundaries have failed here historically, silently and by over-reaching:
#   * "next `- name:`" — while the opt-in block was commented out, the next `- name:` was inside
#     it and therefore invisible, so the scan ran to EOF and swallowed 130 unrelated lines. #70
#     made those steps live, so today that boundary would in fact stop at the MTP-log step — but
#     it stops there by accident of the current layout, not by construction, and the next
#     commented step anywhere above would break it again.
#   * "next `--8<--` sentinel" — that sentinel is gone since #70, and even while it existed the
#     opt-in section opened with ~40 lines of comment ABOVE it, at the step's own indent, which
#     still got absorbed.
# Everything belonging to this step is indented deeper than its `- name:`, so the first non-blank
# line back at that indent is the true end. The assertions below then quote this step or nothing.
indent = len(lines[start]) - len(lines[start].lstrip())
end = next((i for i in range(start + 1, len(lines))
            if lines[i].strip() and (len(lines[i]) - len(lines[i].lstrip())) <= indent),
           len(lines))
block = "\n".join(lines[start:end])
# Prove the slice really is one step, so a future boundary regression surfaces here rather than
# silently widening what the assertions below are allowed to match.
assert "Setup Node" not in block, "the extracted block leaked into the opt-in steps"
assert "À N'ACTIVER" not in block, "the extracted block absorbed the opt-in section's preamble"
assert end - start < 40, f"the artifact step slice is {end - start} lines — it over-reached"

assert "UTF-16" in block, (
    "the artifact step no longer says its .log files are UTF-16. Someone downloading the artifact "
    "will grep them as UTF-8, get no output, and read that as 'the log is empty' — which is the "
    "one wrong conclusion available here (issue #74)."
)
assert "iconv" in block or "encoding=" in block, (
    "the UTF-16 warning names no way to actually read the file. State the decode command "
    "(iconv -f UTF-16) or the Python codec, or the warning leaves the reader exactly as stuck."
)
PY
echo "  [8] the artifact step warns that MTP's logs are UTF-16, and says how to read them"

# ---------------------------------------------------------------------------
# 9. The bin/ fallback is CLEANED before the run, exactly as coverage/ is.
#
#    Publishing a location makes its hygiene part of the contract. The test step already does
#    `rm -rf coverage`, and says why: a self-hosted runner reuses its workspace, so yesterday's
#    files read as today's. The bin/ fallback now ships in an artifact too — and left uncleaned it
#    is worse than coverage/ ever was, because the SAME project's log moves between the two
#    locations depending on the outcome (measured, #74): a run that fails writes it under bin/, and
#    a later GREEN run writes under coverage/ while the stale failure log sits there and gets
#    uploaded. The artifact would then explain a failure that did not happen — a wrong answer, not
#    a missing one.
#
#    Executed as a real shell, not grepped for: the assertion is that stale logs are GONE, which a
#    substring match cannot establish.
# ---------------------------------------------------------------------------
CLEAN_STEP=$(python3 - "$TEMPLATE" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Tests + couverture")
run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
indent = len(lines[run]) - len(lines[run].lstrip()) + 2
body = []
for line in lines[run + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) < indent:
        break
    body.append(line[indent:])
# Only the hygiene prologue: everything before the platform detection. Running the whole step
# would invoke dotnet, which this suite has no business doing.
out = []
for line in body:
    if line.strip().startswith("mtp="):
        break
    out.append(line)
print("\n".join(out).strip("\n"))
PY
)
[ -n "$CLEAN_STEP" ] || { echo "FAIL: could not slice the hygiene prologue of 'Tests + couverture'"; exit 1; }
bash -n <<<"$CLEAN_STEP" 2>/dev/null || { echo "FAIL: the sliced prologue is not valid bash:"; echo "$CLEAN_STEP"; exit 1; }

hyg="$scratch/hygiene"
rm -rf "$hyg" && mkdir -p "$hyg"
# Stale build output from an earlier, failed run…
mkdir -p "$hyg/tests/Proj.Tests/bin/Debug/net10.0/TestResults"
echo stale > "$hyg/tests/Proj.Tests/bin/Debug/net10.0/TestResults/Proj.Tests_net10.0_x64.log"
# …a stale coverage/ …
mkdir -p "$hyg/coverage" && echo stale > "$hyg/coverage/old.cobertura.xml"
# …and a TestResults/ the repo COMMITTED in its sources, which must survive untouched.
mkdir -p "$hyg/tests/Proj.Tests/TestResults"
echo tracked > "$hyg/tests/Proj.Tests/TestResults/committed.log"

( cd "$hyg" && bash -c "$CLEAN_STEP" ) > /dev/null 2>&1 || {
  echo "FAIL: the hygiene prologue of 'Tests + couverture' exited non-zero"; exit 1; }

# `-print -quit`, not `| grep -q .`: this file runs under `set -euo pipefail` (line 29), where grep's
# exit-at-first-match SIGPIPEs find into a 141 that pipefail promotes to the pipeline's status — so
# the `if` takes its else-branch precisely when stale logs DID survive, skipping the very failure it
# exists to report (#48). Found by grepping the whole repo for the idiom rather than only the file
# where it was first seen; the sibling suite tests/xunit-v3/test.sh carries the same fix.
stale_bin_log=$(find "$hyg" -path '*/bin/*' -name '*.log' -print -quit 2>/dev/null || true)
if [ -n "$stale_bin_log" ]; then
  echo "FAIL: a stale MTP log under bin/ survived the cleanup. Since that location is now"
  echo "      published as an artifact, a green run would ship the previous run's failure log"
  echo "      and the artifact would explain a failure that never happened (issue #74):"
  find "$hyg" -path '*/bin/*' -name '*.log'
  exit 1
fi
[ -f "$hyg/tests/Proj.Tests/TestResults/committed.log" ] || {
  echo "FAIL: the cleanup deleted a repo-tracked TestResults/ file. It must only ever remove"
  echo "      build output — anchor it under */bin/*."; exit 1; }
[ -d "$hyg/coverage" ] && [ -z "$(ls -A "$hyg/coverage")" ] || {
  echo "FAIL: coverage/ was not reset to an empty directory by the prologue"; exit 1; }
echo "  [9] stale bin/ logs are cleaned before the run; a committed TestResults/ is left alone"

echo "ci-dotnet template opt-in bundle gate golden test OK"
