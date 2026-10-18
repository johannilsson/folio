# Drift reviews

A weekly review of design drift and maintainability in Folio. Each run adds a dated file to this folder (`YYYY-MM-DD.md`) and one new row to this table. The pinned "Drift review" issue always holds the latest run's summary.

| Date | Trend | Top finding | Opened | Closed |
|---|---|---|---|---|
| [2026-10-18](2026-10-18.md) | Baseline: stable | The page saves the whole sidecar from its own copy, which can drop an agent's concurrent writes | [#22](https://github.com/johannilsson/folio/issues/22), [#23](https://github.com/johannilsson/folio/issues/23) | none |

## How to read a review

- Each review ranks at most 5 findings, and each finding says whether it is **small** or **needs design**.
- Each small finding gets a `refactor-candidate` issue. Findings that need design stay on the review page.
- A `refactor-candidate` issue is closed if it is no longer valid, or if nobody has touched it for three reviews.
