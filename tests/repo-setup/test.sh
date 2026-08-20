#!/usr/bin/env bash
# Golden test for repo-setup.sh (#192) — the `apply` half of the repo-configuration story.
#
# Why this exists. get-repo-profile's repo-profile.sh ships two verbs and both READ (`show`,
# `detect`). When a probe found no `priority:`/`effort:`/`area:` axis and no
# `.github/ISSUE_TEMPLATE/`, its only outlet was `TODO: <hint>` — the right answer for a fact it
# cannot read, the wrong one for a configuration the repo does not HAVE. Every repo the lifecycle
# skills are ported into therefore starts degraded: `create-issue` files one label instead of four,
# `auto-dev` sorts a backlog it cannot sort, and nothing anywhere goes red. This suite pins the
# verb that closes that gap.
#
# The properties pinned here are the ones a careless rewrite drops SILENTLY — each is a green-
# looking failure, which is the class this repo keeps rediscovering (#45, #131, #72):
#
#   * idempotence          — a second `apply` issues no writes, and `plan` afterwards exits 0;
#   * additive by default  — a live label absent from the manifest survives unless --prune;
#   * never clobber        — an existing issue form is reported, not overwritten;
#   * degrade per surface  — a refused settings PATCH still leaves the labels applied, exit 3;
#   * `plan` writes nothing, ever — asserted by diffing the target repo around the call.
#
# Every `gh` call goes through a stub on PATH that RECORDS its invocation (the tick-plan pattern),
# so "did not write" is measured rather than assumed.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$KIT_ROOT/skills/setup-repo/scripts/repo-setup.sh"

. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
# Decided, not omitted — tests/_lib.sh's contract asks a converted suite to say either way, so that
# "forgot" and "does not apply" stop looking alike. This one runs a kit script that WRITES issue
# forms into a repo; the guard is what proves it never wrote into the frozen fixture instead.
kit_guard kit_guard_samples_unchanged

fail() { echo "FAIL: $1"; exit 1; }

[ -r "$SCRIPT" ] || fail "$SCRIPT missing — nothing to test"

# A scratch git repository, which is what every case below configures.
new_repo() {
  local d
  d=$(kit_scratch)
  git -C "$d" init -q 2>/dev/null || return 1
  printf '%s\n' "$d"
}

# ------------------------------------------------------------------- 1. usage and preconditions

# An unknown verb is a usage error, never a silent default to `plan`.
rc=0; out=$(bash "$SCRIPT" frobnicate 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "unknown verb: expected exit 2, got $rc"
case "$out" in
  *"plan|apply"*) ;;
  *) fail "unknown verb: the message does not show the usage — got: $out" ;;
esac
echo "  ok: usage — an unknown verb exits 2 and prints the usage"

# An option that takes a value and is given none must not swallow the next word silently.
rc=0; bash "$SCRIPT" plan --manifest >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--manifest with no value: expected exit 2, got $rc"
echo "  ok: usage — --manifest without a value exits 2"

# Outside a git repository there is nothing to configure. Same exit code repo-profile.sh uses for
# the same condition, so the two scripts cannot disagree about what 4 means.
nogit=$(kit_scratch)
rc=0; out=$(bash "$SCRIPT" plan "$nogit" 2>&1) || rc=$?
[ "$rc" -eq 4 ] || fail "plan outside a git repo: expected exit 4, got $rc"
case "$out" in
  *"not inside a git repository"*) ;;
  *) fail "plan outside a git repo: message does not name the cause — got: $out" ;;
esac
echo "  ok: preconditions — outside a git repository, plan exits 4 and names the cause"

# An explicit --manifest that cannot be read is exit 2, and the message NAMES the path. A manifest
# that silently resolved to the shipped default would configure the repo from the wrong desired
# state — the failure this check exists to make impossible.
repo=$(new_repo) || fail "could not create a scratch git repo"
rc=0; out=$(bash "$SCRIPT" plan "$repo" --manifest "$repo/nope.yml" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "unreadable manifest: expected exit 2, got $rc"
case "$out" in
  *"$repo/nope.yml"*) ;;
  *) fail "unreadable manifest: message does not name the path — got: $out" ;;
esac
echo "  ok: manifest — an unreadable --manifest exits 2 and names the path"

