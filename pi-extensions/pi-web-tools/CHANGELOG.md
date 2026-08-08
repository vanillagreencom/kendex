# Changelog

## Consumer-impacting changes

### 1.3.2

- YouTube transcript requests now fetch complete native caption tracks through `youtube-transcript-plus`, preserve every caption segment with `[HH:MM:SS]` timestamps, decode HTML entities, and store the full transcript under the returned content id.
- `web_fetch` adds `videoMode` (`auto`, `transcript`, `understand`) and `transcriptLanguage` inputs. `auto` routes transcript/verbatim/caption prompts to native captions and other video prompts to Gemini.
- Failed YouTube extraction no longer silently falls through to Exa `/contents`, which ignored the video prompt and returned a provider-capped 6,000-character page excerpt.
- Mixed URL batches now return stored successes plus provider-attributed per-URL failures instead of throwing after hiding already-stored content ids. Failure output obeys the same aggregate caps as previews, Exa HTTP-200 per-URL statuses are reconciled, and cancellation preserves `AbortError` identity.
- Gemini Web stream parsing now selects the latest non-empty streamed candidate instead of stopping at the first candidate container, fixing empty-response failures against current response envelopes.

### 1.3.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
