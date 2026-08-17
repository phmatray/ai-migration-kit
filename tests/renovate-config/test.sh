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
#   4. the pin is managed — a customManager exists that Renovate can bump it through;
#   5. ci.yml invokes the validator with BOTH --no-global and --strict (see below);
#   6. it REJECTS a repo config carrying a global-only option (what --no-global buys);
#   7. it REJECTS a config that still needs migration (what --strict buys).
#
# Why the two flags, measured against renovate@44.23.3 in #79 rather than read off the docs:
#   --no-global — passing a filename positionally makes the validator judge it as a GLOBAL
#     self-hosted config ("Validating renovate.json as global config"). This file is a REPO config.
#     `autodiscover` and `baseDir`, which Renovate ignores outright in a repo config, PASS without
#     the flag and fail with it — the silent-ignore failure this gate exists to catch, found inside
#     the gate itself.
#   --strict — NOT what catches an unknown key: a mistyped key inside customManagers already exits 1
#     unflagged, because renovate 44 sets returnVal=1 on warnings too. `strict` is consulted in one
#     branch only, `if (isMigrated)`, so it means "fail if the config needs migration" — the only
#     thing that catches a stale `fileMatch` spelling. Measured 0 without, 1 with.
#   Cases 6 and 7 are golden tests for exactly those two claims, so a future edit that drops a flag
#   fails here instead of quietly widening the hole again. Case 5 catches the drop in ci.yml itself.
#
# Known limit (follow-up): RE2 is an OPTIONAL native module. When it fails to load, the validator
# falls back to JS RegExp and logs "RE2 not usable" as a bare warning that does NOT affect the exit
# code — so a matchStrings pattern only RE2 would reject can still pass. Not asserted here yet.
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

. "$KIT/tests/_lib.sh"
kit_init "$KIT"
# This suite only reads ci.yml and renovate.json and shells out to npx, so it registers no extra
# guard. Saying so beats leaving it unsaid: before #72 this was the one suite silently missing the
# samples/ check, and "decided it does not apply" looked exactly like "forgot".
scratch=$(kit_scratch)

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
# 5. ci.yml passes BOTH flags. Cases 6/7 below prove what each one buys, but they prove it about
#    the validator, not about the command CI actually runs — a flag silently dropped from ci.yml
#    would leave 6/7 green while the real gate went back to accepting the bad configs. Asserted
#    offline, before the network work, for the same reason as [3].
# ---------------------------------------------------------------------------
# awk, not a python heredoc: the two `$(python3 - … <<PY … PY)` blocks above are the one construct
# bash 3.2 (still /bin/bash on macOS) mis-parses, so this deliberately does not add a third.
# It joins backslash continuations into logical lines first — the flags may sit on either side of
# the break — then picks the line that invokes the validator.
#
# Comment lines are dropped before the match, and that is not fussiness: the step in ci.yml is
# wrapped in prose explaining why each flag is load-bearing, and prose in this repo names the tool
# it is about. Without the filter the first `#` line mentioning renovate-config-validator wins the
# `head -1`, and this assertion starts grading a comment instead of the command — passing while the
# real invocation has lost a flag, which is precisely the failure it exists to prevent.
validator_invocation=$(awk '
  { line = buf $0
    if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); buf = line; next }
    buf = ""; print line }
' "$CI" | grep -v '^[[:space:]]*#' | grep -F 'renovate-config-validator' | head -1)
if [ -z "$validator_invocation" ]; then
  echo "FAIL: ci.yml no longer invokes renovate-config-validator at all."
  exit 1
fi
for flag in --no-global --strict; do
  # -F and the -- guard: the needle itself starts with dashes.
  if ! printf '%s' "$validator_invocation" | grep -qF -- "$flag"; then
    echo "FAIL: ci.yml invokes the validator without $flag:"
    echo "        $validator_invocation"
    if [ "$flag" = "--no-global" ]; then
      echo "      Without --no-global the file is judged as a GLOBAL self-hosted config, and"
      echo "      global-only options (autodiscover, baseDir) pass despite being ignored in a"
      echo "      repo config — the silent-ignore failure this gate exists to catch."
    else
      echo "      Without --strict a config that still needs migration (e.g. fileMatch for"
      echo "      managerFilePatterns) is silently accepted and exits 0."
    fi
    exit 1
  fi
