#!/usr/bin/env bash
# audit-inventory `vendoredAssets` golden test.
#
# The key exists because a vendored front-end copy is invisible to dependency automation: no
# manifest entry means Renovate never opens a PR and Dependabot never raises an advisory. The CVE
# is not unfixed — it is UNSEEN, on a repo that looks tended. Phase 1 is the last place that
# finding can still change a plan, so the assessment has to carry it.
#
# Measured on 193 local .NET repos before this was written (issue #32): 17 carry a
# `wwwroot/lib/<name>`, 38 directories in all, 1201 files — and NOT ONE is covered by a manifest.
# So the reported case is the common one and the covered case is the rare one; both are pinned
# here, because a check that only ever reports would pass just as well by reporting everything.
#
# What is asserted:
#   1. an uncovered `wwwroot/lib/<name>` is reported, at library granularity, with its file count;
#   2. a directory a `package.json` covers is NOT reported — the check is "no manifest covers it",
#      not "the path looks like a lib folder";
#   3. `libman.json` counts as a manifest too — it is the ASP.NET-native way to declare exactly
#      this directory, and ignoring it would report a repo that does declare its libraries;
#   4. the key is present and EMPTY when there is nothing to report, never absent — a consumer has
#      to be able to tell "measured, none" from "not measured";
#   5. a nested app (`src/App/wwwroot/lib/…`) is found, and `node_modules` is never walked;
#  5b. a nested CHECKOUT is not counted twice — and 5c, one under wwwroot/lib still IS reported,
#      with its `.git` pointer not counted as an asset;
#  5d. coverage is resolved per path and per scope, never from a global pool of bare names;
#  5e. a nested checkout's manifest cannot silence a finding in the host repo;
#  5f. loose files count as vendoring, and a declared name covers one only on a name boundary;
#   7. ONE traversal rule — a nested checkout inflates no key, not just `vendoredAssets`;
#   8. `packages/` is judged per child by shape (name, lib/, .nupkg, v3 layout), and every child
#      dropped by that decision is NAMED in `excludedFromWalk`;
#  8b. DEPTH decides nothing: a first-party package is walked whether its project sits in the
#      child, under `lib/`, or under a version-shaped directory (#107);
#   9. a loose file is a finding only when it is an asset — `.gitkeep` and `README.md` are not;
#   6. the output is still valid JSON, including from a foreign working directory.
#
# Sections 7-9 are new and sit before 6, which is the historical tail. The numbering is the order
# they were added, not the order they run — the list above is in FILE order so it stays a map.
#
# Every branch of the `packages/` detector is mutation-tested: break one and this suite fails.
# That is not decoration. The first version of section 8 piled every signal into one fixture, so
# each masked the others, and 4 of 6 mutants survived — a heuristic deciding whether a whole repo
# is visible, with no effective test.
#
# Everything runs on scratch trees under $(mktemp -d). samples/LegacyShop is read-only here, and
# cleanup() asserts it on every exit path.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
INV="$KIT/scripts/audit-inventory.sh"

. "$KIT/tests/_lib.sh"
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged
# Deliberately NO __pycache__ guard here, though a sibling suite registers one. This file only ever
# runs `python3 - <<PY` (script on stdin) and audit-inventory.sh (likewise), and neither path can
# write bytecode — so the guard would be dead with respect to its own work. The only way it could
# fire is on a __pycache__ left by an EARLIER ci.yml step, and it would then blame this suite for
# another's leftovers. tests/xunit-v3/test.sh owns that kit-wide invariant, where the importlib
# loader it guards actually lives.

scratch=$(kit_scratch)

# A minimal .NET repo shape. audit-inventory walks the filesystem, so a csproj is all it needs to
# recognise the tree; git is optional (the script already falls back to "unknown" for the dates).
mk_app() {
  local root="$1"
  mkdir -p "$root"
  cat > "$root/App.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>
XML
}

# n files under a directory, so the reported count is a number this test chose.
mk_files() {
  local dir="$1" n="$2" i
  mkdir -p "$dir"
  for i in $(seq 1 "$n"); do echo "/* $i */" > "$dir/f$i.js"; done
}

