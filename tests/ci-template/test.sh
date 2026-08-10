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
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm "commit the bundle"
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

echo "ci-dotnet template opt-in bundle gate golden test OK"
