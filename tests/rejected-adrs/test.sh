#!/usr/bin/env bash
# Golden test for skills/triage-backlog/scripts/rejected-adrs.sh — the grep half of the
# prior-rejection lookup (#319).
#
# Why a golden test for a FALLBACK. The helper only ever runs on the path where the good answer is
# already unavailable: AdrMcp is not connected, so `search_adrs` cannot be asked whether this idea
# has been declined before, and a keyword scan of `docs/adr/` is all that is left. That is exactly
# the path nobody exercises by hand — the maintainer runs with the server connected — so a defect
# in it would surface only in the situation where nothing else is watching. And it would surface as
# SILENCE: a lookup that finds nothing and a lookup that never looked print the same thing, which
# is the failure #319 exists to close, one level down. An idea gets re-filed, re-brainstormed,
# re-triaged and re-declined, and every pass costs the owner a triage row.
#
# So the suite asserts the RENDERED ROWS over a fixture tree — the bytes a skill reads — and the
# exit code beside them, never the internals. In particular it does NOT pin the stopword list: that
# list is an implementation detail the helper is free to grow, and a suite that froze it would
# redden on every improvement while still proving nothing about what a caller sees. What it does
# pin about stopwords is the only part that is contractual: a stopword must not COUNT toward the
# two shared words a hit requires (case 6).
#
# The two failure codes are asserted separately and on purpose. This repository draws a hard line
# between "I looked and found nothing" (exit 1 — the root was read, no rejected ADR matched) and
# "no verdict was possible" (exit 2 — the root is absent, unreadable, or the invocation was wrong).
# Collapsing them is how a lookup pointed at the wrong directory reports a clean bill of health
# forever: the caller sees 1, says "0 hits", and files the issue that was declined last month.
# Cases 8, 9, 10 and 11 are that line, driven from both sides.
#
# The fixtures carry the REAL section shape — `## Context and Problem Statement`, `## Considered
# Options`, `## Decision Outcome`, `## Consequences`, `## Prior requests`, all at h2 — because that
# is what AdrMcp renders into docs/adr/ and what the migrated rejections use. A suite that invented
# a tidier shape would pass over documents the helper will never actually meet.
#
# What this suite guards:
#   1.  a mixed tree: two rejected, one accepted, one malformed   -> `list` prints EXACTLY the two
#   2.  the malformed file carries a literal `status: rejected`
#       line in its BODY                                          -> still not a row (a naive
#                                                                    `grep -l` fallback would have
#                                                                    claimed it)
#   3.  the exact rendered row of one fixture, TABs and the
#       prior-request count included                              -> byte-for-byte
#   4.  match "hypothesis tree exploration"                       -> the idea-tree ADR ONLY, exit 0
#       Two things at once, and both are the point. The rejected ADR's TITLE shares only one word
#       with that query — the other two live in its Prior requests bullets, which is where the
#       vocabulary a request arrived in is recorded, and the whole reason a keyword fallback can
#       match a concept under new words at all. Meanwhile the ACCEPTED fixture shares all three
#       query words and is still not returned.
#   5.  match "hypothesis" — one content word                     -> exit 1 (the >= 2 rule)
#   6.  match "the of and tree" — three stopwords and one word    -> exit 1 (stopwords are stripped
#                                                                    from BOTH sides, never counted)
#   7.  match "zzz"                                               -> exit 1, nothing on stdout
#   8.  `list` over an existing but EMPTY root                    -> exit 1, never 2: the root was
#                                                                    read and held nothing
#   9.  --root /nonexistent, for `list` AND for `match`           -> exit 2, never 1 and never 0
#  10.  --root pointing at a regular FILE                         -> exit 2
#  11.  mis-invocations: unknown subcommand, `match` with no
#       query, unknown flag, an extra argument, no verb           -> exit 2, NEVER 0
#  12.  the helper never writes: a checksum snapshot of the
#       fixture tree before and after a list+match run            -> unchanged
#  13.  a rejected ADR with ZERO prior-request bullets            -> count 0, in BOTH spellings
#       (the heading present but empty, and no heading at all) — rendered, never skipped
#  14.  no --root at all                                          -> `docs/adr` relative to the
#                                                                    working directory
#  15.  prior requests that are NOT `#N`-shaped                   -> counted, and their words
#                                                                    searched
#  16.  a prior request WRAPPED over three lines                  -> counts ONCE, and every one of
#                                                                    its lines is searched
#
# Case 16 is the shape the kit's own migrated rejections have, and the two halves pull opposite
# ways: count the continuation lines and one request reads as three; skip their words and
# `match "hypothesis tree exploration"` stops finding `Idea-tree search`, whose title shares only
# the word "tree" with that query. The first draft of this helper counted and searched the same
# lines, and AC5 failed against the real docs/adr/ — which is how this case got here.
#
# Case 15 is not a curiosity: it is the shape the migrated rejections use. A concept can be
# declined years before anyone opens an issue for it — the three Arbor non-adoptions cite a review
# directory, not an issue number — and a counter that only recognised `- #N` would report those
# ADRs as having zero prior requests AND contribute none of their words to `match`, which is the
# half of the lookup that does the actual work.
#
# Case 12 is the one that is easy to lose. The helper is a READER on a path where the writer half
# (triage-backlog Step 7, through AdrMcp) has refused to run: a fallback that quietly normalised,
# reformatted or touched an ADR would be mutating the decision record precisely when the tool that
# validates it is absent. Snapshotting the tree is cheap; discovering that by hand is not.
#
# Case 2 is the reason this helper is not one line of grep. `grep -l '^status: rejected' *.md`
# matches any file with that text anywhere in it — a rejected ADR quoted inside a design ADR, a
# template, a body paragraph — and every false row it returns is an idea wrongly reported as
# already declined, which is worse than no lookup at all: it suppresses a legitimate issue.
#
# Case 14 exists because the default is the whole ergonomics of the thing. Every caller in the kit
# runs from the repository root and passes no --root; if the default drifted, every one of them
# would take the exit-2 path and report "prior-rejection lookup unavailable" forever, which reads
# as a degraded environment rather than as a bug in this file.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
HELPER="$KIT/skills/triage-backlog/scripts/rejected-adrs.sh"

