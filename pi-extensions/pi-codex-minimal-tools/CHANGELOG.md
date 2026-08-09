# Changelog

## Consumer-impacting changes

### 1.3.0

- Pi 0.84.0 parity: `null` provider headers are now treated as deletion markers. `ModelRegistry.getApiKeyAndHeaders()` returns `ProviderHeaders` (`Record<string, string | null>`) where `null` means "remove this header"; the background image-generation request passed them to `Headers.set()`, which stringified them and transmitted the literal `"null"`. `buildHeaders()` is now exported and deletes on `null`.
- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
