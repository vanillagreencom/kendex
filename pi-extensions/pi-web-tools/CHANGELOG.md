# Changelog

## Consumer-impacting changes

### 1.3.2

- YouTube transcript requests now fetch complete native caption tracks through `youtube-transcript-plus`, preserve every caption segment with `[HH:MM:SS]` timestamps, decode HTML entities, and store the full transcript under the returned content id.
- `web_fetch` adds `videoMode` (`auto`, `transcript`, `understand`) and `transcriptLanguage` inputs. `auto` routes transcript/verbatim/caption prompts to native captions and other video prompts to Gemini.
- Failed YouTube transcript extraction no longer silently falls through to Exa `/contents`, which ignored the video prompt and returned a provider-capped 6,000-character page excerpt. Non-transcript YouTube requests retain Exa page-content fallback when Gemini understanding is unavailable.
- Mixed URL batches now return stored successes plus provider-attributed per-URL failures instead of throwing after hiding already-stored content ids. Failure rows and blocks stay bounded even with explicit preview caps, Exa HTTP-200 per-URL statuses are reconciled, and cancellation preserves `AbortError` identity.
- Gemini Web stream parsing now selects the latest non-empty streamed candidate instead of stopping at the first candidate container, fixing empty-response failures against current response envelopes.
- Unspecified transcript language now preserves YouTube's first-track fallback; explicit language requests recover case-insensitive regional matches, transcript metadata records the selected track, and caption fetches honor caller timeouts. HTML entities decode in one pass, with invalid numeric scalars retained literally.
- Exa empty-success documents and missing requested URLs now surface as failures, status matching normalizes both URL and id fields, mixed transcript conflicts no longer abort unrelated URLs, and unresolved Gemini card placeholders no longer replace a genuine streamed answer.
- Native caption extraction invoked through `web_fetch` now has a 120-second default timeout, and auto transcript detection recognizes common forms such as transcriptions, captioning, and subtitling.
- Mostly-failed batches size successful previews from the content actually stored while retaining the original request-size aggregate cap. Exa content reconciliation accepts safe scheme/`www` canonicalization, result ids, and missing-URL positional responses without merging unrelated results.

### 1.3.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