# ---------------------------------------------------------------------------
# 1+2+3. Reported vs not reported, in ONE tree — so the check has to discriminate
#        rather than pass by reporting everything or nothing.
# ---------------------------------------------------------------------------
A="$scratch/discriminate"
mk_app "$A"
mk_files "$A/wwwroot/lib/bootstrap/dist" 4        # vendored, no manifest    -> covered=false
mk_files "$A/wwwroot/lib/jquery" 2                # declared in package.json -> covered=true
mk_files "$A/wwwroot/lib/prism" 3                 # declared in libman.json  -> covered=true
cat > "$A/package.json" <<'JSON'
{ "name": "app", "dependencies": { "jquery": "3.7.1" } }
JSON
cat > "$A/libman.json" <<'JSON'
{
  "version": "1.0",
  "defaultProvider": "cdnjs",
  "libraries": [ { "library": "prism@1.29.0", "destination": "wwwroot/lib/prism/" } ]
}
JSON

out=$("$INV" "$A")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
va = inv.get("vendoredAssets")
assert va is not None, "audit-inventory.sh emits no vendoredAssets key"
paths = {e["path"]: e for e in va}
assert "wwwroot/lib/bootstrap" in paths, \
    f"the uncovered vendored copy was not reported: {sorted(paths)}"
assert paths["wwwroot/lib/bootstrap"]["files"] == 4, paths["wwwroot/lib/bootstrap"]
assert paths["wwwroot/lib/bootstrap"]["coveredByManifest"] is False, paths["wwwroot/lib/bootstrap"]
assert paths["wwwroot/lib/bootstrap"].get("coveredBy") is None, paths["wwwroot/lib/bootstrap"]
# The key is a CENSUS: a declared library is still listed, with the manifest that declares it. That
# is the de-vendoring evidence phase 1 needs — it shows the repo already has a working pattern to
# copy, in a named file — and it is what makes `coveredByManifest` real data instead of a constant
# that could only ever read false.
for lib, manifest in (("jquery", "package.json"), ("prism", "libman.json")):
    e = paths.get(f"wwwroot/lib/{lib}")
    assert e is not None, f"the census dropped a covered library: {sorted(paths)}"
    assert e["coveredByManifest"] is True, e
    assert e["coveredBy"] == manifest, \
        f"{lib} must name the manifest that covers it, got {e.get('coveredBy')!r}"
assert len(va) == 3, f"the census must list all three vendored directories, got {va}"
PY
echo "  [1-3] a census: the uncovered copy AND the covered ones, each naming its manifest"

# ---------------------------------------------------------------------------
# 4. Present and empty when there is nothing to report — "measured, none" must be
#    distinguishable from "not measured".
# ---------------------------------------------------------------------------
B="$scratch/no-frontend"
mk_app "$B"
out=$("$INV" "$B")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
assert "vendoredAssets" in inv, "the key must be present even when there is nothing to report"
assert inv["vendoredAssets"] == [], inv["vendoredAssets"]
PY
# The committed fixture is a real repo with no front-end: same contract, on something not built here.
out=$("$INV" "$KIT/samples/LegacyShop")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
assert inv.get("vendoredAssets") == [], inv.get("vendoredAssets")
PY
echo "  [4] the key is present and empty on a repo with no front-end (scratch AND the fixture)"

# ---------------------------------------------------------------------------
# 5. A nested app is found; node_modules is never walked.
#
#    The node_modules case is not hypothetical: two repos in the measured population track
#    node_modules in git (1430 and 971 files). Walking it would bury the real findings under
#    every transitive package that happens to ship a `wwwroot/lib`.
# ---------------------------------------------------------------------------
C="$scratch/nested"
mk_app "$C/src/App"
mk_files "$C/src/App/wwwroot/lib/bootstrap" 5
mk_files "$C/node_modules/some-pkg/wwwroot/lib/bootstrap" 7
out=$("$INV" "$C")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
paths = {e["path"]: e for e in inv["vendoredAssets"]}
assert "src/App/wwwroot/lib/bootstrap" in paths, \
    f"a vendored copy inside a nested app was missed: {sorted(paths)}"
assert paths["src/App/wwwroot/lib/bootstrap"]["files"] == 5, paths
assert not any("node_modules" in p for p in paths), \
    f"node_modules was walked: {sorted(paths)}"
PY
echo "  [5] finds a nested app's copy, and never walks node_modules"

