#!/usr/bin/env bash
# rejected-adrs.sh — has this idea already been declined? The keyword half of the prior-rejection
# lookup, for the runs where the semantic half is unavailable. Reads; never writes.
#
#   rejected-adrs.sh [--root <dir>] list
#   rejected-adrs.sh [--root <dir>] match "<query>"
#
# Rows on stdout, TAB-separated, sorted by id ascending:
#
#   NNNN<TAB><title><TAB><prior-request count>
#
# Exit codes:
#   0  rows were printed — for `match`, at least one rejected ADR matched the query
#   1  I LOOKED AND FOUND NOTHING. The root was read and understood; it simply holds no rejected
#      ADR (`list`), or none that matches (`match`). This is an ANSWER.
#   2  NO VERDICT WAS POSSIBLE. The root is absent or is not a directory, a file under it could not
#      be read, or the invocation itself was wrong — an unknown subcommand, a missing query, an
#      unrecognised flag, a stray argument. Nothing was searched, so nothing may be concluded.
#
# ---------------------------------------------------------------------- why this file exists
#
# The kit has three inlets that file issues (`create-issue` Step 3, `merge-pr` 6c, the auto-dev
# workers' off-scope capture) and one outlet that declines them (`triage-backlog` Step 7, close by
# decision). Until #319 nothing connected the outlet back to the inlets: a close-by-decision wrote
# its reason into an issue comment and no skill ever read it again, so the same idea came back,
# was re-brainstormed, re-triaged and re-declined, at the cost of a triage row and the owner's
# attention every single time. #319 makes a rejection a durable, searchable record — an ADR with
# `status: rejected`, tagged `out-of-scope`, written and searched through AdrMcp.
#
# This script is what happens when AdrMcp is NOT connected. It is deliberately the weaker half, and
# saying so is part of its contract: `search_adrs` matches by CONCEPT — "night theme" finds
# `dark-mode` — and a word-overlap scan cannot do that. It will miss rejections whose vocabulary
# has moved on. Every caller therefore states which mode ran ("prior-rejection lookup: grep
# fallback (AdrMcp not connected)"), because a degraded answer reported as a full one is worse
# than no answer: it converts "we did not really look" into "there is no prior rejection".
#
# WHY EXIT 1 AND EXIT 2 ARE DIFFERENT CODES, and why the whole script is shaped around keeping them
# apart. Both of them print no rows. To a caller that only tests for zero-ness they are the same
# outcome, and the wrong one is silently absorbing: a lookup pointed at a directory that does not
# exist — a repo whose ADRs live somewhere else, a caller that did not cd to the repo root, a
# --root typo — would report "0 hits" forever, the inlet would file the issue, and the rejection
# that already answered it would sit unread on disk. That is the exact failure #319 exists to
# close, reintroduced one layer down and invisible, because a lookup that never looked prints
# precisely what a lookup that found nothing prints. So: the root not being there is a REFUSAL, not
# an empty result; a typo'd subcommand is a REFUSAL, not a lookup with no hits; and a root that
# genuinely holds no rejections is exit 1, because a repository before its first close-by-decision
# is a normal repository and must not read as a broken one.
#
# WHY IT IS NOT ONE LINE OF GREP. `grep -l "^status: rejected" docs/adr/*.md` matches that text
# ANYWHERE in a file — quoted inside a design ADR, sitting in a template, spelled out in a body
# paragraph explaining the wire vocabulary. Every false row it returns is an idea wrongly reported
# as already declined, and the caller's response to a hit is to SUPPRESS the issue. A lookup whose
# false positives silently swallow legitimate work is worse than no lookup, so `status` is read
# from the YAML frontmatter BLOCK — the file must open with `---` on line 1 and the key must sit at
# the top level of it — and never from a line of prose that happens to look like one.
#
# ------------------------------------------------------------------------------- what it reads
#
# Files directly under <root> named `NNNN-<anything>.md` (four or more leading digits, then a
# hyphen), whose frontmatter carries `status: rejected`. For each one:
#
#   * <title> is the frontmatter `title`. Absent, the level-1 `# ` heading; absent that, the
#     filename slug. A rejection is not allowed to become unreportable because the file was
#     hand-written on the very path where the tool that would have rendered it is missing — this
#     script runs precisely when AdrMcp is not there to have written the file.
#   * <prior-request count> is the number of `- ` bullets under the `## Prior requests` heading —
#     ANY bullet, not only `- #N — …` ones. A concept can be declined long before anyone opens an
#     issue for it: the kit's own migrated rejections cite `reviews/2026-07-23-jobs/`, and a
#     counter that recognised only issue numbers would report those as having no prior requests at
#     all.
#   * a file's WORD SET, which is what `match` compares against, is the title words plus every word
#     of that whole section — bullet lines AND the wrapped continuation lines beneath them, which
#     is where a real prior request keeps most of its text. (Counted and searched differently on
#     purpose: only a line that OPENS a bullet adds to the count, or a three-line request would
#     read as three.) That section is where the vocabulary each request ARRIVED IN is recorded, and
#     it is the only reason a keyword scan can find a concept under a name it was not filed under.
#     Stripping it would leave `match` comparing titles, which is a search that finds a rejection
#     only when the asker already knows what it is called — the kit's own `Idea-tree search`
#     rejection is not reachable from "hypothesis tree exploration" by its title alone.
#
# `match` reports a file when it shares AT LEAST TWO content words with the query, case-folded,
# with stopwords removed from both sides. Two, not one: a single shared word is how "test" matches
# everything. The stopword list below is not a contract — it may grow — but the rule that a
# stopword never COUNTS toward those two is, and tests/rejected-adrs/test.sh pins that rather than
# the list.
#
# Ported from mattpocock/skills (MIT), `engineering/triage/OUT-OF-SCOPE.md`, whose rejection store
# gives this its two jobs — institutional memory and deduplication — its one-file-per-CONCEPT rule,
# and its matching rule: matching is by concept, not keyword ("night theme" matches `dark-mode`).
# Credit belongs to Matt Pocock. The kit stores the concept as a MADR rejection under `docs/adr/`
# instead of a second folder, and this script is the honest, weaker stand-in for the semantic
# search that rule really asks for.
#
# ------------------------------------------------------------------------------- known limits
#
#   * Word overlap, not meaning. See above; the semantic path is the real one.
#   * The word scan folds to ASCII: `[^a-z0-9]` is the separator, so an accented or non-Latin word
#     is cut at the accent. The rejections this reads are English by convention (the migration of
#     `docs/backlog.md` §Non-adoptions translated them for exactly this reason).
#   * Only <root> itself is read, never subdirectories: an ADR root is flat, and recursing would
#     start reporting archived or vendored copies as live rejections.
#   * `## Prior requests` is matched at h2 and its section ends at the next h1 or h2, so a deeper
#     `### ` subheading inside it is treated as part of it.
#
# bash 3.2 compatible (macOS still ships it as /bin/bash): no associative arrays, no `${var,,}`,
# no `mapfile`, no process substitution. POSIX awk only — no `gensub`, no `asort`, no gawk
# extensions. Nothing beyond coreutils and awk; no python, no jq, no yq, and no git, so it works in
# a checkout the caller has not told it about. Driven by tests/rejected-adrs/test.sh.
set -euo pipefail

