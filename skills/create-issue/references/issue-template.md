# Issue template → markdown mapping

`gh issue create` posts a plain markdown body; it does **not** render the GitHub *form* template in
`.github/ISSUE_TEMPLATE/*.yml`. So you read the YAML form and reconstruct an equivalent markdown body
by hand. This file shows how.

## The rule

For each entry in the template's `body:` array:

| YAML `type` | What to emit |
|-------------|--------------|
| `markdown`  | skip — it's instructional text shown to the human, not a field |
| `input`     | `## <attributes.label>` heading + a one-line answer |
| `textarea`  | `## <attributes.label>` heading + a prose/markdown answer |
| `dropdown`  | `## <attributes.label>` heading + the single best `options` value, verbatim |
| `checkboxes`| `## <attributes.label>` heading + a `- [x]` / `- [ ]` list |

Honor `validations.required: true` — every required field needs real, specific content. The
template's top-level `labels:` and the triage labels (the profile's priority / effort / scope) are
**not** written into the body — they're applied via `--label` when the issue is created in SKILL.md
Step 7, picked from the repo's live taxonomy (the profile's *Labels*). The body is just the form fields
below, which become the visible top of the description (the brainstorm/spec/plan sections follow).

## Worked example — `feature_request.yml`

Suppose the repo's feature_request form has required `Problem / motivation`, required
`Proposed solution`, optional `Alternatives considered`, and a required `Area` dropdown (your
repo's form will differ — always read the live YAML). A compliant body:

```markdown
## Problem / motivation

Reports can only be viewed in the browser today. Finance asks for a monthly extract they can
open in a spreadsheet; copy-pasting the HTML table loses number formatting and locale.

## Proposed solution

A new `Services/CsvExportService` selected via an `Accept: text/csv` content negotiation on the
existing report endpoint, mirroring the JSON exporter's split-by-concern layout:

- one row per report line, header row from the column metadata
- culture-invariant number formatting; locale applied client-side
- streaming write for large reports (no full buffering)

Reuse the existing `ReportModel` untouched. Adds `CsvExportService` and a formatter parallel to
the JSON one.

## Alternatives considered

- Generating the CSV client-side from the JSON — rejected, duplicates formatting rules.
- A scheduled email export — heavier, and doesn't answer the ad-hoc need.

## Area

Reporting / export
```

This body is only the form fields. In the real run the brainstorm/spec/plan get appended below it
(SKILL.md Steps 5-6) before the issue is created. Create it with type + priority + effort labels —
all known by SKILL.md Step 7, since the plan already exists:

```bash
gh issue create --title "Add CSV export" \
  --label "<type>" --label "<priority tier>" --label "<effort size>" \
  --body-file /tmp/issue-csv-export.md
```

## Worked example — the Spec contract

Continuing the same CSV-export issue: the 📋 Spec (SKILL.md Step 5) closes with the three-heading
contract. Criteria are a **numbered list, never `- [ ]`** checkboxes — the Step 7 readback and
`tick-plan.sh` count every checkbox in the body, so a criterion written as one would inflate the
plan's count and could be ticked by a step that never satisfied it.

```markdown
### Acceptance criteria

1. AC1 — `GET /reports/{id}?format=csv` returns `Content-Type: text/csv` with a header row matching
   the report's column metadata.
2. AC2 — numeric columns render with invariant-culture formatting regardless of the request's
   `Accept-Language`.
3. AC3 — a 10,000-row report streams without the process's working-set growing past the JSON
   exporter's baseline (no full buffering).

### Testing decisions

**Seams under test:** `CsvExportService.Export(ReportModel)`'s returned file content — the same
public boundary the existing JSON exporter is tested through, not a private formatting helper.
**Prior art:** `JsonExportServiceTests` already asserts the JSON exporter's `Export()` output the
same way; the CSV tests mirror its shape.
**A good test here:** assert on the returned CSV text (header row, a formatted numeric cell, row
count) — never on which internal method built each cell (see
[`../../_shared/test-seams.md`](../../_shared/test-seams.md)).

### Out of scope

- A `.xlsx` export format — a separate content type, not part of this issue.
- Client-side locale re-formatting of the CSV — the export stays invariant-culture; locale
  formatting is the spreadsheet's job, not this service's.
```

## Area dropdown values (feature_request)

Pick exactly one, copied verbatim from the option list in the live `feature_request.yml`. If the
profile's *Labels* section defines an area axis, pick the dropdown option that agrees with the
`--label` you'll apply.

## bug_report

Only use this template when the user is filing a defect (something emits wrong/crashes), not an idea.
Read `bug_report.yml` the same way and map its fields (repro steps, expected vs actual, version, etc.)
to headings. Its declared labels apply via `--label`.