# ---------------------------------------------------------------------------
# 5b. A nested CHECKOUT is a copy — counting it doubles every finding.
#
#     Found by running the new key against real repos rather than only against fixtures:
#     NetImpex reported 8 vendored directories for 4 real ones, 120 files instead of 60, because
#     an agent worktree under `.claude/worktrees/` holds a second copy of the whole app. A wrong
#     number, not a missing one — and an assessment is read as a count.
#
#     The rule is general (own `.git` ⇒ own project): agent worktree, submodule, vendored clone.
#     A git worktree's `.git` is a FILE, not a directory, so the check tests existence, not isdir.
# ---------------------------------------------------------------------------
D="$scratch/nested-checkout"
mk_app "$D/src/App"
mk_files "$D/src/App/wwwroot/lib/bootstrap" 6
mkdir -p "$D/.claude/worktrees/agent-copy/src/App"
cp "$D/src/App/App.csproj" "$D/.claude/worktrees/agent-copy/src/App/App.csproj"
mk_files "$D/.claude/worktrees/agent-copy/src/App/wwwroot/lib/bootstrap" 6
echo "gitdir: /elsewhere/.git/worktrees/agent-copy" > "$D/.claude/worktrees/agent-copy/.git"
# A submodule-shaped nested checkout, with a real .git DIRECTORY this time.
mkdir -p "$D/vendor/thirdparty/.git"
mk_files "$D/vendor/thirdparty/wwwroot/lib/bootstrap" 6
out=$("$INV" "$D")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
va = inv["vendoredAssets"]
paths = sorted(e["path"] for e in va)
assert paths == ["src/App/wwwroot/lib/bootstrap"], \
    f"a nested checkout was counted as part of this repo: {paths}"
assert va[0]["files"] == 6, va[0]
PY
echo "  [5b] a nested checkout (agent worktree, submodule) is not counted twice"

# ---------------------------------------------------------------------------
# 5c. …but a nested checkout that IS the vendored copy must still be reported.
#
#     A git submodule under `wwwroot/lib/` is the LEAST watched shape of all: Renovate's
#     `git-submodules` manager is off by default and Dependabot's `gitsubmodule` ecosystem must be
#     opted into. The "own .git ⇒ own project" rule of 5b would drop precisely the case this key
#     exists for, so the rule has to stop at the vendor directory.
# ---------------------------------------------------------------------------
E="$scratch/vendored-submodule"
mk_app "$E"
mk_files "$E/wwwroot/lib/bootstrap" 3
echo "gitdir: /elsewhere/.git/modules/bootstrap" > "$E/wwwroot/lib/bootstrap/.git"
out=$("$INV" "$E")
python3 - "$out" <<'PY'
import json, sys
va = json.loads(sys.argv[1])["vendoredAssets"]
paths = [e["path"] for e in va]
assert paths == ["wwwroot/lib/bootstrap"], \
    f"a submodule-vendored library was dropped as if it were a foreign project: {paths}"
# The submodule's `.git` POINTER is a file, not a directory, so it falls through PRUNE (which
# names `.git` as a directory) straight into the file count — inflating every submodule-vendored
# entry by one. The fixture has 3 assets; 4 means the pointer was counted as an asset.
assert va[0]["files"] == 3, \
    f"the submodule's .git pointer was counted as one of the library's files: {va[0]}"
PY
echo "  [5c] a submodule UNDER wwwroot/lib is reported, and its .git pointer is not an asset"