done
echo "  [5] ci.yml invokes the validator with --no-global and --strict"

# ---------------------------------------------------------------------------
# 1+2. The pinned validator accepts the real config and rejects a bogus one.
# ---------------------------------------------------------------------------
# Mirrors ci.yml exactly — flags included. A suite that validated with a different command than the
# gate runs would be testing something nobody ships; [5] above keeps the two spellings in step.
run_validator() {
  npx --yes --package "renovate@$PIN" -- \
    renovate-config-validator --no-global --strict "$1" > "$2" 2>&1
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

# ---------------------------------------------------------------------------
# 6. What --no-global buys: a repo config carrying a GLOBAL-only option must be rejected.
#    Measured in #79 — without the flag this exact file exits 0, because the validator judges it
#    against the global schema where these options are legal. Renovate ignores them in a repo
#    config, so the config is quietly not what it says it is: absence-of-PRs, no error anywhere.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$scratch/global-only.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
# Both are self-hosted/global options, meaningless inside a repository's renovate.json.
cfg["autodiscover"] = True
cfg["baseDir"] = "/tmp/renovate"
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/global-only.json" "$scratch/global-only.txt"; then
  echo "FAIL: the validator ACCEPTED a repo config carrying global-only options."
  echo "      That means --no-global is not in effect and the file is being judged as a GLOBAL"
  echo "      self-hosted config — options Renovate ignores in a repo config score as valid:"
  cat "$scratch/global-only.txt"
  exit 1
fi
# Non-zero alone is not proof: npx exits non-zero when the registry is unreachable too, and that
# would let an outage score as a passing rejection — "a validator that could not run has not
# validated anything" applies to the negative cases as much as the positive one. Assert the REASON.
if ! grep -q 'is a global option reserved' "$scratch/global-only.txt"; then
  echo "FAIL: the validator rejected the global-only config, but not for being global-only."
  echo "      Expected the \"is a global option reserved\" diagnostic; got:"
  cat "$scratch/global-only.txt"
  exit 1
fi
echo "  [6] it rejects a repo config carrying global-only options (--no-global is in effect)"

# ---------------------------------------------------------------------------
# 7. What --strict buys: a config that still needs migration must be rejected.
#    `fileMatch` is the pre-managerFilePatterns spelling. Renovate migrates it silently and exits 0
#    unflagged; --strict turns that into a failure. This is the "rename landing on the wrong side of
#    a Renovate major" bullet from #79, and the only case that distinguishes the flag.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$scratch/needs-migration.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
managers = cfg.get("customManagers") or []
# Pick the first manager that actually carries the modern spelling, rather than assuming [0] does —
# a bare managers[0].pop() would raise KeyError and surface as an opaque crash instead of this
# message the day someone reorders the list or hand-writes one with `fileMatch` already.
target = next((m for m in managers if "managerFilePatterns" in m), None)
assert target is not None, (
    "no customManager in renovate.json uses 'managerFilePatterns', so there is nothing to downgrade "
    "to the superseded 'fileMatch' spelling — rewrite this case against whatever migration is current"
)
# Downgrade that one manager; everything else stays valid, so the ONLY reason to fail is migration.
target["fileMatch"] = target.pop("managerFilePatterns")
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/needs-migration.json" "$scratch/needs-migration.txt"; then
  echo "FAIL: the validator ACCEPTED a config still using the superseded 'fileMatch' spelling."
  echo "      --strict is what makes a needed migration fatal; without it the config is silently"
  echo "      migrated in-memory and scores as valid:"
  cat "$scratch/needs-migration.txt"
  exit 1
fi
# Same reasoning as [6]: prove it failed for the migration, not because npx could not reach npm.
if ! grep -q 'Config migration necessary' "$scratch/needs-migration.txt"; then
  echo "FAIL: the validator rejected the unmigrated config, but not for needing migration."
  echo "      Expected the \"Config migration necessary\" diagnostic; got:"
  cat "$scratch/needs-migration.txt"
  exit 1
fi
echo "  [7] it rejects a config that still needs migration (--strict is in effect)"

echo "renovate-config golden test OK"
