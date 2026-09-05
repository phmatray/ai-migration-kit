# UI platform rewrite — playbook

Pipeline for apps whose UI platform is dead (WinRT, UWP, Windows Phone, WPF → Blazor). Complements
phases 1–6 (modernization in place); validated on wave 1 of the WinRT portfolio (sokoban,
2026-07-22).

## The central pattern: port, characterize, wrap

1. **Port the core byte for byte.** Copy engine/domain/services to `src/<App>.Core`, changing only
   namespace and usings. Do NOT modernize during the port — every simultaneous "improvement"
   destroys the proof of no regression.
2. **Characterize with tests, quirks included.** Legacy quirks (inconsistent state, missing rules,
   side effects) are pinned by tests that document the REAL behaviour. A quirk is not a test bug.
3. **Fix by wrapper, never inside the legacy.** Missing semantics (validation, state detection,
   counters) live in a class that wraps the ported code. The legacy stays intact and proven; the
   new code is tested separately.
4. **Rewrite the UI only afterward**, on a core that is already green.

## Protocols from waves 1 to 3 (sokoban, chords, fleurs-du-mal, pokedexg)

- **Legacy SQL on modern SQLite** (wave 3): queries from the 2014-2016 era can use an ON clause
  referencing a table joined further to the right — the old engine accepted it, the modern one
  answers "ON clause references tables to its right". Minimal reconstruction: reorder the joins so
  each ON only sees tables already joined (identical semantics on equality LEFT JOINs), a
  RECONSTRUCTION header in the .sql file, and a characterization test on the result. **Run every
  legacy query early**: it is a free smoke test of the target engine.
- **Assets outside the project: never a Blazor `Content Link`** (wave 3): an asset linked from
  another folder (`<Content Include="..\..\Legacy\Assets\**" Link="wwwroot\...">`) is served
  **200 with 0 bytes** by the dev server — a silent phantom mapping. Copy it physically into
  `wwwroot` via an MSBuild target (`SkipUnchangedFiles`), a gitignored folder, and **build before
  publishing** (the `wwwroot/**` glob evaluation precedes the targets: a cold publish without a
  prior build would lose the files). Mandatory proof: a cold `dotnet publish` then `ls` of the
  published folder.
- **Tailwind 4 cascade** (wave 3): any element rule (`a { color: … }`) written outside a layer
  overrides the utilities (`text-…`), which live in `@layer utilities`. Base styles go in
  `@layer base` — otherwise the symptom is invisible or wrongly-coloured text that only
  `getComputedStyle` explains.
- **Per-route content PWA: precache is the contract** (wave 3): when each page loads its JSON on
  demand, "offline" only holds for pages already visited. If the original app was **installed**
  with all its content local, parity requires precaching data (+ small images) in the service
  worker (`Promise.allSettled`, never an all-or-nothing `addAll`), and writing down what remains
  cache-on-visit.
- **Offline, provable without production** (wave 3): when prod does not exist yet, cutting DNS
  does not cut off a local server reached by IP — the real cutoff is to **kill the server** after
  warm-up (persistent profile, 2-3 online visits), then open a never-visited route.

### Protocols from waves 1 and 2

- **Inventory local binary assets BEFORE drawing the UI** (wave-2 lesson: an artist's original
  drawing, `Assets/Background.png`, the heart of the 2014 design, had nearly been lost).
  `find <app> -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.svg' -o -iname '*.mp3' \)`
  outside `bin/obj` — look at every non-trivial asset (> a few KB). Embedded illustrations
  (backgrounds, boards, signed artwork) are part of the work: they port **byte for byte** (shasum),
  with artist credit (an owner decision if the name is not in the code). Never conclude "no images"
  on the sole faith of dead external URLs; any discarded asset is logged in the report with the
  reason.
- **Contrast measured, never eyeballed**: any rewritten UI palette goes through
  `scripts/contrast-check.py "#ink:#bg:label" …` — every text/background pair, light **and** dark
  themes, AA = 4.5:1 (normal text), 3:1 (large text/UI, `--min 3`). Wave-2 lesson: a muted ink
  "that looked readable" measured 4.16:1.
- **A PWA's offline mode is tested, never declared**: after deployment, a browser session with
  the network cut (a profile that has already visited prod) must render the app — root AND a deep
  route. Known trap: a `caches.match('index.html')` fallback never matches if the root was cached
  under the directory URL; use `caches.match('./')` first.

- **Namespaces: keep them.** The purest port keeps the original namespaces (chords: 102 files, 0
  lines changed). Only change them if a real conflict forces it.
- **Files referenced but never committed** (repo rot — the csproj lists absent files): reconstruct
  **the minimum used** (YAGNI), in a file carrying a dated "RECONSTRUCTION" header explaining the
  provenance — never mixed with the ported code.
- **Historical tests that never went green**: do not rewrite them, do not delete them. Mark them
  `Skip = "<documented legacy bug + where the intent is restored>"`, pin the actual behaviour with
  characterization tests, restore the intent via a wrapper, and prove the intent with **new** tests
  that reuse the original expected values.
- **Period test style** (e.g. `Assert.Equal(x == y, true)` → xUnit2000): suppress via a commented
  `<NoWarn>` in the test csproj — the files stay verbatim.

## Rules learned in the field

- **The deliverable does not narrate its own migration.** No banner, footer, meta description or
  UI text mentions the port, the tooling or the process: the end user gets a product, not a case
  study. Provenance lives in the README, `migration/report.md` and the git history. Exception: code
  comments that encode a maintenance constraint ("verbatim port — do not modernize this file")
  stay, because they protect the proof.
- **The new solution excludes the legacy project.** `dotnet new sln` can pull in existing csproj
  files: check with `dotnet sln list` — a WinRT project in the graph breaks every build outside
  Windows. The original app stays in the repo as a reference, outside the solution.
- **The original data are assets, not code.** Embed the data files as-is (embedded resource)
  without format conversion: zero risk of content regression, and the diff proves identity.
- **Standard platform substitutions**: `Windows.Storage` → `localStorage` · `DispatcherTimer` →
  `PeriodicTimer` · lifecycle → PWA (manifest + service worker) · XAML → Razor + Tailwind
  (utilities + a small custom CSS layer for visual identity; generated CSS versioned so
  `dotnet build` stays self-contained without Node).
- **Blazor WASM and deep routes**: the host must return `index.html` on 404 (GitHub Pages: a
  `404.html` copy; dev: the devserver does it; a bare `python -m http.server` does NOT — a
  verification trap).
- **Verify in a real browser**: publish in Release, serve with the SPA fallback, capture the
  screen and LOOK at it (home + a deep route). Unit tests prove the engine, not the rendering.

## Exit gate

Like phase 6: 0 error / 0 warning build, all tests green, browser screenshots verified,
`migration/report.md` written per `report-template.md` — with its **Next steps** checklist
(critical path to production) kept distinct from **Deferred follow-ups**.
