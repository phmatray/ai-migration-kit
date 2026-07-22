# LegacyShop — deliberately legacy demo fixture

A small order-processing solution frozen in time, used to demonstrate and regression-test the AI Migration Kit. **Do not modernize this code in place** — it is the pipeline's input fixture. Run the kit against a copy (see `docs/demo-walkthrough.md` at the repo root).

## What is deliberately wrong

- Targets **net6.0** (out of support since November 2024).
- `WebClient` in `PriceCatalogClient` → `SYSLIB0014` obsolete warning, sync-only I/O.
- No nullable annotations, no implicit usings, block-scoped namespaces, manual `for` loops, string concatenation.
- Order status is a raw `string` ("Pending" / "Paid" / "Shipped").
- Classic `static void Main` entry point.
- Old test stack pins (xunit 2.4.x, Test SDK 17.3).

## Run it

```bash
dotnet build
dotnet test
dotnet run --project src/LegacyShop.App
```

All green on the legacy TFM — that's the point: the kit migrates *working* software and proves it still works after.
