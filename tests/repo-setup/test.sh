#!/usr/bin/env bash
# Golden test for repo-setup.sh (#192) — the `apply` half of the repo-configuration story.
#
# Why this exists. profile-repo's repo-profile.sh ships two verbs and both READ (`show`,
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

# The parser's stdout must be UTF-8 whatever the host locale says — not merely where the locale is
# already UTF-8. parse-manifest.py pins the NEWLINE for this exact class of hazard and left the
# ENCODING to the locale, which on a Windows console is cp1252: an em-dash in a label description
# then leaves as the single byte 0x97, `gh` sends that, and the label is created with a description
# that can never equal what the manifest asks for. MEASURED 2026-08-20 against this repository: ten
# labels applied corrupted, and every subsequent `plan` reported them ~EDIT forever — apply rewrote
# all ten on every run and converged on none. The shipped manifest's own descriptions carry em
# dashes, so this needs no fixture; PYTHONIOENCODING reproduces the condition on the Linux runner,
# where the locale would otherwise hide it (#174 is the same platform gap, one layer up).
enc_bytes=$(PYTHONIOENCODING=cp1252 python3 "$KIT_ROOT/skills/setup-repo/scripts/parse-manifest.py" "$MANIFEST" | od -An -tx1 | tr -d ' \n')
case "$enc_bytes" in
  *e28094*) ;;
  *) fail "parse-manifest.py did not emit U+2014 as UTF-8 under a non-UTF-8 locale — label descriptions would be applied corrupted" ;;
esac
# The same dump proves the OTHER half for free. Dropping newline="\n" puts a CR inside the last
# TAB-separated field of every record, so every description reads as "…\r", never equals what `gh`
# reports, and `apply` rewrites every label on every run — the failure parse-manifest.py's own
# header records as measured. Both halves of that one call are load-bearing; assert both.
case "$enc_bytes" in
  *0d0a*) fail "parse-manifest.py emitted CRLF — a CR lands in the last field of every record and no label ever converges" ;;
esac
echo "  ok: parser — stdout is UTF-8 and LF whatever the host locale is"

# A relative --manifest resolves against the CALLER's directory, not the target repo's. Without
# this, `plan ../other-repo --manifest my.yml` hunts for my.yml INSIDE other-repo — a path the
# operator never typed. The suite has cd'd to the kit root, so this relative path is meaningful
# here and meaningless inside $repo, which is exactly what makes the case discriminating.
rc=0; out=$(bash "$SCRIPT" plan "$repo" --manifest "tests/repo-setup/fixtures/manifest.yml" 2>&1) || rc=$?
[ "$rc" -ne 2 ] || fail "a relative --manifest was resolved against the target repo, not the caller: $out"
echo "  ok: manifest — a relative --manifest resolves against the caller's directory"

# ------------------------------------------------------------------------------ 3. the gh stub
#
# Records every invocation, so "did not write" below is MEASURED rather than assumed — the
# tick-plan pattern. It serves JSON, not TSV: the script pipes `gh --json` through jq (a `required`
# entry in requirements.json) rather than using gh's built-in --jq, so what the stub has to imitate
# is just GitHub's payload shape.
WORK=$(kit_scratch)
mkdir -p "$WORK/bin"
#
# The stub is STATEFUL: a `label create` really does append to the JSON that the next `label list`
# serves back. Idempotence is otherwise unmeasurable — against a stub that forgot every write, a
# second `apply` would re-create every label and the run would still look green, which is the exact
# failure the idempotence case exists to catch.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"

put_label() {   # put_label <name> <color> <description> — create and edit are the same operation
  jq --arg n "$1" --arg c "$2" --arg d "$3" \
     'map(select(.name != $n)) + [{name:$n, color:($c|ascii_downcase), description:$d}]' \
     "$GH_LABELS_JSON" > "$GH_LABELS_JSON.tmp" && mv "$GH_LABELS_JSON.tmp" "$GH_LABELS_JSON"
}

# gh_fail_body <status> <url-suffix> — the stderr shapes gh actually prints for a failed write
# (#200), MEASURED against a real repository:
#   gh label edit "area: ci" --description "$(printf 'x%.0s' $(seq 1 101))"
#     HTTP 422: Validation Failed (https://api.github.com/repos/OWNER/REPO/labels/area:%20ci)
#     description is too long (maximum is 100 characters)
# 403 is not independently reproducible here (it needs a token with too little scope, not one this
# suite can hold), so every caller shares one 403 shape. Shared by every failing write/read this
# stub imitates (create/edit, delete, the settings PATCH, label list, the settings read — #222)
# rather than four near-identical copies of the same case statement.
gh_fail_body() {
  case "$1" in
    422)
      echo "HTTP 422: Validation Failed (https://api.github.com/repos/acme/widgets/$2)" >&2
      echo "description is too long (maximum is 100 characters)" >&2 ;;
    # Not independently measured — this shape asserts two simultaneous field errors are POSSIBLE
    # in one 422 body (GitHub returns one entry per invalid field), not that this exact wording is
    # what gh prints for it.
    422multi)
      echo "HTTP 422: Validation Failed (https://api.github.com/repos/acme/widgets/$2)" >&2
      echo "color is invalid" >&2
      echo "description is too long (maximum is 100 characters)" >&2 ;;
    # A `gh` killed by signal (CI timeout, OOM) can exit non-zero with nothing on stderr at all —
    # this is the shape, not a status gh actually names.
    empty)
      : ;;
    # A transient rate-limit or 5xx: neither a scope problem nor a manifest problem, and the whole
    # point of #223's read-side half is that this must NOT collapse to the 403 sentence. Deliberately
    # NOT "HTTP 403" — GitHub's classic REST rate-limit response really is a 403, which #222/#223
    # leave classified as a scope problem (out of scope: distinguishing 403 flavors); this is the
    # OTHER shape a real rate-limit or an overloaded API can return.
    ratelimited)
      echo "HTTP 429: API rate limit exceeded for installation ID 1 (https://api.github.com/repos/acme/widgets/$2)" >&2 ;;
    *)
      echo "HTTP 403: Resource not accessible by integration (https://api.github.com/repos/acme/widgets/$2)" >&2 ;;
  esac
}

