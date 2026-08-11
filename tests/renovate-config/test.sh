#!/usr/bin/env bash
# renovate.json is judged by the engine that consumes it.
#
# CI proved this file PARSES (#34 added it to the json.tool step). Parsing is not acceptance:
# `customManagers` must compile under RE2, `managerFilePatterns` regexes are validated, and any
# unknown key raises CONFIG_VALIDATION. When Renovate rejects a config it stops managing the WHOLE
# repository, and the only symptom is an absence — no PRs, no Dependency Dashboard updates, nothing
# in a log anyone reads. That is the failure shape #34 was filed for; this closes the half it left.
#
# What is asserted:
#   1. the pinned validator accepts the real renovate.json;
#   2. it REJECTS a config carrying an unknown key — without this, a validator that always exited 0
#      would score as a pass;
#   3. ci.yml pins the validator to an exact version, and that pin is >= the measured floor;
#   4. the pin is managed — a customManager exists that Renovate can bump it through.
#
# Why the pin is load-bearing, measured in #66:
#   `npx --yes --package renovate -- …` with NO version resolved 37.440.7, a major predating
#   `managerFilePatterns` (the successor to `fileMatch`). It reported 8 Configuration Errors against
#   a config the real Renovate accepts. An unpinned gate is therefore not merely fragile — it is red
#   on correct input, and its obvious "fix" (renaming back to fileMatch) silently downgrades the
#   config for the Renovate that actually runs. Floor measured at major 40; 39 and below reject.
#
# Network: this suite shells out to npx. When the registry is unreachable it SKIPS with a clear
# message rather than passing — a validator that could not run has not validated anything.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
CI="$KIT/.github/workflows/ci.yml"
FLOOR=40

scratch=""
cleanup() {
  local rc=$?
  [ -n "$scratch" ] && rm -rf "$scratch"
  exit "$rc"
}
trap cleanup EXIT
scratch=$(mktemp -d)

# ---------------------------------------------------------------------------
# 3. ci.yml pins an exact version, at or above the measured floor.
#    Asserted BEFORE the network work, so a missing pin fails fast and offline.
# ---------------------------------------------------------------------------
PIN=$(python3 - "$CI" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'RENOVATE_VALIDATOR_VERSION:\s*["\']?([0-9]+(?:\.[0-9]+)*)["\']?', text)
print(m.group(1) if m else "")
PY
)
if [ -z "$PIN" ]; then
  echo "FAIL: ci.yml does not pin RENOVATE_VALIDATOR_VERSION to an exact version."
  echo "      An unpinned 'npx --package renovate' resolved 37.440.7 when this was measured,"
  echo "      and reported 8 Configuration Errors against a config Renovate accepts."
  exit 1
fi
MAJOR=${PIN%%.*}
if [ "$MAJOR" -lt "$FLOOR" ]; then
  echo "FAIL: the pinned validator is major $MAJOR, below the measured floor of $FLOOR."
  echo "      Majors under $FLOOR reject 'managerFilePatterns' and would redden a correct config."
  exit 1
fi
echo "  [3] ci.yml pins the validator to $PIN (>= floor $FLOOR)"

# ---------------------------------------------------------------------------
# 4. The pin is MANAGED. A version pinned and then forgotten is #35 all over again —
#    the shipped workflows that sat three majors stale while the repo's own CI stayed
#    current. Renovate must be able to bump this one.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$CI" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
managers = cfg.get("customManagers") or []
ci_rel = ".github/workflows/ci.yml"
owning = []
for m in managers:
    pats = m.get("managerFilePatterns") or m.get("fileMatch") or []
    if not any(re.search(p.strip("/"), ci_rel) for p in pats):
        continue
    blob = json.dumps(m)
    if "renovate" in blob and "npm" in blob:
        owning.append(m)
assert owning, (
    "no customManager claims the validator pin in ci.yml — nothing would ever bump it, "
    "which is exactly the stale-shipped-config failure of #35"
)
# The manager must actually capture the pin we wrote, not merely mention the file.
#
# Renovate evaluates matchStrings with RE2, where a named group is `(?<name>…)`; Python spells the
# same thing `(?P<name>…)`. Same translation as tests/xunit-v3/test.sh's `to_python()` — a third
# copy of that helper, which is one more tenant for the shared tests/_lib.sh proposed in #72.
# No lookbehind assertion here: the pinned validator above now judges RE2 compatibility for real,
# which is strictly better than a second hand-written model of somebody else's grammar.
def to_python(pattern):
    return pattern.replace("(?<", "(?P<")


text = open(sys.argv[2], encoding="utf-8").read()
hit = False
for m in owning:
    for s in m.get("matchStrings", []):
        if re.search(to_python(s), text, re.M | re.S):
            hit = True
assert hit, "the customManager's matchStrings do not match the pin as written in ci.yml"
PY
echo "  [4] the pin is claimed by a customManager whose matchStrings actually match it"

# ---------------------------------------------------------------------------
# 1+2. The pinned validator accepts the real config and rejects a bogus one.
# ---------------------------------------------------------------------------
run_validator() {
  npx --yes --package "renovate@$PIN" -- renovate-config-validator "$1" > "$2" 2>&1
}

if ! run_validator "$KIT/renovate.json" "$scratch/real.txt"; then
  if grep -qiE 'ENOTFOUND|ETIMEDOUT|EAI_AGAIN|network|registry\.npmjs\.org.*failed' "$scratch/real.txt"; then
    echo "  [1-2] SKIPPED — npm registry unreachable; the validator could not run."
    echo "        (A validator that could not run has not validated anything.)"
    exit 0
  fi
  echo "FAIL: the pinned validator ($PIN) rejects the repo's own renovate.json:"
  cat "$scratch/real.txt"
  exit 1
fi
echo "  [1] renovate@$PIN accepts renovate.json"

python3 - "$KIT/renovate.json" "$scratch/bogus.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
cfg["totallyBogusKeyThatRenovateMustReject"] = 1
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/bogus.json" "$scratch/bogus.txt"; then
  echo "FAIL: the validator ACCEPTED a config with an unknown key — it would pass anything,"
  echo "      and this gate would be decoration:"
  cat "$scratch/bogus.txt"
  exit 1
fi
echo "  [2] it rejects a config carrying an unknown key"

echo "renovate-config golden test OK"