# ---------------------------------------------------------------------------
# 5d. Coverage is resolved by PATH and by SCOPE, not by a global pool of bare names.
#
#     Three false verdicts the "one set of names for the whole repo" version produced, all
#     reproduced here:
#       (a) a libman `destination` pointing DEEPER than the library directory
#           (`wwwroot/lib/bootstrap/dist`) contributed only `dist` and the package id, never
#           `bootstrap` — so a declared library was reported as an unwatched blind spot;
#       (b) in a multi-app solution — the NORMAL shape for this kit's targets — appB's
#           package.json silenced appA's genuinely undeclared copy;
#       (c) a destination ending in `/dist` injected the bare name `dist` and masked an unrelated
#           `wwwroot/lib/dist`.
# ---------------------------------------------------------------------------
F="$scratch/scoped"
mk_app "$F/appA"
mk_app "$F/appB"
mk_files "$F/appA/wwwroot/lib/jquery" 2          # (b) undeclared HERE -> must be reported
mk_files "$F/appB/wwwroot/lib/bootstrap" 2       # (a) declared by a deep libman destination
mk_files "$F/appB/wwwroot/lib/dist" 2            # (c) unrelated, must not be masked
cat > "$F/appB/package.json" <<'JSON'
{ "name": "b", "dependencies": { "jquery": "3.7.1" } }
JSON
cat > "$F/appB/libman.json" <<'JSON'
{
  "version": "1.0",
  "defaultProvider": "cdnjs",
  "libraries": [ { "library": "twitter-bootstrap@5.3.3",
                   "destination": "wwwroot/lib/bootstrap/dist" } ]
}
JSON
out=$("$INV" "$F")
python3 - "$out" <<'PY'
import json, sys
by = {e["path"]: e for e in json.loads(sys.argv[1])["vendoredAssets"]}
# Every directory is listed now; what discriminates is `coveredByManifest`.
assert by["appA/wwwroot/lib/jquery"]["coveredByManifest"] is False, \
    f"(b) another app's package.json silenced a real finding: {by['appA/wwwroot/lib/jquery']}"
assert by["appB/wwwroot/lib/bootstrap"]["coveredByManifest"] is True, \
    f"(a) a library declared by a deep libman destination reads as unwatched: {by['appB/wwwroot/lib/bootstrap']}"
assert by["appB/wwwroot/lib/bootstrap"]["coveredBy"] == "appB/libman.json", \
    by["appB/wwwroot/lib/bootstrap"]
assert by["appB/wwwroot/lib/dist"]["coveredByManifest"] is False, \
    f"(c) an unrelated directory was masked by a bare name from a destination: {by['appB/wwwroot/lib/dist']}"
PY
echo "  [5d] coverage is per-path and per-scope (deep libman dest, multi-app, no bare-name leak)"

# ---------------------------------------------------------------------------
# 5e. A manifest inside a NESTED CHECKOUT must not silence the host repo.
#
#     The mirror of 5b, and the same root cause: the old code pruned nested checkouts from the
#     vendored walk but still read their manifests, so a submodule declaring `bootstrap` erased a
#     real finding in the parent. A missing number instead of a wrong one — on the key whose
#     entire point is saying "nothing watches this".
# ---------------------------------------------------------------------------
G="$scratch/foreign-manifest"
mk_app "$G"
mk_files "$G/wwwroot/lib/bootstrap" 3
mkdir -p "$G/sub"
echo "gitdir: /elsewhere/.git/modules/sub" > "$G/sub/.git"
cat > "$G/sub/package.json" <<'JSON'
{ "name": "sub", "dependencies": { "bootstrap": "5.3.3" } }
JSON
out=$("$INV" "$G")
python3 - "$out" <<'PY'
import json, sys
paths = [e["path"] for e in json.loads(sys.argv[1])["vendoredAssets"]]
assert paths == ["wwwroot/lib/bootstrap"], \
    f"a nested checkout's package.json silenced the host repo's finding: {paths}"
PY
echo "  [5e] a nested checkout's manifest cannot silence the host repo"

# ---------------------------------------------------------------------------
# 5f. Loose files dropped straight into wwwroot/lib/ are vendoring too.
#
#     `wwwroot/lib/htmx.min.js` with no subdirectory is the archetypal copy-paste, and it carries
#     CVEs exactly like a directory does. Measured locally: 3 repos, 8 files (htmx, chart.min.js,
#     pico.css) against 17 repos using subdirectories — rare, not absent. Without this, `[]` would
#     sometimes mean "measured, and missed it" while phase 1 reads it as "measured, none".
#
#     A declared name still covers its file, but only on a name boundary: `jquery` covers
#     `jquery-3.4.1.min.js`, and must NOT cover `jqueryui.js`.
# ---------------------------------------------------------------------------
H="$scratch/loose"
mk_app "$H"
mkdir -p "$H/wwwroot/lib"
echo 'x' > "$H/wwwroot/lib/htmx.min.js"            # undeclared      -> reported
echo 'x' > "$H/wwwroot/lib/jquery-3.4.1.min.js"    # declared jquery -> not reported
echo 'x' > "$H/wwwroot/lib/jqueryui.js"            # NOT jquery      -> reported
cat > "$H/package.json" <<'JSON'
{ "name": "h", "dependencies": { "jquery": "3.4.1" } }
JSON
out=$("$INV" "$H")
python3 - "$out" <<'PY'
import json, sys
va = json.loads(sys.argv[1])["vendoredAssets"]
by = {e["path"]: e for e in va}
assert by["wwwroot/lib/htmx.min.js"]["coveredByManifest"] is False, \
    f"an undeclared loose file reads as covered: {by['wwwroot/lib/htmx.min.js']}"
