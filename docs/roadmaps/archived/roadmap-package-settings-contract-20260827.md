# Roadmap — package-settings-contract

Created 2026-08-27. Owner-approved at the plan gate; .env layer dropped everywhere (KEN-560 absorbed into KEN-702).

**Plan data**: docs/roadmaps/roadmap-package-settings-contract.json **Spec**: docs/plans/package-settings.md (full text: Linear "Package Settings" project overview)

| # | Issue | Title | Est | Pri | Deps |
|---|-------|-------|-----|-----|------|
| 1 | KEN-702 | Align every vendored settings resolver to one precedence contract with [env]-only reads | 3 | P1 | — |
| 2 | KEN-703 | Publish the settings authoring contract and delete the root example | 3 | P2 | KEN-702 |
| 3 | KEN-704 | Add the strict settings-template parser with marketplace-check findings and shared-key conflict notes | 3 | P2 | KEN-703 |
| 4 | KEN-705 | Package settings in the Customize UI (bundle parent) | — | P2 | KEN-704 |
| 5 | KEN-706 | Compose settings reads and edits into core planning as one save transaction | 5 | P2 | parent KEN-705 |
| 6 | KEN-707 | Add the package Settings section to the Customize UI | 3 | P3 | KEN-706, parent KEN-705 |

Cancelled: KEN-560 (absorbed into KEN-702). Related: KEN-706↔KEN-604, KEN-707↔KEN-582.
