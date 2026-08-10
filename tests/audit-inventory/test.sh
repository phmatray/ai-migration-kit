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
  if find "$KIT/scripts" "$KIT/tests" -name '__pycache__' -type d 2>/dev/null | grep -q . ; then
    echo "FAIL: the test left a __pycache__ inside the kit — it must not modify the repo it tests."
    exit 1
  fi
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
# 6. Still valid JSON, including from a foreign working directory — CI runs this
#    script from someone else's checkout on purpose.
# ---------------------------------------------------------------------------
( cd "$(mktemp -d)" && bash "$INV" "$A" | python3 -m json.tool > /dev/null )
echo "  [6] valid JSON, from a foreign working directory"

echo "audit-inventory vendoredAssets golden test OK"