assert by["wwwroot/lib/jquery-3.4.1.min.js"]["coveredByManifest"] is True, \
    f"a loose file covered by a declared name reads as unwatched: {by['wwwroot/lib/jquery-3.4.1.min.js']}"
assert by["wwwroot/lib/jqueryui.js"]["coveredByManifest"] is False, \
    f"the name-boundary rule leaked: 'jquery' must not cover 'jqueryui.js': {by['wwwroot/lib/jqueryui.js']}"
assert all(e["files"] == 1 for e in va if e["path"].endswith(".js")), va
PY
echo "  [5f] loose files count, and a declared name covers only on a name boundary"

# ---------------------------------------------------------------------------
# 5g. When several manifests cover the same directory, ONE of them is named, and it is the same
#     one on every run.
#
#     Without a rule, `coveredBy` depends on os.walk order — so the JSON churns between runs on a
#     repo nobody touched, and a consumer diffing two assessments sees a change that is not one.
#     The rule: the NEAREST manifest wins (the one whose directory is deepest, i.e. most specific
#     to the library); libman breaks a tie, because it is the manifest that actually governs
#     `wwwroot/lib` while package.json merely happens to name the same package.
# ---------------------------------------------------------------------------
J="$scratch/multi-manifest"
mk_app "$J/app"
mk_files "$J/app/wwwroot/lib/bootstrap" 2
cat > "$J/package.json" <<'JSON'
{ "name": "root", "dependencies": { "bootstrap": "5.3.3" } }
JSON
cat > "$J/app/package.json" <<'JSON'
{ "name": "app", "dependencies": { "bootstrap": "5.3.3" } }
JSON
cat > "$J/app/libman.json" <<'JSON'
{ "version": "1.0", "defaultProvider": "cdnjs",
  "libraries": [ { "library": "twitter-bootstrap@5.3.3",
                   "destination": "wwwroot/lib/bootstrap" } ] }
JSON
first=$("$INV" "$J")
second=$("$INV" "$J")
python3 - "$first" "$second" <<'PY'
import json, sys
a = {e["path"]: e for e in json.loads(sys.argv[1])["vendoredAssets"]}
b = {e["path"]: e for e in json.loads(sys.argv[2])["vendoredAssets"]}
e = a["app/wwwroot/lib/bootstrap"]
assert e["coveredByManifest"] is True, e
assert e["coveredBy"] == b["app/wwwroot/lib/bootstrap"]["coveredBy"], \
    ("coveredBy changed between two runs of the same tree — the JSON would churn and a consumer "
     f"diffing assessments would see a phantom change: {e['coveredBy']!r} vs "
     f"{b['app/wwwroot/lib/bootstrap']['coveredBy']!r}")
# Nearest wins: app/ beats the repo root. Libman breaks the tie at the same depth.
assert e["coveredBy"] == "app/libman.json", \
    f"expected the nearest manifest (app/libman.json), got {e['coveredBy']!r}"
PY
echo "  [5g] several covering manifests -> the nearest one, named, and stable across runs"