TOOL="rejected-adrs"

usage() {
  sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;s/^# \{0,1\}//;p;}' "$0"
}

# Every exit-2 path goes through here, so the code and the reason can never drift apart. The
# wording says "no verdict" rather than "error" on purpose: the caller is a skill deciding whether
# to file an issue, and it has to be able to tell this apart from an empty result.
refuse() {
  printf '%s: REFUSED — %s\n' "$TOOL" "$*" >&2
  printf '  No verdict was possible, so nothing may be concluded about prior rejections. This is\n' >&2
  printf '  NOT the same as finding none (exit 1): report the lookup as unavailable, not as clean.\n' >&2
  exit 2
}

ROOT="docs/adr"
MODE=""
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --root)
      [ $# -ge 2 ] || refuse "--root needs a directory"
      ROOT="$2"; shift 2 ;;
    --root=*)
      ROOT="${1#--root=}"
      [ -n "$ROOT" ] || refuse "--root needs a directory"
      shift ;;
    -*)
      refuse "unknown flag: $1 (expected --root <dir>, or -h)" ;;
    list|match)
      [ -z "$MODE" ] || refuse "two subcommands given ($MODE and $1); expected exactly one"
      MODE="$1"; shift
      if [ "$MODE" = match ]; then
        # A `match` with no query must NOT degrade into `list`. An empty query shares no content
        # word with anything, so a lenient reading would answer "no prior rejection" — the one
        # answer a caller acts on by filing the issue.
        [ $# -ge 1 ] || refuse "match needs a query: rejected-adrs.sh match \"<title and gist>\""
        # And a query that is really a FLAG is the same mis-invocation wearing the shape of an
        # answer. `match --root` would otherwise be read as the one-word query "--root", share no
        # content word with anything, and exit 1 — "I looked and found no prior rejection", which
        # is precisely the answer a caller acts on by filing the issue. Every other mis-invocation
        # in this file refuses; this one must too.
        case "$1" in
          -*) refuse "match's query looks like a flag ('$1'); flags go BEFORE the subcommand, as in: rejected-adrs.sh --root <dir> match \"<title and gist>\"" ;;
        esac
        QUERY="$1"; shift
      fi ;;
    *)
      if [ -n "$MODE" ]; then
        refuse "unexpected extra argument: $1 (quote the whole query as ONE argument)"
      fi
      refuse "unknown subcommand: $1 (expected 'list' or 'match')" ;;
  esac
