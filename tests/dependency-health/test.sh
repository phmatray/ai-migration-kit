#!/usr/bin/env bash
# dependency-health golden test (#267, layer 1).
#
# Why this suite exists. Phase 6 defines what "verified" means, and until #267 it meant three
# properties of the SOURCE — it compiles, the tests pass, the diagnostics did not get worse — and
# nothing at all about the DEPENDENCY GRAPH, which is the part phase 3 rewrites most aggressively.
# `scripts/dependency-health.sh` is the measurement that closes that gap, and this is the suite
# that proves the measurement is real rather than decorative.
#
# The failure mode being closed is specific and quiet: **a check that cannot verify must not answer
# "healthy"**. A script that swallows a failing `dotnet` and prints an empty `vulnerable[]` looks
# byte-identical to a clean graph, and phase 6 would pass on it. So the case that matters most here
# is section 3 — the one where `dotnet` fails — and it asserts the ABSENCE of a healthy answer, not
# merely the presence of an error message.
#
# What is asserted:
#   1. `clean`        — both invocations succeed and report nothing: `status == "ok"`, both arrays
#                       empty, exit 0. The `checkedAt` stamp is present and ISO-8601 shaped, so a
#                       reader can tell WHEN the graph was examined and not merely that it was.
#   2. `findings`     — one TRANSITIVE vulnerable package and one deprecated package with an
#                       alternative: `status == "findings"`, `vulnerable[0].transitive == true`
#                       (the transitive half is the load-bearing one — that is where the exposure
#                       the customer never chose actually lives), severity and advisory URL survive
#                       the flattening, the alternative package id is carried through, and the exit
#                       status is still 0 because the posture is REPORT, not block.
#   3. `dotnet-fails` — the stub exits non-zero: `status == "unavailable"`, the reason names the
#                       failing invocation, the block is still emitted (phase 6 hard-gates on that
#                       key's existence, so a silent no-output would fail differently and less
#                       usefully), and the script exits 1.
#
# The suite never touches the network and never runs a real `dotnet`: every case drives the script
# through the `DOTNET_BIN` test-injection seam over recorded JSON, so it is deterministic on a
# machine with no SDK at all. `samples/` is read-only here and kit_guard_samples_unchanged asserts
# it on every exit path.
#
# Layer 2 (registry legitimacy scoring for newly-introduced package ids) was deferred at triage on
# 2026-08-31 — its thresholds are unverified external figures — so there is deliberately no
# `newPackages` case, and section 1 asserts the key is ABSENT. An empty `newPackages[]` would read
# as "nothing new was introduced", which is precisely the claim this layer cannot make.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
DH="$KIT/scripts/dependency-health.sh"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged
# No __pycache__ guard, for the reason tests/audit-inventory/test.sh states about itself: every
# python3 in this file and in the script under test runs from stdin (`python3 - <<PY`), which
# cannot write bytecode, so the guard would be dead with respect to this suite's own work and could
# only ever fire on an earlier CI step's leftovers.

[ -f "$DH" ] || {
  echo "FAIL: $DH is missing — the script this suite measures does not exist yet"; exit 1; }
[ -x "$DH" ] || {
  echo "FAIL: $DH exists but is not executable"; exit 1; }

scratch=$(kit_scratch)

# ---------------------------------------------------------------------------------- the test seam
#
# One `dotnet` double, written once and pointed at the fixture files sitting beside it. It answers
# the invocations the script makes — `--version`, `restore`, and the two `list package … --format
# json` calls — and refuses anything else LOUDLY (exit 99) rather than returning empty output: a
# stub that answered an unexpected invocation with silence would let the script's own parsing
# decide the verdict, and the suite would then be measuring the stub.
make_case() {
  # $1 = case name. Prints the case directory; the caller drops fixtures into it.
  local dir="$scratch/$1"
  mkdir -p "$dir/repo"
  cat > "$dir/dotnet" <<'STUB'
#!/usr/bin/env bash
# Test double for `dotnet`. Reads its answers from the files beside it.
here="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  --version) cat "$here/sdk-version.txt" 2>/dev/null || echo "8.0.100"; exit 0 ;;
  restore)   exit 0 ;;
esac
if [ -f "$here/fail-on" ]; then
  needle="$(cat "$here/fail-on")"
  case "$*" in
    *"$needle"*) echo "stub: simulated dotnet failure on '$needle'" >&2; exit 7 ;;
  esac
fi
case "$*" in
  *--vulnerable*) cat "$here/vulnerable.json"; exit 0 ;;
  *--deprecated*) cat "$here/deprecated.json"; exit 0 ;;
esac
echo "stub: unexpected invocation: $*" >&2
exit 99
STUB
  chmod +x "$dir/dotnet"
  printf '%s\n' "$dir"
}

