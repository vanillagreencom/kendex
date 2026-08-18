# Changelog

## Consumer-impacting changes

### 1.7.2

- Documentation only, no runtime change: the packaged README is trimmed to the consumer contract — what the extension does, its settings, and setup — with contributor-facing internals moved to `DEVELOPMENT.md`, which is not published. Republished so the npm and pi.dev gallery pages carry the current copy. The manifest also gains a `test` script (`bun test ./extensions/__tests__`), which the repo's CI and `tools/validate-changed` now run.

### 1.7.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
