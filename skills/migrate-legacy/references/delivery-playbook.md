# Delivery — playbook

A migration is only finished **deployed and verified in production**. Deterministic steps; the
kit's templates are **mandatory** (no hand-rolled workflow).

## Steps

1. **Discover the default branch** (it varies: `main`, `dev`…):
   `gh api repos/<o>/<r> --jq .default_branch` — that is the merge target and the workflow trigger.
2. **Check the remote repo's state**: if it is **archived** (read-only), unarchive it before any
   push: `gh api repos/<o>/<r> -X PATCH -f archived=false` — report it to the user (reversible).
3. **Drop in the workflows from the templates**:
   - `templates/ci-dotnet.yml` → `.github/workflows/ci.yml` — **set `SOLUTION`** if the old legacy
     solution still coexists at the root (otherwise MSB1011). If the repo **commits a front-end
     bundle** consumed by a .NET project, also arm the drift guard: copy
     `templates/bundle-gate.json.example` → `.github/bundle-gate.json` and set `src`/`dist` there
     (detail: `docs/bundle-gate.md`). Otherwise: nothing to do, the guard stays inert.
   - `templates/deploy-pages-blazor.yml` → `.github/workflows/deploy-pages.yml` — set `SOLUTION`,
     `WEB_PROJECT`, `BASE_PATH=/<repo>/`, and `branches:` = the default branch.
4. **Push the migration branch, merge** (`--no-ff`) into the default branch, push.
5. **Enable Pages in workflow mode**: `gh api repos/<o>/<r>/pages -X POST -f build_type=workflow`
   — idempotent: a `409` means "already enabled", that is a success, continue.
   (Also works from a private repo if the plan allows it — the returned URL is authoritative.)
6. **Wait for the runs to conclude** (`gh run list`) — a CI failure gets fixed before continuing,
   even if the deployment succeeded.
7. **Verify production**: `curl` the root **and a deep route** (the SPA fallback is trap #1).
   ⚠ With GitHub Pages' 404.html fallback, the deep route responds **HTTP status 404 but content
   = the app**: verify the content (`grep` the app's shell), never the status code alone. Then a
   browser screenshot of the deep route — look at it, don't just produce it.
8. **Close the loop on the report**: check off the delivered steps in `migration/report.json`,
   regenerate the dashboard (`scripts/report-dashboard.py`), commit.
9. **Feed lessons back (phase 7 contract, rule 8)**: the migration closes with a `lessons` entry in
   `migration/report.json` — either the reference of the change applied to the kit (commit/PR: a
   Common issues line, a playbook protocol, a script guard), or an explicit "nothing to learn from
   this wave". Schema:
   `"lessons": [{ "strong": "<title>.", "text": "<the lesson>", "ref": "kit@<commit> (optional)" }]`.
   The dashboard renders the "Wave lessons" card; a wave with no `lessons` entry is incomplete —
   the pipeline does not leave the repo without one.

## Known traps (all encountered in wave 1)

| Trap | Symptom | Guard |
|-------|----------|--------|
| Default branch ≠ `main` | workflows never trigger | step 1 |
| Archived repo | `403` on push | step 2 |
| Two `.sln` at the root | `MSB1011` in CI | explicit `SOLUTION` |
| No SPA fallback | deep routes come back 404 (a bare `http.server` doesn't handle it locally either) | template (404.html) + step 7 check |
| `<base href>` not adjusted | blank page under /repo/ | the template's `BASE_PATH` (built-in guard rail: placeholder refused, rewrite verified) |
| Pages already enabled | `409` on the POST | idempotent — continue (step 5) |
| 404.html fallback | deep route reads "404" to curl while everything works | verify the content and the screenshot, not the status (step 7) |