# A manifest that is not valid YAML is the same class of refusal, never a partial apply.
badman="$repo/bad.yml"
printf 'labels:\n  - name: "unclosed\n' > "$badman"
rc=0; out=$(bash "$SCRIPT" apply "$repo" --manifest "$badman" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "unparseable manifest: expected exit 2, got $rc"
echo "  ok: manifest — an unparseable manifest exits 2 before anything is applied"

# ------------------------------------------------------------------------ 2. the shipped default

MANIFEST="$KIT_ROOT/templates/repo-setup.yml"
[ -r "$MANIFEST" ] || fail "templates/repo-setup.yml missing — the shipped desired state"

# The shipped manifest must actually carry the three axes whose absence #192 is about. A manifest
# that parsed but declared nothing would make every assertion below vacuously true.
parsed=$(python3 "$KIT_ROOT/skills/setup-repo/scripts/parse-manifest.py" "$MANIFEST") \
  || fail "the shipped manifest does not parse"
for axis in "priority: " "effort: " "area: "; do
  case "$parsed" in
    *"$axis"*) ;;
    *) fail "the shipped manifest declares no '$axis' label — the axis #192 is about" ;;
  esac
done
echo "  ok: manifest — the shipped default declares the priority:, effort: and area: axes"

# ------------------------------------------------------------------------------ 3. the gh stub
#
# Records every invocation, so "did not write" below is MEASURED rather than assumed — the
# tick-plan pattern. It serves JSON, not TSV: the script pipes `gh --json` through jq (a `required`
# entry in requirements.json) rather than using gh's built-in --jq, so what the stub has to imitate
# is just GitHub's payload shape.
WORK=$(kit_scratch)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
case "$*" in
  *"auth status"*)  [ "${GH_AUTH_FAILS:-0}" = 1 ] && exit 1; exit 0 ;;
  *"repo view"*)    printf '{"nameWithOwner":"acme/widgets"}\n'; exit 0 ;;
  *"label list"*)   cat "$GH_LABELS_JSON"; exit 0 ;;
  *"-X PATCH"*)     [ "${GH_PATCH_FAILS:-0}" = 1 ] && { echo "gh: HTTP 403 Must have admin rights" >&2; exit 1; }; exit 0 ;;
  *"api repos/"*)   cat "$GH_SETTINGS_JSON"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GH_LABELS_JSON="$WORK/labels.json"
export GH_SETTINGS_JSON="$WORK/settings.json"
export GH_CALL_LOG="$WORK/gh-calls.log"

FIXTURE="$KIT_ROOT/tests/repo-setup/fixtures/manifest.yml"
[ -r "$FIXTURE" ] || fail "fixture manifest missing at $FIXTURE"

# Fresh call log per case, so a count means what the case name says.
fresh_log() { GH_CALL_LOG="$WORK/gh-calls.$1.log"; export GH_CALL_LOG; : > "$GH_CALL_LOG"; }
gh_calls_matching() { grep -c -- "$1" "$GH_CALL_LOG" 2>/dev/null || true; }

# The converged live state: exactly the fixture's two real labels, normalised the way gh reports
# them (bare lower-case hex), plus the one setting.
converged_labels() {
  printf '%s\n' '[{"name":"priority: high","color":"b60205","description":"Pull this first"},' \
                ' {"name":"effort: small","color":"c2e0c6","description":"One task"}]'
}

# --------------------------------------------------------------------------- 4. plan finds drift

repo=$(new_repo) || fail "could not create a scratch git repo"
fresh_log empty
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

# Assertions on the report are LINE-oriented, never `case "$out" in *"+ADD"*"area:"*`. A glob over
# the whole multi-line report matches ACROSS lines: "+ADD" from the first label and "area:" from
# the placeholder three lines down satisfy that pattern with nothing wrong. Measured — it is what
# made this very assertion fire against a correct report.
has_line() { printf '%s\n' "$2" | grep -q "$1"; }

