#!/usr/bin/env python3
"""ci-wiring-check.py — every tests/<name>/test.sh must be run by a step that can fail the build.

Why this exists (#45). The README used to carry an enumeration of the golden suites, and it went
stale four times: four suites existed that the only human-facing index of tests/ never mentioned.
Replacing prose with prose would have gone stale a fifth time, so the inventory is now mechanical
and this script is it.

The failure being closed is not the stale list. It is that **a suite nobody runs looks exactly like
a suite that passes**: CI is green, the check name is absent rather than red, and nothing anywhere
reports a problem. That is the same shape as the incidents tests/tick-plan/ and tests/guarded-git/
were written for, and it gets the same treatment — a script, a golden test that drives its refusal
path, and a CI step that runs both.

WIRED means more than "the path appears in the workflow". A step can name a suite and still enforce
nothing, so all of these count as UNWIRED and are reported with the reason:

  * the step is commented out            — the path survives as comment text a plain grep accepts
  * continue-on-error: true              — the suite runs, fails, and the build stays green
  * if: false                            — the step never runs at all
  * run: ./tests/x/test.sh || true       — the exit status is discarded
  * the workflow has no automatic trigger — a workflow_dispatch-only suite is not "CI-run"
  * the workflow never runs on `main`    — a pull_request-only or schedule-only workflow, or a
                                           push trigger whose branch filter misses `main`, does
                                           not run on the push that lands on the default branch
  * the suite's git INDEX mode is not `100755` — a Windows checkout has core.filemode=false, so
                                           `chmod +x` never reaches the index; the suite is
                                           committed 100644 (or, if it is a symlink, 120000) and
                                           CI's `./tests/x/test.sh` dies with "Permission denied",
                                           exit 126, on a step every rule above accepts as enforcing
  * the suite was never staged at all    — it exists on disk and a step invokes it, but `git add`
                                           was never run; the path is absent from the index
                                           entirely, so no real clone or CI checkout would contain
                                           it even though every rule above accepts it as enforcing

That last-but-two used to be implied rather than checked (#133). Any of push / pull_request /
pull_request_target / schedule counted as "automatically triggered", which was accidentally
sufficient while ci.yml was the repo's only run:-bearing workflow — it carries both `push: [main]`
and `pull_request`, so the weaker test happened to agree with the stronger one. #119 added a
pull_request-only workflow and removed the coincidence.

The last two rows are about a different thing than the six above them (#195, #210): all six are
about the **step** that invokes a suite, and these two are about the **file** being invoked. A step
can satisfy every rule above — commented nowhere, no `continue-on-error`, no `if: false`, no
discarded exit status, triggered by a push to `main` — and still be worthless if the file it names
cannot execute, or is not even in the checkout that would execute it. Read from the INDEX (`git
ls-files -s`), never the filesystem: the working copy on the machine that committed the bad mode (or
never staged the file at all) reports itself as executable regardless, which is exactly what makes
the defect invisible locally.

Comments are handled by parsing the YAML rather than by filtering '#' lines: a commented-out step
simply is not in the parsed document, which is correct by construction instead of by regex.

Usage:
  ci-wiring-check.py [--repo <path>] [--tests <glob-root>] [--workflows <dir>]

Exit codes:
  0  every suite is invoked by at least one enforcing step, at an index mode CI can execute
  1  REFUSE — a suite is unwired, wired only into a step that cannot fail the build, committed at
     an index mode CI cannot execute, never staged at all, or the index could not be read to tell
  2  usage / plumbing error — could not read the tests or the workflows, so no verdict is possible
"""

import argparse
import fnmatch
import os
import pathlib
import subprocess
import sys

import yaml

# The branch whose pushes are the merge gate. A constant rather than a literal sprinkled through
# the predicates below, so a repo that renames its default branch has one line to change.
MAIN_BRANCH = "main"

# The only index mode CI can execute a suite at. A symlink (120000) or anything else that is not
# this is refused the same as 100644 — accepting a mode nobody intended is how the next hole opens.
REQUIRED_MODE = "100755"

# `push:` with an empty body parses to None, which is a legitimate value meaning "every branch".
# `.get("push")` cannot tell that apart from "no push trigger at all", and those are opposite
# verdicts — hence a sentinel rather than a None check.
_ABSENT = object()


def load_workflows(workflow_dir):
    """Parse every workflow. An unparseable one is a plumbing error, never a silent skip."""
    docs = []
    for path in sorted(workflow_dir.glob("*.y*ml")):
        try:
            with path.open() as fh:
                doc = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            raise SystemExit(f"ci-wiring-check: cannot parse {path}: {exc}")
        if isinstance(doc, dict):
            docs.append((path, doc))
    return docs


