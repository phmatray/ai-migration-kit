# auto-dev — token economics (the why)

The actionable rules live in `SKILL.md` (§ Token economics). This file is the rationale +
measurement methodology — read it when tuning cost or explaining a run's economics, not every turn.

## The shape of the spend

A long auto-dev run is expensive in a specific, fixable way. Measured over a 120-merge run:
**~83% of all spend was context *cache* (re-reading each agent's context every turn), only ~16% was
generated output.** In an agentic loop you pay for *context volume × number of turns*, not for
thinking. That single fact drives all three levers.

## Lever 1 — tier the model (≈⅔ of the savings)

Cache-read tokens dominate, and they are ~5× cheaper on a mid model and ~15× cheaper on a small model
than on the top model. Most fleet work is *mechanical* — make one failing test pass, fix a guard,
regenerate a snapshot, edit docs — and doesn't need the top model. The failing-test-first + green-CI
gates in the child skills catch any miss a cheaper model makes, which is what makes cheap-by-default
safe. Reserve the top model for genuine reasoning (cross-cutting/ambiguous work) and for
**escalation**: re-dispatch once on the top model when a lower tier couldn't green it (Step 4).

The orchestrator stays on the top model — its dispatch/conflict reasoning is worth it — but its
*per-turn context* is what it pays to re-read every turn, so keep that small (lever 2).

## Lever 2 — shrink what's re-read every turn

- **No per-issue TaskList.** A task list grows unboundedly and is re-injected on *every* turn — pure
  cache-read waste multiplied by thousands of turns. The state file is the only working memory.
- **Compact deliberately, don't wait for 100% auto-compact.** Both cost and answer quality degrade
  well before the window is full. Compact *with a focus directive* so the summary keeps what's
  expensive to reconstruct. Continuity otherwise lives in the state file — so the first action after
  any compact / `/clear` / `loop` re-fire is to re-read it; that turns a reset into a clean base
  instead of amnesia.
- **Delegate heavy reads to throwaway `Explore` sub-agents.** When you must read widely to find a
  small answer, the sub-agent does the reading and returns only the conclusion, so the file-dump dies
  with it instead of riding in your re-read-every-turn context. (This is also why a symbol-retrieval
  MCP didn't pay off: it adds per-turn schema weight and extra round-trips — the opposite of this.)
- **Launch the supervisor session lean.** Every connected MCP server injects its tool schemas into
  *every* turn of *every* session — dead weight re-read thousands of times — and sub-agents inherit
  the supervisor's MCP set. Per-worker MCP stripping is no longer available (the Agent tool has no
  per-spawn MCP config), so connect only the servers actually used (usually none) where you launch
  the supervisor.

## Lever 3 — take fewer turns

Each tool round-trip is a turn, and every turn re-reads the whole context.
- **Batch independent tool calls** into one turn (this is why ripgrep beats per-symbol retrieval:
  many matches per call, fewer round-trips).
- **Let scripts collapse query+classify** — a script turns a multi-turn "query then reason" into one
  call.
- **Cache-TTL nuance:** the prompt cache has a ~5-min TTL, so a wake *past* it pays a full cache
  **write** (1.25× input), not a cheap read (0.1×). A needless short tick is pure cost; a wake after a
  long idle should batch all pending reconcile work to amortize the rewrite.

## Lever 4 — route work to the tier that priced it best

### Measured per-tier costs, including the top tier

Measured from a 19-merge run on bsca-dev/partners-api (2026-08-24), 37 worker sessions, via `scripts/usage_report.py`:

| Tier | Sessions | Tokens | $ list-equiv | $/Mtok |
|---|---|---|---|---|
| opus (top) | 4 | 78,844,117 | $187.23 | $2.376 |
| sonnet (mid) | 31 | 568,624,991 | $238.46 | $0.419 |
| haiku (small) | 2 | 9,012,921 | $1.51 | $0.168 |

**Derived cost ratios:** 5.7× (top:mid), 2.5× (mid:small), 14.1× (top:small).

Dollar figures are API list-price equivalents — on a subscription they map to rate-limit budget, not cash.

**Historical note:** An earlier record stated "≈2.7×" as the mid:small ratio but did not document the measurements it came from (the printed 2.395/2.145 figures do not derive that ratio). The ratio should be re-derived from a documented run rather than propagated without source.

## Session length — the cost centre the levers above do not bound

Levers 1–4 shrink what a *turn* costs and shave round-trips off it. None of them bounds **how long a
session is allowed to run**, and cost is *Σ over turns of context size* — so the tail of a long
session is where the money actually goes. Two measurements from the same 19-merge run (bsca-dev/partners-api, 2026-08-24) say that tail
is not a rounding error, on either side of the fleet.

### The orchestrator is the single most expensive session in the run

The headline `SKILL.md` quotes — *"19-merge run … 21 worker sessions, 863M tokens"* — counts **worker
sessions only**. Adding the supervisor's own transcript to the same rollup:

| | Sessions | Tokens | $ list-equiv |
|---|---|---|---|
| Workers | 38 | 656,482,029 | $427.20 |
| **Orchestrator** | **1** | **116,086,877** | **$212.65** |
| **Total** | 39 | **772,568,906** | **$639.85** (~$33.7/merge) |

One session, **33% of the run's list-equivalent cost** — more than the four top-tier worker sessions
combined ($187.23). It ran 551 assistant messages at **~210K average context per message** and
**never compacted once across all 19 merges**, because the cadence in force at the time (*~40–50% of
the window, or every ~20 merges*) could not fire inside a 19-merge run at all.

Corroborated on this repo, 2026-08-31: a ~30-merge fleet run whose supervisor again never compacted
once. A rule that has not fired in two consecutive runs is not a bound; it is a note.

### Worker cost is a tail, not an average

`scripts/analyze_cache.py` over the same run's 37 analysable worker sessions:

```
sessions=37  turns=4690  cacheRead=643M
avg turns/session=127  avg context/turn=137K

sess      turns  ctx@start  ctx@peak  cacheRead
ecb6dbb8    434        30K      347K      95.7M   ← issue #263, effort: medium, MID tier
2d051111    307        30K      314K      60.3M
c6943a7a    279        30K      276K      48.9M
29700f65    270        30K      279K      47.9M
...
00410c0c    177        16K      180K      21.0M
```

The **top 3 of 37 sessions consumed 205M of 643M cache-read — 32% of all worker cost**, and the worst
of them was an `effort: medium` bug on the **mid** tier whose token total alone beat all four
top-tier sessions put together. Neither the effort label nor the tier predicted it, so neither can be
the control.

`SKILL.md`'s lever 2 is the relevant negative result: per-turn tool-call batching was A/B'd and did
not move (0.556 → 0.537 calls per turn). Per-turn optimisation is close to exhausted, which leaves **session length** as the
variable nothing has touched — and lever 1 already proved that exact mechanism pays, by splitting one
session at a *phase* boundary. A length boundary is the same cut at a less natural seam.

### The two budgets — declared here, cited everywhere else

Both integers live in this file and **nowhere else**. `SKILL.md` and `commands/auto-dev-worker.md`
cite this section rather than carrying a number of their own, and `tests/auto-dev-cost-budgets/test.sh`
fails the build if either is restated there — a figure repeated in two documents is a figure that
drifts, which is why this repo already gates its pinned version literals the same way.

- **COMPACTION CADENCE = 8 merges.** The supervisor compacts (with a focus directive) as soon as
  `merges - lastCompacted >= 8`, counted off the state file's existing merge counter instead of
  eyeballed off `/context`. Derived from the run above: from a ~30K session start, ~8 merges is
  roughly where per-turn context has multiplied several-fold and every remaining turn starts costing
  ~10× an early one. The **re-survey** cadence is the proof the mechanism works — it is counted off
  the same field, and it *did* fire, twice, inside the very run whose compaction rule never fired.
- **WORKER TURN BUDGET = 150 turns.** Past ~150 self-estimated turns a phase-1 worker takes on no new
  task scope: it finishes the task in hand to green, commits, pushes, leaves the PR open, and reports
  `STATUS: PARTIAL` naming the plan checkboxes it did not reach. Derived from the 127-turn mean —
  comfortably above it, well below the 434-turn outlier. Two 150-turn sessions cost far less than one
  300-turn session because the second one restarts at ~30K instead of continuing from ~300K.

Both are **starting values derived from one run on one repo, not A/B-verified optima**, and this
file's own standard (*never claim a lever works without an A/B*) applies to them too. Re-measure with
`analyze_cache.py` and change them **here**, in the one place, when a second run disagrees.

### Substrate note — what changed when workers became sub-agents (#314)

Since v2.0 a worker is an in-process background sub-agent, not a `claude -p` process. That does not
soften either budget; it changes how each is applied.

- **A budget resume is a fresh dispatch, never a `SendMessage`.** `SendMessage` resumes a live
  sub-agent *with its context intact* — which is exactly the context the turn budget exists to
  discard. Messaging an over-budget worker to carry on saves nothing at all; the saving comes only
  from a **new** sub-agent starting again at ~30K against the branch and draft PR that already exist,
  which is what `implement-issue`'s Step 4 resume contract is for.
- **The supervisor gains a cheap lever the old substrate could not offer.** A `claude -p` worker could
  only bound itself. A live sub-agent can be *told* to wrap up: one `SendMessage` — "you are past the
  turn budget; take on no new scope, finish to green, push, report `PARTIAL`" — costs the supervisor a
  single turn. That is the intervention for a slot that has been implementing a long time with no
  report. Reading the worker's transcript to count its turns instead would cost precisely the money
  this section is about, and `SKILL.md` forbids it for that reason.

## Measurement

`scripts/usage_report.py <project-transcript-dir> --main <orchestrator-session-id>` aggregates tokens
+ $-equivalent across the orchestrator and every worker session, broken down by model (so the tiering
payoff is visible). It auto-detects the transcript dir from `$PWD` if not given. Track **tokens/merge**
and **$/merge** across runs so a regression shows up immediately. Dollar figures are API list-price
equivalents — on a subscription they map to rate-limit budget, not cash; the authoritative cash figure
is the built-in `/cost`.
