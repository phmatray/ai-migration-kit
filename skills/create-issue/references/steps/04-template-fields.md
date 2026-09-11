## Step 4 — Build the template-compliant body fields

These are the **visible top of the description** (brainstorm/spec/plan come after). They MUST match the
project's issue form — never invent structure. Read the live template:

```bash
ls .github/ISSUE_TEMPLATE/
cat .github/ISSUE_TEMPLATE/feature_request.yml
```

`gh issue create` doesn't apply a form template, so reconstruct it as markdown:

- Use **feature_request** for ideas/enhancements (common case); `bug_report` only for a clear defect.
- For each `textarea`/`input` field, emit a `## <label>` heading and fill it. Honor `validations.required`.
- For each `dropdown`, pick the best-fitting option and write it under its heading, verbatim from the live YAML.
- The **Area** dropdown mirrors the profile's `area:` labels — pick the option matching the `area:` label you'll apply in Step 7 so the body and the label agree.
- The template's declared `labels:` apply at creation in Step 7, not in the body.

See `references/issue-template.md` for a worked feature_request example and the exact field→heading
mapping. Hold this markdown for Step 7.

**With `--seed #N`: keep what the issue already says; synthesize only what is missing.** The original
body is preserved **verbatim** by Step 7 — you are not rewriting it, and you never "improve" someone's
Problem statement. So compare its headings against the live form and produce only the **gap**:

- A required field the body already answers, under whatever heading — leave it alone, and don't emit a
  second copy of it under the form's spelling. Two `## Problem` sections that disagree is worse than
  one that is worded oddly.
- A required field nothing in the body answers (commonly **Area**, which raw issues never carry) —
  synthesize it from what the body and your Step 3 sweep establish, and emit it under the form's
  heading in the appended section.
- Nothing missing — emit nothing here. A seeded body is then just the original plus the trail.

Every synthesized field is a claim you made about someone else's issue, so list them in Step 8.