def workflow_triggers(doc):
    """The workflow's `on:` block, normalised to {event-name: config-or-None}.

    PyYAML reads YAML 1.1, where the bare key `on:` is the BOOLEAN True, not the string "on".
    Reading only doc["on"] therefore finds nothing in every real workflow file, and every suite
    would look untriggered. Both spellings are checked.

    `on: push`, `on: [push, pull_request]` and `on: {push: {branches: [main]}}` are all legal
    spellings of the same block, so all three collapse to one mapping here and every caller below
    reads exactly one shape.
    """
    triggers = doc.get("on", doc.get(True))
    if isinstance(triggers, str):
        return {triggers: None}
    if isinstance(triggers, list):
        return {t: None for t in triggers if isinstance(t, str)}
    if isinstance(triggers, dict):
        return {k: v for k, v in triggers.items() if isinstance(k, str)}
    return {}


def selects_main(patterns):
    """True when GitHub's branch-filter patterns select `main`.

    Order matters, and `!` is real filter syntax rather than part of a branch name: `branches:
    ['**', '!main']` means "every branch except main", and GitHub resolves such a list by walking
    it and letting the LAST matching pattern decide. Read as a bare `any(...)` that list says
    "runs on main" — a fail-open of exactly the kind this script exists to close, inside the guard
    closing it (#133). So the list is walked in order, and a negated match un-selects.

    `fnmatch` is a good enough stand-in for the pattern syntax itself here, and only here:
    GitHub's `*` does not cross `/` while fnmatch's does, but the sole branch name ever matched
    against these patterns is `main`, which contains no `/`. On that input the two agree.

    A non-list, non-string filter (`branches:` with every entry commented out parses to None)
    selects nothing — the same verdict as the `branches: []` it is a spelling of, and the
    fail-closed direction either way.
    """
    if isinstance(patterns, str):
        patterns = [patterns]
    if not isinstance(patterns, list):
        return False
    selected = False
    for pattern in patterns:
        if not isinstance(pattern, str):
            continue
        negated = pattern.startswith("!")
        if fnmatch.fnmatchcase(MAIN_BRANCH, pattern[1:] if negated else pattern):
            selected = not negated
    return selected


def main_push_verdict(doc):
    """Does a push to `main` run this workflow? Returns (True, None) or (False, "<reason>").

    This replaces `has_automatic_trigger()`, which accepted any of push / pull_request /
    pull_request_target / schedule (#45). That test was accidentally sufficient rather than
    correct: `ci.yml` was the only run:-bearing workflow in the repository and it carries BOTH
    `push: branches: [main]` and `pull_request`, so "automatically triggered" silently also meant
    "runs on main" — not because anything checked, but because there was nowhere else for a suite
    to be. #119 added a pull_request-only workflow and removed the coincidence, at which point a
    suite could be moved into a PR-only workflow, never run on a push to `main`, and still be
    reported as enforced (#133). That is this script's own stated failure mode — a suite nobody
    runs looking exactly like a suite that passes — reappearing through a case its model did not
    represent. It bites here because `main` really does take direct pushes: every squash-merge
    lands one, and that run is the last verdict before release-please cuts a tag.

    The verdict and its reason are returned together on purpose. Computed by two functions they
    drift, and a refusal whose explanation names the wrong cause is worse than none at all.
    """
    triggers = workflow_triggers(doc)
    push = triggers.get("push", _ABSENT)

    never = f"never on a push to {MAIN_BRANCH}"
    if push is _ABSENT:
        if "pull_request" in triggers or "pull_request_target" in triggers:
            return False, f"workflow runs on pull requests only, {never}"
        if "schedule" in triggers:
            return False, f"workflow runs on a schedule only, {never}"
        return False, "workflow has no automatic trigger"

    if not isinstance(push, dict):
        # `push:` with nothing under it — every branch and every tag, so `main` among them.
        return True, None

    unreached = f"workflow's push trigger does not reach {MAIN_BRANCH}"
    # Presence of the KEY, not truthiness of its value: `branches:` with every entry commented out
    # parses to None, and reading that as "no branch filter at all" would accept a workflow whose
    # filter selects nothing — while the `branches: []` it is a spelling of gets refused. Same
    # question, same answer, and the answer is the fail-closed one.
    has_include, has_exclude = "branches" in push, "branches-ignore" in push
    if has_include and has_exclude:
        # GitHub rejects the two together, so this workflow runs on nothing at all. Refusing with
        # a reason that says so beats guessing which half would have won.
        return False, "workflow sets both branches and branches-ignore, so its push trigger is invalid"
    if has_include:
        return (True, None) if selects_main(push["branches"]) else (False, unreached)
    if has_exclude:
        return (False, unreached) if selects_main(push["branches-ignore"]) else (True, None)
    if "tags" in push or "tags-ignore" in push:
        # A tag filter with no branch filter narrows the trigger to tag pushes only, so nothing
        # here fires when a commit lands on a branch.
        return False, unreached
    # Filters that are not about the ref — `paths`, `paths-ignore` — are deliberately NOT read.
    # They can genuinely stop a workflow running on a push to `main`, but answering that means
    # deciding whether a suite's own inputs fall inside the filter, which is a different and much
    # larger question than "which branch". Recorded as a known limit rather than half-implemented.
    return True, None


