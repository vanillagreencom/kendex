# Changelog

## Consumer-impacting changes

### 1.8.0

- Pi 0.84.0 parity: session auto-rename now forwards `null` provider headers unchanged. `ModelRegistry.getApiKeyAndHeaders()` returns `ProviderHeaders` (`Record<string, string | null>`) where `null` is a header-deletion marker pi-ai acts on; `headerRecord()` dropped those entries, silently re-sending headers Pi asked to remove. `headerRecord()` is now exported and preserves `null` while still dropping empty and non-string values.

### 1.7.5

- Long-session budget guard now gives Pi's built-in post-response compaction first chance, avoiding duplicate `Already compacted` failures.
- Successful compaction suppresses repeat attempts at the same threshold until usage falls below the guard or advances to a new threshold; unrelated failures still surface and retry normally.
- Minimum supported Pi version is now 0.80.4 for long-session budget guard support.
- Active budget-guard compaction now finishes before terminal settlement or one-shot pane shutdown can overtake it. Delayed activity from a replaced session is ignored instead of changing the current session's guard state.

### 1.7.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