case "$1 $2" in
  "auth status")   [ "${GH_AUTH_FAILS:-0}" = 1 ] && exit 1; exit 0 ;;
  "repo view")     printf '{"nameWithOwner":"acme/widgets"}\n'; exit 0 ;;
  "label list")
    if [ "${GH_LIST_FAILS:-0}" = 1 ]; then
      gh_fail_body "${GH_LIST_FAIL_STATUS:-403}" "labels"
      exit 1
    fi
    cat "$GH_LABELS_JSON"; exit 0 ;;
  "label create"|"label edit")
    if [ "${GH_LABEL_FAILS:-0}" = 1 ]; then
      gh_fail_body "${GH_LABEL_FAIL_STATUS:-403}" "labels"
      exit 1
    fi
    name="$3"; color=""; desc=""; shift 3
    while [ $# -gt 0 ]; do
      case "$1" in
        --color)       color="$2"; shift 2 ;;
        --description) desc="$2";  shift 2 ;;
        *)             shift ;;
      esac
    done
    put_label "$name" "$color" "$desc"; exit 0 ;;
  "label delete")
    if [ "${GH_DELETE_FAILS:-0}" = 1 ]; then
      gh_fail_body "${GH_DELETE_FAIL_STATUS:-403}" "labels"
      exit 1
    fi
    jq --arg n "$3" 'map(select(.name != $n))' "$GH_LABELS_JSON" > "$GH_LABELS_JSON.tmp" \
      && mv "$GH_LABELS_JSON.tmp" "$GH_LABELS_JSON"
    exit 0 ;;
esac

case "$*" in
  *"-X PATCH"*)
    if [ "${GH_PATCH_FAILS:-0}" = 1 ]; then
      case "${GH_PATCH_FAIL_STATUS:-403}" in
        403) echo "gh: HTTP 403 Must have admin rights" >&2 ;;
        *)   gh_fail_body "${GH_PATCH_FAIL_STATUS:-403}" "acme/widgets" ;;
      esac
      exit 1
    fi
    # Record the new values so the next read reflects the write, same as the label side.
    for a in "$@"; do
      case "$a" in
        *=*) k="${a%%=*}"; v="${a#*=}"
             jq --arg k "$k" --argjson v "$v" '.[$k] = $v' "$GH_SETTINGS_JSON" > "$GH_SETTINGS_JSON.tmp" \
               && mv "$GH_SETTINGS_JSON.tmp" "$GH_SETTINGS_JSON" ;;
      esac
    done
    exit 0 ;;
  *"api repos/"*)
    if [ "${GH_SETTINGS_READ_FAILS:-0}" = 1 ]; then
      gh_fail_body "${GH_SETTINGS_READ_FAIL_STATUS:-403}" "acme/widgets"
      exit 1
    fi
    cat "$GH_SETTINGS_JSON"; exit 0 ;;
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

# Shared reader for an issue form's `area` dropdown options, one per line, in file order (#198) —
# used to compare a copied/generated form against the manifest without a bare grep, which would
# also match the description prose above the list.
#
# Loads project-area-options.py's own find_area_field() rather than re-deriving the id+type match
# here — two independent implementations of the same "is this the area field" decision is this
# repo's own recurring failure shape (#141, #163), and this exact decision already had to be
# reconciled once during #198 (the placeholder-substring check, repo-setup.sh's is_placeholder_name).
#
# Routed through py_module (tests/_lib/py.sh) — the kit's ONE importlib loader (#51).
# xunit-v3/test.sh section 8 fails the whole suite if a second copy of the loader appears anywhere
# under tests/ or scripts/, which hand-rolling importlib's own module-from-path call here would be.
#
# A bash FUNCTION, never `$(python3 - <<PY)` at the call site: bash 3.2's command-substitution
# scanner does not honour heredoc quoting when the heredoc sits directly inside `$(…)` (#131). The
# heredoc below is parsed once, at function definition — a plain top-level construct — so calling
# `$(read_area_options "$path")` never nests it inside the substitution itself.
# xunit-v3/test.sh's own read_const() is the same shape.
kit_source "$KIT_ROOT/tests/_lib/py.sh"
read_area_options() {
  py_module "$KIT_ROOT/skills/setup-repo/scripts/project-area-options.py" "$1" <<'PY'
import sys

import yaml

sys.stdout.reconfigure(encoding="utf-8", newline="\n")

with open(sys.argv[2], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle) or {}
field = mod.find_area_field(doc)
if field is not None:
    for option in field.get("attributes", {}).get("options") or []:
        print(option)
PY
}

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
# The fixture's area axis is still the "<fill-me>" placeholder, and an unfilled axis is drift
# (#198) — so a repo that has converged on everything ELSE still exits 1, on the placeholder alone.
[ "$rc" -eq 1 ] || fail "plan on an otherwise-converged repo with an unfilled area axis: expected exit 1, got $rc — output: $out"
case "$out" in
  *"+ADD"*) fail "plan on a converged repo still reports +ADD — output: $out" ;;
esac
case "$out" in
  *"~EDIT"*) fail "plan on a converged repo still reports ~EDIT — output: $out" ;;
esac
has_line "^!TODO .*area: <fill-me>" "$out" \
  || fail "plan: the placeholder line disappeared instead of counting as drift — output: $out"
echo "  ok: plan — a converged repo with an unfilled area axis exits 1 (!TODO is drift), no +ADD/~EDIT"

# "Run apply to converge" is FALSE advice here — apply never creates a placeholder (#198) — so the
# verdict line has to say "edit the manifest", not repeat the one instruction that resolves nothing.
has_line "^plan: 1 item(s) of drift, all unfilled placeholder(s)" "$out" \
  || fail "plan: the all-placeholder verdict did not name the manifest as the fix — output: $out"
case "$out" in
  *"Run \`repo-setup.sh apply\` to converge."*) fail "plan told the operator to run apply when apply would fix nothing — output: $out" ;;
esac
echo "  ok: plan — when every drift item is an unfilled placeholder, the verdict says edit the manifest, not apply"

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
# Still exit 1 here too — but only because of the ever-present placeholder, never because of the
# undeclared label: an !EXTRA must not itself count as drift.
[ "$rc" -eq 1 ] || fail "an undeclared live label must not itself change the exit code, got exit $rc — $out"
case "$out" in
  *"+ADD"*) fail "an undeclared live label was queued as +ADD — output: $out" ;;
esac
case "$out" in
  *"!EXTRA"*"legacy-thing"*) ;;
  *) fail "plan: an undeclared live label is not reported — output: $out" ;;
esac
echo "  ok: plan — an undeclared live label reports !EXTRA and does not itself count as drift"

# ---------------------------------------------------------------- 7. apply is idempotent

# The property that makes "deterministic" mean anything. It is asserted twice over, because the two
# measurements fail differently: a second run issuing zero writes is what makes `apply` safe to put
# in a loop or a cron, and `plan` exiting 0 afterwards is what proves the writes actually landed
# where the diff expects to read them back.
repo3=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log apply1
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "first apply: expected exit 0, got $rc — output: $out"
first_writes=$(gh_calls_matching "label create")
[ "$first_writes" -eq 2 ] || fail "first apply: expected 2 label creates, got $first_writes"
echo "  ok: apply — a first run creates every declared, non-placeholder label"

fresh_log apply2
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "second apply: expected exit 0, got $rc — output: $out"
for forbidden in "label create" "label edit" "label delete"; do
  n=$(gh_calls_matching "$forbidden")
  [ "$n" -eq 0 ] || fail "second apply issued $n '$forbidden' call(s) — apply is not idempotent"
done
echo "  ok: apply — a second run issues zero label writes"