def is_disabled(node):
    """A step or job that cannot fail the build.

    `if: false` is the literal boolean after YAML parsing; `if: ${{ false }}` stays a string.
    Anything else is a real condition that may well be true, so it is NOT treated as disabled —
    guessing at expressions would make this refuse on perfectly good steps.
    """
    if node.get("continue-on-error") is True:
        return True
    cond = node.get("if")
    if cond is False:
        return True
    if isinstance(cond, str) and cond.strip().strip("${} ").lower() == "false":
        return True
    return False


def invocation_lines(run_text, suite):
    """The lines of a `run:` block that invoke `suite` in a way whose failure is not discarded."""
    lines = []
    for line in run_text.splitlines():
        if suite not in line:
            continue
        # `|| true`, `|| :` and a trailing `|| echo …` all swallow the suite's exit status. Only
        # the part of the line AFTER the invocation can do that, so look there.
        tail = line.split(suite, 1)[1]
        if "||" in tail:
            continue
        lines.append(line.strip())
    return lines


def index_modes(repo, paths):
    """The git INDEX mode for each of `paths`, keyed by the same relative-path string given.

    The filesystem mode is the wrong authority — that is the bug this closes. A Windows checkout
    with `core.filemode=false` reports its working copy as executable no matter what git actually
    recorded, because `chmod +x` there never reaches the index; only the index is what CI receives.

    Returns (modes, error). `modes` maps a path present in the index to its six-digit mode string;
    a path absent from the index (untracked, or the filesystem enumeration and the index simply
    disagree) is absent from the dict — a different condition from `error`, which is set when the
    index could not be read AT ALL (no `git` binary, not a repository, or any other non-zero exit).
    The caller must treat a non-None `error` as unanswerable, never as "every suite is fine".

    Invoked with `-z`: without it, git C-quotes any path it considers "unusual" — which includes
    every non-ASCII byte — so a suite such as `tests/café/test.sh` comes back as the literal string
    `"tests/caf\303\251/test.sh"`, which never matches the plain path used as the lookup key. That
    is not a refusal, it is a silent miss: the mismatched path is simply absent from `modes`, the
    caller reads that as untracked, and a suite committed 100644 under such a name is reported
    enforced (measured). `-z` NUL-terminates each record and turns quoting off unconditionally,
    since a raw path cannot contain the NUL byte that already delimits the stream.
    """
    if not paths:
        return {}, None
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-s", "-z", "--", *paths],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as exc:
        return {}, f"git is not available ({exc})"
    if proc.returncode != 0:
        return {}, proc.stderr.strip() or f"git ls-files exited {proc.returncode}"
    modes = {}
    for record in proc.stdout.split("\0"):
        if not record:
            continue
        # "<mode> <sha> <stage>\t<path>" — the mode is the first whitespace-separated token, which
        # never contains a tab, so splitting on the first tab cannot cut it in half.
        meta, _, path = record.partition("\t")
        modes[path] = meta.split()[0]
    return modes, None


