# Changelog

## Consumer-impacting changes

### 4.0.0

- **Breaking**: fetched and searched text is stored once, on disk, under `~/.pi/agent/kendex/sessions/<session>/pi-web-tools/content/`. The session record, the `web_fetch` details (`stored`) and the `get_web_content` details now carry the id, title, URL, metadata, `contentLength` and the `sessionId` of the session that stored the text, not the text. A forked session reads its parent's ids from the parent's directory. Text stored in a session by an earlier version cannot be read with `get_web_content`, which fails with `Stored content text gone: <id>`, as it does for any recorded id whose file was deleted.
- **Breaking**: the `web_search`, `code_search`, `web_answer`, `web_find_similar` and `web_research` details carry each result's title, URL, published date and content id, not its text, summary or highlights, and no longer carry the raw provider response (`raw`) or its request `metadata`. `code_search` details no longer carry the code context text, and `web_search` details no longer carry the Perplexity or Gemini answer, which stays in the tool output. `web_research` details and its session entry carry `metadata` with the research mode, Exa type and query and source counts only, not the request bodies, which hold the text of every context file. The raw metadata file keeps the full metadata; `web_research` writes it when `outputPath` is given with a `reportFormat` other than `json`, or when `rawOutputPath` is given without `outputPath`. Any other call keeps the full metadata nowhere.
- At most 8,388,608 characters of stored text are held in memory, least recently read dropped first; a dropped item is read from disk again when requested. One item larger than that bound by itself is still held until the next item is stored. Memory is cleared when a session starts or ends.
- A session's stored text is deleted once the session's working directory is gone (a merged worktree), and any stored file older than 5 days is deleted, when the next session starts.

### 3.1.0

- `web_fetch` streams each page, GitHub file, README and Jina Reader body and stops reading at 8 MB. The stored item then carries `bodyTruncatedAtBytes` and `bodyTruncatedBy` in its metadata, the preview reads `source cut at N bytes`, and `get_web_content` labels the item `source cut at N bytes` instead of `full` and names the cut in the text it returns. A PDF over 32 MB is refused with its size named instead of being loaded whole.
- Each `web_fetch` call has a 64 MB byte budget for those bodies and files. The URL that crosses it is cut at the bytes left, and its preview says the call budget cut it; a PDF there is refused. Each later URL fails with `web_fetch byte budget exhausted`, or goes to the Exa fallback given an Exa key and a provider other than `http`; the URLs fetched before it are still returned.
- Concurrent `web_fetch` calls share a 64 MB in-flight byte budget. A read waits for room instead of being cut; a read that waits past 60 seconds fails its URL with the in-flight budget named, as a URL past the call budget does. A page or file body read now fails with `web_fetch body stalled` after 30 seconds with no data, and a body with no declared length that reaches its ceiling is cut there without waiting for more.
- Files from the GitHub clone cache are sized before they are read and read without blocking Pi. A committed symlink that resolves outside the clone is no longer followed: its target is never read, sized or listed. `readBlobFromCache`, `readReadmeFromCache` and `readTreeFromCache` are async; the first two take the URL's reads from the call's byte budget.
- Scanned PDF pages are rasterized within a 4-megapixel budget per page. The DPI of the whole document is lowered until its largest page fits, so one large page lowers the DPI of every page, and the crop box `pdfinfo` measures is the box rendered.
- HTML conversion removes script, style, noscript and svg blocks in one pass, then rewrites the other tags in one scan, and builds its text once. A 5 MB page with many navigation boxes no longer stalls Pi while it is converted.
- The unused `fetchPdfText` and `fetchLocalPdfText` exports are removed; they read a PDF whole with no size limit.

### 3.0.2

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk. The resolved settings, `op://` keys included, are kept while no settings, `.env` or private config file changes, so `op read` runs once per change instead of on every provider request. A reference that did not resolve is tried again after one second.

### 3.0.1

- The npm install and uninstall helper reports each refusal as an `append-system: <key>=<value>` line followed by the explanation, and an appendSystem source that cannot be read is reported and skipped instead of throwing.

### 3.0.0

- `web_fetch` stays in the active tool set without an Exa API key. Its direct HTTP, GitHub clone, PDF and YouTube transcript paths need no key, and the Exa `/contents` fallback is skipped when the key is unset. The Exa-only tools (`web_research`, `web_answer`, `web_find_similar`, `code_search` and their `_exa` aliases) remain gated on the key.
- **Breaking**: `buildWebFetchToolResult` takes an options object only; the numeric `maxCharacters` positional form and the trailing page-images argument are removed. Callers pass `{ maxCharacters, pageImages }` instead.
- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-web-tools"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-web-tools"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-web-tools.installed`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.3.2

- YouTube transcript requests now fetch complete native caption tracks through `youtube-transcript-plus`, preserve every caption segment with `[HH:MM:SS]` timestamps, decode HTML entities, and store the full transcript under the returned content id.
- `web_fetch` adds `videoMode` (`auto`, `transcript`, `understand`) and `transcriptLanguage` inputs. `auto` routes transcript/verbatim/caption prompts to native captions and other video prompts to Gemini.
- Failed YouTube transcript extraction no longer silently falls through to Exa `/contents`, which ignored the video prompt and returned a provider-capped 6,000-character page excerpt. Non-transcript YouTube requests retain Exa page-content fallback when Gemini understanding is unavailable.
- Mixed URL batches now return stored successes plus provider-attributed per-URL failures instead of throwing after hiding already-stored content ids. Failure rows and blocks stay bounded even with explicit preview caps, Exa HTTP-200 per-URL statuses are reconciled, and cancellation preserves `AbortError` identity.
- Gemini Web stream parsing now selects the latest non-empty streamed candidate instead of stopping at the first candidate container, fixing empty-response failures against current response envelopes.
- Unspecified transcript language now preserves YouTube's first-track fallback; explicit language requests recover case-insensitive regional matches, transcript metadata records the selected track, and caption fetches honor caller timeouts. HTML entities decode in one pass, with invalid numeric scalars retained literally.
- Exa empty-success documents and missing requested URLs now surface as failures, status matching normalizes both URL and id fields, mixed transcript conflicts no longer abort unrelated URLs, and unresolved Gemini card placeholders no longer replace a genuine streamed answer.
- Native caption extraction invoked through `web_fetch` now has a 120-second default timeout, and auto transcript detection recognizes common forms such as transcriptions, captioning, and subtitling.
- Mostly-failed batches size successful previews from the content actually stored while retaining the original request-size aggregate cap. Exa content reconciliation accepts safe scheme/`www` canonicalization and result ids. Anonymous results use positions only for all-anonymous or position-preserving mixed responses, with single-result inference when one anonymous result and one request remain; ambiguous mixed responses stay failed instead of being misattributed.
- Explicit YouTube `understand` mode now preserves the caller's prompt unchanged for both Gemini Web and API paths instead of appending transcript-format instructions.

### 1.3.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