# Runs the script for a case and leaves stdout in $dir/out.json, stderr in $dir/err.txt and the
# exit status in $dir/rc.txt. The status is captured rather than asserted at the call site because
# one of the three cases expects a NON-zero one, and `set -e` would otherwise end the suite at the
# invocation instead of at the assertion that explains it.
run_case() {
  local dir="$1" rc=0
  DOTNET_BIN="$dir/dotnet" "$DH" "$dir/repo" > "$dir/out.json" 2> "$dir/err.txt" || rc=$?
  printf '%s\n' "$rc" > "$dir/rc.txt"
}

# assert_json <case-dir> <<'ASSERT' … python … ASSERT
#
# The assertion program arrives on THIS function's stdin (a heredoc at the call site) and is handed
# to python3 through the environment, so a program full of quotes and f-strings never has to
# survive a round-trip through shell quoting — the shape that makes an assertion silently stop
# asserting. The preamble parses the emitted JSON itself instead of grepping it, so a shape change
# fails as a shape change, and binds `block`, `rc`, `err`, `raw` and `fail` for the program.
assert_json() {
  local dir="$1"
  local prog
  prog=$(cat)
  DH_CASE="$dir" DH_PROG="$prog" python3 - <<'PY'
import json, os, re, sys

case = os.environ["DH_CASE"]
name = os.path.basename(case)
with open(os.path.join(case, "out.json"), encoding="utf-8") as fh:
    raw = fh.read()
with open(os.path.join(case, "err.txt"), encoding="utf-8") as fh:
    err = fh.read()
with open(os.path.join(case, "rc.txt"), encoding="utf-8") as fh:
    rc = int(fh.read().strip())


def fail(msg):
    print("FAIL [%s]: %s" % (name, msg))
    print("  stdout was:")
    print("\n".join("    " + line for line in raw.splitlines()) or "    (empty)")
    print("  stderr was:")
    print("\n".join("    " + line for line in err.splitlines()) or "    (empty)")
    sys.exit(1)


try:
    doc = json.loads(raw)
except ValueError as exc:
    fail("stdout is not valid JSON (%s)" % exc)

if "dependencyHealth" not in doc:
    fail("the emitted object has no `dependencyHealth` key — phase 6 hard-gates on that key's "
         "presence, so the wrapper is part of the contract, not a formatting choice")
block = doc["dependencyHealth"]

exec(os.environ["DH_PROG"], {
    "block": block, "rc": rc, "err": err, "raw": raw, "fail": fail, "re": re, "json": json,
})
PY
}

# ---------------------------------------------------------------------------------- 1. clean
#
# Both invocations succeed and report nothing. The FIRST project carries the shape `dotnet` really
# emits for a project with no matching packages — the `frameworks` key is OMITTED ENTIRELY, not set
# to `[]` (measured against SDK 10.0.400). That distinction matters more than it looks: it is the
# same shape a project whose examination FAILED comes back as, which is why the script refuses on
# `problems[]` rather than inferring anything from a missing `frameworks`. The second project
# carries the empty-array spelling, so both are pinned and neither can regress unnoticed.
clean=$(make_case clean)
cat > "$clean/vulnerable.json" <<'JSON'
{
  "version": 1,
  "parameters": "--vulnerable --include-transitive",
  "projects": [
    { "path": "/repo/src/App/App.csproj" },
    { "path": "/repo/src/Lib/Lib.csproj", "frameworks": [] }
  ]
}
JSON
cat > "$clean/deprecated.json" <<'JSON'
{
  "version": 1,
  "parameters": "--deprecated --include-transitive",
  "projects": [
    { "path": "/repo/src/App/App.csproj" },
    { "path": "/repo/src/Lib/Lib.csproj", "frameworks": [] }
  ]
}
JSON
run_case "$clean"
assert_json "$clean" <<'ASSERT'
if rc != 0:
    fail("a clean graph must exit 0, got %d" % rc)
if block.get("status") != "ok":
    fail("status must be \"ok\" on a clean graph, got %r" % (block.get("status"),))
if block.get("vulnerable") != []:
    fail("vulnerable[] must be empty, got %r" % (block.get("vulnerable"),))
if block.get("deprecated") != []:
    fail("deprecated[] must be empty, got %r" % (block.get("deprecated"),))
stamp = block.get("checkedAt") or ""
if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", stamp):
    fail("checkedAt must be an ISO-8601 UTC stamp, got %r — a reader has to be able to tell WHEN "
         "the graph was examined, not merely that it was" % (stamp,))
if "newPackages" in block:
    fail("layer 2 was deferred, so `newPackages` must be ABSENT rather than an empty array: an "
         "empty array reads as \"nothing new was introduced\", a claim this layer cannot make")
ASSERT
echo "  ok: clean — status ok, both arrays empty, exit 0, checkedAt stamped"

