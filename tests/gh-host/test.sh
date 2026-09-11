#!/usr/bin/env bash
# Golden test for skills/_shared/scripts/_gh-host.sh — the one place the kit decides which host
# `gh` talks to (#514).
#
# Measured before that file existed: on a GitHub Enterprise repository, every kit script that
# addressed the repository by a bare OWNER/REPO reached github.com instead. `gh -R OWNER/REPO` takes
# gh's DEFAULT host even inside a GHE checkout, and `gh api` never infers one. tick-plan.sh was
# refused 13 times and parent-decision-note.sh failed 6 times in 7 sessions, each time until
# someone typed `export GH_HOST=…` by hand into the same command.
#
# The seam is what a PATH `gh` stub actually receives: its argv plus the GH_HOST in its
# environment, appended to a call log. A fixture caller sources the helper, calls gh_host_resolve
# on its slug and runs `gh api "repos/$KIT_REPO_SLUG/x"` — the shape of every migrated call site.
# Nothing here reads a helper variable back out: every assertion is about what `gh` was asked, and
# on which host.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

# The stub logs `GH_HOST=<value|<unset>> ARGS: <argv>` for every call, and answers
# `gh auth token --hostname H` — the helper's credential probe — with exit 0 only for a host
# listed in $GH_STUB_HOSTS. Its token goes to stdout, as real gh's does, so a case below can prove
# the helper never lets it through.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH_HOST=${GH_HOST-<unset>} ARGS: $*" >> "$GH_CALL_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
  host=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--hostname" ] && host="$a"
    prev="$a"
  done
  case " ${GH_STUB_HOSTS:-} " in
    *" $host "*) echo "gho_stub_token_for_$host"; exit 0 ;;
  esac
  echo "no oauth token found for $host" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$WORK/bin/gh"

# The fixture caller: what every migrated script does, and nothing else.
cat > "$WORK/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
. "$GH_HOST_LIB" || { echo "caller: cannot source $GH_HOST_LIB" >&2; exit 1; }
gh_host_resolve "$1" || exit $?
gh api "repos/$KIT_REPO_SLUG/x"
CALLER

# One scratch checkout per origin shape. `none` is a repository with no origin; `plain` is not a
# repository at all.
checkout() { # checkout <name> [<origin-url>]
  local dir="$WORK/co-$1"
  git init -q "$dir"
  [ -z "${2:-}" ] || git -C "$dir" remote add origin "$2"
  printf '%s\n' "$dir"
}
CO_SCP=$(checkout scp 'git@GHE.example.com:acme/widgets.git')
CO_HTTPS=$(checkout https 'https://ghe.example.com/acme/widgets.git')
CO_SSH=$(checkout ssh 'ssh://git@ghe.example.com:2222/acme/widgets')
CO_CASE=$(checkout case 'git@ghe.example.com:Acme/Widgets.git')
CO_ALIAS=$(checkout alias 'git@github-work:acme/widgets.git')
CO_OTHER=$(checkout other 'git@ghe.example.com:other/thing.git')
CO_NONE=$(checkout none)
CO_PLAIN="$WORK/plain"
mkdir -p "$CO_PLAIN"

# run <name> <dir> <slug> [VAR=value…] — the caller, from <dir>, with the stub first on PATH. The
# ambient GH_HOST is cleared first, so the developer's own shell cannot decide a case; the stub
# holds credentials for ghe.example.com unless a case says otherwise. Leaves the exit code in $RC.
run() {
  local name="$1" dir="$2" slug="$3"
  shift 3
  : > "$WORK/log.$name"
  RC=0
  ( cd "$dir" && env -u GH_HOST PATH="$WORK/bin:$PATH" GH_CALL_LOG="$WORK/log.$name" \
      GH_HOST_LIB="$LIB" GH_STUB_HOSTS=ghe.example.com "$@" bash "$WORK/caller.sh" "$slug" ) \
    > "$WORK/out.$name" 2>&1 || RC=$?
}

fail() { # fail <name> <message>
  echo "FAIL [$1]: $2"
  echo "  --- gh call log:"
  sed 's/^/  | /' "$WORK/log.$1"
  echo "  --- caller output:"
  sed 's/^/  | /' "$WORK/out.$1"
  exit 1
}