fresh_log applyplan
rc=0; out=$(bash "$SCRIPT" plan "$repo3" --manifest "$FIXTURE" 2>&1) || rc=$?
# `apply` never creates the placeholder (by design), so the fixture's area axis stays !TODO
# forever — exit 1 on that alone, with nothing else outstanding, is what "the writes landed"
# looks like now.
[ "$rc" -eq 1 ] || fail "plan after apply: expected exit 1 (only the unfilled area axis remains), got $rc — output: $out"
case "$out" in
  *"+ADD"*) fail "plan after apply still reports +ADD — the writes did not land — output: $out" ;;
esac
case "$out" in
  *"~EDIT"*) fail "plan after apply still reports ~EDIT — the writes did not land — output: $out" ;;
esac
has_line "^!TODO .*area: <fill-me>" "$out" \
  || fail "plan after apply: the placeholder line disappeared — output: $out"
echo "  ok: apply — plan afterwards reports only the unfilled area axis, so the writes landed where the diff reads"

# The placeholder must never reach the network, on any run.
n=$(grep -c -- "fill-me" "$WORK/gh-calls.apply1.log" 2>/dev/null || true)
[ "$n" -eq 0 ] || fail "apply sent the <…> placeholder to gh $n time(s)"
echo "  ok: apply — the <…> placeholder is never sent to gh"

# ------------------------------------------------------- 8. apply is additive unless --prune

# A repo that already runs its own taxonomy must not have it renamed out from under it by a kit
# upgrade. This is the invariant that makes `apply` safe to run on somebody else's repository.
jq '. + [{"name":"legacy-thing","color":"ededed","description":"someone else was here"}]' \
  "$GH_LABELS_JSON" > "$GH_LABELS_JSON.t" && mv "$GH_LABELS_JSON.t" "$GH_LABELS_JSON"

fresh_log additive
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply with an undeclared live label: expected exit 0, got $rc — $out"
n=$(gh_calls_matching "label delete")
[ "$n" -eq 0 ] || fail "apply deleted an undeclared label without --prune ($n call(s))"
jq -e '[.[] | select(.name == "legacy-thing")] | length == 1' "$GH_LABELS_JSON" > /dev/null \
  || fail "apply removed 'legacy-thing' from the live set without --prune"
has_line "^!EXTRA .*legacy-thing" "$out" || fail "apply did not report the undeclared label — $out"
echo "  ok: apply — an undeclared live label survives and is reported, without --prune"

fresh_log prune
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" --prune 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply --prune: expected exit 0, got $rc — output: $out"
n=$(gh_calls_matching "label delete")
[ "$n" -eq 1 ] || fail "apply --prune: expected 1 label delete, got $n"
jq -e '[.[] | select(.name == "legacy-thing")] | length == 0' "$GH_LABELS_JSON" > /dev/null \
  || fail "apply --prune did not remove 'legacy-thing'"
echo "  ok: apply --prune — and only --prune — deletes an undeclared label"

# ...but a label a TOOL owns survives even --prune. Found by running `plan` against this kit's own
# repository: release-please's `autorelease: pending` / `autorelease: tagged` look undeclared
# because no human declares them, and the repo profile says in as many words that they are never
# applied by hand. One `apply --prune` would have deleted both and broken the release pipeline.
jq '. + [{"name":"bot-owned: state","color":"ededed","description":"a tool owns this"}]' \
  "$GH_LABELS_JSON" > "$GH_LABELS_JSON.t" && mv "$GH_LABELS_JSON.t" "$GH_LABELS_JSON"

fresh_log prunekeep
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" --prune 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply --prune with a protected label: expected exit 0, got $rc — $out"
jq -e '[.[] | select(.name == "bot-owned: state")] | length == 1' "$GH_LABELS_JSON" > /dev/null \
  || fail "apply --prune DELETED a label matching pruneKeep — the protection is gone"
has_line "^!KEEP .*bot-owned: state" "$out" \
  || fail "apply --prune did not report the protected label — output: $out"
n=$(gh_calls_matching "label delete")
[ "$n" -eq 0 ] || fail "apply --prune issued $n delete(s) against a protected label"
echo "  ok: apply --prune — a label matching pruneKeep is reported !KEEP and never deleted"

# The glob has to be a glob: `autorelease: *` covering two real labels is the whole reason the
# field exists, so a fixture that only ever matched literally would prove nothing.
jq '. + [{"name":"bot-owned: other","color":"ededed","description":"second one"}]' \
  "$GH_LABELS_JSON" > "$GH_LABELS_JSON.t" && mv "$GH_LABELS_JSON.t" "$GH_LABELS_JSON"
