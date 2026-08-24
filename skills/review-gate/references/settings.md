# Review-gate settings

All keys resolve environment-first, then the repo's `kendex.settings.toml`,
then the built-in default (`REVIEW_GATE_SETTINGS_FILE` overrides the file
path, e.g. in tests). List values pack into one string with `;` separators.
Commented defaults ship in this skill's `kendex.settings.toml.example`;
per-repo wiring and values: [adoption.md](adoption.md).

Script-consumed keys are matched file-wide by exact name, regardless of the
enclosing TOML table. Every such key name is reserved across the whole file:
keep these names out of unrelated tables. The parser fails loud when the same
name is assigned more than once anywhere in the file.

| Key | Default | Meaning |
|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | Gate commit-status context (the required check name). |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | (empty) | Clean-analysis check-run/status names; either API counts, and on both the NEWEST row/run per name decides. Empty disables the source. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | `rate limited;skipped;queued` | Case-insensitive substrings marking a trusted "pass" as analysis-not-run → not evidence. Empty disables. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | (empty) | `login:binding-pattern` pairs; first `:` splits; pattern is a literal prefix. Empty disables the source. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | Shortest sha prefix a comment may bind (4–40). |
| `REVIEW_GATE_OUTAGE_CONTEXT` | `kendex-reviewer-outage` | LEGACY name for the operator override status context (below). Still read by the predicate; new installs and the shipped examples set only `REVIEW_GATE_OVERRIDE_CONTEXT`. Empty disables. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | (absent = fall back to `REVIEW_GATE_OUTAGE_CONTEXT`) | v2 name for the operator override status context, resolved by `.agents/skills/review-gate/scripts/review-predicate.sh` itself. When present anywhere (env or settings file) it wins over `REVIEW_GATE_OUTAGE_CONTEXT`. The override's status description must carry a non-empty REASON (enforced; shown in the gate detail). Empty disables the override source. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | (empty) | Commit-status creator logins that are never evidence, on both the trusted-context and override reads (typically `github-actions[bot]`). While this list is configured, a status with NO creator login is not evidence. Empty disables (the shipped default). Configuring it requires the override to be posted by a non-Actions identity (operator PAT). |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | Review-object trust list. Empty = any non-author. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` counts any accepted review row; `approved` requires an APPROVED not withdrawn by a later CHANGES_REQUESTED from the same login. |
| `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | `encountered an error and was unable to review` | Case-insensitive substrings marking a review row's BODY as an errored-run attestation → not evidence and never a carry candidate. Never a blocker: the changes-requested reduction ignores this list. A configured value replaces the default list. Empty disables. |
| `REVIEW_GATE_THREADS` | `enforce` | `enforce` fails closed on unresolved review threads; `off` skips the reviewThreads GraphQL read and never emits `threads-open` — only for repos with a server-side zero-bypass `required_review_thread_resolution` ruleset. Only the thread term is disabled; evidence and changes-requested still fail closed. |
| `REVIEW_GATE_API_ATTEMPTS` | `1` | Bounded retries per evidence read in the predicate. Failing through every attempt is exit 2 (no verdict). |
| `REVIEW_GATE_API_RETRY_DELAY_SECONDS` | `2` | Pause between retry attempts. The selftest validates the committed value through the predicate; the battery itself replays with the delay pinned to 0. |
| `REVIEW_GATE_CARRY_FORWARD` | (empty) | Carry-safe delta classes (`docs`, `comments`; `;` or `\|` separated; empty = off, exact-head evidence only). With NO evidence at head, a qualifying review object at an ancestor commit N satisfies the evidence term when the N→head diff classifies entirely into the enabled classes — docs-only files (`*.md`/`*.markdown` by extension), or comment-only changes to code files (per-extension comment-token table; added/removed/renamed files, patch-less files, and unknown extensions refuse) — or the trees are identical. Only the NEWEST ancestor candidate decides. Code changes always require fresh evidence; changes-requested / unresolved threads still fail closed with carried evidence. A delta at the compare API's 300-file cap refuses carry. The `comments` classifier is line-lexical (blind to heredocs and multiline strings) — enable `comments` only where that residual risk is acceptable. |
| `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` | (empty) | Path globs (`;`-separated, shell-style; `*` matches `/` too — fnmatch without FNM_PATHNAME) that disqualify a carry: any file in the N→head delta matching an exclusion refuses carry-forward, forcing fresh evidence. Use for policy-bearing markdown (`AGENTS.md`, instruction files under `.github/`). Non-matching deltas still carry; identical-tree carries are unaffected. Inert while `REVIEW_GATE_CARRY_FORWARD` is empty. An all-wildcard entry such as `*` fails the selftest — narrow the exclusions or disable the carry class. |
| `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` | (empty) | Exclusion globs (`;`-separated, exact glob text) DECLARED to match no tracked path today. The selftest fails an exclusion glob that matches nothing in the repository unless declared here. A glob matching tracked paths only OUTSIDE the enabled carry classes must NOT be declared here. Whenever declarations exist: an entry that is not an exact member of the active exclusion list FAILs (every mode); an entry whose glob now matches tracked paths FAILs (tracked mode). An EMPTY `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` with declarations FAILs on the membership rule. Read by the selftest only. Inert while `REVIEW_GATE_CARRY_FORWARD` is empty. |
| `REVIEW_GATE_MODE` | `enforce` | The one-switch per-repo gate disable. `enforce` is full behavior. `off` makes the predicate answer `approved` with the attestation detail `review gate disabled by settings (REVIEW_GATE_MODE=off)` before ANY evidence read — zero API traffic, no evidence model, no thread term; the writer converges the required status to success and this context stops blocking the queue (a server-side `required_review_thread_resolution` rule still blocks on open threads). Merge-group statuses never read the mode and always post success as `merge-queue entry: post-approval by construction`. Unknown values are a config error (exit 2). Orch's submit flow reads the same key and skips its reviewer wait when `off`. RESOLUTION BOUNDARY: engine-only sources on BOTH sides — the engine and orch's `approval-wait --resolve-mode` each read process env and `kendex.settings.toml` only, never `.env`/`.env.local` (unlike `PR_REVIEW_WAIT_SECS`), so a dotenv value cannot split the waiter from the gate. Set it in `kendex.settings.toml` or export it. |
| `PR_REVIEW_WAIT_SECS` | `900` | Review-wait quiet period in seconds — a non-negative integer of at most 9 digits after leading zeros; `.agents/skills/review-gate/scripts/pr-watch.sh` treats any other value (empty, `90s`, negative, out of range) as a configuration error (exit 2). SHARED with the orch skill (approval-wait's absent-positional budget). Read by `pr-watch.sh` as the `awaiting-stale` threshold. RESOLUTION BOUNDARY: review-gate scripts resolve env > `kendex.settings.toml` > default; orch additionally reads `.env`/`.env.local`. Set this key in `kendex.settings.toml` or export it — a `.env`-only value reaches orch but not the watcher. |

Two env-only PER-INVOCATION seams are NOT settings keys:

- `REVIEW_GATE_SETTINGS_FILE` — overrides the settings-file path (e.g. in
  tests, or a caller resolving settings for a different checkout). Falling
  back to built-in defaults covers an ABSENT PLAIN FILE only: a path that
  exists as a directory, FIFO, socket or device, a symlink that does not
  resolve, or a file that exists but cannot be READ is a configuration
  error every reader fails loud on. A symlink that resolves to a readable
  regular file reads normally. `/dev/null` is the one exempt path — the
  handle for forcing defaults.
- `REVIEW_GATE_STATUS_SNAPSHOT_FILE` — path to a status snapshot (JSON
  object with a `statuses` array and a top-level `sha` equal to the
  invocation's `HEAD_SHA`) the CALLER already holds. The rows must come
  from the per-commit statuses LIST endpoint (`/commits/<sha>/statuses`).
  The combined endpoint (`/commits/<sha>/status`) is NOT a valid source;
  while `REVIEW_GATE_STATUS_PUBLISHER_REJECT` is configured, the seam
  refuses a snapshot containing login-less rows (exit 2). Merge every
  page's rows into one `statuses` array under a top-level `sha`. When set,
  the predicate evaluates trusted-context and outage evidence against it
  instead of fetching the statuses itself. A snapshot for another head is
  refused. An unreadable, malformed, or wrong-head snapshot gets the read
  contract: exit 2, no verdict.

# Security posture

The one workflow that writes the gate status runs the DEFAULT-branch engine
on every leg that runs it, with credentials-dropped checkouts, and reads PR
data only through the API; no PR-controlled code ever executes with the
write-capable token and no trust-posture knob exists. The PR-attached legs
reach a relay that checks out nothing and executes no engine. A PR that
repairs a broken engine cannot open its own gate — it merges via the
ruleset's bypass actor. Wiring: [adoption.md](adoption.md).