# ---------------------------------------------------------------------------------- 2. findings
#
# One transitive vulnerable package and one deprecated top-level package with an alternative. The
# transitive half is the load-bearing one: `--include-transitive` is what reaches the dependencies
# the customer never chose, which is where the exposure usually is.
findings=$(make_case findings)
cat > "$findings/vulnerable.json" <<'JSON'
{
  "version": 1,
  "parameters": "--vulnerable --include-transitive",
  "projects": [
    {
      "path": "/repo/src/App/App.csproj",
      "frameworks": [
        {
          "framework": "net10.0",
          "topLevelPackages": [],
          "transitivePackages": [
            {
              "id": "System.Text.Encodings.Web",
              "resolvedVersion": "4.5.0",
              "vulnerabilities": [
                {
                  "severity": "High",
                  "advisoryurl": "https://github.com/advisories/GHSA-ghhp-997w-qr28"
                }
              ]
            }
          ]
        },
        {
          "framework": "net8.0",
          "topLevelPackages": [],
          "transitivePackages": [
            {
              "id": "System.Text.Encodings.Web",
              "resolvedVersion": "4.5.0",
              "vulnerabilities": [
                {
                  "severity": "High",
                  "advisoryurl": "https://github.com/advisories/GHSA-ghhp-997w-qr28"
                }
              ]
            }
          ]
        }
      ]
    },
    {
      "path": "/repo/src/Lib/Lib.csproj",
      "frameworks": [
        {
          "framework": "net10.0",
          "topLevelPackages": [],
          "transitivePackages": [
            {
              "id": "System.Text.Encodings.Web",
              "resolvedVersion": "4.5.0",
              "vulnerabilities": [
                {
                  "severity": "High",
                  "advisoryurl": "https://github.com/advisories/GHSA-ghhp-997w-qr28"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON
cat > "$findings/deprecated.json" <<'JSON'
{
  "version": 1,
  "parameters": "--deprecated --include-transitive",
  "projects": [
    {
      "path": "/repo/src/App/App.csproj",
      "frameworks": [
        {
          "framework": "net10.0",
          "topLevelPackages": [
            {
              "id": "Microsoft.AspNetCore.Mvc.Versioning",
              "requestedVersion": "5.1.0",
              "resolvedVersion": "5.1.0",
              "deprecationReasons": ["Legacy"],
              "alternativePackage": {
                "id": "Asp.Versioning.Mvc",
                "versionRange": ">= 0.0.0"
              }
            }
          ],
          "transitivePackages": [
            {
              "id": "Microsoft.Azure.KeyVault",
              "resolvedVersion": "3.0.5",
              "deprecationReasons": ["Legacy", "Other"]
            }
          ]
        }
      ]
    }
  ]
}
JSON
run_case "$findings"
assert_json "$findings" <<'ASSERT'
if rc != 0:
    fail("findings must NOT fail the script — the posture is report, not block — got exit %d" % rc)
if block.get("status") != "findings":
    fail("status must be \"findings\", got %r" % (block.get("status"),))
vuln = block.get("vulnerable") or []
if len(vuln) != 1:
    fail("expected exactly one vulnerable row, got %d: %r" % (len(vuln), vuln))
v = vuln[0]
if v.get("id") != "System.Text.Encodings.Web":
    fail("the vulnerable package id was lost: %r" % (v,))
if v.get("transitive") is not True:
    fail("transitive must be True for a package found under transitivePackages: %r — "
         "--include-transitive is the load-bearing half of this check, and a row that does not "
         "say which half it came from cannot be acted on" % (v,))
if v.get("resolved") != "4.5.0":
    fail("the resolved version was lost: %r" % (v,))
if v.get("severity") != "high":
    fail("severity must be normalised to the spec vocabulary (low|moderate|high|critical), "
         "got %r" % (v.get("severity"),))
if v.get("advisory") != "https://github.com/advisories/GHSA-ghhp-997w-qr28":
    fail("the advisory URL was lost: %r" % (v,))
# The same package under two target frameworks of one project is ONE finding — that repetition is
# a presentation detail of the query. The same package in a SECOND project is a wider finding, and
# `projects[]` is what keeps it from collapsing into silence: phase 6 maps one *Prochaines étapes*
# row per finding, and an owner told "upgrade this package" has to know where.
if v.get("projects") != ["/repo/src/App/App.csproj", "/repo/src/Lib/Lib.csproj"]:
    fail("projects[] must name every project the finding was seen in, sorted, got %r"
         % (v.get("projects"),))
dep = block.get("deprecated") or []
if len(dep) != 2:
    fail("expected two deprecated rows (one top-level, one transitive), got %d: %r"
         % (len(dep), dep))
by_id = dict((row.get("id"), row) for row in dep)
d = by_id.get("Microsoft.AspNetCore.Mvc.Versioning")
if d is None:
    fail("the top-level deprecated package id was lost: %r" % (dep,))
if d.get("reasons") != ["Legacy"]:
    fail("the deprecation reasons were lost: %r" % (d,))
if d.get("transitive") is not False:
    fail("a deprecated row must say which half it came from, got transitive=%r for a top-level "
         "package: %r" % (d.get("transitive"), d))
if d.get("alternative") != "Asp.Versioning.Mvc":
    fail("the alternative package must be carried through as a bare id, got %r — it is the one "
         "piece of the finding that tells the owner what to do about it"
         % (d.get("alternative"),))
# `--deprecated` carries `--include-transitive` for the same reason the vulnerable leg does: a
# deprecation the customer never chose is still one they now own. Without the flag this row would
# never exist and the flattener's transitive branch would be dead code reading as coverage.
t = by_id.get("Microsoft.Azure.KeyVault")
if t is None:
    fail("the TRANSITIVE deprecated package never reached the block: %r" % (dep,))
if t.get("transitive") is not True:
    fail("a transitively deprecated package must be marked transitive: %r" % (t,))
if t.get("alternative") is not None:
    fail("a deprecated package with no alternativePackage must report alternative=None, got %r"
         % (t.get("alternative"),))
ASSERT
echo "  ok: findings — transitive vulnerability and deprecations carried through, exit still 0"

# ---------------------------------------------------------------------------- 3. dotnet-fails
#
# THE case this suite exists for. A check that cannot verify must not answer "healthy": the block is
# still emitted (phase 6 gates on its existence), its status is `unavailable`, the reason names what
# failed, and the exit status is 1 so a caller that never parses the JSON still learns something is
# wrong.
fails=$(make_case dotnet-fails)
printf '%s' '--vulnerable' > "$fails/fail-on"
cat > "$fails/deprecated.json" <<'JSON'
{ "version": 1, "parameters": "--deprecated", "projects": [] }
JSON
run_case "$fails"
assert_json "$fails" <<'ASSERT'
if rc != 1:
    fail("a failed dotnet invocation must exit 1, got %d" % rc)
if block.get("status") != "unavailable":
    fail("status must be \"unavailable\" when dotnet fails, got %r — a check that cannot verify "
         "must not answer healthy" % (block.get("status"),))
reason = block.get("reason") or ""
if "--vulnerable" not in reason:
    fail("the reason must name the failing invocation, got %r" % (reason,))
if not err.strip():
    fail("the reason must also reach stderr, so an operator running the script by hand sees it "
         "without having to parse the JSON")
if block.get("vulnerable") != [] or block.get("deprecated") != []:
    fail("an unavailable result must carry EMPTY arrays and say so through `status`, never "
         "partial data that reads as a complete answer")
ASSERT
echo "  ok: dotnet-fails — status unavailable, reason names the invocation, exit 1"

# ---------------------------------------------------------------- 4. project-problems
#
# The same lesson as section 3, one level in. `dotnet` can report a project it could not examine in
# `problems[]` — and such a project entry carries NO `frameworks` key, so the walk skips it in
# SILENCE, indistinguishable from a project that simply has no matching packages. Section 3's
# protection is dotnet's EXIT CODE; this one is about the data. Without it, "the check ran" would
# mean "the process exited 0", and a graph examined in part would be published as `ok`.
problems=$(make_case project-problems)
cat > "$problems/vulnerable.json" <<'JSON'
{
  "version": 1,
  "parameters": "--vulnerable --include-transitive",
  "problems": [
    {
      "project": "/repo/src/Broken/Broken.csproj",
      "level": "error",
      "text": "No assets file was found for /repo/src/Broken/Broken.csproj. Run a NuGet package restore."
    }
  ],
  "projects": [
    { "path": "/repo/src/App/App.csproj", "frameworks": [] },
    { "path": "/repo/src/Broken/Broken.csproj" }
  ]
}
JSON
cat > "$problems/deprecated.json" <<'JSON'
{ "version": 1, "parameters": "--deprecated --include-transitive", "projects": [] }
JSON
run_case "$problems"
assert_json "$problems" <<'ASSERT'
if block.get("status") != "unavailable":
    fail("a project dotnet could not examine must NOT be reported as a clean graph, got %r — a "
         "partially-examined graph is not a verified one" % (block.get("status"),))
if rc != 1:
    fail("a project-level error must exit 1, got %d" % rc)
reason = block.get("reason") or ""
if "Broken.csproj" not in reason and "assets file" not in reason:
    fail("the reason must carry dotnet's own problem text so the operator can fix it, got %r"
         % (reason,))
ASSERT
echo "  ok: project-problems — a project dotnet could not examine is not silently skipped"

echo "dependency-health golden test OK"
