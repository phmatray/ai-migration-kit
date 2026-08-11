#!/usr/bin/env bash
# templates/ci-dotnet.yml — the OPT-IN committed-bundle drift gate.
#
# The hazard, measured on Ninjadog (2026-07-26): `Ninjadog.CLI.csproj` embeds `WebUI/dist/**` as an
# EmbeddedResource, `dist/` is committed, and no MSBuild target calls npm. Bumping the vulnerable
# JS dependency therefore changed the lockfile and NOT ONE BYTE of the shipped binary — while the
# PR closed and the Dependency Dashboard showed the advisory as fixed. That is worse than leaving
# it unfixed: it manufactures a FALSE REMEDIATION.
#
# The step ships COMMENTED OUT, and that is a measured decision, not timidity (issue #32): across
# 193 local .NET repos, exactly 3 commit build output and exactly 1 has it consumed by the .NET
# build. A step that fails by default on the other 192 would be deleted or `continue-on-error`'d,
# which teaches a team to ignore a red step — strictly worse than absent.
#
# A commented-out step is dead text that nothing executes, so it rots silently. This file is what
# stops that: it UNCOMMENTS the block and runs the guard for real, both ways.
#
# What is asserted:
#   1. the block is still there, and the template parses as YAML once it is uncommented — so the
#      step cannot drift into something that would not run when a consumer enables it;
#   2. the guard FAILS on a bundle that no longer matches its sources;
#   3. it fails specifically on the content-hash rename (delete + UNTRACKED add) — and the same
#      tree is proven invisible to `git diff`, which is why `git status --porcelain` is mandatory;
#   4. the guard PASSES on a bundle that does match — a gate that always fails is not a gate;
#   5. the commented block leaves the ACTIVE template untouched: still valid YAML, and no step of
#      it runs by default.
#
# Needs PyYAML, which ci.yml installs before every test step.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
TEMPLATE="$KIT/templates/ci-dotnet.yml"

scratch=""
# The template must come out of this run byte-identical. Compared against a hash taken HERE, not
# against git HEAD: the PR that adds this test also edits the template, so a `git status` check
# would report the author's own work as damage and fail every run of a correct test.
TEMPLATE_BEFORE=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
cleanup() {
  local rc=$?
  [ -n "$scratch" ] && rm -rf "$scratch"
  local after
  after=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
  if [ "$after" != "$TEMPLATE_BEFORE" ]; then
    echo "FAIL: this test modified templates/ci-dotnet.yml — it must only read it."
    exit 1
  fi
  local dirty
  dirty=$(git -C "$KIT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated:"
    echo "$dirty"
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

scratch=$(mktemp -d)

# Uncomment the sentinel-delimited opt-in block and print the whole template. Everything below
# runs against THIS text, never a hand-copied paraphrase of it — a test that asserts things about
# its own string proves nothing about what the kit ships.
uncommented() {
  python3 - "$TEMPLATE" <<'PY'
import re, sys
BEGIN = "--8<-- opt-in: committed-bundle drift gate"
END = "--8<-- end opt-in"
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines) if BEGIN in l), None)
stop = next((i for i, l in enumerate(lines) if END in l), None)
if start is None or stop is None or stop <= start:
    sys.exit("templates/ci-dotnet.yml no longer carries the opt-in block sentinels")
out = lines[:start]
for line in lines[start + 1:stop]:
    m = re.match(r"^(\s*)#( ?)(.*)$", line)
    # A line inside the block that is not a comment would mean the block leaked into the
    # active workflow — refuse rather than silently emit it twice.
    if not m:
        sys.exit(f"line inside the opt-in block is not commented out: {line!r}")
    out.append(m.group(1) + m.group(3))
out += lines[stop + 1:]
print("\n".join(out))
PY
}

# ---------------------------------------------------------------------------
# 1. The block exists, and the template is valid YAML once uncommented.
# ---------------------------------------------------------------------------
uncommented > "$scratch/enabled.yml"
python3 - "$scratch/enabled.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]
names = [s.get("name") for s in steps]
want = "Garde — le bundle front committé correspond toujours à ses sources"
assert want in names, f"the guard step is missing once uncommented: {names}"
rebuild = "Reconstruire le bundle front committé"
assert rebuild in names, f"the rebuild step is missing once uncommented: {names}"
# The rebuild must come BEFORE the guard, or the guard measures a tree nothing regenerated
# and passes on a stale bundle — the exact failure it exists to catch.
assert names.index(rebuild) < names.index(want), \
    f"the rebuild step must precede the guard: {names}"
PY
echo "  [1] the opt-in block uncomments into valid YAML, rebuild before guard"

# Extract the guard's shell body from the UNCOMMENTED text.
guard_body() {
  python3 - "$scratch/enabled.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
step = next(s for s in doc["jobs"]["test"]["steps"]
            if s.get("name") == "Garde — le bundle front committé correspond toujours à ses sources")
sys.stdout.write(step["run"])
PY
}
guard_body > "$scratch/guard.sh"
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
( cd "$D" && BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-renamed.txt" 2>&1
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
( cd "$A" && BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-added.txt" 2>&1
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
( cd "$I" && BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-ignored.txt" 2>&1
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
( cd "$M" && BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-match.txt" 2>&1
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
  ( cd "$B" && BUNDLE_DIST="$bad" bash "$scratch/guard.sh" ) > "$scratch/out-bad.txt" 2>&1
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
( cd "$U" && BUNDLE_DIST=other/dist bash "$scratch/guard.sh" ) > "$scratch/out-untracked.txt" 2>&1
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
# 5. As shipped, the block is inert: the template is valid YAML and carries
#    neither step. A default-on gate on the 192 repos this does not apply to is
#    exactly what the measurement ruled out.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
names = [s.get("name") for s in doc["jobs"]["test"]["steps"]]
for forbidden in ("Reconstruire le bundle front committé",
                  "Garde — le bundle front committé correspond toujours à ses sources"):
    assert forbidden not in names, \
        f"the opt-in step is ACTIVE in the shipped template: {forbidden}"
PY
echo "  [5] as shipped the block is inert — neither step is active"

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
# Two boundary tests fail here, both silently and both by over-reaching:
#   * "next `- name:`" — the next one in this file is inside the opt-in block and is COMMENTED
#     OUT, so the scan runs to EOF and swallows 130 unrelated lines;
#   * "next `--8<--` sentinel" — better, but the opt-in section opens with ~40 lines of comment
#     ABOVE its sentinel, at the step's own indent, which still get absorbed.
# Everything belonging to this step is indented deeper than its `- name:`, so the first non-blank
# line back at that indent is the true end. The assertions below then quote this step or nothing.
indent = len(lines[start]) - len(lines[start].lstrip())
end = next((i for i in range(start + 1, len(lines))
            if lines[i].strip() and (len(lines[i]) - len(lines[i].lstrip())) <= indent),
           len(lines))
block = "\n".join(lines[start:end])
# Prove the slice really is one step, so a future boundary regression surfaces here rather than
# silently widening what the assertions below are allowed to match.
assert "--8<--" not in block, "the extracted block leaked into the opt-in section"
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

if find "$hyg" -path '*/bin/*' -name '*.log' | grep -q .; then
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