fresh_log pruneglob
rc=0; out=$(bash "$SCRIPT" apply "$repo3" --manifest "$FIXTURE" --prune 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply --prune, second protected label: expected exit 0, got $rc — $out"
jq -e '[.[] | select(.name | startswith("bot-owned: "))] | length == 2' "$GH_LABELS_JSON" > /dev/null \
  || fail "the pruneKeep pattern did not match as a glob — one of the two was deleted"
echo "  ok: apply --prune — pruneKeep entries match as globs, covering a whole namespace"

# ------------------------------------------------------------- 9. issue forms: copy, never clobber

repo4=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log forms
rc=0; out=$(bash "$SCRIPT" apply "$repo4" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply into a repo with no forms: expected exit 0, got $rc — $out"
[ -f "$repo4/.github/ISSUE_TEMPLATE/feature_request.yml" ] \
  || fail "apply did not write .github/ISSUE_TEMPLATE/feature_request.yml"
cmp -s "$KIT_ROOT/templates/issue-forms/feature_request.yml" \
       "$repo4/.github/ISSUE_TEMPLATE/feature_request.yml" \
  || fail "the copied form differs from the shipped source"
echo "  ok: apply — a declared form absent from the target is copied verbatim"

# Never clobber. A consumer's tuned form outranks the kit's default, so an existing file is
# reported and left alone — the difference between a helpful tool and one that eats your work.
repo5=$(new_repo) || fail "could not create a scratch git repo"
mkdir -p "$repo5/.github/ISSUE_TEMPLATE"
printf 'name: MINE-DO-NOT-TOUCH\n' > "$repo5/.github/ISSUE_TEMPLATE/feature_request.yml"
fresh_log noclobber
rc=0; out=$(bash "$SCRIPT" apply "$repo5" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply over an existing form: expected exit 0, got $rc — $out"
grep -q 'MINE-DO-NOT-TOUCH' "$repo5/.github/ISSUE_TEMPLATE/feature_request.yml" \
  || fail "apply OVERWROTE an existing issue form — the never-clobber rule is gone"
has_line "^!SKIP .*feature_request.yml" "$out" \
  || fail "apply did not report the skipped form — output: $out"
echo "  ok: apply — an existing form is reported !SKIP and never overwritten"

# A placeholder-only manifest — $FIXTURE, exercised above — leaves the shipped placeholder
# untouched. cmp -s at line 481 already proves this byte-for-byte; this reads it through the same
# lens the real-areas case below uses, so both halves of the contract are visible side by side.
form_areas=$(read_area_options "$repo4/.github/ISSUE_TEMPLATE/feature_request.yml") \
  || fail "the copied placeholder-only form does not parse as YAML"
[ "$form_areas" = "area: <your-area>" ] \
  || fail "a placeholder-only manifest changed the copied form's Area dropdown — got: $form_areas"
echo "  ok: apply — a placeholder-only manifest leaves the shipped Area placeholder untouched"

# --------------------------------------------- 9b. issue forms: apply projects the manifest's areas
#
# The other half of #198: a manifest that HAS filled in real area: labels gets a copied form whose
# Area dropdown offers exactly those labels, in manifest order — generated, not hand-edited.

AREAS_FIXTURE="$KIT_ROOT/tests/repo-setup/fixtures/manifest-areas.yml"
[ -r "$AREAS_FIXTURE" ] || fail "fixture $AREAS_FIXTURE missing"

repo4b=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log formsareas
rc=0; out=$(bash "$SCRIPT" apply "$repo4b" --manifest "$AREAS_FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply with real areas: expected exit 0, got $rc — output: $out"
[ -f "$repo4b/.github/ISSUE_TEMPLATE/bug_report.yml" ] \
  || fail "apply did not write .github/ISSUE_TEMPLATE/bug_report.yml"

form_areas=$(read_area_options "$repo4b/.github/ISSUE_TEMPLATE/bug_report.yml") \
  || fail "the generated bug_report.yml does not parse as YAML"
expected_areas="area: alpha
area: beta
area: gamma"
[ "$form_areas" = "$expected_areas" ] \
  || fail "the generated Area dropdown does not match the manifest's real areas, in order — got: $form_areas"
echo "  ok: apply — a manifest with real areas projects them into the copied form's Area dropdown, in order"

# Everything else about the form is untouched — the projection is a line-range replacement of the
# options: block, not a round-trip dump that would reflow the file and drop its comments.
# `diff` exits 1 merely because the files differ (the expected, intentional case), and under this
# suite's `set -o pipefail` that would abort the WHOLE script right here with no FAIL line — `||
# true` on the pipeline, same guard section 6 uses for its own "fill-me" grep.
diff_lines=$(diff "$KIT_ROOT/templates/issue-forms/bug_report.yml" \
                   "$repo4b/.github/ISSUE_TEMPLATE/bug_report.yml" | grep -c '^[<>]' || true)
[ "$diff_lines" -eq 4 ] \
  || fail "the generated form differs from the shipped source by more than the options: block ($diff_lines changed line(s))"
echo "  ok: apply — projecting the Area dropdown touches only the options: block, nothing else"

# `plan` was only ever exercised against a PLACEHOLDER-only manifest (where it now permanently
# exits 1, per Task 1). A manifest whose area axis is genuinely filled in must still reach a
# converged plan once everything else lands — the property Task 1's change could plausibly break
# for the "good" case while fixing the "bad" one.
fresh_log formsareasplan
rc=0; out=$(bash "$SCRIPT" plan "$repo4b" --manifest "$AREAS_FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "plan after apply with real areas: expected exit 0 (converged), got $rc — output: $out"
case "$out" in
  *"!TODO"*) fail "plan after apply with real areas still reports !TODO — output: $out" ;;
esac
echo "  ok: plan — a manifest with a fully filled-in area axis reaches a converged plan"

# --------------------------------------- 9c. apply refuses a form whose Area dropdown projection
#                                              failed, instead of silently noting it (#240)
#
# project-area-options.py exit 3 means "the structural check found an id: area dropdown, but the
# textual line-range locator couldn't find its options: list to rewrite" — a projection the diff
# pass already PROMISED ("+ADD … Area dropdown will be generated") and then didn't deliver.
# Before #240 this routed through note(), which is exit 0 and adds nothing to REFUSED — so a form
# shaped this way looked converged forever after the first `apply`, with nothing anywhere going
# red. This pins the fix: exit 3 now counts as a refusal, the same way every other partial `apply`
# result already does.

BROKEN_FORM_FIXTURE="$KIT_ROOT/tests/repo-setup/fixtures/broken-options-form.yml"
BROKEN_FORM_MANIFEST="$KIT_ROOT/tests/repo-setup/fixtures/manifest-broken-form.yml"
[ -r "$BROKEN_FORM_FIXTURE" ] || fail "fixture $BROKEN_FORM_FIXTURE missing"
[ -r "$BROKEN_FORM_MANIFEST" ] || fail "fixture $BROKEN_FORM_MANIFEST missing"

# issueTemplates entries resolve against the kit's OWN templates/issue-forms/ — repo-setup.sh's
# FORMS_DIR is a fixed constant, not configurable per run — so exercising this through the real
# `apply` path means placing the broken fixture there for the one `apply` call below, never as a
# lasting addition to the kit's shipped forms. `rc`/`out` are captured rather than asserted on the
# spot precisely so the `rm` runs unconditionally, before any `fail` that would otherwise exit this
# script with the fixture still sitting in a tracked directory.
BROKEN_FORM_DEST="$KIT_ROOT/templates/issue-forms/broken-options-form.yml"
[ -e "$BROKEN_FORM_DEST" ] && fail "$BROKEN_FORM_DEST already exists — refusing to overwrite it"
cp "$BROKEN_FORM_FIXTURE" "$BROKEN_FORM_DEST"

repo4d=$(new_repo) || { rm -f "$BROKEN_FORM_DEST"; fail "could not create a scratch git repo"; }
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log brokenform
rc=0; out=$(bash "$SCRIPT" apply "$repo4d" --manifest "$BROKEN_FORM_MANIFEST" 2>&1) || rc=$?
rm -f "$BROKEN_FORM_DEST"

[ "$rc" -eq 3 ] \
  || fail "apply with a form the projector cannot rewrite: expected exit 3 (REFUSED), got $rc — output: $out"
has_line "^!REFUSED .*forms.*broken-options-form.yml.*could not be generated" "$out" \
  || fail "a failed Area-dropdown projection did not report !REFUSED — output: $out"
case "$out" in
  *"!NOTE"*"broken-options-form.yml"*) fail "a failed Area-dropdown projection still went through !NOTE (silent, exit 0) — output: $out" ;;
esac
[ -f "$repo4d/.github/ISSUE_TEMPLATE/broken-options-form.yml" ] \
  || fail "apply did not copy the form even though its dropdown projection failed — a copied-but-unprojected form is still a form"
echo "  ok: apply — a form whose Area dropdown projection fails (exit 3) reports !REFUSED and exits 3, not a silent !NOTE at exit 0"

# A manifest can declare a placeholder-SHAPED area label that ISN'T the literal shipped
# "area: <your-area>" — e.g. "area: parser <experimental>", a label someone is still deciding on.
# The main diff loop's placeholder test is a SUBSTRING match (`*"<"*">"*`, a few lines above this
# file), so it correctly !TODO's this and never creates it. AREA_ARGS's filter must agree — an
# anchored pattern that only excluded the exact shipped placeholder would let this one through, so
# `apply` would project an Area dropdown option pointing at a label that is never created.
MIXED_FIXTURE="$KIT_ROOT/tests/repo-setup/fixtures/manifest-mixed-placeholder.yml"
[ -r "$MIXED_FIXTURE" ] || fail "fixture $MIXED_FIXTURE missing"

repo4c=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log mixedplaceholder
rc=0; out=$(bash "$SCRIPT" plan "$repo4c" --manifest "$MIXED_FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "plan with a mixed placeholder: expected exit 1, got $rc — output: $out"
has_line "^!TODO .*area: parser <experimental>" "$out" \
  || fail "plan: the substring placeholder is not reported as !TODO — output: $out"
# Line-oriented, never a `case` glob over the whole multi-line report (the file's own §4 comment,
# a few hundred lines up, explains why): "+ADD" from an unrelated line and "area: parser
# <experimental>" from the !TODO line above would satisfy a cross-line glob with nothing wrong.
! has_line "^\+ADD .*area: parser <experimental>" "$out" \
  || fail "plan queued the substring placeholder for creation — output: $out"
echo "  ok: plan — a substring-shaped placeholder (not the literal shipped one) is still !TODO, never +ADD"

fresh_log mixedplaceholderapply
rc=0; out=$(bash "$SCRIPT" apply "$repo4c" --manifest "$MIXED_FIXTURE" 2>&1) || rc=$?
[ -f "$repo4c/.github/ISSUE_TEMPLATE/bug_report.yml" ] \
  || fail "apply did not write .github/ISSUE_TEMPLATE/bug_report.yml"
n=$(gh_calls_matching "experimental")
[ "$n" -eq 0 ] || fail "apply sent the substring placeholder to gh $n time(s)"
mixed_form_areas=$(read_area_options "$repo4c/.github/ISSUE_TEMPLATE/bug_report.yml") \
  || fail "the generated bug_report.yml does not parse as YAML"
[ "$mixed_form_areas" = "area: alpha" ] \
  || fail "the substring placeholder leaked into the generated Area dropdown — got: $mixed_form_areas"
echo "  ok: apply — the substring placeholder never reaches gh and never leaks into the generated dropdown"

# --------------------------------------- 9d. forms: an OS-level write failure names its cause (#222)
#
# The form-copy refusal was a bare "could not write $FORMS_TARGET/$f1" — no cause at all, unlike
# the gh-write refusals #200/#222 fixed for labels and settings. Not a `gh` call, so there is no
# HTTP status to classify: just capture what mkdir/cp actually said. A plain FILE sitting where the
# target directory needs to be forces that failure without depending on write permissions (which
# root — or a container running as root, as CI sometimes does — would sail straight through).

repo4e=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"
mkdir -p "$repo4e/.github"
: > "$repo4e/.github/ISSUE_TEMPLATE"   # a file, not a directory — mkdir -p must fail on this path

fresh_log formwritefail
rc=0; out=$(bash "$SCRIPT" apply "$repo4e" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, form copy blocked by a non-directory target: expected exit 3, got $rc — output: $out"
has_line "^!REFUSED .*forms.*could not write .*ISSUE_TEMPLATE/feature_request.yml" "$out" \
  || fail "the form refusal does not name the path — output: $out"
case "$out" in
  *"could not write .github/ISSUE_TEMPLATE/feature_request.yml"$'\n'*)
    fail "a form-copy refusal reports the path with no OS-level cause — output: $out" ;;
esac
echo "  ok: forms — an OS-level form-copy failure names the cause mkdir/cp actually reported, not just the path"

# ------------------------------------------------------------------ 10. settings: one PATCH, once

repo6=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log settings1
rc=0; out=$(bash "$SCRIPT" apply "$repo6" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "apply with a drifting setting: expected exit 0, got $rc — $out"
n=$(gh_calls_matching "PATCH")
[ "$n" -eq 1 ] || fail "expected exactly 1 PATCH call, got $n — settings must batch into one"
grep -q 'delete_branch_on_merge=true' "$GH_CALL_LOG" \
  || fail "the PATCH did not carry delete_branch_on_merge=true — log: $(cat "$GH_CALL_LOG")"
echo "  ok: apply — drifting settings batch into exactly one PATCH carrying the desired value"

fresh_log settings2
rc=0; out=$(bash "$SCRIPT" apply "$repo6" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "second apply: expected exit 0, got $rc — $out"
n=$(gh_calls_matching "PATCH")
[ "$n" -eq 0 ] || fail "second apply issued $n PATCH call(s) — the settings surface is not idempotent"
echo "  ok: apply — a converged setting issues no PATCH at all"

# -------------------------------------------------------- 11. degrade per surface, never abort
#
# The point of exit 3. "The settings needed admin rights and everything else is in place" and
# "nothing happened, and you get to guess why" are different outcomes, and a script that aborts on
# the first refusal reports the second while having done the first. profile-repo makes the same
# argument for writing an honest TODO rather than no profile at all.

repo7=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log noadmin
rc=0; out=$(GH_PATCH_FAILS=1 bash "$SCRIPT" apply "$repo7" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply without admin rights: expected exit 3, got $rc — output: $out"
n=$(gh_calls_matching "label create")
[ "$n" -eq 2 ] || fail "a refused PATCH stopped the label surface: expected 2 creates, got $n"
[ -f "$repo7/.github/ISSUE_TEMPLATE/feature_request.yml" ] \
  || fail "a refused PATCH stopped the form surface — the form was never written"
has_line "^!REFUSED .*settings" "$out" \
  || fail "the refused surface is not named in the report — output: $out"
echo "  ok: degrade — a refused settings PATCH still applies labels and forms, and exits 3"

# The report must name the surface, not just fail: the operator's next action (grant admin, or
# accept the gap) depends on knowing WHICH half did not land.
case "$out" in
  *"admin"*) ;;
  *) fail "the refusal does not say what is missing — output: $out" ;;
esac
echo "  ok: degrade — the refusal names the surface and the missing permission"

# Without gh at all, both remote surfaces are unreadable — and the local half still runs.
repo8=$(new_repo) || fail "could not create a scratch git repo"
fresh_log noauth
rc=0; out=$(GH_AUTH_FAILS=1 bash "$SCRIPT" apply "$repo8" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply without gh auth: expected exit 3, got $rc — output: $out"
[ -f "$repo8/.github/ISSUE_TEMPLATE/feature_request.yml" ] \
  || fail "unauthenticated gh stopped the purely local form copy"
has_line "^!REFUSED .*labels" "$out" || fail "the labels surface is not reported — output: $out"
n=$(gh_calls_matching "label create")
[ "$n" -eq 0 ] || fail "apply issued $n label write(s) while unauthenticated"
echo "  ok: degrade — unauthenticated gh refuses both remote surfaces, local forms still land"

# And `plan` reports the same way rather than claiming a converged repo it could not read. A plan
# that exits 0 because it read nothing is the exact "absence looks like success" failure this whole
# suite is about.
fresh_log noauthplan
rc=0; out=$(GH_AUTH_FAILS=1 bash "$SCRIPT" plan "$repo8" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "plan without gh auth: expected exit 3, got $rc — output: $out"
echo "  ok: degrade — plan exits 3 on an unreadable surface, never 0"

# ---------------------------------------- 12. a refused label write names what gh observed (#200)
#
# `!REFUSED` blamed EVERY non-zero label write on the token — including a 422, which is the
# operator's OWN manifest (an over-long description, a colour GitHub rejects), not a permissions
# gap. MEASURED against a real repository:
#   gh label edit "area: ci" --description "$(printf 'x%.0s' $(seq 1 101))"
#     HTTP 422: Validation Failed (https://api.github.com/repos/OWNER/REPO/labels/area:%20ci)
#     description is too long (maximum is 100 characters)
# 403 is the one case where the token sentence IS the right cause, so it must survive unchanged.

repo9=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log label403
rc=0; out=$(GH_LABEL_FAILS=1 GH_LABEL_FAIL_STATUS=403 bash "$SCRIPT" apply "$repo9" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label write refused by 403: expected exit 3, got $rc — output: $out"
has_line "^!REFUSED .*labels.*check the token's scope on this repository" "$out" \
  || fail "a 403 label refusal must keep today's token sentence — output: $out"
echo "  ok: labels — a 403 refusal still names the token"

repo10=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log label422
rc=0; out=$(GH_LABEL_FAILS=1 GH_LABEL_FAIL_STATUS=422 bash "$SCRIPT" apply "$repo10" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label write refused by 422: expected exit 3, got $rc — output: $out"
case "$out" in
  *"check the token's scope"*) fail "a 422 label refusal must not blame the token — output: $out" ;;
esac
has_line "^!REFUSED .*labels.*description is too long" "$out" \
  || fail "a 422 label refusal must echo GitHub's field message — output: $out"
echo "  ok: labels — a 422 refusal names the validation cause, not the token"

# A 422 with TWO simultaneous field errors must not silently drop the second one — a fixed line
# number cannot be trusted to be "the" field message when GitHub reports more than one.
repo10b=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log label422multi
rc=0; out=$(GH_LABEL_FAILS=1 GH_LABEL_FAIL_STATUS=422multi bash "$SCRIPT" apply "$repo10b" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label write refused by a multi-field 422: expected exit 3, got $rc — output: $out"
case "$out" in
  *"color is invalid"*"description is too long"*) ;;
  *) fail "a multi-field 422 refusal dropped one of the two field errors — output: $out" ;;
esac
echo "  ok: labels — a 422 refusal with two field errors reports both, not just the first"

# A `gh` that exits non-zero with NOTHING on stderr must not regress below the old universal
# sentence: a dangling "— " with no cause is strictly less useful than what it replaced.
repo10c=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log labelempty
rc=0; out=$(GH_LABEL_FAILS=1 GH_LABEL_FAIL_STATUS=empty bash "$SCRIPT" apply "$repo10c" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label write refused with empty stderr: expected exit 3, got $rc — output: $out"
case "$out" in
  *"— "$'\n'*) fail "an empty-stderr label refusal trails off with nothing after the dash — output: $out" ;;
esac
has_line "^!REFUSED .*labels.*gh gave no reason" "$out" \
  || fail "an empty-stderr label refusal must still say something actionable — output: $out"
echo "  ok: labels — a refusal with empty stderr still reports an actionable cause, never a dangling dash"

# ------------------------------- 12b. a refused label delete names what gh observed (#222)
#
# `!REFUSED` collapsed EVERY refused delete to a bare "could not delete '$f1'" — no cause at all,
# not even the token-scope sentence #200 gave label create/edit. #222 routes it through the same
# gh_refusal() classifier those already use.

repo12=$(new_repo) || fail "could not create a scratch git repo"
printf '[{"name":"priority: high","color":"b60205","description":"Pull this first"},{"name":"effort: small","color":"c2e0c6","description":"One task"},{"name":"legacy-thing","color":"ededed","description":"someone else was here"}]\n' \
  > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":true}\n' > "$GH_SETTINGS_JSON"

fresh_log delete422
rc=0; out=$(GH_DELETE_FAILS=1 GH_DELETE_FAIL_STATUS=422 bash "$SCRIPT" apply "$repo12" --manifest "$FIXTURE" --prune 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply --prune, delete refused by 422: expected exit 3, got $rc — output: $out"
n=$(gh_calls_matching "label delete")
[ "$n" -eq 1 ] || fail "expected exactly 1 delete attempt, got $n"
case "$out" in
  *"could not delete 'legacy-thing'"$'\n'*)
    fail "a refused delete still reports the bare old sentence with no cause — output: $out" ;;
esac
has_line "^!REFUSED .*labels.*could not delete 'legacy-thing' — refused (422): description is too long" "$out" \
  || fail "a 422 delete refusal must echo GitHub's field message, not a bare sentence — output: $out"
echo "  ok: labels — a refused delete names the status it observed, not a bare sentence"

# ---------------------------- 12c. a refused settings PATCH names what gh observed (#222)
#
# The settings refusal hardcoded "the token needs admin rights on it" for EVERY failure, including
# a 422 (an invalid setting value) that has nothing to do with admin rights. The 403 case keeps
# that exact sentence (#222's Task 2: it is the established, already-tested wording for that
# branch) — only the other statuses change.

repo13=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log settings422
rc=0; out=$(GH_PATCH_FAILS=1 GH_PATCH_FAIL_STATUS=422 bash "$SCRIPT" apply "$repo13" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, settings PATCH refused by 422: expected exit 3, got $rc — output: $out"
case "$out" in
  *"admin rights"*) fail "a 422 settings refusal must not blame the token — output: $out" ;;
esac
has_line "^!REFUSED .*settings.*description is too long" "$out" \
  || fail "a 422 settings refusal must echo GitHub's field message — output: $out"
echo "  ok: settings — a 422 refusal names the validation cause, not admin rights"

repo14=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log settings403
rc=0; out=$(GH_PATCH_FAILS=1 GH_PATCH_FAIL_STATUS=403 bash "$SCRIPT" apply "$repo14" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, settings PATCH refused by 403: expected exit 3, got $rc — output: $out"
has_line "^!REFUSED .*settings.*the token needs admin rights on it" "$out" \
  || fail "a 403 settings refusal must keep the established admin-rights sentence — output: $out"
echo "  ok: settings — a 403 refusal keeps the established admin-rights sentence unchanged"

# ------------------------------------- 12d. reads name what gh observed, not a fixed sentence (#223)
#
# `gh label list` and `gh api repos/$SLUG` (reading current settings) discarded stderr and always
# reported "no access"/"settings were not read" — so a transient rate-limit or a 5xx got the exact
# same wording as an actual 403. The 403 case keeps the pre-#223 sentence; anything else now names
# what gh actually said. Folded from #223 into #222 as this issue's fifth site.

repo15=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log listratelimit
rc=0; out=$(GH_LIST_FAILS=1 GH_LIST_FAIL_STATUS=ratelimited bash "$SCRIPT" apply "$repo15" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label list rate-limited: expected exit 3, got $rc — output: $out"
case "$out" in
  *"no access to this repository's labels"*)
    fail "a rate-limited label list must not report the fixed 'no access' sentence — output: $out" ;;
esac
has_line "^!REFUSED .*labels.*API rate limit exceeded" "$out" \
  || fail "a rate-limited label list must name what gh actually said — output: $out"
echo "  ok: labels — a read refused by something other than real access names that cause, not 'no access'"

fresh_log listaccess
rc=0; out=$(GH_LIST_FAILS=1 GH_LIST_FAIL_STATUS=403 bash "$SCRIPT" apply "$repo15" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, label list refused by a real 403: expected exit 3, got $rc — output: $out"
has_line "^!REFUSED .*labels.*no access to this repository's labels" "$out" \
  || fail "an actual 403 label-list refusal must keep the established 'no access' sentence — output: $out"
echo "  ok: labels — a real 403 on label list keeps the established 'no access' sentence"

repo16=$(new_repo) || fail "could not create a scratch git repo"
printf '[]\n' > "$GH_LABELS_JSON"
printf '{"delete_branch_on_merge":false}\n' > "$GH_SETTINGS_JSON"

fresh_log settingsreadratelimit
rc=0; out=$(GH_SETTINGS_READ_FAILS=1 GH_SETTINGS_READ_FAIL_STATUS=ratelimited bash "$SCRIPT" apply "$repo16" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, settings read rate-limited: expected exit 3, got $rc — output: $out"
case "$out" in
  *"settings were not read"*)
    fail "a rate-limited settings read must not report the fixed 'not read' sentence — output: $out" ;;
esac
has_line "^!REFUSED .*settings.*API rate limit exceeded" "$out" \
  || fail "a rate-limited settings read must name what gh actually said — output: $out"
echo "  ok: settings — a read refused by something other than real access names that cause, not 'not read'"

fresh_log settingsreadaccess
rc=0; out=$(GH_SETTINGS_READ_FAILS=1 GH_SETTINGS_READ_FAIL_STATUS=403 bash "$SCRIPT" apply "$repo16" --manifest "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || fail "apply, settings read refused by a real 403: expected exit 3, got $rc — output: $out"
has_line "^!REFUSED .*settings.*settings were not read" "$out" \
  || fail "an actual 403 settings-read refusal must keep the established 'not read' sentence — output: $out"
echo "  ok: settings — a real 403 on the settings read keeps the established 'not read' sentence"

# --------------------------------- 13. an over-long description is caught locally, never sent (#200)
#
# The 422 case above IS reachable — GitHub really does refuse a >100-char description — but the kit
# already parses the manifest locally, so this is knowable before any network round-trip. Refusing
# it in parse-manifest.py turns a live-API surprise into a `plan`-time message pointing at the
# operator's own manifest, and costs nothing the 422 path wasn't already going to cost.

LONG_FIXTURE="$KIT_ROOT/tests/repo-setup/fixtures/manifest-long-description.yml"
[ -r "$LONG_FIXTURE" ] || fail "fixture $LONG_FIXTURE missing"

repo11=$(new_repo) || fail "could not create a scratch git repo"
fresh_log longdesc
rc=0; out=$(bash "$SCRIPT" plan "$repo11" --manifest "$LONG_FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "plan with an over-long description: expected exit 2, got $rc — output: $out"
case "$out" in
  *"area: too-long"*) ;;
  *) fail "the refusal does not name the offending label — output: $out" ;;
esac
case "$out" in
  *"101"*) ;;
  *) fail "the refusal does not name the length — output: $out" ;;
esac
n=$(gh_calls_matching "label")
[ "$n" -eq 0 ] || fail "an over-long description reached the gh stub — $n call(s) logged, expected 0"
echo "  ok: parser — an over-long description refuses locally, names the label and length, and never reaches gh"

# -------------------------------------------------- 14. this repository's own configuration (#196)
#
# Sections 1-11 drive the tool over scratch repos. This one asserts a fact about THIS repository,
# the way tests/repo-profile/test.sh asserts that the kit tracks its own profile: the kit shipped
# the taxonomy in #192 and did not adopt it, so `auto-dev`'s effort ordering and area isolation
# read nothing HERE, in the repo the fleet is most often run in.
#
# The taxonomy lives in `.github/repo-setup.yml`, NOT in the shipped default: repo-setup.sh:103
# prefers the target repo's own file, and this repo's area names (`area: merge-pr`,
# `area: implement-issue`) describe the KIT — pushing them onto every consumer who applies the
# shipped manifest unedited is the cost that override exists to avoid.

REPO_MANIFEST="$KIT_ROOT/.github/repo-setup.yml"
[ -r "$REPO_MANIFEST" ] || fail ".github/repo-setup.yml missing — this repo declares no taxonomy of its own (#196)"

# stderr captured to its OWN file rather than folded into $repo_parsed: parse-manifest.py's
# `die()` messages (a bad label name, an over-long description, #200) go to stderr, and a `fail`
# that cannot see them can only say "does not parse" — which label, and why, is then a re-run away.
repo_parse_err="$(kit_scratch)/repo-manifest-parse.err"
repo_parsed=$(python3 "$KIT_ROOT/skills/setup-repo/scripts/parse-manifest.py" "$REPO_MANIFEST" 2>"$repo_parse_err") \
  || fail ".github/repo-setup.yml does not parse: $(cat "$repo_parse_err" 2>/dev/null)"

for axis in "priority: " "effort: " "area: "; do
  case "$repo_parsed" in
    *"$axis"*) ;;
    *) fail "this repo's manifest declares no '$axis' label — the axis #192 is about" ;;
  esac
done
echo "  ok: repo manifest — .github/repo-setup.yml declares the priority:, effort: and area: axes"

# A placeholder here would mean the axis is still unfilled, which is precisely the state #196
# reports: `apply` never creates a <bracketed> name, so it would look converged and configure
# nothing. Line-oriented, never a glob over the whole report: `case $all in *"L"*"<"*)` matches
# across lines and would pass on any manifest with any label at all.
# The DESCRIPTION is checked as well as the name: `- name: "area: docs"` carrying the shipped
# default's "Replace with one entry per functional area of this repo" is a filled-in axis by name
# and an unfilled one in substance, and GitHub would carry that sentence on a real label forever
# while `plan` reported it =OK.
ph=$(printf '%s\n' "$repo_parsed" | awk -F'\t' '$1 == "L" && ($2 ~ /<.*>/ || $4 ~ /<.*>/ || $4 ~ /^Replace with/) { n++ } END { print n+0 }')
[ "$ph" -eq 0 ] || fail "this repo's manifest still carries $ph placeholder label(s) — the axis is unfilled"
echo "  ok: repo manifest — no <placeholder> label or stock description survives in this repo's own manifest"

# Every tracked top-level entry must fall under some area, because both forms mark the Area
# dropdown `required: true` — an uncovered path is a path no issue can be filed against, and one
# `auto-dev` can hand no worker as a non-overlapping slice. Checked as a floor on the axis rather
# than as a path-by-path mapping, which would encode the tree into the suite: the first draft of
# this taxonomy covered six trees and left five (docs/, reviews/, samples/, .claude/,
# .claude-plugin/) with no option at all, and nothing here would have noticed.
#
# No separate length assertion here for GitHub's 100-character description cap (#197 had added
# one): parse-manifest.py now refuses an over-long description itself (#200, section 13 above), so
# `repo_parsed` above could not exist if this manifest carried one — one home for the rule.

n_areas=$(printf '%s\n' "$repo_parsed" | awk -F'\t' '$1 == "L" && $2 ~ /^area: / { n++ } END { print n+0 }')
n_trees=$(git ls-files | awk -F/ '{ print $1 }' | sort -u | wc -l)
[ "$n_areas" -ge 10 ] \
  || fail "only $n_areas area: labels for $n_trees tracked top-level entries — the axis cannot cover the tree"
echo "  ok: repo manifest — $n_areas area: labels for $n_trees tracked top-level entries"

# The repo-local manifest REPLACES the shipped one rather than extending it, so pruneKeep does not
# come along by itself. Dropping it re-arms the case `plan` found against this very repository: a
# single `apply --prune` deleting release-please's housekeeping labels and Renovate's.
# `case` over a captured string, not `printf … | grep -q`: under this suite's `set -o pipefail`,
# `grep -q` exits at the first match and SIGPIPEs the writer, so the pipeline returns 141 and the
# assertion fires on a manifest that is correct. Latent at this manifest's size, load-bearing the
# day it grows past the pipe buffer.
keeps=$(printf '%s\n' "$repo_parsed" | awk -F'\t' '$1 == "K" { print $2 }')
for keep in "autorelease: *" "dependencies"; do
  case "
$keeps
" in
    *"
$keep
"*) ;;
    *) fail "this repo's manifest lost the pruneKeep entry '$keep' — --prune would delete it" ;;
  esac
done
echo "  ok: repo manifest — pruneKeep still protects the release-please and Renovate labels"

# The forms and the labels are one taxonomy in two files, and `create-issue` picks the label
# matching whatever the dropdown offered — so a dropdown that disagrees with the label set makes
# the issue body and the issue's label contradict each other, with nothing anywhere going red.
# Order too: the two are read side by side by whoever edits them next, and a silent re-ordering is
# how the copies start drifting. read_area_options() is the shared reader defined once, near
# `has_line` — one home for the mechanism, not a second copy that can drift from it (#198).

manifest_areas=$(printf '%s\n' "$repo_parsed" | awk -F'\t' '$1 == "L" && $2 ~ /^area: / { print $2 }')
for form in feature_request bug_report; do
  form_path="$KIT_ROOT/.github/ISSUE_TEMPLATE/$form.yml"
  shipped_path="$KIT_ROOT/templates/issue-forms/$form.yml"
  [ -r "$form_path" ] || fail ".github/ISSUE_TEMPLATE/$form.yml missing — apply did not copy it"
  # The `area` dropdown's options only: the forms carry other fields, and a bare grep for quoted
  # "area: …" strings would also match the description prose above the list.
  form_areas=$(read_area_options "$form_path") \
    || fail "$form.yml does not parse as YAML"
  [ "$manifest_areas" = "$form_areas" ] \
    || fail "$form.yml's Area dropdown does not match the manifest's area: labels, in order"

  # The stronger check (#198): the committed form is now GENERATED, not hand-edited, so it must
  # differ from the shipped source in the options: block and NOTHING else — closing finding (c),
  # where a field added to the shipped template could silently miss the kit's own copy and nothing
  # would notice. Every changed line (diff's `<`/`>`) must itself be a quoted options-list item;
  # anything else surviving the filter is a divergence this check exists to catch. `|| true`: diff
  # exits 1 merely because the files differ (expected), and this suite runs under pipefail.
  stray_diff=$(diff "$shipped_path" "$form_path" | grep '^[<>]' | grep -v '^[<>] *- "area: ' || true)
  [ -z "$stray_diff" ] \
    || fail "$form.yml differs from $shipped_path outside the generated options: block — $stray_diff"
done
echo "  ok: forms — both Area dropdowns offer exactly this repo's area: labels, in order"
echo "  ok: forms — both committed forms differ from the shipped source only in the generated options: block"

# And the shipped default must STILL be a placeholder. This is the half a well-meaning later edit
# breaks: filling it in looks like finishing the job, and silently exports `area: merge-pr` to
# every consumer. `area:` is the only axis that cannot be defaulted — priority and effort are
# universal, areas name someone's code.
ship_ph=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "L" && $2 ~ /^area: <.*>$/ { n++ } END { print n+0 }')
[ "$ship_ph" -eq 1 ] \
  || fail "templates/repo-setup.yml carries $ship_ph area placeholder(s), expected exactly 1 — a consumer must not inherit this repo's area names (#196)"

# Counting the placeholder is only half of it: ADDING `area: merge-pr` beside the placeholder
# leaves that count at 1 and still exports this repo's names to every consumer who applies the
# default unedited. So the real assertion is that the shipped manifest declares NO area label
# other than the placeholder.
ship_real=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "L" && $2 ~ /^area: / && $2 !~ /^area: <.*>$/ { n++ } END { print n+0 }')
[ "$ship_real" -eq 0 ] \
  || fail "templates/repo-setup.yml declares $ship_real filled-in area: label(s) — the shipped default must carry the placeholder ONLY (#196)"
echo "  ok: shipped default — templates/repo-setup.yml keeps its area placeholder, and only that"

# The forms are the other copy of the same hazard, and the direction that bites is syncing the
# kit's own forms BACK over the shipped ones "to finish the job": the manifest check above
# inspects labels, not dropdowns, so that export would pass unnoticed.
for shipped_form in templates/issue-forms/feature_request.yml templates/issue-forms/bug_report.yml; do
  [ -r "$KIT_ROOT/$shipped_form" ] || fail "$shipped_form missing — the shipped form a consumer inherits"
  shipped_areas=$(read_area_options "$KIT_ROOT/$shipped_form") \
    || fail "$shipped_form does not parse as YAML"
  case "$shipped_areas" in
    "area: <"*">") ;;
    *) fail "$shipped_form's Area dropdown is no longer the lone placeholder — a consumer would inherit this repo's areas (#196)" ;;
  esac
done
echo "  ok: shipped default — both shipped forms keep the lone Area placeholder"

echo "PASS: tests/repo-setup"