# ---------------------------------------------------------------------------
# 7. ONE traversal rule — a nested checkout must not inflate ANY key.
#
#    `vendoredAssets` has skipped nested checkouts since #64; every other key still walked them,
#    because the script carried two encodings of "directories we never walk" (`EXCLUDE`, used by
#    files(); `PRUNE`/prune(), used by the vendored scan only). Measured before this was fixed:
#      - ai-migration-kit reported testStack = 6 for ONE test project — five were copies of
#        samples/LegacyShop inside its own agent worktrees, each contributing the same xunit pin;
#      - Koine 1825 csFiles, NetImpex 1116, repo-audit 348, all inflated by worktree copies.
#    Wrong numbers with no symptom, in a document phase 1 copies into an assessment.
# ---------------------------------------------------------------------------
N="$scratch/nested-inflates"
mk_app "$N/src/App"
cat > "$N/src/App/Real.cs" <<'CS'
namespace App { public class Real { public int X() { return 1; } } }
CS
# A worktree-shaped copy of the whole app, carrying its own .git — a COPY, not this repo's code.
mkdir -p "$N/.claude/worktrees/agent/src/App"
cp "$N/src/App/App.csproj" "$N/.claude/worktrees/agent/src/App/App.csproj"
cp "$N/src/App/Real.cs"    "$N/.claude/worktrees/agent/src/App/Real.cs"
echo "gitdir: /elsewhere/.git/worktrees/agent" > "$N/.claude/worktrees/agent/.git"
# …and a test project inside the copy, which is what inflated testStack.
mkdir -p "$N/.claude/worktrees/agent/tests/App.Tests"
cat > "$N/.claude/worktrees/agent/tests/App.Tests/App.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net6.0</TargetFramework></PropertyGroup>
  <ItemGroup><PackageReference Include="xunit" Version="2.4.2" /></ItemGroup>
</Project>
XML
out=$("$INV" "$N")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
assert inv["csFiles"] == 1, \
    f"a nested checkout inflated csFiles: expected 1, got {inv['csFiles']}"
assert inv["testStack"] == [], \
    f"a nested checkout's test project entered testStack: {inv['testStack']}"
assert inv["projects"] == ["App"], \
    f"a nested checkout's project entered the project list: {inv['projects']}"
PY
echo "  [7] a nested checkout inflates no key — csFiles, testStack and projects all exclude it"

# ---------------------------------------------------------------------------
# 8. `packages/` is decided by CONTENT, not by its name.
#
#    Skipping it repo-wide is right for the legacy population, where it is the NuGet restore
#    folder, and catastrophic for a monorepo that keeps its apps there: measured, openjam-monorepo
#    reported csFiles = 0, locTotal = 0, testStack = 0 — not "small", INVISIBLE, with zeroes
#    instead of an error.
#
#    Declaration-based detection was the plan and it is dead: ZERO local repos declare a
#    `packages/` workspace, openjam-monorepo has no root package.json at all. The measured
#    discriminator is content — a restore folder carries `.nupkg` files (and usually
#    `repositories.config`); a source folder does not. 8/8 correct on the real population.
# ---------------------------------------------------------------------------
# Each restore SHAPE gets its OWN fixture. The first version of this section piled every signal
# into one tree, so each masked the others: mutation-testing the detector (drop the
# repositories.config branch / the depth-2 scan / the flat .nupkg check, one at a time) left the
# whole suite GREEN. A heuristic that decides whether an entire repo is visible had, in effect, no
# test. Each fixture below carries exactly one shape, plus third-party source that must not leak.
# A restore folder carries third-party source AND a foreign project — both must stay out, or the
# assertions below are vacuous (nothing to leak means nothing can be caught leaking).
seed_foreign() {
  mkdir -p "$1/lib/net45"
  echo 'namespace Third { public class Junk { } }' > "$1/lib/net45/Junk.cs"
  cat > "$1/lib/net45/Third.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net45</TargetFramework></PropertyGroup>
  <ItemGroup><PackageReference Include="xunit" Version="2.4.2" /></ItemGroup>
</Project>
XML
}

# One real .cs, one real project — every restore case must report exactly these and nothing else.
mk_host() {
  mk_app "$1/src/App"
  echo 'namespace App { public class Real { } }' > "$1/src/App/Real.cs"
}

# A NAMED library project plus one source file, for the fixtures where the project's own name is
# the assertion — `projects` reports csproj stems, so "MyLib" appearing there is the proof that
# this exact directory was walked rather than some other one.
mk_lib() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cat > "$dir/$name.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>
XML
  echo "namespace $name { public class Svc { } }" > "$dir/Svc.cs"
}

