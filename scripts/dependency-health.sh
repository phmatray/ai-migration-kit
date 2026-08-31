#!/usr/bin/env bash
# dependency-health.sh <repo-dir | solution | project>
#
# Examines the DELIVERED dependency graph and emits a `dependencyHealth` block, as JSON on stdout,
# for `migration/report.json` to carry. Phase 6 runs it (see
# skills/migrate-legacy/references/phase-6-verify.md).
#
# Why it exists (#267). Phase 6 defines what "verified" means, and it used to mean three properties
# of the SOURCE — it compiles, the tests still pass, the diagnostics did not get worse. None of them
# is a property of the dependency graph, which is the part phase 3 rewrites most aggressively. The
# gap leans in an unhelpful direction: the pipeline is very good at moving every package to its
# newest version, which is exactly the operation that makes a result LOOK healthy. "Latest" and
# "not known-vulnerable" are different claims, and the report used to make neither.
#
# THE POSTURE: report, don't block — but prove the check ran. A CVE in a transitive dependency of a
# customer's app is frequently not fixable inside the migration's scope, so making a finding a hard
# gate would turn a legitimately-complete migration red for something the pipeline cannot fix, and
# would push an operator toward skipping a gate. Findings therefore become a recorded section in
# `migration/report.md` and rows in *Next steps* / *Follow-ups*, which `review-followups` already drains.
# What IS hard-gated is the block's existence and a status that is not `unavailable`: **a check that
# cannot verify must not answer "healthy"**. That is why every failure path below still prints the
# block, with `status: "unavailable"` and a reason, and exits 1 — an empty `vulnerable[]` from a
# `dotnet` that never ran is byte-identical to a clean graph, and that silence is the actual defect
# being closed.
#
# Exit status:
#   0  status is `ok` or `findings` — the check ran
#   1  status is `unavailable` — the check could not run; the reason is on stderr AND in the block
#
# Test seam: `DOTNET_BIN` (default `dotnet`). tests/dependency-health/test.sh drives every case
# through a stub over recorded JSON, so the suite needs no SDK and no network.
#
# Layer 2 of #267 — registry legitimacy scoring for package ids the migration itself introduced
# (`newPackages[]`, `OK`/`SUS`/`SLOP`) — was DEFERRED at triage on 2026-08-31 because its thresholds
# are unverified external figures. This script therefore emits no `newPackages` key at all rather
# than an empty one: an empty array would be read as "nothing new was introduced", which is exactly
# the claim this layer cannot make.
set -euo pipefail

REPO="${1:?usage: dependency-health.sh <repo-dir | solution | project>}"
DOTNET_BIN="${DOTNET_BIN:-dotnet}"

# `dotnet list package --format json` needs SDK >= 7. The kit already requires >= 8, so this floor
# is met by construction — the check is here so that a machine which somehow is not gets an
# `unavailable` block naming its SDK version, rather than an unparseable-output failure that reads
# like a bug in this script.
MIN_SDK_MAJOR=7

TMP=""
cleanup() {
  # FIRST statement, always — the invariant tests/_lib.sh spells out for its own trap handler:
  # anything before it (an `rm`, an `echo`) replaces the status this handler is reporting.
  local rc=$?
  [ -n "$TMP" ] && rm -rf "$TMP"
  exit "$rc"
}

# Prints the `unavailable` block on stdout, the reason on stderr, and exits 1. Both, deliberately:
# stdout is what phase 6 records and gates on, stderr is what an operator running this by hand
# actually reads.
emit_unavailable() {
  echo "dependency-health.sh: $1" >&2
  DH_REASON="$1" python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone

# The cp1252 boundary rule (see the repo profile's Environment gotchas): a script whose output is
# compared or piped must pin both halves, or an em-dash leaves this process as a single byte on a
# Windows host and the JSON downstream is corrupt.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

print(json.dumps({"dependencyHealth": {
    "status": "unavailable",
    "reason": os.environ["DH_REASON"],
    "checkedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "vulnerable": [],
    "deprecated": [],
}}, indent=2, ensure_ascii=False))
PY
  exit 1
}

