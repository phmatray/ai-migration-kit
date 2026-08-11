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
#   6. the output is still valid JSON, including from a foreign working directory.
#
# Everything runs on scratch trees under $(mktemp -d). samples/LegacyShop is read-only here, and
# cleanup() asserts it on every exit path.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
INV="$KIT/scripts/audit-inventory.sh"

scratch=""
# `rc=$?` must be the FIRST statement: anything before it overwrites the status being reported,
# which would turn a failure below into a silent green.
cleanup() {
  local rc=$?
  [ -n "$scratch" ] && rm -rf "$scratch"
  local dirty
  dirty=$(git -C "$KIT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated — this test must not write to samples/:"
    echo "$dirty"
    exit 1
  fi
  # Deliberately NO __pycache__ assertion here, though sibling suites carry one. This file only
  # ever runs `python3 - <<PY` (script on stdin) and audit-inventory.sh (likewise), and neither
  # path can write bytecode — so the guard would be dead with respect to its own work. The only
  # way it could fire is on a __pycache__ left by an EARLIER ci.yml step, and it would then blame
  # this test for another's leftovers. tests/xunit-v3/test.sh §8 owns that kit-wide invariant,
  # where the importlib loader it guards actually lives.
  exit "$rc"
}
trap cleanup EXIT

scratch=$(mktemp -d)

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
mk_files "$A/wwwroot/lib/bootstrap/dist" 4        # vendored, no manifest        -> reported (4)
mk_files "$A/wwwroot/lib/jquery" 2                # declared in package.json     -> not reported
mk_files "$A/wwwroot/lib/prism" 3                 # declared in libman.json      -> not reported
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
# The whole point of the check: a declared library is NOT a finding.
assert "wwwroot/lib/jquery" not in paths, "a package.json dependency was reported as vendored"
assert "wwwroot/lib/prism" not in paths, "a libman.json library was reported as vendored"
assert len(va) == 1, f"expected exactly one finding, got {va}"
PY
echo "  [1-3] reports the uncovered copy, and only it (package.json and libman.json both count)"

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
paths = [e["path"] for e in json.loads(sys.argv[1])["vendoredAssets"]]
assert paths == ["wwwroot/lib/bootstrap"], \
    f"a submodule-vendored library was dropped as if it were a foreign project: {paths}"
PY
echo "  [5c] a submodule UNDER wwwroot/lib is still reported — the least-watched shape of all"

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
paths = sorted(e["path"] for e in json.loads(sys.argv[1])["vendoredAssets"])
assert "appA/wwwroot/lib/jquery" in paths, \
    f"(b) another app's package.json silenced a real finding: {paths}"
assert "appB/wwwroot/lib/bootstrap" not in paths, \
    f"(a) a library declared by a deep libman destination was reported anyway: {paths}"
assert "appB/wwwroot/lib/dist" in paths, \
    f"(c) an unrelated directory was masked by a bare name harvested from a destination: {paths}"
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
paths = sorted(e["path"] for e in va)
assert "wwwroot/lib/htmx.min.js" in paths, f"a loose vendored file was missed: {paths}"
assert "wwwroot/lib/jquery-3.4.1.min.js" not in paths, \
    f"a loose file covered by a declared name was reported: {paths}"
assert "wwwroot/lib/jqueryui.js" in paths, \
    f"the name-boundary rule leaked: 'jquery' must not cover 'jqueryui.js': {paths}"
assert all(e["files"] == 1 for e in va if e["path"].endswith(".js")), va
PY
echo "  [5f] loose files count, and a declared name covers only on a name boundary"

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
P="$scratch/packages-restore"
mk_app "$P/src/App"
mkdir -p "$P/packages/Newtonsoft.Json.13.0.1/lib/net45"
: > "$P/packages/Newtonsoft.Json.13.0.1/Newtonsoft.Json.13.0.1.nupkg"
: > "$P/packages/repositories.config"
# A .cs inside the restore folder must never be counted as this repo's code.
echo 'namespace Pkg { public class Junk { } }' > "$P/packages/Newtonsoft.Json.13.0.1/lib/net45/Junk.cs"
out=$("$INV" "$P")
python3 - "$out" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
assert inv["csFiles"] == 0, f"a NuGet restore folder was walked: csFiles={inv['csFiles']}"
assert inv["projects"] == ["App"], inv["projects"]
PY

Q="$scratch/packages-source"
mkdir -p "$Q/packages/app-one"
mk_app "$Q/packages/app-one"
echo 'namespace One { public class Svc { public int N() { return 2; } } }' \
  > "$Q/packages/app-one/Svc.cs"
mk_files "$Q/packages/app-one/wwwroot/lib/bootstrap" 3
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
PY
echo "  [8] packages/ walked when it holds source, skipped when it holds .nupkg restore output"

# ---------------------------------------------------------------------------
# 6. Still valid JSON, including from a foreign working directory — CI runs this
#    script from someone else's checkout on purpose.
# ---------------------------------------------------------------------------
( cd "$(mktemp -d)" && bash "$INV" "$A" | python3 -m json.tool > /dev/null )
echo "  [6] valid JSON, from a foreign working directory"

echo "audit-inventory vendoredAssets golden test OK"
