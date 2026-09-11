## Step 7 — Assemble the description, choose labels, and create the issue

Stitch one description and file it in a single `gh issue create`. Because the plan exists, you know the
effort too — **all** labels go on at creation.

**Assemble the body** top (most-read) to bottom, into one temp file:

1. The template fields from Step 4 (Problem / Proposed solution / Area …) — visible.
2. The `**Related:** #N, #M` line from Step 3, if any — plus every ADR id Step 5's check
   cited, written `ADR-N` alongside the issue numbers.
3. The collapsible 🧠 **Brainstorm** and 📋 **Spec** from Step 5 — the Spec carries its
   `### Acceptance criteria` / `### Testing decisions` / `### Out of scope` contract.
4. The 🛠️ **Implementation plan** from Step 6 — **visible, never inside a `<details>`**.

**Verify the plan survived** before filing — zero checkboxes means it got mangled; reformat into the
Step 6 task/checkbox structure. Also verify the Spec's contract survived — exactly one
`### Acceptance criteria` heading, since a mangled `<details>` block can silently swallow it same as
the checkboxes:

```bash
grep -c '^- \[ \]' /tmp/issue-<slug>.md               # must be > 0; expect one per actionable step
grep -c '^### Acceptance criteria' /tmp/issue-<slug>.md   # must be exactly 1
```

**Choose labels.** The taxonomy (exact strings, priority tiers and meanings, effort sizes, scope) lives
in the profile's *Labels* section. Read the **live** set first (labels drift):

```bash
gh label list --limit 100
```

Pick one label per axis (none are guesses — your analysis already implies them):