# expect <name> <GH_HOST the stub saw, or <unset>> <endpoint>
expect() {
  [ "$RC" -eq 0 ] || fail "$1" "the caller exited $RC"
  grep -Fx -- "GH_HOST=$2 ARGS: api $3" "$WORK/log.$1" > /dev/null \
    || fail "$1" "gh was never asked for 'api $3' with GH_HOST=$2"
  echo "  ok: $1 — gh api $3 reached GH_HOST=$2"
}

echo "rule 1: a host prefix on the slug"
run prefix "$CO_NONE" ghe.example.com/acme/widgets
expect prefix ghe.example.com repos/acme/widgets/x
if grep -F 'repos/ghe.example.com' "$WORK/log.prefix" > /dev/null; then
  fail prefix "the host leaked into a gh api endpoint"
fi
run prefix-case "$CO_NONE" GHE.Example.COM/acme/widgets
expect prefix-case ghe.example.com repos/acme/widgets/x
run prefix-beats-preset "$CO_NONE" ghe.example.com/acme/widgets GH_HOST=other.example
expect prefix-beats-preset ghe.example.com repos/acme/widgets/x

echo "rule 2: a GH_HOST the caller already set"
run preset-kept "$CO_SCP" acme/widgets GH_HOST=other.example
expect preset-kept other.example repos/acme/widgets/x

echo "rule 3: origin's host, same repository, credentialed"
run origin-scp "$CO_SCP" acme/widgets
expect origin-scp ghe.example.com repos/acme/widgets/x
if grep -F 'gho_stub_token' "$WORK/out.origin-scp" > /dev/null; then
  fail origin-scp "the credential probe's token reached the caller's output"
fi
run origin-https "$CO_HTTPS" acme/widgets
expect origin-https ghe.example.com repos/acme/widgets/x
run origin-ssh-port "$CO_SSH" acme/widgets
expect origin-ssh-port ghe.example.com repos/acme/widgets/x
run origin-case "$CO_CASE" acme/widgets
expect origin-case ghe.example.com repos/acme/widgets/x
run empty-slug "$CO_SCP" ""
expect empty-slug ghe.example.com repos//x
# The merge-pr prose passes gh's own placeholder verbatim (`remote-branch-teardown.sh "$HEAD_BRANCH"
# "{owner}/{repo}"`). It names the checkout's repository by definition, so origin's host applies, and
# the placeholder itself reaches gh untouched for `gh api` to expand.
run placeholder "$CO_SCP" '{owner}/{repo}'
expect placeholder ghe.example.com 'repos/{owner}/{repo}/x'
run placeholder-other-repository "$CO_OTHER" '{owner}/{repo}'
expect placeholder-other-repository ghe.example.com 'repos/{owner}/{repo}/x'

echo "rule 4: nothing resolves — gh's default host, exactly as before"
run alias-uncredentialed "$CO_ALIAS" acme/widgets
expect alias-uncredentialed '<unset>' repos/acme/widgets/x
run other-repository "$CO_OTHER" acme/widgets
expect other-repository '<unset>' repos/acme/widgets/x
run no-origin "$CO_NONE" acme/widgets
expect no-origin '<unset>' repos/acme/widgets/x
run not-a-repository "$CO_PLAIN" acme/widgets
expect not-a-repository '<unset>' repos/acme/widgets/x

echo "a malformed slug is refused before any gh call"
for slug in acme a/b/c/d; do
  name="malformed-$(printf '%s' "$slug" | tr '/' '-')"
  run "$name" "$CO_SCP" "$slug"
  [ "$RC" -eq 2 ] || fail "$name" "exited $RC, want 2"
  grep -F -- "gh-host: malformed repository slug '$slug' — expected [HOST/]OWNER/REPO" \
    "$WORK/out.$name" > /dev/null || fail "$name" "stderr does not name the slug"
  [ ! -s "$WORK/log.$name" ] || fail "$name" "gh was called for a malformed slug"
  echo "  ok: $name — exit 2, slug named, no gh call"
done

echo "the helper refuses to be executed"
RC=0
bash "$LIB" > "$WORK/out.executed" 2>&1 || RC=$?
[ "$RC" -eq 2 ] || { echo "FAIL [executed]: running $LIB directly exited $RC, want 2"; exit 1; }
grep -F 'SOURCED, never executed' "$WORK/out.executed" > /dev/null \
  || { echo "FAIL [executed]: no 'SOURCED, never executed' message"; cat "$WORK/out.executed"; exit 1; }
echo "  ok: executed — exit 2, says to source it"

