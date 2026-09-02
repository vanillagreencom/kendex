# Review-gate settings

All keys resolve environment-first, then `.env.local` (`KEY=value` dotenv
shape, parsed, never sourced), then `.kendex/settings.toml`, then the repo's
`kendex.settings.toml`, then the built-in default (`REVIEW_GATE_SETTINGS_FILE`
overrides the settings files and consults only itself, e.g. in tests). The
one exception is `REVIEW_GATE_MODE`, which skips the dotenv layer — see its
row. A `.env` file is never read. List values pack into one string with `;`
separators.
Commented defaults ship in this skill's `kendex.settings.toml.example`;
per-repo wiring and values: [adoption.md](adoption.md).

A repo checks its own resolved values with
`.agents/skills/review-gate/scripts/validate.sh`, which reconciles the
carry-forward exclusions against tracked paths and names any key the engine
does not read. It judges no value itself: every rule below is the engine's,
reached through `review-predicate.sh --check-config`, so the tool cannot
drift from what the gate actually reads. The parser reads ONE key shape — the bare name at the start of
its own line, followed by its own `=`. Everything else is unsupported syntax
that resolves to nothing, so `validate.sh` reports any line carrying a
`REVIEW_GATE_` token in another shape, string values included, and refuses a
settings file that is a symlink, whose target's bytes are not what CI checks
out. `review-predicate.sh --check-config` is the value-rule half
alone: it validates every key below and exits without reading evidence or
needing a PR.

## Reading the pending status

`no review evidence at <sha> yet` is the whole `awaiting` verdict. It names the
head and nothing else; a GitHub status description has only 140 characters,
so this file names the sources that can open the gate. Act on those settings,
not on the pending state. Where the configured sources are bots and one has
already reviewed this head, dispatch the writer instead of waiting.