- **Type** — feature/idea for the common case (what feature_request declares), or bug for a defect; match the template you built from.
- **Priority** — exactly one tier (the judgment your brainstorm's Recommendation makes).
- **Effort** — exactly one size, the one you settled on in Step 6.
- **Area** — **exactly one** area label, when the profile's *Labels* section defines an area axis.
  This is the queryable functional-area tag, so a whole area is one filter away
  (`gh issue list --label "<area label>"`); the scope you'd derive for the PR-title prefix usually
  names the area outright.
- **Sub-area** — *only when the profile defines a sub-namespace under the chosen area*, add **one**
  sub-label too — that's what makes a single feature findable. If the work is a genuinely new
  sub-area with no fitting label, `gh label create "<namespace>: <slug>" --color c5def5
  --description "…"` first, then apply it — grow the taxonomy rather than collapsing to the parent
  area alone.

Decide, note the call in the report, don't open a triage Q&A. Create with every axis the profile
defines:

```bash
gh issue create \
  --title "Add CSV export" \
  --label "<type>" \
  --label "<priority tier>" \
  --label "<effort size>" \
  --label "<area>" \
  --body-file /tmp/issue-<slug>.md
```

Capture the printed URL and number. If a chosen label isn't in the live list, create without it rather
than failing, and flag the gap.

**Read it back.** The pre-create `grep` proved your *local* file; this proves *GitHub* stored it (a
malformed `<details>`, an oversized field, or a `--body-file` that didn't carry everything can leave a
broken issue that looks fine in the terminal):

```bash
NUM=<issue-number>
filed=$(grep -c '^- \[ \]' /tmp/issue-<slug>.md)
live=$(gh issue view "$NUM" --json body --jq .body | grep -c '^- \[ \]')
echo "checkboxes — filed $filed / live $live"          # must be equal and > 0
gh issue view "$NUM" --json labels --jq '.labels[].name'   # confirm every intended label applied
```

If `live` ≠ `filed` (or zero), the body didn't round-trip — repair and push with
`gh issue edit "$NUM" --body-file …`, **guarded by `[ -s /tmp/issue-<slug>.md ]` first**: that flag
overwrites the whole body, so handing it an empty or truncated file destroys the issue exactly the
way `implement-issue`'s checkbox PATCH once did. If a label is missing, re-add (`gh issue edit "$NUM"
--add-label …`) or flag it. Move on only once the readback is clean.

### The decomposed variant — parent first, children in dependency order, then wire the edges

When Step 6 took the decompose branch, one `gh issue create` becomes **1 + N** of them plus one
wiring call. The labels are the parent's on every issue **except effort**: the parent carries the
largest size (it is the whole job), each child its own small or medium.

```bash
# 1. The parent — the tracking body, ZERO checkboxes. Prove it before filing: the same tokens
#    survey.sh reads, so a parent that trips this would be dispatched as if it were a plan.
[ "$(grep -cE 'Implementation plan|### Task|- \[ \]' /tmp/issue-<slug>.md || true)" -eq 0 ] \
  || { echo "REFUSED — the parent body carries a plan token"; exit 1; }
[ "$(grep -c '^## Destination' /tmp/issue-<slug>.md || true)" -eq 1 ] \
  || { echo "REFUSED — the parent body has no ## Destination"; exit 1; }
P=$(gh issue create --title "<parent title>" --label "<type>" --label "<priority>" \
      --label "effort: large" --label "<area>" --body-file /tmp/issue-<slug>.md | grep -oE '[0-9]+$')

# 2. The children, BLOCKERS FIRST — every child with no blockers, then every child whose blockers
#    are all filed — so each body's `Part of #P` and `**Blocked by:**` line names real numbers.
#    Fill the placeholders in the child file, verify the plan survived, file, capture the number.
sed "s/#<parent>/#$P/g" /tmp/issue-<slug>-child-1.tmpl > /tmp/issue-<slug>-child-1.md   # and each blocker's #<n>; no `sed -i` (its -i differs between GNU and BSD)
[ "$(grep -c '^- \[ \]' /tmp/issue-<slug>-child-1.md || true)" -gt 0 ] \
  || { echo "REFUSED — child 1's plan has no checkboxes"; exit 1; }
[ "$(grep -c '^### Acceptance criteria' /tmp/issue-<slug>-child-1.md || true)" -eq 1 ] \
  || { echo "REFUSED — child 1's Spec contract did not survive"; exit 1; }
C1=$(gh issue create --title "<child 1 title>" --label "<type>" --label "<priority>" \
      --label "effort: small" --label "<area>" --body-file /tmp/issue-<slug>-child-1.md | grep -oE '[0-9]+$')
# … C2, C3 in the same order; a child blocked by C1 is filed after C1 so it can name #$C1.

# 3. The second pass — sub-issue links and native blocked_by edges, one call for the whole set.
#    `fallback` on a line means that endpoint answered 404 (feature off on this host): the text
#    `**Blocked by:**` line in the body stands and Step 8 says so. Exit 1 is a real API failure.
#    Redirect, don't `tee`: through a pipe the exit code you read would be tee's.
skills/create-issue/scripts/wire-edges.sh --repo {owner}/{repo} --parent "$P" \
  --child "$C1" --child "$C2:blocked-by=$C1" --child "$C3:blocked-by=$C1,$C2" > /tmp/issue-<slug>-edges.txt
rc=$?; cat /tmp/issue-<slug>-edges.txt; echo "wire-edges exit $rc"     # 0 = ok/fallback; 1 = a real API failure
```

`wire-edges.sh` resolves database ids itself (`gh api repos/o/r/issues/<n> --jq .id` — never the
number, never the node id), is idempotent (an edge that already exists is `ok`), and takes `--dry-run`
to print the POSTs without sending them. Its contract and exit codes are in its header
(`--help`) and pinned by `tests/wire-edges/test.sh`.

**Read it all back.** The parent's checkbox count is the invariant, the children's the proof each
plan round-tripped, the summary the proof the edges exist where GitHub reads them:

```bash
live=$(gh issue view "$P" --json body --jq .body | grep -cE 'Implementation plan|### Task|- \[ \]' || true)
[ "$live" -eq 0 ] || { echo "PARENT #$P carries a plan token — repair before anything else"; exit 1; }
for c in "$C1" "$C2" "$C3"; do
  n=$(gh issue view "$c" --json body --jq .body | grep -c '^- \[ \]' || true)
  head=$(gh issue view "$c" --json body --jq .body | head -2 | grep -cE "^Part of #$P|^\*\*Blocked by:\*\*" || true)
  blocked=$(gh api "repos/{owner}/{repo}/issues/$c" --jq '.issue_dependencies_summary.blocked_by // "n/a"')
  echo "#$c checkboxes=$n header-lines=$head blocked_by=$blocked"    # n > 0, head = 2, blocked_by = its open-blocker count
done
```

A parent whose `live` is not `0` is repaired the way any body is (`gh issue edit "$P" --body-file …`,
guarded by `[ -s ]`), and nothing else proceeds until it reads `0`. A `blocked_by` of `n/a` on every
child with the edges file saying `fallback` is the documented degraded state, not a failure.

### The `--seed #N` variant — edit in place, never create

Same body, one destination change: it goes onto the **existing** issue with `gh issue edit`, and no
issue is created. The assembly order puts the original first because it is the part the author wrote:

1. **The original body, verbatim** — byte for byte as Step 2 fetched it, no reflow, no correction.
2. A `---` horizontal rule. Everything above it is theirs; everything below it is the seeder's work.
3. The `**Related:** #N, #M` line from Step 3, if any, and the synthesized template fields from Step 4, if any.
4. The collapsible 🧠 **Brainstorm** and 📋 **Spec** from Step 5.
5. The 🛠️ **Implementation plan** from Step 6 — visible, never inside a `<details>`.

Write items 3-5 — everything that goes *below* the rule — into `/tmp/seed-trail-$N.md` first; the
original comes straight back out of the JSON Step 2 already fetched, so it can never be retyped:

Every check below is a **condition**, not a printout. On the create path a slipped gate produces a
junk new issue; here the very next command replaces text somebody else wrote, so a gate that only
prints its verdict is a gate that does nothing at the one moment it matters:

```bash
# The trail is checked BEFORE the assembly. If it is missing or empty, the brace group still emits
# the original body plus a bare `---` — non-empty, so `[ -s ]` on the RESULT would pass, and the
# edit would replace the author's issue with their own text and nothing else.
[ -s /tmp/seed-trail-$N.md ] || { echo "REFUSED — no trail to append; #$N untouched"; exit 1; }

# Count the CONTRACT in the trail, not in the assembled file: a well-written issue may already
# carry an `### Acceptance criteria` heading of its own, and counting the assembly would then read
# 2 and send you off to "reformat" — which on this path means editing the author's text, the one
# thing the seed contract forbids.
[ "$(grep -c '^- \[ \]' /tmp/seed-trail-$N.md || true)" -gt 0 ] \
  || { echo "REFUSED — the plan has no checkboxes; it got mangled"; exit 1; }
[ "$(grep -c '^### Acceptance criteria' /tmp/seed-trail-$N.md || true)" -eq 1 ] \
  || { echo "REFUSED — the Spec contract did not survive assembly"; exit 1; }

{ jq -r '.body // ""' /tmp/issue-seed-$N.json; printf '\n\n---\n\n'; cat /tmp/seed-trail-$N.md; } \
  > /tmp/issue-seed-$N.md

# `--body-file` REPLACES the whole body, so an empty or truncated file DESTROYS someone else's
# issue — the same wipe `implement-issue`'s checkbox PATCH once caused, except the text lost here
# was written by somebody who is not in this conversation. The `[ -s ]` test is the guard, and it
# is load-bearing, not decoration.
[ -s /tmp/issue-seed-$N.md ] || { echo "REFUSED — assembled body is empty; #$N untouched"; exit 1; }
gh issue edit "$N" --body-file /tmp/issue-seed-$N.md
```

**Labels: complete the axes, replace nothing.** Read what the issue already carries and `--add-label`
only the axes that are **absent**. A `priority: low` you disagree with stays `priority: low` — the
owner set it, and re-triaging someone's issue is `triage-backlog`'s job, not the seeder's. The type
axis is usually already there (the form applied it); **effort** and **area** usually are not, and
effort you now genuinely know, because you just wrote the plan:

```bash
gh issue view "$N" --json labels --jq '.labels[].name'      # what it already carries
gh issue edit "$N" --add-label "effort: medium" --add-label "area: create-issue"   # ABSENT axes only
```

Never pass `--remove-label` on this path, and never re-apply an axis that is already present under a
different value — that is a replacement wearing an addition's clothes.

**Read it back** — the same proof a create gets, plus one a create never needs, because this path
edits a body it did not author:

```bash
gh issue view "$N" --json body --jq .body > /tmp/seed-live-$N.md
jq -r '.body // ""' /tmp/issue-seed-$N.json  > /tmp/seed-orig-$N.md

# `|| true` on BOTH: `grep -c` exits 1 when it counts none, and `live` being 0 is precisely the
# wipe this readback exists to catch — without it a `set -e` shell aborts here and the label, title
# and verbatim checks below never run, in exactly the case they were written for.
filed=$(grep -c '^- \[ \]' /tmp/issue-seed-$N.md || true)
live=$(grep  -c '^- \[ \]' /tmp/seed-live-$N.md  || true)
echo "checkboxes — filed $filed / live $live"               # must be equal and > 0
gh issue view "$N" --json labels --jq '.labels[].name'      # every intended axis present
gh issue view "$N" --json title --jq .title                 # UNCHANGED from Step 2's fetch

# The original text is still the head of the body, byte for byte. `wc -c < file` with the redirect
# (never `… | wc -c`) and `tr -d ' '`, the same spelling implement-issue's tick-plan.sh uses: BSD
# `wc` reading a PIPE right-aligns its count in an 8-character field, so a piped count would splice
# spaces into the command below, break it, and produce an empty comparison — read as "the original
# was rewritten", whose documented remedy is to restore, i.e. to delete the plan just written.
orig_bytes=$(wc -c < /tmp/seed-orig-$N.md | tr -d ' ')
head -c "$orig_bytes" /tmp/seed-live-$N.md | diff - /tmp/seed-orig-$N.md
```

That `diff` is the one that matters. If it reports anything, you rewrote someone's issue: restore the
original (`[ -s /tmp/seed-orig-$N.md ]`, then `gh issue edit "$N" --body-file /tmp/seed-orig-$N.md`)
and say so, rather than leaving the edit standing.

**`--seed #N` on the decompose branch — #N becomes the parent, if its own text allows it.** The
invariant is over the **whole** body, and the original above the `---` rule is text you may not
edit — so check it first:

```bash
jq -r '.body // ""' /tmp/issue-seed-$N.json | grep -cE 'Implementation plan|### Task|- \[ \]' || true
```

- **Non-zero** — the original already carries a plan token (a `--force` re-seed, or a rescoped root
  that kept its old plan). It **cannot** become a tracking parent: seeding the tracking sections
  under it leaves `plan=true` and the parent gets dispatched whole. Refuse the in-place parent, file
  a **fresh** parent through the decomposed variant with `**Related:** #N` and #N cited under its
  *Decisions so far*, and report it (`triage-backlog`'s rescope then closes #N as folded into the
  parent).
- **Zero** — proceed in place. The trail is then the 🧠 Brainstorm, the 📋 Spec and the tracking
  sections (`## Destination` … `## Out of scope`) — no plan — so the two trail gates above
  **invert**: the trail must count **`0`** `- [ ]` lines and **exactly one** `^## Destination`. The
  readback replaces the checkbox count with the three-token grep over the **full live body**, which
  must print `0` (plus the same `diff` on the original text). Then file the children and wire the
  edges exactly as in the decomposed variant, with `P=$N`.

Labels on this path: the parent must carry the **largest** effort size, because the tier check is the
second guard that keeps it out of `QUEUE` even if a later edit trips the token invariant. This is the
**one** sanctioned replacement on the seed path: an `effort: small`/`medium` on #N is swapped for
`effort: large` (`--remove-label` then `--add-label`), and the report says so by name.