# sweep <repository-root> — print each tracked, shipped script under skills/*/scripts/, scripts/ or
# hooks/ that addresses a repository by slug — `gh … -R/--repo "$…"`, `gh api … "repos/$…"`, or an
# endpoint `="repos/$…"` built for a later `gh api` — without loading _gh-host.sh, and return 1 when
# there is one. The helper itself is the one exemption: it is where the host gets resolved. The eight
# migrated scripts were found by grep once; this is what stops a ninth from quietly reaching
# github.com on every GitHub Enterprise repository again.
SWEEP_PATTERN='gh .*(-R|--repo)[ =]"\$|gh api[^|]*"repos/\$|="repos/\$'
sweep() {
  local root="$1" f found=0
  git -C "$root" ls-files -- 'skills/*/scripts/*' 'scripts/*' 'hooks/*' > "$WORK/sweep.list"
  while IFS= read -r f; do
    case "$f" in */_gh-host.sh) continue ;; esac
    [ -f "$root/$f" ] || continue
    grep -Eq -- "$SWEEP_PATTERN" "$root/$f" || continue
    if grep -Fq '_gh-host.sh' "$root/$f"; then continue; fi
    printf '%s\n' "$f"
    found=1
  done < "$WORK/sweep.list"
  return "$found"
}

echo "the tree sweep: a shipped script that addresses a repository by slug loads the helper"
# Proven against a fixture first, so a sweep that matches nothing cannot pass the real tree by
# default. Each file is one shape: `gh api "repos/$…"`, an endpoint built for a later `gh api`
# (tick-plan.sh's and finish-task.sh's shape, which the first pattern alone misses), `gh --repo "$…"`,
# the same call with the helper loaded, and a test file, which ships nothing and is out of scope.
FIX="$WORK/sweep-fixture"
git init -q "$FIX"
mkdir -p "$FIX/skills/x/scripts" "$FIX/skills/y/scripts" "$FIX/scripts" "$FIX/hooks" "$FIX/tests/z"
printf '%s\n' '#!/usr/bin/env bash' 'gh api "repos/$REPO/issues/1"' > "$FIX/skills/x/scripts/bad.sh"
printf '%s\n' '#!/usr/bin/env bash' 'endpoint="repos/$REPO/issues/1"' 'gh api "$endpoint"' \
  > "$FIX/scripts/endpoint.sh"
printf '%s\n' '#!/usr/bin/env bash' 'gh pr view 1 --repo "$REPO"' > "$FIX/hooks/hook.sh"
printf '%s\n' '#!/usr/bin/env bash' '. "$HERE/../../_shared/scripts/_gh-host.sh"' \
  'gh issue view 1 -R "$REPO"' > "$FIX/skills/y/scripts/good.sh"
printf '%s\n' '#!/usr/bin/env bash' 'gh api "repos/$REPO/x"' > "$FIX/tests/z/test.sh"
git -C "$FIX" add -A
RC=0
sweep "$FIX" > "$WORK/out.sweep-fixture" 2>&1 || RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL [sweep-fixture]: exit $RC, want 1"; cat "$WORK/out.sweep-fixture"; exit 1; }
for want in skills/x/scripts/bad.sh scripts/endpoint.sh hooks/hook.sh; do
  grep -Fx -- "$want" "$WORK/out.sweep-fixture" > /dev/null \
    || { echo "FAIL [sweep-fixture]: $want was not reported"; cat "$WORK/out.sweep-fixture"; exit 1; }
done
for spared in skills/y/scripts/good.sh tests/z/test.sh; do
  if grep -Fx -- "$spared" "$WORK/out.sweep-fixture" > /dev/null; then
    echo "FAIL [sweep-fixture]: $spared was reported"; cat "$WORK/out.sweep-fixture"; exit 1
  fi
done
echo "  ok: sweep-fixture — the three bare-slug shapes reported, the helper-loading script and the test spared"

RC=0
sweep "$KIT_ROOT" > "$WORK/out.sweep-tree" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || {
  echo "FAIL [sweep-tree]: these shipped scripts address a repository by slug without loading"
  echo "  skills/_shared/scripts/_gh-host.sh — on a GitHub Enterprise repository they reach github.com:"
  sed 's/^/  | /' "$WORK/out.sweep-tree"
  exit 1
}
echo "  ok: sweep-tree — every shipped script that addresses a repository by slug loads the helper"

echo "gh-host golden test OK"
