# auto-dev — the retro taxonomy (#318)

Ported from [mattpocock/skills](https://github.com/mattpocock/skills)' `in-progress/retro/SKILL.md`
(MIT licensed), which conducts a retrospective over a single coding session and sorts candidate
environment improvements into seven fixed categories. This file re-aims each category's *use when*
at a **fleet run** — many workers, a shared decision-events log, a state file — rather than at one
session's transcript, and adds *where it lands in the kit*: the concrete file or suite a candidate in
that category turns into, so a `lessons:` entry (`SKILL.md` Step 6) is pre-shaped for `create-issue`
rather than a restatement of the observation.

The taxonomy exists so retro candidates are **comparable across runs** instead of free prose. Matt's
own framing still applies unchanged: a retro suggests improvements to the coding agent's
*environment*, not to the code it produced — these seven categories are about the kit, never about
the issue a worker happened to be implementing.

## navigation

**Use when** a worker took a long time to find a file, or a hidden dependency between files cost it
several turns it should not have needed. In a fleet run this shows up as a worker's `DETAIL:` line
describing exploration rather than implementation, or a review finding that the same file was
mis-located by more than one worker across separate runs.

**Where it lands in the kit.** A navigation pointer in the repo profile's *Architecture grain*
section (`.claude/skills/repo-profile.md`), or a `CLAUDE.md` cross-reference — never a restatement of
the file's contents, per the pointer-not-copy rule `writing-for-agents` already applies to `CLAUDE.md`
and `AGENTS.md`.

## automated-checks

**Use when** a worker made a mistake a linter, type-checker, test, or filesystem guard could have
caught before it ever reached review. A fleet's own evidence: a code-review finding that repeats
across workers, or a bug that reached a merged PR because nothing red-lit it first.

**Where it lands in the kit.** A new or extended golden suite under `tests/<name>/test.sh`
(`ci-wiring-check.py` then requires it wired into CI), or a guard script under `skills/<skill>/scripts/`
following the guard convention (`README.md`'s "Hardening a destructive operation").

## coding-standards

**Use when** the reviewer agent — the `code-review` skill in `implement-issue` Step 7 — failed to
catch a mistake it should have, or enforced a rule that turned out to be wrong or unclear. The
Implementation-vs-Review split Matt's skill documents applies directly here: the reviewer has the
least context pressure of the two stages (no exploration, often no code to write), which is exactly
why coding standards belong to it rather than to the worker doing the implementing.

**Where it lands in the kit.** The repo profile's *Coding standards* line (`.claude/skills/repo-profile.md`),
or, for a fleet-wide convention rather than a per-repo one, a clarification in `skills/implement-issue/SKILL.md`
Step 7 itself.

## steering

**Use when** a standing instruction that belongs in an automated check or the repo profile instead
is sitting in prose a worker has to re-read every run — Matt's original category is *Global
AGENTS.md*, renamed here since the kit ships no `AGENTS.md`; the concern is any standing instruction
file, `CLAUDE.md` included. *Use when* a steering file has grown large enough that its token cost is
measurable — the kit's own `CLAUDE.md` at 44 KB costing 52M tokens across a run (Token economics) is
the case this category exists to catch, and it was found by hand, after the fact, because no retro
step existed to surface it during the run.

**Where it lands in the kit.** A trim of `.claude/CLAUDE.md` (pointers, not restatements — the same
rule as *navigation*), or a graduation of the instruction into a golden suite (*automated-checks*) or
the repo profile (*coding-standards*) if it is actually enforceable rather than merely advisory.

## tool-economy

**Use when** a worker made an expensive tool call that could have been streamlined, or a custom tool
(a CLI, an MCP server) turned out to be token-inefficient in practice. The kit's own Token economics
section exists because of exactly this category: tool-call batching that measured as *not* working,
the two-phase implement/merge split, the supervisor-side CI wait before dispatching phase 2 — each
was a tool-economy lesson recovered by hand from a real run's numbers.

**Where it lands in the kit.** `skills/auto-dev/references/token-economics.md` (the rationale +
measurement methodology) and the actionable rules in `SKILL.md`'s own Token economics section; a
`decision-tally.sh` row flagged `repeat-poll` is exactly this category's fleet-scale evidence — the
same input polled far more times than it has distinct values.

## no-ops

**Use when** an instruction in a command or skill file turns out to change no behavior at all — it
reads as guidance but nothing in the run ever actually depended on it. Matt's own *use when* — "the
steering files are large and unwieldy" — still holds: a no-op is cheapest to find while trimming a
file that has grown past the point anyone rereads it in full.

**Where it lands in the kit.** Deletion from the command or skill file it was found in
(`commands/auto-dev-*.md`, `skills/auto-dev/SKILL.md`) — a no-op earns no replacement text, since by
definition nothing was relying on it.

## information-access

**Use when** a fact the worker needed was not reachable from where it was standing — no read-only
access to a third-party service, no tee'd log, no script that answers the question directly, so the
worker either guessed or spent turns reconstructing something the kit could have hand it outright.
`scripts/decide.sh`'s own event log is the fleet-scale version of this: the diagnostic ("twenty
`sync` events with ONE hash is one PR polled twenty times") was always computable, and until
`decision-tally.sh` (#318) nothing computed it — a fact the kit already held but made no one able to
reach.

**Where it lands in the kit.** A new read-only script (`scripts/`, `skills/<skill>/scripts/`) in the
same fail-open, report-don't-decide style as `decide.sh`'s own event logger, or a line added to the
repo profile naming where the fact already lives.

---

### Reference: implementation vs review (from Matt's skill)

All work in this kit already goes through two stages: `implement-issue` (exploration, writing code,
debugging failures — the highest context pressure) and its Step 7 code-review pass (a diff only, no
exploration needed, often no code to write — the lowest context pressure). This is why
**coding-standards** candidates route to the reviewer's side of that split rather than to the
worker's: the stage with less context pressure is the one that can afford to hold and enforce a
standard.