done

[ -n "$MODE" ] || refuse "no subcommand given (expected 'list' or 'match')"

# Checked in two steps so the message names which of the two it is. "not there" and "there, but not
# a directory" send a reader to different places — a wrong --root versus a repo whose ADR root is a
# file — and one message covering both sends them to the wrong one half the time.
[ -e "$ROOT" ] || refuse "the ADR root '$ROOT' does not exist"
[ -d "$ROOT" ] || refuse "the ADR root '$ROOT' is not a directory"
# A root that exists and IS a directory can still be one this process cannot read into. Without
# these two the glob below expands to the literal pattern, every `[ -f ]` fails, and the run exits
# 1 — "I looked and found nothing" — for a root it never opened. That is the exit-1/exit-2 leak
# this whole script is shaped around, at the one level where the per-file `[ -r ]` refusal further
# down can never fire, because the loop it guards has no files to iterate.
[ -r "$ROOT" ] || refuse "the ADR root '$ROOT' is not readable — no verdict is possible over a directory this process cannot list"
[ -x "$ROOT" ] || refuse "the ADR root '$ROOT' is not searchable (no execute bit) — no verdict is possible over a directory this process cannot enter"

# ------------------------------------------------------------------------------- the row reader
#
# One pass per file, emitting at most one row. Written as a single-quoted string rather than a
# heredoc because a heredoc opened inside a `$( … )` is the construct bash 3.2 mis-scans (#131,
# scripts/parse-sweep.sh); as a plain argument there is no substitution to be inside of.
#
# The program contains NO apostrophe anywhere — not even in a comment — because it lives inside a
# single-quoted shell string, where one would end the string. The YAML single quote it has to
# recognise is therefore built as a character code (Q, below) instead of written literally.
ROW_AWK='
function norm(s,   t) {
  t = tolower(s)
  gsub(/[^a-z0-9]+/, " ", t)
  sub(/^ +/, "", t)
  sub(/ +$/, "", t)
  return t
}

# Fills out[] as a SET of content words. Returns how many it added. Both sides of the comparison go
# through this one function, so the query and the file can never be normalised differently — which
# is the way a word-overlap rule usually breaks: one side folded, the other not, and every match
# quietly stops happening.
function wordset(s, out,   n, arr, i, w, k) {
  n = split(norm(s), arr, " ")
  k = 0
  for (i = 1; i <= n; i++) {
    w = arr[i]
    if (w == "") continue
    if (length(w) < 2) continue
    if (w in STOP) continue
    if (w in out) continue
    out[w] = 1
    k++
  }
  return k
}

BEGIN {
  Q = sprintf("%c", 39)
  TABC = sprintf("%c", 9)
  split("a able about above after again against all almost also am an and any are as at be because been before being below between both but by can cannot could did do does doing done down during each either else few for from further had has have having he her here hers him his how i if in inside into is it its itself just may me might more most much must my no nor not now of off on once only onto or other others ought our ours out over own per same shall she should since so some such than that the their theirs them themselves then there these they this those through to too under until up upon us very was we were what when where whether which while who whom why will with within without would you your yours", SW, " ")
  for (i in SW) STOP[SW[i]] = 1
  # The query comes through the ENVIRONMENT, not through -v: awk expands escape sequences in a -v
  # value, so a query holding a backslash would arrive as something the user never typed.
  if (MODE == "match") wordset(ENVIRON["RA_QUERY"], QW)
}

# Trailing whitespace off every line, first, so a CRLF checkout does not make the frontmatter
# fences unrecognisable and silently drop every ADR in the tree.
{ sub(/[[:space:]]+$/, "") }

# Line 1 decides whether this file has frontmatter AT ALL. A file that does not open with the fence
# is not an ADR, however much of one it looks like further down — this is the rule that stops a
# body paragraph reading "status: rejected" from being claimed as a rejection.
NR == 1 { if ($0 == "---") INFM = 1; else BAD = 1; next }
BAD == 1 { next }