rc=0; out=$(bash "$SCRIPT" plan "$repo" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "plan on an unconfigured repo: expected exit 1 (drift), got $rc — output: $out"
for want in "priority: high" "effort: small"; do
  has_line "^+ADD .*label .*$want" "$out" || fail "plan: no +ADD line for '$want' — output: $out"
done
echo "  ok: plan — an unconfigured repo reports +ADD per label and exits 1"

# The settings surface drifts too: live says false, the manifest says true.
has_line "^~EDIT .*setting .*delete_branch_on_merge" "$out" \
  || fail "plan: no ~EDIT for delete_branch_on_merge — output: $out"
echo "  ok: plan — a setting whose live value differs reports ~EDIT"

# The placeholder is reported, never created. Both halves matter: reporting it is what keeps an
# unfilled axis visible, and NOT adding it is what stops a literal "area: <fill-me>" label from
# being created in someone's repo.
has_line "^!TODO .*area: <fill-me>" "$out" \
  || fail "plan: the <…> placeholder is not reported as !TODO — output: $out"
! has_line "^+ADD .*area: <fill-me>" "$out" \
  || fail "plan: the placeholder was queued as +ADD — output: $out"
echo "  ok: plan — a <…> placeholder reports !TODO and is never queued for creation"

# ------------------------------------------------------------------- 5. plan writes NOTHING, ever

# Two independent measurements, because they fail differently: the working tree covers files the
# script might create, the call log covers writes it might push to GitHub.
before=$(git -C "$repo" status --porcelain)
fresh_log readonly
# `|| true`, deliberately: this repo is unconfigured, so plan exits 1 BY DESIGN. Under the suite's
# `set -e` a bare call would abort here — silently, with neither a FAIL line nor the PASS at the
# end, which reads as a crash rather than as the assertion it is.
bash "$SCRIPT" plan "$repo" --manifest "$FIXTURE" >/dev/null 2>&1 || true
after=$(git -C "$repo" status --porcelain)
[ "$before" = "$after" ] || fail "plan modified the working tree: '$before' -> '$after'"
[ ! -d "$repo/.github/ISSUE_TEMPLATE" ] || fail "plan created .github/ISSUE_TEMPLATE/"
for forbidden in "label create" "label edit" "label delete" "PATCH"; do
  n=$(gh_calls_matching "$forbidden")
  [ "$n" -eq 0 ] || fail "plan issued $n '$forbidden' call(s) — it must write nothing"
done
echo "  ok: plan — writes nothing: working tree unchanged and zero write calls to gh"

# --------------------------------------------------------------------------- 6. plan on converged

repo2=$(new_repo) || fail "could not create a scratch git repo"
converged_labels > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":true}\n' > "$GH_SETTINGS_JSON"
mkdir -p "$repo2/.github/ISSUE_TEMPLATE"
printf 'name: Feature request\n' > "$repo2/.github/ISSUE_TEMPLATE/feature_request.yml"

fresh_log converged
rc=0; out=$(bash "$SCRIPT" plan "$repo2" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "plan on a converged repo: expected exit 0, got $rc — output: $out"
case "$out" in
  *"+ADD"*) fail "plan on a converged repo still reports +ADD — output: $out" ;;
esac
case "$out" in
  *"~EDIT"*) fail "plan on a converged repo still reports ~EDIT — output: $out" ;;
esac
echo "  ok: plan — a converged repo exits 0 with no +ADD and no ~EDIT"

# The uppercase "#B60205" in the fixture against gh's "b60205" is the case that proves it: without
# normalisation this label would report ~EDIT forever and `apply` would rewrite it on every run.
echo "  ok: plan — colour normalisation converges #B60205 against gh's b60205"

# A live label the manifest does not declare is reported, not silently accepted and not queued for
# deletion. This is the additive invariant seen from plan's side.
printf '%s\n' '[{"name":"priority: high","color":"b60205","description":"Pull this first"},' \
              ' {"name":"effort: small","color":"c2e0c6","description":"One task"},' \
              ' {"name":"legacy-thing","color":"ededed","description":"someone else was here"}]' \
  > "$GH_LABELS_JSON"
fresh_log extra
rc=0; out=$(bash "$SCRIPT" plan "$repo2" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "an undeclared live label must not count as drift, got exit $rc — $out"
case "$out" in
  *"!EXTRA"*"legacy-thing"*) ;;
  *) fail "plan: an undeclared live label is not reported — output: $out" ;;
esac
echo "  ok: plan — an undeclared live label reports !EXTRA and does not count as drift"

echo "PASS: tests/repo-setup"