assert_restore_skipped() {
  python3 - "$($INV "$1")" "$2" "$3" <<'PY'
import json, sys
inv, name, child = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
assert inv["csFiles"] == 1, f"[{name}] restore folder walked: csFiles={inv['csFiles']} (want 1)"
assert inv["locTotal"] == 1, f"[{name}] third-party lines in locTotal: {inv['locTotal']}"
assert inv["projects"] == ["App"], f"[{name}] a foreign project leaked in: {inv['projects']}"
assert inv["testStack"] == [], f"[{name}] a foreign test project leaked in: {inv['testStack']}"
# Skipped is not enough — a directory dropped by a DECISION must be named, or the reader of the
# assessment sees a smaller number with nothing to explain it.
got = {e["path"]: e["reason"] for e in inv["excludedFromWalk"]}
assert f"packages/{child}" in got, \
    f"[{name}] the restored package was skipped WITHOUT being named: {got}"
PY
}

# The mirror image: a FIRST-PARTY package under `packages/` must be walked, and must not appear in
# `excludedFromWalk` at all — "named" is the consolation prize for a directory that was dropped,
# not a substitute for counting one that should not have been.
assert_package_walked() {
  python3 - "$($INV "$1")" "$2" "$3" "$4" <<'PY'
import json, sys
inv, name, child, projet = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
assert inv["projects"] == sorted(["App", projet]), \
    f"[{name}] the first-party project was dropped: projects={inv['projects']}"
assert inv["csFiles"] == 2, \
    f"[{name}] its sources were not counted: csFiles={inv['csFiles']} (want 2)"
assert inv["locTotal"] == 2, f"[{name}] its lines were not counted: locTotal={inv['locTotal']}"
got = {e["path"] for e in inv["excludedFromWalk"]}
assert f"packages/{child}" not in got, \
    f"[{name}] a first-party package was excluded from the walk: {sorted(got)}"
PY
}

# Each case isolates ONE signal, because signals that co-occur mask each other: with the combined
# fixture, mutation-testing the detector (drop each branch in turn) left 4 of 6 mutants alive.
# Here every branch is the sole reason its fixture is skipped, so killing it shows up.

# (a) the name alone: `<Id>.<Version>`, with no lib/, no content/, no .nupkg anywhere.
P1="$scratch/pkg-by-name"; mk_host "$P1"
mkdir -p "$P1/packages/Newtonsoft.Json.13.0.1"
echo 'namespace Third { public class Junk { } }' > "$P1/packages/Newtonsoft.Json.13.0.1/Junk.cs"
assert_restore_skipped "$P1" by-name Newtonsoft.Json.13.0.1

# (b) the extracted layout alone: an unversioned name carrying lib/. This is the ORDINARY shape of
#     a committed packages/ — the stock Visual Studio .gitignore excludes *.nupkg, so the archive
#     is usually absent. The first detector walked exactly this (measured: csFiles 1 -> 11).
P2="$scratch/pkg-by-lib"; mk_host "$P2"
mkdir -p "$P2/packages/somelib"
seed_foreign "$P2/packages/somelib"
assert_restore_skipped "$P2" by-lib somelib

# (c) the archive alone: an unversioned name, no lib/, just a .nupkg beside the code.
P3="$scratch/pkg-by-nupkg"; mk_host "$P3"
mkdir -p "$P3/packages/somelib"
: > "$P3/packages/somelib/somelib.nupkg"
echo 'namespace Third { public class Junk { } }' > "$P3/packages/somelib/Junk.cs"
assert_restore_skipped "$P3" by-nupkg somelib

# (d) the v3 "global packages" layout — packages/<id>/<version>/…, what
#     `dotnet restore --packages packages` produces. Neither the child's name nor its immediate
#     contents look like a package; only "every child of it is a version" does.
P4="$scratch/pkg-v3"; mk_host "$P4"
mkdir -p "$P4/packages/newtonsoft.json/13.0.1"
echo 'namespace Third { public class Junk { } }' > "$P4/packages/newtonsoft.json/13.0.1/Junk.cs"
assert_restore_skipped "$P4" v3-global newtonsoft.json

Q="$scratch/packages-source"
mkdir -p "$Q/packages/app-one"
mk_app "$Q/packages/app-one"
echo 'namespace One { public class Svc { public int N() { return 2; } } }' \
  > "$Q/packages/app-one/Svc.cs"
mk_files "$Q/packages/app-one/wwwroot/lib/bootstrap" 3
# A STRAY artefact must not flip the verdict. `dotnet pack -o .`, a committed local feed, or one
# vendored offline package would otherwise make every app in the monorepo invisible again — the
# exact all-zeros failure this section exists to prevent, re-created by a single file.
: > "$Q/packages/app-one/App.1.0.0.nupkg"
out=$("$INV" "$Q")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
assert inv["csFiles"] == 1, \
    f"a SOURCE packages/ was skipped — the repo reads as invisible: csFiles={inv['csFiles']}"