[ -x "$HELPER" ] || {
  echo "FAIL: $HELPER is missing or not executable — the suite has nothing to drive"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# kit_guard_samples_unchanged NOT registered, deliberately: this suite never reads or writes
# samples/ — it builds its ADR trees from scratch under kit_scratch and the helper under test is
# read-only by contract (case 12 proves it). Said explicitly so "decided it does not apply" cannot
# be mistaken for "forgot to call it" (tests/_lib.sh).

OUT="$(kit_scratch)/out.txt"
ERR="$(kit_scratch)/err.txt"
TAB=$(printf '\t')

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

RC=0
run_helper() {
  RC=0
  "$HELPER" "$@" > "$OUT" 2> "$ERR" || RC=$?
}

show() {
  printf '          --- stdout (tabs shown as |) ---\n'
  tr '\t' '|' < "$OUT" | sed 's/^/          /'
  printf '          --- stderr ---\n'
  sed 's/^/          /' "$ERR"
}

# expect_rc <want> <label> [args…] — the code, and nothing else. Used where the OUTPUT is asserted
# separately, or where there is deliberately none.
expect_rc() {
  local want="$1" label="$2"
  shift 2
  run_helper "$@"
  if [ "$RC" -eq "$want" ]; then
    ok "$label"
  else
    bad "$label — expected exit $want, got $RC"
    show
  fi
}

# expect_rows <want-rc> <label> <expected-stdout> [args…] — the code AND the bytes. Both halves
# matter: an exit code alone passes on a helper that returned the wrong rows for the right reason,
# and rows alone pass on one that cannot tell a hit from a plumbing failure.
expect_rows() {
  local want="$1" label="$2" expected="$3" got
  shift 3
  run_helper "$@"
  got=$(cat "$OUT")
  if [ "$RC" -ne "$want" ]; then
    bad "$label — expected exit $want, got $RC"
    show
    return
  fi
  if [ "$got" = "$expected" ]; then
    ok "$label"
  else
    bad "$label — stdout is not what the contract says (tabs shown as |)"
    printf '          --- want ---\n'
    printf '%s\n' "$expected" | tr '\t' '|' | sed 's/^/          /'
    printf '          --- got ---\n'
    tr '\t' '|' < "$OUT" | sed 's/^/          /'
    printf '          --- stderr ---\n'
    sed 's/^/          /' "$ERR"
  fi
}

# ------------------------------------------------------------------------------- the fixture tree
#
# Four files, one of each shape the helper has to tell apart, written INLINE rather than committed
# under a fixtures/ directory: the whole suite is four short documents, and a reader who has to
# open another file to learn what "the accepted one" contains cannot check case 4 at all.
#
# Each case that mutates anything gets its OWN copy, so no case can inherit another one's damage.
fixture_root() {
  local d
  d="$(kit_scratch)/adr"
  mkdir -p "$d"

  # REJECTED, two prior requests, one of them NOT `#N`-shaped (case 15). The title deliberately
  # shares only ONE word with case 4's query — the other two live in the bullets, which is the
  # arrangement the real migrated rejections have and the one that decides whether this fallback
  # can find a concept under new words.
  cat > "$d/0001-idea-tree-search.md" <<'ADR'
---
id: 1
title: Idea-tree search
status: rejected
date: 2026-08-31
tags:
- out-of-scope
---

# Idea-tree search

## Context and Problem Statement

A branching search over competing directions, re-asked under a new name about twice a year.

## Considered Options

* Adopt it.
* Decline it, and record why.

## Decision Outcome

Not pursued by decision (2026-08-31): the kit optimises no open metric, so a search over
competing directions has nothing to score against.

## Consequences

Reopen only if the kit starts optimising an open metric.

## Prior requests

- reviews/2026-07-23-jobs/ — multi-hypothesis exploration over an open space (2026-07-23)
- #177 — Multi-branch exploration for the assessment phase (2026-06-18)
ADR

  # REJECTED, and its Prior requests section is EMPTY. Case 13: a concept declined once, before
  # anybody thought to list the request, still has to be findable — a helper that skipped it would
  # hide the very first rejection of every concept.
  cat > "$d/0002-interaction-modes.md" <<'ADR'
---
id: 2
title: Interaction modes as a configuration surface
status: rejected
date: 2026-08-31
tags:
- out-of-scope
---

# Interaction modes as a configuration surface

## Context and Problem Statement

A configuration key selecting how much the skills ask before acting.

## Decision Outcome

Not pursued by decision (2026-08-31): the confirmation grammar is per skill and documented,
not a global dial.

## Consequences

Reopen if a second consumer repository needs a different grammar.

## Prior requests
ADR

  # ACCEPTED, and it shares EVERY word of case 4's query. If the status filter regressed, this file
  # is what would show up — which is why it is worded this way rather than as a neutral fixture.
  cat > "$d/0003-hypothesis-tree-exploration.md" <<'ADR'
---
id: 3
title: Hypothesis tree exploration is the default
status: accepted
date: 2026-08-31
tags:
- kit
---

# Hypothesis tree exploration is the default

## Context and Problem Statement

Pinned by tests/rejected-adrs/test.sh case 4.

## Decision Outcome

Accepted, so it is not a prior rejection and must never be returned as one.

## Consequences

None.

## Prior requests

- #204 — Hypothesis tree exploration (2026-05-02)
ADR

  # MALFORMED: no frontmatter at all, and a literal `status: rejected` line in the BODY. This is
  # what a one-line `grep -l` fallback would have claimed as a rejection.
  cat > "$d/0004-a-file-with-no-frontmatter.md" <<'ADR'
# A file with no frontmatter

Prose that quotes the wire vocabulary verbatim:

status: rejected

…which is text, not frontmatter. A reader that keys on the line rather than on the block
would report this file as a prior rejection and suppress a legitimate issue.

## Prior requests

- #999 — Never counted, because this file is not an ADR (2026-08-31)
ADR

  printf '%s\n' "$d"
}

# A checksum listing of a whole tree: the path list AND the bytes. Either half alone is blind —
# checksums miss a file that was created or removed, and a path list misses one that was rewritten
# in place, which is precisely what a "helpful" normalisation would do.
snapshot() {
  ( cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} \; | LC_ALL=C sort )
}