# A DIRECTORY, a `.sln`/`.slnx`, or a `.csproj` — whatever `dotnet restore` and `dotnet list`
# themselves accept. Directory-only would be a gate nobody can pass on a repo root holding two
# solution files or a solution beside a root `build.proj`: MSBuild answers MSB1050 ("specify which
# project or solution file to use"), the block comes back `unavailable`, and phase 6's exit gate
# then refuses a migration that is in fact complete — with no way to name the intended solution.
if [ ! -e "$REPO" ]; then
  case "$REPO" in
    /*) emit_unavailable "no such file or directory: $REPO" ;;
    *)  emit_unavailable "no such file or directory: $(pwd -P)/$REPO (relative path resolved from $(pwd -P))" ;;
  esac
fi

TMP=$(mktemp -d)
trap cleanup EXIT

# ------------------------------------------------------------------------------ the SDK floor
#
# A version this cannot parse is NOT a verdict: `dotnet --version` can legitimately print a preview
# or a private build string, and refusing on those would be a check that stops the pipeline over its
# own inability to read a number. Only a version that parses AND is below the floor refuses.
sdk_version=$("$DOTNET_BIN" --version 2>/dev/null | head -1 | tr -d '\r' || true)
case "$sdk_version" in
  [0-9]*)
    sdk_major="${sdk_version%%.*}"
    if [ "$sdk_major" -lt "$MIN_SDK_MAJOR" ] 2>/dev/null; then
      emit_unavailable "'$DOTNET_BIN --version' reports $sdk_version, but 'dotnet list package --format json' needs SDK >= $MIN_SDK_MAJOR"
    fi
    ;;
esac

# ------------------------------------------------------------------------------ restore first
#
# `--vulnerable` and `--deprecated` read the restored assets file, not the project files: without a
# restore they report NOTHING and exit 0, which is the healthy-looking silence this whole script
# exists to prevent. Phase 3 has normally restored already, so this is usually a no-op — but "the
# caller probably did it" is not something a gate may assume.
rc=0
"$DOTNET_BIN" restore "$REPO" > "$TMP/restore.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  emit_unavailable "'$DOTNET_BIN restore $REPO' exited $rc — the package graph could not be resolved, so neither --vulnerable nor --deprecated can be trusted (last lines: $(tail -3 "$TMP/restore.log" | tr '\n' ' '))"
fi

# ------------------------------------------------------------------------------ the two queries
#
# `--include-transitive` on the vulnerable leg is the load-bearing half: that is where the exposure
# the customer never chose actually lives, and it is invisible to a top-level-only scan.
run_query() {
  # $1 = output file, rest = arguments after `list package`
  local out="$1"; shift
  local status=0
  "$DOTNET_BIN" list "$REPO" package "$@" > "$out" 2> "$TMP/query.err" || status=$?
  if [ "$status" -ne 0 ]; then
    emit_unavailable "'$DOTNET_BIN list package $* ' exited $status — the check did not run (stderr: $(tr '\n' ' ' < "$TMP/query.err" | cut -c1-400))"
  fi
}

run_query "$TMP/vulnerable.json" --vulnerable --include-transitive --format json
run_query "$TMP/deprecated.json" --deprecated --include-transitive --format json

# ------------------------------------------------------------------------------ flatten and emit
DH_VULN="$TMP/vulnerable.json" DH_DEPR="$TMP/deprecated.json" python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8", newline="\n")

CHECKED_AT = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def unavailable(reason):
    """The same contract the shell's emit_unavailable() honours: the block still exists, its status
    says the check did not run, and the process exits 1. Duplicated in behaviour rather than in
    code because this half has already left the shell — but the SHAPE is the contract, and
    tests/dependency-health/test.sh drives it from the shell side."""
    print("dependency-health.sh: %s" % reason, file=sys.stderr)
    print(json.dumps({"dependencyHealth": {
        "status": "unavailable",
        "reason": reason,
        "checkedAt": CHECKED_AT,
        "vulnerable": [],
        "deprecated": [],
    }}, indent=2, ensure_ascii=False))
    sys.exit(1)


def load(path, label):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.loads(fh.read())
    except (OSError, ValueError) as exc:
        unavailable("'dotnet list package %s' did not produce parseable JSON (%s)" % (label, exc))


def frameworks(doc):
    """`projects[].frameworks[]` — and `frameworks` is ABSENT, not empty, on some SDK/project
    combinations that match nothing, so every level is defended."""
    for project in doc.get("projects") or []:
        for framework in project.get("frameworks") or []:
            yield project.get("path"), framework


def refuse_on_problems(doc, label):
    """`dotnet list package` reports a project it could not examine in `problems[]` — and a project
    entry whose examination failed carries NO `frameworks` key, so the walk above skips it in
    SILENCE. That is the script's own invariant turned against it: without this, "a check that
    cannot verify must not answer healthy" would rest entirely on dotnet's exit code, and any
    problem it reports while still exiting 0 would be published as `status: "ok"` for a graph that
    was only partly examined."""
    problems = []
    for scope in [doc] + list(doc.get("projects") or []):
        for problem in scope.get("problems") or []:
            if (problem.get("level") or "").strip().lower() == "error":
                problems.append(problem.get("text") or json.dumps(problem, sort_keys=True))
    if problems:
        unavailable("'dotnet list package %s' reported %d project-level error(s), so part of the "
                    "graph was never examined: %s"
                    % (label, len(problems), " | ".join(problems[:3])))


VULN_LABEL = "--vulnerable --include-transitive"
DEPR_LABEL = "--deprecated --include-transitive"

vuln_doc = load(os.environ["DH_VULN"], VULN_LABEL)
depr_doc = load(os.environ["DH_DEPR"], DEPR_LABEL)
refuse_on_problems(vuln_doc, VULN_LABEL)
refuse_on_problems(depr_doc, DEPR_LABEL)

# One row per (package, advisory): a package carrying two advisories is two decisions for the
# owner, not one.
#
# Two things collapse into one row, and the difference matters. A package resolved identically
# under several TARGET FRAMEWORKS is reported once per framework by `dotnet` — a presentation
# detail of the query, not a second finding. A package present in several PROJECTS of a solution is
# a genuinely wider finding, so those do not silently merge either: the row carries `projects[]`,
# naming every project it was found in. Phase 6 maps one *Prochaines étapes* row per finding, and
# an owner told "upgrade this package" needs to know where.
def collect(rows, key_fields, row, project):
    fingerprint = json.dumps([row.get(field) for field in key_fields], sort_keys=True)
    existing = rows.get(fingerprint)
    if existing is None:
        row["projects"] = []
        rows[fingerprint] = existing = row
    if project and project not in existing["projects"]:
        existing["projects"].append(project)
    return existing


vulnerable_rows = {}
for project_path, framework in frameworks(vuln_doc):
    for key, transitive in (("topLevelPackages", False), ("transitivePackages", True)):
        for package in framework.get(key) or []:
            for advisory in package.get("vulnerabilities") or []:
                severity = (advisory.get("severity") or "").strip().lower() or None
                collect(vulnerable_rows,
                        ("id", "requested", "resolved", "transitive", "severity", "advisory"), {
                            "id": package.get("id"),
                            "requested": package.get("requestedVersion"),
                            "resolved": package.get("resolvedVersion"),
                            "transitive": transitive,
                            "severity": severity,
                            "advisory": advisory.get("advisoryurl"),
                        }, project_path)

deprecated_rows = {}
for project_path, framework in frameworks(depr_doc):
    # `--include-transitive` on this leg too, for the reason it is on the vulnerable one: a
    # deprecation the customer never chose is still a deprecation they now own. Without it this
    # second branch would be dead code that reads as coverage the query does not provide, and the
    # `transitive` field below is what stops a reader from having to guess which half a row is.
    for key, transitive in (("topLevelPackages", False), ("transitivePackages", True)):
        for package in framework.get(key) or []:
            reasons = package.get("deprecationReasons") or []
            if not reasons:
                continue
            alternative = package.get("alternativePackage")
            if isinstance(alternative, dict):
                alternative = alternative.get("id")
            collect(deprecated_rows, ("id", "resolved", "transitive", "alternative"), {
                "id": package.get("id"),
                "resolved": package.get("resolvedVersion"),
                "transitive": transitive,
                "reasons": list(reasons),
                "alternative": alternative or None,
            }, project_path)


def sort_key(row):
    return tuple("" if value is None else str(value) for value in row.values())


vulnerable = sorted(vulnerable_rows.values(), key=sort_key)
deprecated = sorted(deprecated_rows.values(), key=sort_key)
for row in vulnerable + deprecated:
    row["projects"].sort()

# `status` is DERIVED here, from what the two queries actually returned — it is never an argument,
# never an environment variable, and nothing upstream can assert it. That is the difference between
# a measurement and a claim: `ok` is reachable only when both queries ran and both came back empty.
status = "findings" if (vulnerable or deprecated) else "ok"

print(json.dumps({"dependencyHealth": {
    "status": status,
    "reason": None,
    "checkedAt": CHECKED_AT,
    "vulnerable": vulnerable,
    "deprecated": deprecated,
}}, indent=2, ensure_ascii=False))
PY