def check(repo, tests_root, workflow_dir):
    suites = sorted(str(p.relative_to(repo)) for p in tests_root.glob("*/test.sh"))
    if not suites:
        raise SystemExit(
            f"ci-wiring-check: no {tests_root.name}/*/test.sh under {repo} — refusing to report "
            "'all wired' over an empty set."
        )

    workflows = load_workflows(workflow_dir)
    if not workflows:
        raise SystemExit(f"ci-wiring-check: no workflows under {workflow_dir} — nothing could run.")

    # Computed even when the index turns out to be unreadable (below): the wiring verdict is
    # independent of git entirely — filesystem enumeration plus workflow parsing — so a repo with
    # BOTH an unreadable index and a genuinely unwired suite must still name the unwired one. An
    # early return here would report only the index problem and hide the second, unrelated defect
    # until a follow-up run — a diagnostic regression this file exists to avoid, not commit.
    modes, mode_error = index_modes(repo, suites)
    not_executable = {}
    if not mode_error:
        not_executable = {
            # `modes` is keyed by the forward-slash paths `git ls-files` always emits, regardless
            # of OS. `suite` came from pathlib's `relative_to()` and is joined with the platform's
            # own separator — a backslash on native Windows — so looking it up unmodified would
            # never hit on that platform and every suite would silently read as untracked. `os.sep`
            # is a no-op `/` -> `/` replace everywhere this script actually runs today, so this
            # changes nothing here; it only matters the day Windows is a supported host for this
            # check.
            #
            # `mode is None` (untracked — never `git add`ed) IS flagged here (#210): a suite absent
            # from the index is absent from any real clone or CI checkout, the exact failure class
            # this script exists to catch. The print block below special-cases `None` with its own
            # message and remedy rather than the wrong-mode text.
            suite: mode
            for suite in suites
            if (mode := modes.get(suite.replace(os.sep, "/"))) != REQUIRED_MODE
        }

    verdicts = {}
    for suite in suites:
        reasons = []
        for path, doc in workflows:
            on_main, not_on_main = main_push_verdict(doc)
            for job in (doc.get("jobs") or {}).values():
                if not isinstance(job, dict) or is_disabled(job):
                    continue
                for step in job.get("steps") or []:
                    if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                        continue
                    if not invocation_lines(step["run"], suite):
                        continue
                    if is_disabled(step):
                        reasons.append(f"{path.name}: step exists but cannot fail the build")
                        continue
                    if not on_main:
                        reasons.append(f"{path.name}: {not_on_main}")
                        continue
                    verdicts[suite] = None  # wired, and enforcing
                    break
                if suite in verdicts:
                    break
            if suite in verdicts:
                break
        else:
            verdicts[suite] = reasons or ["no step invokes it"]

    unwired = {s: r for s, r in verdicts.items() if r}
    if unwired or not_executable or mode_error:
        if unwired:
            print("ci-wiring-check: REFUSED — these golden test suites are not enforced by CI:")
            for suite, reasons in unwired.items():
                print(f"  {suite}")
                for reason in dict.fromkeys(reasons):
                    print(f"      {reason}")
            print()
            print("  Wire each one in as a `run:` step of a workflow that runs on a push to")
            print(f"  `{MAIN_BRANCH}`, whose failure fails the build. A pull-request-only workflow is")
            print("  not enough: it never runs on the push that lands the merge. To exclude a suite")
            print("  deliberately, say why in the diff.")
        if not_executable:
            if unwired:
                print()
            # Reported under its own heading rather than folded into `unwired` above: a step that
            # invokes the suite and can fail the build is genuinely WIRED by every rule this file
            # otherwise knows — the file itself is what CI cannot run, a different cause that would
            # be lost if the two reasons were conflated in one block.
            print("ci-wiring-check: REFUSED — these golden test suites are not executable:")
            for suite, mode in not_executable.items():
                print(f"  {suite}")
                if mode is None:
                    if suite in unwired:
                        # This suite is ALSO reported above under "not enforced by CI" — no step
                        # invokes it at all, so claiming "CI invokes it" here would contradict that
                        # verdict in the same run.
                        print(
                            "      not staged in the index at all, and no step invokes it either — "
                            "a real clone would not contain it even if one did"
                        )
                    else:
                        print(
                            f"      not staged in the index at all — CI invokes it as ./{suite}, but "
                            "a real clone would not contain it"
                        )
                    print(f"      fix: git add {suite}")
                    continue
                print(f"      index mode {mode}, expected {REQUIRED_MODE} — CI invokes it as ./{suite}")
                if mode == "120000":
                    # `git update-index --chmod=+x` refuses outright on a symlink entry ("cannot
                    # chmod +x") — chmod changes the mode of an existing 100644/100755 blob, it does
                    # not turn a symlink into a regular file. The fix has to replace the entry, not
                    # flip a bit on it.
                    print(
                        f"      fix: replace the symlink with a real, executable file, then "
                        f"`git rm --cached {suite} && git add {suite}`"
                    )
                else:
                    print(f"      fix: git update-index --chmod=+x {suite}")
                    print(
                        "      (a Windows checkout has core.filemode=false, so chmod alone never "
                        "reaches the index)"
                    )
        if mode_error:
            if unwired or not_executable:
                print()
            print(
                "ci-wiring-check: REFUSED — the git index could not be read, so no suite's "
                "executability is knowable (independent of the wiring verdicts above, if any):"
            )
            print(f"  {mode_error}")
            print()
            print("  An unanswerable question is not a pass — the same rule worktrees-ignored.sh")
            print("  applies to its own verdict.")
        return 1

    print(f"ci-wiring-check: {len(suites)} golden test suites, all enforced by CI.")
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    ap.add_argument("--tests", default="tests", help="directory holding the suites")
    ap.add_argument("--workflows", default=".github/workflows", help="workflow directory")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    tests_root, workflow_dir = repo / args.tests, repo / args.workflows
    if not tests_root.is_dir():
        raise SystemExit(f"ci-wiring-check: {tests_root} is not a directory.")
    if not workflow_dir.is_dir():
        raise SystemExit(f"ci-wiring-check: {workflow_dir} is not a directory.")
    return check(repo, tests_root, workflow_dir)


if __name__ == "__main__":
    sys.exit(main())