# ------------------------------------------------------------------ 1-3. list over a mixed tree

root=$(fixture_root)

expect_rows 0 "list — exactly the two rejected ADRs, in id order" \
  "0001${TAB}Idea-tree search${TAB}2
0002${TAB}Interaction modes as a configuration surface${TAB}0" \
  --root "$root" list

# Cases 2, 13 and 15, read off the same run as case 1 rather than re-run: the assertion above
# already says the accepted file (0003) and the frontmatter-less one (0004) produced no row, that
# 0002 rendered `0` rather than vanishing, and that 0001 counted BOTH of its bullets — the
# `#177` one and the `reviews/…` one. Stated here so a reader looking for those case numbers finds
# them attached to the assertion that actually holds them.
if grep -q '0003' "$OUT" || grep -q '0004' "$OUT"; then
  bad "status-filter — an accepted ADR or a frontmatter-less file was reported as a rejection"
  show
else
  ok "status-filter — the accepted ADR and the body-text \`status: rejected\` are both excluded"
fi

# Case 3, stated on its own so the row FORMAT has a case of its very own: one file, one row, tabs
# and count included.
expect_rows 0 "row-format — id, title and prior-request count, TAB-separated" \
  "0001${TAB}Idea-tree search${TAB}2" \
  --root "$root" match "multi branch exploration"

# ------------------------------------------------------------------------------ 4. match by concept

