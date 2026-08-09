# Review-gate settings

All keys resolve environment-first, then the repo's `vstack.settings.toml`,
then the built-in default (`REVIEW_GATE_SETTINGS_FILE` overrides the file
path, e.g. in tests). List values pack into one string with `;` separators.
Commented defaults ship in this skill's `vstack.settings.toml.example`;
per-repo wiring and values: [adoption.md](adoption.md).

Script-consumed keys are matched file-wide by exact name, regardless of the
enclosing TOML table — that is how assignments under an adopter's `[env]`
table resolve at all. Every such key name is therefore reserved across the
whole file: a same-named key under an unrelated table would be read as the
gate setting, so keeping these names out of unrelated tables is the
adopter's responsibility. The parser fails loud on the one detectable
ambiguity — the same name assigned more than once anywhere in the file.

| Key | Default | Meaning |
|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | Gate commit-status context (the required check name). |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | (empty) | Clean-analysis check-run/status names; either API counts, and on both the NEWEST row/run per name decides (a newer pending/failed/skip-marked round withdraws the older success). Empty disables the source — trust is opt-in per repo, never a shipped vendor default. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | `rate limited;skipped;queued` | Case-insensitive substrings marking a trusted "pass" as analysis-not-run → not evidence. Empty disables. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | (empty) | `login:binding-pattern` pairs; first `:` splits; pattern is a literal prefix. Empty disables the source. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | Shortest sha prefix a comment may bind (4–40). |
| `REVIEW_GATE_OUTAGE_CONTEXT` | `vstack-reviewer-outage` | LEGACY name for the operator override status context (below) — still read by the predicate so existing installs keep working, but new installs and the shipped examples set only `REVIEW_GATE_OVERRIDE_CONTEXT`. Empty disables. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | (absent = fall back to `REVIEW_GATE_OUTAGE_CONTEXT`) | v2 name for the operator override status context (the outage attestation generalized), resolved by `review-predicate.sh` itself so EVERY live gate read honors it (the writer, consumers' heavy-job gate jobs, the selftest). When the key is present anywhere (env or settings file) it wins over the legacy `REVIEW_GATE_OUTAGE_CONTEXT`; when absent, the legacy resolution applies unchanged — existing repos need no edit. The override's status description must carry a non-empty REASON (enforced; it appears in the gate detail). Empty disables the override source. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | (empty) | Commit-status creator logins that are never evidence, on both the trusted-context and override reads (typically `github-actions[bot]` — the publisher PR content can wield where PR workflows hold `statuses:write`). Statuses are read from the per-commit statuses LIST endpoint, where every real publisher — GitHub Apps included — carries a creator login; while this list is configured, a status with NO creator login is an anomaly and is not evidence. Empty disables (the shipped default) — configuring it requires the override to be posted by a non-Actions identity (operator PAT). |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | Review-object trust list. Empty = any non-author (compatible default). |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` counts any accepted review row; `approved` requires an APPROVED not withdrawn by a later CHANGES_REQUESTED from the same login. |
| `REVIEW_GATE_THREADS` | `enforce` | `enforce` fails closed on unresolved review threads; `off` skips the reviewThreads GraphQL read entirely and never emits `threads-open` — for repos whose thread hygiene is a server-side zero-bypass ruleset (`required_review_thread_resolution`), where the CI-side term is a latency optimization, not the enforcement point of record. Only the thread term is disabled; evidence and changes-requested still fail closed. |
| `REVIEW_GATE_API_ATTEMPTS` | `1` | Bounded retries per evidence read in the predicate. Default = single attempt; failing through every attempt is still exit 2 (no verdict). |
| `REVIEW_GATE_API_RETRY_DELAY_SECONDS` | `2` | Pause between retry attempts. |
| `REVIEW_GATE_CARRY_FORWARD` | (empty) | Carry-safe delta classes (`docs`, `comments`; `;` or `\|` separated; empty = off, exact-head evidence only). With NO evidence at head, a qualifying review object at an ancestor commit N satisfies the evidence term when the N→head diff classifies entirely into the enabled classes — docs-only files (`*.md`/`*.markdown` by extension — a directory rule would carry executable files like `docs/conf.py`), or comment-only changes to code files (conservative per-extension comment-token table; added/removed/renamed files, patch-less files, and unknown extensions refuse) — or the trees are identical (rebase residue). Only the NEWEST ancestor candidate decides. Never a waiver: real evidence must exist and only extends across a delta review would not re-examine; code changes always require fresh evidence, and changes-requested / unresolved threads still fail closed with carried evidence. The compare API caps its file list at 300 entries, so a delta at the cap refuses carry (completeness unprovable), and the `comments` classifier is line-lexical — blind to an enclosing heredoc or multiline string where a full-line `#`/`//`-prefixed change is data — so enable `comments` only where that residual risk is acceptable. |
| `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` | (empty) | Path globs (`;`-separated, shell-style; `*` matches `/` too — fnmatch without FNM_PATHNAME) that disqualify a carry: any file in the N→head delta matching an exclusion refuses carry-forward even when the delta classifies entirely carry-safe, forcing fresh evidence. Built for policy-bearing markdown the `docs` class would otherwise carry — `AGENTS.md`, reviewer/agent instruction files under `.github/` — which is "docs" by extension yet obeyed mechanically by agents. Surgical: non-matching deltas still carry. Identical-tree carries are unaffected (no delta, nothing to exclude). Inert while `REVIEW_GATE_CARRY_FORWARD` is empty. |
| `REVIEW_GATE_MODE` | `enforce` | The one-switch per-repo gate disable (owner decision 2026-08-08). `enforce` is today's full behavior. `off` makes the predicate answer `approved` with the attestation detail `review gate disabled by settings (REVIEW_GATE_MODE=off)` before ANY evidence read — zero API traffic, no evidence model, no thread term — so the writer converges the required status to success and the merge queue admits on CI alone. Every posted status says the gate is disabled, never that a review happened. Unknown values are a config error (exit 2): a typo cannot disable a merge gate. Orch's submit flow reads the same key and skips its reviewer wait entirely when `off`. RESOLUTION BOUNDARY (same as `PR_REVIEW_WAIT_SECS`): set it in `vstack.settings.toml` or export it — orch additionally reads `.env`/`.env.local`, the engine does not, so an env-file-only `off` would skip orch's wait while the writer keeps enforcing (fail-closed, but the PR then waits on a gate the operator thinks is off). |
| `PR_REVIEW_WAIT_SECS` | `900` | Review-wait quiet period in seconds — must be a non-negative integer of at most 9 digits after leading zeros (~31 years); `pr-watch.sh` treats any other value (empty, `90s`, negative, out of range) as a loud configuration error (exit 2), never a silent fallback to the default. SHARED with the orch skill (approval-wait's absent-positional budget). Read by `pr-watch.sh` as the `awaiting-stale` threshold — an un-reviewed head older than this is attention. One key so the watcher and the waiter agree on what "silence too long" means. RESOLUTION BOUNDARY: review-gate scripts resolve env > `vstack.settings.toml` > default; orch additionally reads `.env`/`.env.local`. Set this key in `vstack.settings.toml` (it is public project config, not a secret) or export it — a `.env`-only value reaches orch but not the watcher. |

Two env-only PER-INVOCATION seams are deliberately NOT settings keys:

- `REVIEW_GATE_SETTINGS_FILE` — overrides the settings-file path (e.g. in
  tests, or a caller resolving settings for a different checkout). Which
  file to resolve from is a property of one invocation, never of the repo
  the file itself describes — a settings key naming its own settings file
  would be circular.
- `REVIEW_GATE_STATUS_SNAPSHOT_FILE` — path to a status snapshot (JSON
  object with a `statuses` array and a top-level `sha` equal to the
  invocation's `HEAD_SHA`) the CALLER already holds. The rows must come
  from the per-commit statuses LIST endpoint (`/commits/<sha>/statuses`) —
  the same endpoint the predicate's own fetch path uses: full per-context
  history, real `creator.login` on every row. The combined endpoint
  (`/commits/<sha>/status`) is NOT a valid source — it projects
  latest-per-context and serializes `creator` as null for App-posted rows,
  which `REVIEW_GATE_STATUS_PUBLISHER_REJECT`'s anomaly rule treats as
  not-evidence; while that reject list is configured, the seam refuses a
  snapshot containing login-less rows (exit 2) rather than silently
  dropping real evidence. The caller wraps the rows itself: merge every
  page's rows into one `statuses` array under a top-level `sha` (a
  first-page-only snapshot silently drops later-page evidence). When set,
  the predicate evaluates trusted-context and outage evidence against it
  instead of fetching the statuses itself — a converge-style sweep that
  reads the status list for its own required-status projection stops
  paying that read twice per head. The snapshot is bound to one head at
  one moment, which is why it can never be a repo setting — and the `sha`
  requirement enforces that binding: a snapshot for another head is
  refused. An unreadable, malformed, or wrong-head snapshot gets the read
  contract: exit 2, no verdict.

# Security posture

Workflows that execute repository-controlled code with a write-capable token
are the gate's own attack surface: a malicious PR could edit the predicate,
read the token, or post an `approved` status. The v2 writer closes this by
construction — the one workflow that writes the gate status runs the
DEFAULT-branch engine on every leg with credentials-dropped checkouts, and
reads PR data only through the API, so no PR-controlled code ever executes
with the write-capable token and no trust-posture knob exists. The
corollary: a PR that repairs a broken engine cannot open its own gate — it
merges via the ruleset's bypass actor. Wiring: [adoption.md](adoption.md).
