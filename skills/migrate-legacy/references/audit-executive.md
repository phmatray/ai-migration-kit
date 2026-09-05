# Executive audit (`/migrate-audit`)

The kit's entry-point deliverable: a **read-only** audit that speaks to decision-makers. Three app
profiles:

- **Modernization in place** (obsolete TFM, same UI platform) → the audit extends
  `phase-1-assess.md` with a costed estimate and risks.
- **UI platform rewrite** (WinRT, UWP, Windows Phone, WPF → Blazor) → the target platform no
  longer exists or does not run on the web; cost the UI rewrite and the **verbatim porting of the
  logic**.
- **Healthy, nothing to migrate** (every TFM already at target, runtime in support, no obsolete
  API cluster) → phase 1's `ALREADY_MODERN` verdict (`phase-1-assess.md` step 6): the audit
  concludes **"no migration required"**, a zero cost estimate, and **never** points toward a
  net`N`→net`N` retarget. If the owner wants a guarantee, route to `/migrate-verify` (quality gate,
  phase 6) — modern ≠ clean: a green `dotnet restore` can still surface a high-severity transitive
  vulnerability (dogfooded on StaticWGen: `NU1903`).

## Rules

1. **Absolute read-only** on the target app (the report is written elsewhere).
2. **Every figure comes from `scripts/audit-inventory.sh`** (reproducible JSON). The agent
   interprets; it does not invent counts.
3. **C# analysis:** try RoselineMCP `analyze_solution` first. Old-style UAP/WP projects do not
   load in Roslyn outside Windows: **log the failure in the report** (one line) and continue on
   the structural inventory. Never a silent degradation.
4. Several apps → one report per app **+ a portfolio synthesis**.

## Per-app report format

1. **Identity card** — era (the script's `era`), active period, projects, size (files/LOC),
   tests.
2. **UI surface** — `xamlPages`, `xamlControls`, `locCodeBehind`. Everything is to be rewritten
   (Razor + Tailwind, WCAG 2.1 AA semantics).
3. **Platform APIs** — `windowsApiClusters` → web equivalent (table below) → cost.
4. **Extractability** — `locLogic` vs `locTotal`: pure logic (models, services, algorithms) ports
   **as-is** into a modern .NET class library. That is the central economic argument for the port.
5. **Effort** (formula below) + **recommended target** (static WASM if self-contained content;
   WASM + backend proxy if external APIs with keys; Server if strong server-side state; Hybrid if
   residual native need).
6. **Risks & cost of inaction** — non-installable platform, dead distribution (Store), knowledge
   debt, archived dependencies.

## Effort formula (days)

| Item | Cost |
|-------|------|
| Base per app (Blazor + Tailwind project, CI, review) | 3 d |
| Per XAML page | 1.5 d |
| Per custom control | 1 d |
| Per platform API cluster | HttpClient: 0 · Storage → localStorage/IndexedDB: 0.5 d · ApplicationModel/UI chrome: 1 d · Notifications/tiles → Web Push: 2 d · native Media/Devices: 2 d or an accepted drop |
| Pure logic ported as-is | 0 d |
| No existing tests | +20% (characterization tests on the ported logic) |

Range shown: **±30%**. Always show the calculation.

**Dual costing is mandatory.** The formula above produces **human-team-days**: that is the cost
avoided, not the price of execution. The pipeline's measured actual runs on the order of
**half an hour per app** (chords: 18 min; fleurs-du-mal: ~30 min). Every audit shows both numbers
side by side — "team equivalent: N d (±30%) · pipeline execution: ~M min, calibrated on measured
waves". Either number alone would be either noise (a three-orders-of-magnitude systematic error)
or unsellable (minutes with no frame of reference).

**Skeleton projects.** `audit-inventory.sh` flags near-empty projects (≤ 1 real file or < 30 LOC)
as `skeleton: true`: they **never** count toward the portable-logic share nor toward the cost
estimate — a "layered architecture" can be nothing but scaffolding.

**Premises verified, never inferred** (wave-3 lesson — the pokedexg audit got this wrong twice):

- **The TFM tells the truth, not the package versions.** `projectDetails[].targetFramework` comes
  from the csproj; `zombie: true` flags an old TFM (netcoreapp1/2, netstandard1, PCL, UAP) where an
  update bot pushes package bumps 10+. A netcoreapp1.0 webservice watered by Renovate had been
  audited as "backend already modern, keep as-is" — it had not compiled in years and had **never
  been wired to the frontend**. An update bot is not a sign of life.
- **Tests exist when `hasTests` says so** (`[Fact]`/`[Test]` attributes found in the code), never
  because a project named "Tests" lingers in a `.sln` — pokedexg's referenced a test project
  deleted years ago (a dangling reference).
- **A data flow is proven by a call**: look for the HttpClient (or equivalent) that consumes the
  assumed API before writing "frontend wired to backend" in an audit.

## Windows → web API mappings

| Cluster | Blazor/web equivalent |
|---------|----------------------|
| `Windows.UI.Xaml` / `System.Windows` | Razor + Tailwind components (rewrite) |
| `Windows.Storage` | `localStorage` / IndexedDB / backend API |
| `Windows.Networking` / `System.Net.Http` | `HttpClient` (often portable as-is) |
| `Windows.ApplicationModel` (lifecycle, tiles) | PWA (manifest, service worker) |
| `Windows.UI.Notifications` | Web Push / Notifications API |
| `Windows.Media` | `<audio>`/`<video>` + JS interop |
| `Windows.Devices` / sensors | Web APIs (Geolocation, etc.) or an accepted drop |
| `Microsoft.Phone.*` | No direct equivalent — mobile-first PWA rewrite |

## Portfolio synthesis

- Table: app · era · pages · reusable logic LOC · effort (d) · target · value.
- **Value/effort matrix** and migration order: quick wins first (small UI surface, portable logic,
  demonstrable value).
- Totals and a proposed first wave (2-3 apps).