expect_rows 0 "match-hit — the rejected ADR whose BULLETS carry the query words; the accepted one shares all three and is not returned" \
  "0001${TAB}Idea-tree search${TAB}2" \
  --root "$root" match "hypothesis tree exploration"

# ----------------------------------------------------------------------- 5-7. match, and no match

expect_rows 1 "match-one-word — a single shared content word is not a match (the >= 2 rule)" "" \
  --root "$root" match "hypothesis"

expect_rows 1 "match-stopwords — stopwords are stripped from both sides, never counted toward two" "" \
  --root "$root" match "the of and tree"

expect_rows 1 "match-miss — a query sharing nothing exits 1 with nothing on stdout" "" \
  --root "$root" match "zzz"

# ------------------------------------------------------- 8. an empty root is 1, not 2 and not 0
#
# The root WAS read; it holds no rejected ADR. That is an answer, and it is the same answer a real
# repository gives before its first close-by-decision — so it must not be spelled as the plumbing
# failure below, or every fresh repo would look misconfigured.
empty="$(kit_scratch)/empty-adr"
mkdir -p "$empty"
expect_rows 1 "empty-root — a readable root with no rejected ADRs exits 1: looked, found nothing" "" \
  --root "$empty" list

# ------------------------------------------------------------ 9-10. no verdict was possible (2)
#
# BOTH subcommands, because they fail differently in the obvious implementation: `match` already
# has an exit-1 path for "no hits" and is the one that would swallow an absent root into it.
expect_rc 2 "absent-root-list — a root that is not there is refused, never reported as empty" \
  --root /nonexistent/adr/root list
expect_rc 2 "absent-root-match — the same for match, which must not fold it into its no-hit path" \
  --root /nonexistent/adr/root match "hypothesis tree"

not_a_dir="$(kit_scratch)/not-a-directory"
: > "$not_a_dir"
expect_rc 2 "root-is-a-file — a regular file is not an ADR root; no verdict is possible" \
  --root "$not_a_dir" list

# ------------------------------------------------------------------------- 11. mis-invocations
#
# A helper that exits 0 on a typo'd subcommand prints exactly what a clean no-hit run prints, and
# the caller writes "prior-rejection lookup: 0 hits" into its recap. The dangerous answer here is
# not a bad message; it is any answer at all.
expect_rc 2 "usage-unknown-subcommand — a typo is a mis-invocation, not a lookup with no hits" \
  --root "$root" frobnicate
expect_rc 2 "usage-match-no-query — match with nothing to match refuses rather than matching all" \
  --root "$root" match
expect_rc 2 "usage-unknown-flag — an unrecognised flag is refused, never ignored" \
  --root "$root" --nope list
expect_rc 2 "usage-extra-argument — a stray unquoted query word is refused, not silently dropped" \
  --root "$root" match "hypothesis tree" exploration
expect_rc 2 "usage-no-subcommand — no verb at all is a mis-invocation" \
  --root "$root"

# --------------------------------------------------------------------------- 12. it never writes

root=$(fixture_root)
before=$(snapshot "$root")
run_helper --root "$root" list
run_helper --root "$root" match "hypothesis tree exploration"
run_helper --root "$root" match "zzz"
after=$(snapshot "$root")
if [ "$before" = "$after" ]; then
  ok "read-only — list and match leave the ADR tree byte-for-byte unchanged"
else
  bad "read-only — the helper modified the ADR tree; it is a READER on the path where the writer refused to run"
  printf '%s\n' "$before" > "$OUT"
  printf '%s\n' "$after"  > "$ERR"
  diff "$OUT" "$ERR" | sed 's/^/          /' || true
fi

# ------------------------------------------- 13. zero prior requests, in its other spelling too
#
# 0002 above covers "the heading is there and empty". This covers "there is no heading at all",
# which is what `create_adr` writes before the first request is ever appended. Both must render 0.
noheading="$(kit_scratch)/no-heading"
mkdir -p "$noheading"
cat > "$noheading/0007-novelty-search.md" <<'ADR'
---
id: 7
title: Novelty search over external paper feeds
status: rejected
date: 2026-08-31
tags:
- out-of-scope
---

# Novelty search over external paper feeds

## Context and Problem Statement

Ranking incoming ideas by how unlike the existing backlog they are.

## Decision Outcome

Not pursued by decision (2026-08-31): novelty is not a goal of the kit.

## Consequences

Reopen only if the kit starts optimising an open metric.
ADR
expect_rows 0 "no-prior-requests-section — an ADR that never got the heading still renders count 0" \
  "0007${TAB}Novelty search over external paper feeds${TAB}0" \
  --root "$noheading" list