assert inv["projects"] == ["App"], inv["projects"]
paths = [e["path"] for e in inv["vendoredAssets"]]
assert paths == ["packages/app-one/wwwroot/lib/bootstrap"], \
    f"a vendored copy under a source packages/ was missed: {paths}"
assert not any(e["path"] == "packages" for e in inv["excludedFromWalk"]), \
    f"a source packages/ was reported as excluded: {inv['excludedFromWalk']}"
PY
echo "  [8] packages/ decided by structure — 3 restore shapes skipped and named, source walked"

# ---------------------------------------------------------------------------
# 8b. DEPTH must not decide whether a first-party package is visible (#107).
#
#     The (Q) control above puts its project in the child's own directory, which is the only
#     depth the source markers were ever read at — while the restore signals (`lib/`, a
#     version-shaped grandchild) are read one level deeper. A package whose project sits one
#     level down therefore lost on both counts. Measured on `main` before the fix, and the
#     reason this is a bug report rather than a preference:
#
#         packages/MyLib/lib/MyLib.csproj + Svc.cs -> projects=['App'], csFiles=1 (want 2),
#                                                     excludedFromWalk=['packages/MyLib']
#         packages/api/1.0/Api.csproj              -> projects=['App'],
#                                                     excludedFromWalk=['packages/api']
#
#     Neither layout is exotic: `packages/<Name>/lib/` and `packages/<Name>/src/` are ordinary,
#     and `packages/<name>/<version>/` is what a monorepo that versions its own packages looks
#     like. Both were dropped by the rules meant for NuGet's restore output.
# ---------------------------------------------------------------------------
# (e) the project sits under `lib/` — the very directory name the detector reads as proof of a
#     restored package. Source has to win over that signal, exactly as an immediate `.csproj`
#     already wins over a stray `.nupkg` in (Q).
D1="$scratch/pkg-deep-lib"; mk_host "$D1"
mk_lib "$D1/packages/MyLib/lib" MyLib
assert_package_walked "$D1" deep-lib MyLib MyLib

# (f) the project sits under a version-shaped directory, so the child is caught by the v3
#     "every child is a version" rule — which only ever inspected directory NAMES and never
#     checked that the leaf holds no project. Contrast with (d), whose leaf holds none.
D2="$scratch/pkg-deep-version"; mk_host "$D2"
mk_lib "$D2/packages/api/1.0" Api
assert_package_walked "$D2" deep-version api Api
echo "  [8b] a first-party package is walked however deep its project sits"

# ---------------------------------------------------------------------------
# 9. A loose file is only a finding when it IS an asset.
#
#    Reporting `.gitkeep` — the usual sole occupant of an otherwise-empty wwwroot/lib — would
#    attach this key's whole claim ("nothing watches this, a CVE here would be unseen") to a
#    placeholder. So would a README.
# ---------------------------------------------------------------------------
K="$scratch/loose-nonassets"
mk_app "$K"
mkdir -p "$K/wwwroot/lib"
: > "$K/wwwroot/lib/.gitkeep"
echo "# vendored libraries live here" > "$K/wwwroot/lib/README.md"
echo 'x' > "$K/wwwroot/lib/htmx.min.js"
out=$("$INV" "$K")
python3 - "$out" <<'PY'
import json, sys
paths = sorted(e["path"] for e in json.loads(sys.argv[1])["vendoredAssets"])
assert paths == ["wwwroot/lib/htmx.min.js"], \
    f"a placeholder or doc file was reported as an unwatched vendored library: {paths}"
PY
echo "  [9] .gitkeep and README are not vendored libraries; the real asset still is"

# ---------------------------------------------------------------------------
# 6. Still valid JSON, including from a foreign working directory — CI runs this
#    script from someone else's checkout on purpose.
# ---------------------------------------------------------------------------
( cd "$(kit_scratch)" && bash "$INV" "$A" | python3 -m json.tool > /dev/null )
echo "  [6] valid JSON, from a foreign working directory"

echo "audit-inventory vendoredAssets golden test OK"
