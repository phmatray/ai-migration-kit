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

Comments are handled by parsing the YAML rather than by filtering '#' lines: a commented-out step
simply is not in the parsed document, which is correct by construction instead of by regex.

Usage:
  ci-wiring-check.py [--repo <path>] [--tests <glob-root>] [--workflows <dir>]

Exit codes:
  0  every suite is invoked by at least one enforcing step
  1  REFUSE — a suite is unwired, or wired only into a step that cannot fail the build
  2  usage / plumbing error — could not read the tests or the workflows, so no verdict is possible
"""

import argparse
import pathlib
import sys

import yaml


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


def has_automatic_trigger(doc):
    """True when the workflow runs without a human pressing a button.

    PyYAML reads YAML 1.1, where the bare key `on:` is the BOOLEAN True, not the string "on".
    Reading only doc["on"] therefore finds nothing in every real workflow file, and every suite
    would look untriggered. Both spellings are checked.
    """
    triggers = doc.get("on", doc.get(True))
    if isinstance(triggers, str):
        triggers = [triggers]
    if isinstance(triggers, dict):
        triggers = list(triggers)
    if not isinstance(triggers, list):
        return False
    return any(t in ("push", "pull_request", "pull_request_target", "schedule") for t in triggers)


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

    verdicts = {}
    for suite in suites:
        reasons = []
        for path, doc in workflows:
            auto = has_automatic_trigger(doc)
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
                    if not auto:
                        reasons.append(f"{path.name}: workflow has no automatic trigger")
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
    if unwired:
        print("ci-wiring-check: REFUSED — these golden test suites are not enforced by CI:")
        for suite, reasons in unwired.items():
            print(f"  {suite}")
            for reason in dict.fromkeys(reasons):
                print(f"      {reason}")
        print()
        print("  Wire each one in as a `run:` step of an automatically-triggered workflow, whose")
        print("  failure fails the build. To exclude one deliberately, say why in the diff.")
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