# --------------------------------------------- 15. prior requests that predate any issue number
#
# The migrated Arbor non-adoptions cite `reviews/2026-07-23-jobs/`, not an issue. Both bullets here
# are of that shape, so the count is 2 only if ANY bullet counts — and the match below finds the
# ADR through words that appear NOWHERE but in those bullets, which is the half of the lookup that
# a `- #N` filter would silently switch off.
predates="$(kit_scratch)/predates-issues"
mkdir -p "$predates"
cat > "$predates/0009-novelty-search.md" <<'ADR'
---
id: 9
title: Novelty search
status: rejected
date: 2026-08-31
tags:
- out-of-scope
---

# Novelty search

## Context and Problem Statement

Ranking incoming ideas by how unlike the existing backlog they are.

## Decision Outcome

Not pursued by decision (2026-08-31): novelty is not a goal of the kit.

## Consequences

Reopen only if the kit starts optimising an open metric.

## Prior requests

- reviews/2026-07-23-jobs/ — alphaXiv paper feed as an idea inlet (2026-07-23)
- docs/backlog.md §Non-adoptions — surprise ranking over the backlog (2026-07-23)
ADR
expect_rows 0 "any-bullet-counts — prior requests that predate issue numbers are counted, not ignored" \
  "0009${TAB}Novelty search${TAB}2" \
  --root "$predates" list
expect_rows 0 "any-bullet-searched — words living only in those bullets still find the ADR" \
  "0009${TAB}Novelty search${TAB}2" \
  --root "$predates" match "alphaxiv paper feed"

# --------------------------------------------------- 16. a prior request that WRAPS across lines
#
# The shape the kit's own migrated rejections actually have: one bullet, three lines, and most of
# the concept vocabulary sitting on the continuations. Two halves, and they pull in opposite
# directions — the COUNT must stay 1 (a wrapped request is one request, not three) while the SEARCH
# must reach every line (dropping them makes `match "hypothesis tree exploration"` miss
# `Idea-tree search`, whose title shares only the word "tree"). A reader that treats the section
# uniformly gets one of the two wrong whichever way it chooses.
wrapped="$(kit_scratch)/wrapped-bullet"
mkdir -p "$wrapped"
cat > "$wrapped/0008-idea-tree-search.md" <<'ADR'
---
id: 8
title: Idea-tree search
status: rejected
date: 2026-07-23
tags:
- out-of-scope
---

# Idea-tree search

## Context and Problem Statement

Branching on approach, scoring, pruning, keeping the best.

## Decision Outcome

Not pursued by decision (2026-07-23): the kit executes a known path to a binary destination.

## Consequences

Reopen only if the kit starts optimising an open metric.

## Prior requests

- reviews/2026-07-23-jobs/ — multi-hypothesis tree search that branches candidate approaches
  and explores an open solution space, ported from Arbor (2026-07-23). Declined in
  docs/backlog.md until this ADR replaced it.
ADR
expect_rows 0 "wrapped-bullet-count — a request wrapped over three lines counts ONCE" \
  "0008${TAB}Idea-tree search${TAB}1" \
  --root "$wrapped" list
expect_rows 0 "wrapped-bullet-search — its continuation lines are searched, so the concept is reachable under new words" \
  "0008${TAB}Idea-tree search${TAB}1" \
  --root "$wrapped" match "hypothesis tree exploration"

# ------------------------------------------------------------------------------ 14. the default root
#
# Run from a directory that HAS docs/adr, with no --root. Every caller in the kit invokes it this
# way, so a drifted default would take the exit-2 path everywhere and read as a degraded
# environment rather than as a bug here. The cd is confined to a subshell: this suite runs from the
# kit root and must still be there afterwards.
home="$(kit_scratch)/consumer-repo"
mkdir -p "$home/docs"
cp -R "$root" "$home/docs/adr"
RC=0
( cd "$home" && "$HELPER" list ) > "$OUT" 2> "$ERR" || RC=$?
got=$(cat "$OUT")
if [ "$RC" -eq 0 ] && [ "$got" = "0001${TAB}Idea-tree search${TAB}2
0002${TAB}Interaction modes as a configuration surface${TAB}0" ]; then
  ok "default-root — with no --root the helper reads docs/adr under the working directory"
else
  bad "default-root — expected exit 0 and the two rejected rows, got exit $RC"
  show
fi

# ------------------------------------------------------------------------------------- verdict

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %d case(s) failed\n' "$fails"
  exit 1
fi
echo "OK tests/rejected-adrs — the fallback lookup reports rejected ADRs, refuses what it cannot judge, and writes nothing"