Script-consumed keys are read from the `[env]` table only: an assignment
under any other table (or above the first header) is ignored, and
`validate.sh` reports it. Values are single-line double-quoted strings with
no `"` and no `\` (the kendex settings contract). The parser fails loud when
the same name is assigned more than once inside `[env]`, and on any
`[`-leading line that is not a lone `[name]` header — an unparsed header
would silently misfile every assignment after it.

| Key | Default | Meaning |
|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | Gate commit-status context (the required check name). |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | (empty) | Clean-analysis check-run/status names; either API counts, and on both the NEWEST row/run per name decides. Empty disables the source. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | `rate limited;skipped;queued` | Case-insensitive substrings marking a trusted "pass" as analysis-not-run → not evidence. Empty disables. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | (empty) | `login:binding-pattern` pairs; first `:` splits; pattern is a literal prefix. Empty disables the source. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | Shortest sha prefix a comment may bind (4–40). |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | `kendex-reviewer-outage` | Operator override status context, resolved by `.agents/skills/review-gate/scripts/review-predicate.sh` itself so every live gate read honors it. The override's status description must carry a non-empty REASON (enforced; shown in the gate detail). Empty disables the override source. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | (empty) | Commit-status creator logins that are never evidence, on both the trusted-context and override reads (typically `github-actions[bot]`). While this list is configured, a status with NO creator login is not evidence. Empty disables (the shipped default). Configuring it requires the override to be posted by a non-Actions identity (operator PAT). |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | Review-object trust list. Empty = any non-author. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` counts any accepted review row; `approved` requires an APPROVED not withdrawn by a later CHANGES_REQUESTED from the same login. |
| `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | `encountered an error and was unable to review` | Case-insensitive substrings marking a review row's BODY as an errored-run attestation → not evidence and never a carry candidate. Matched at the start of the body only (first line, after trimming whitespace and markdown quote markers): a review that quotes a pattern in later text is still evidence. Patterns can never reach past line one — when adopting a new reviewer bot or after a bot update, verify the configured marker still appears in the first line of its errored-run body. Never a blocker: the changes-requested reduction ignores this list. A configured value replaces the default list. Empty disables. |
| `REVIEW_GATE_THREADS` | `enforce` | `enforce` fails closed on unresolved review threads; `off` skips the reviewThreads GraphQL read and never emits `threads-open` — only for repos with a server-side zero-bypass `required_review_thread_resolution` ruleset. Only the thread term is disabled; evidence and changes-requested still fail closed. |
| `REVIEW_GATE_API_ATTEMPTS` | `1` | Bounded retries per evidence read in the predicate. Failing through every attempt is exit 2 (no verdict). |
| `REVIEW_GATE_API_RETRY_DELAY_SECONDS` | `2` | Pause between retry attempts. |
| `REVIEW_GATE_CARRY_FORWARD` | (empty) | Carry-safe delta classes (`docs`, `comments`, `vendored`; `;` or `\|` separated; empty = off, exact-head evidence only). `vendored` carries every delta file under a path `REVIEW_GATE_VENDORED_PATHS` names, whatever its extension or status (a rename carries only when both its names are under the set): the repository's committed kendex render trees, trusted as kendex output without review of their bytes. The engine's full contract — class definitions, the newest-ancestor rule, refusal conditions, the line-lexical `comments` caveat — is in `review-predicate.sh --help`. |
| `REVIEW_GATE_VENDORED_PATHS` | (empty) | Path globs (`;`-separated) naming the kendex render trees the `vendored` class carries, e.g. `.agents/*;.claude/skills/*`. Same closed grammar and matcher as `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which outranks it on a shared path; read from the default-branch checkout like every setting, so the PR under judgment cannot widen it. A hand-edit under a listed path rides, so policy-bearing paths (hook scripts, agent instruction markdown) belong in the exclusion list. A renamed file carries only when both its names are under the set. Configuration errors (exit 2, also under `--check-config`): an unsupported spelling, the class enabled over an empty set, an entry naming no literal path text (`*`, `*/*`, `*.*`). |
| `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` | (empty) | Path globs that disqualify a carry, forcing fresh evidence (use for policy-bearing markdown such as `AGENTS.md` and instruction files under `.github/`). Glob semantics and carry interaction: `review-predicate.sh --help`. Inert while `REVIEW_GATE_CARRY_FORWARD` is empty. Spelling is judged by the ENGINE, which owns the matcher, and the grammar is CLOSED: path characters plus `*`, matched against repository-relative names. `review-predicate.sh` refuses anything else as a configuration error — the `[`, `]`, `\` and `?` metacharacters, and a leading `/`, a trailing `/`, or a `.`, `..` or empty path component. A closed grammar is what ends the equivalence hunt: `[.]` and `\.` respell the `.` component the structural rules reject, so the spelling is refused rather than analysed. The refusal runs before any evaluation, so a rejected spelling never reaches the matcher. `validate.sh` relays that verdict and adds what needs the tree: an all-wildcard entry such as `*`, and a glob matching no tracked path. |
| `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` | (empty) | Exclusion globs (`;`-separated, exact glob text) DECLARED to match no tracked path yet. `validate.sh` fails an exclusion glob matching nothing in the repository unless it is declared here, and reconciles the ledger in both directions: a declaration that is not an exact member of the active exclusion list is an orphan, and a declaration whose glob now matches tracked paths is stale. Read by BOTH: `review-predicate.sh` loads it on every invocation and runs the pattern-grammar check over it, so an unsupported spelling declared here is a configuration error (exit 2) like any other; the ledger reconciliation itself is `validate.sh`'s. Inert while `REVIEW_GATE_CARRY_FORWARD` is empty. |
| `REVIEW_GATE_MODE` | `enforce` | The one-switch per-repo gate disable. `enforce` is full behavior. `off` makes the predicate answer `approved` with the attestation detail `review gate disabled by settings (REVIEW_GATE_MODE=off)` before ANY evidence read — zero API traffic, no evidence model, no thread term; the writer converges the required status to success and this context stops blocking the queue (a server-side `required_review_thread_resolution` rule still blocks on open threads). Merge-group statuses never read the mode and always post success as `merge-queue entry: post-approval by construction`. Unknown values are a config error (exit 2). Orch's submit flow reads the same key and skips its reviewer wait when `off`. RESOLUTION BOUNDARY: engine-only sources on BOTH sides — the engine and orch's `approval-wait --resolve-mode` each read process env and the COMMITTED `kendex.settings.toml` only, never `.env.local` or the machine-local `.kendex/settings.toml` (unlike `PR_REVIEW_WAIT_SECS`): CI's checkout carries neither local file, so a local value cannot split the waiter from the gate. Set it in `kendex.settings.toml` or export it. |
| `PR_REVIEW_WAIT_SECS` | `900` | Review-wait quiet period in seconds — a non-negative integer of at most 9 digits after leading zeros; `.agents/skills/review-gate/scripts/pr-watch.sh` treats any other value (empty, `90s`, negative, out of range) as a configuration error (exit 2). SHARED with the orch skill (approval-wait's absent-positional budget). Read by `pr-watch.sh` as the `awaiting-stale` threshold. RESOLUTION BOUNDARY: none left for this key — review-gate scripts and orch both resolve env > `.env.local` > `.kendex/settings.toml` > `kendex.settings.toml` > default. Set it in `kendex.settings.toml` or export it. |

`REVIEW_GATE_CHECK_RUN_NAME` is NOT a settings key either: it is a GitHub
repository variable, read by the writer workflow's relay `if:` before any
checkout exists, and it names the reviewer check the opt-in `check_run`
trigger relays on. Wiring: [adoption.md](adoption.md).

Two env-only PER-INVOCATION seams are NOT settings keys:

- `REVIEW_GATE_SETTINGS_FILE` — overrides the settings-file path (e.g. in
  tests, or a caller resolving settings for a different checkout).
  Set-but-empty is unset: `""` names no file, so the default sources apply.
  Falling back to built-in defaults covers an ABSENT PLAIN FILE only: a path that
  exists as a directory, FIFO, socket or device, a symlink that does not
  resolve, or a file that exists but cannot be READ is a configuration
  error every reader fails loud on. A symlink that resolves to a readable
  regular file reads normally. `/dev/null` is the one exempt path — the
  handle for forcing defaults.
- `REVIEW_GATE_STATUS_SNAPSHOT_FILE` — path to a caller-supplied status
  snapshot the predicate evaluates instead of fetching statuses itself.
  Snapshot shape, the list-endpoint-only rule, and refusal conditions:
  `review-predicate.sh --help`.

# Security posture

The one workflow that writes the gate status runs the DEFAULT-branch engine
on every leg that runs it, with credentials-dropped checkouts, and reads PR
data only through the API; no PR-controlled code ever executes with the
write-capable token and no trust-posture knob exists. The PR-attached legs
reach a relay that checks out nothing and executes no engine. A PR that
repairs a broken engine cannot open its own gate — it merges via the
ruleset's bypass actor. Wiring: [adoption.md](adoption.md).