INFM == 1 {
  if ($0 == "---") { INFM = 0; FMSEEN = 1; next }
  # TOP-LEVEL keys only: the regex is anchored with no leading blank, so a nested `- out-of-scope`
  # under `tags:` cannot be read as a key, and a `status:` nested under some other mapping cannot
  # decide the file.
  if (match($0, /^[A-Za-z_][A-Za-z0-9_-]*[[:blank:]]*:/)) {
    key = substr($0, 1, RLENGTH)
    sub(/[[:blank:]]*:$/, "", key)
    key = tolower(key)
    val = substr($0, RLENGTH + 1)
    sub(/^[[:blank:]]+/, "", val)
    if (length(val) > 1) {
      a = substr(val, 1, 1)
      b = substr(val, length(val), 1)
      if ((a == "\"" && b == "\"") || (a == Q && b == Q)) val = substr(val, 2, length(val) - 2)
    }
    if (key == "status") STATUS = tolower(val)
    else if (key == "title") TITLE = val
  }
  next
}

FMSEEN == 1 {
  if ($0 ~ /^##?[[:blank:]]/) {
    h = $0
    sub(/^#+[[:blank:]]*/, "", h)
    if ($0 ~ /^#[[:blank:]]/ && H1 == "") H1 = h
    # Any other h1 or h2 ENDS the section. A deeper heading does not, which is why the test is on
    # this branch rather than on every line.
    INPR = (tolower(h) == "prior requests") ? 1 : 0
    next
  }
  if (INPR == 1) {
    # COUNT only the lines that OPEN a bullet, but SEARCH every line of the section. A prior
    # request is regularly three wrapped lines of prose naming the concept, and the kit s own
    # migrated rejections are exactly that shape: counting continuations would inflate the count,
    # and dropping their words would throw away most of the vocabulary the lookup runs on.
    if ($0 ~ /^[[:blank:]]*[-*+][[:blank:]]/) PRCOUNT++
    PRTEXT = PRTEXT " " $0
  }
}

END {
  if (BAD == 1) exit 0
  if (FMSEEN != 1) exit 0
  if (STATUS != "rejected") exit 0

  t = TITLE
  if (t == "") t = H1
  if (t == "") t = SLUG
  if (t == "") t = ID
  gsub(TABC, " ", t)

  if (MODE == "match") {
    wordset(t " " PRTEXT, FW)
    hits = 0
    for (w in QW) if (w in FW) hits++
    if (hits < 2) exit 0
  }

  printf "%s\t%s\t%d\n", ID, t, PRCOUNT
}
'

TAB=$(printf '\t')
rows=""

# Four leading digits then a hyphen: the ADR filename shape, so nothing else in the root — a
# README index, a template, a stray note — is ever opened as a decision. The extra `*` before the
# hyphen admits a five-digit id without admitting `notes-2026.md`.
for f in "$ROOT"/[0-9][0-9][0-9][0-9]*-*.md; do
  # An unmatched glob comes back as the literal pattern; this is also the guard against a matching
  # directory. bash 3.2 has no nullglob worth relying on here.
  [ -f "$f" ] || continue
  # Unreadable is a REFUSAL, never a skip. Skipping it would drop a rejection out of the answer
  # while still printing a confident row set — the silent half-answer this whole script is written
  # to avoid.
  [ -r "$f" ] || refuse "cannot read '$f' — a rejection may be there and unreadable"

  base=${f##*/}
  id=${base%%[!0-9]*}
  slug=${base%.md}
  slug=${slug#$id}
  slug=${slug#-}
  slug=$(printf '%s' "$slug" | tr '-' ' ')

  rc=0
  row=$(RA_QUERY="$QUERY" awk -v MODE="$MODE" -v ID="$id" -v SLUG="$slug" "$ROW_AWK" "$f") || rc=$?
  [ "$rc" -eq 0 ] || refuse "awk exited $rc while reading '$f'"
  [ -n "$row" ] || continue
  rows="$rows$row
"
done

if [ -z "$rows" ]; then
  # Exit 1, silently. The root was read and it holds no rejection this run is about — an answer,
  # and the normal one for a repository that has not yet declined anything. Anything printed here
  # would end up quoted in a triage recap as though it were a finding.
  exit 1
fi

# Numeric on the id column: the glob is only lexically sorted, which agrees with id order for
# zero-padded four-digit names and stops agreeing the moment a fifth digit appears.
printf '%s' "$rows" | LC_ALL=C sort -t"$TAB" -k1,1n
exit 0
