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
Exception: `REVIEW_GATE_TRUST_PR_WORKFLOWS` is consumed by workflow wiring,
not by these scripts, so it gets no parser guard — treat its name as
reserved all the same.

| Key | Default | Meaning |
|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | Gate commit-status context (the required check name). |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | (empty) | Clean-analysis check-run/status names; either API counts. Empty disables the source — trust is opt-in per repo, never a shipped vendor default. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | `rate limited;skipped;queued` | Case-insensitive substrings marking a trusted "pass" as analysis-not-run → not evidence. Empty disables. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | (empty) | `login:binding-pattern` pairs; first `:` splits; pattern is a literal prefix. Empty disables the source. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | Shortest sha prefix a comment may bind (4–40). |
| `REVIEW_GATE_OUTAGE_CONTEXT` | `vstack-reviewer-outage` | Outage-attestation status context. Empty disables. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | (empty) | Commit-status creator logins that are never evidence, on both the trusted-context and outage-context reads (typically `github-actions[bot]` — the publisher PR content can wield where PR workflows hold `statuses:write`). App-posted statuses serialize creator as null and are never rejected by a login entry. Empty disables — legitimate outage attestation is Actions-posted on some repos, so rejection is opt-in per repo. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | Review-object trust list. Empty = any non-author (compatible default). |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` counts any accepted review row; `approved` requires an APPROVED not withdrawn by a later CHANGES_REQUESTED from the same login. |
| `REVIEW_GATE_THREADS` | `enforce` | `enforce` fails closed on unresolved review threads; `off` skips the reviewThreads GraphQL read entirely and never emits `threads-open` — for repos whose thread hygiene is a server-side zero-bypass ruleset (`required_review_thread_resolution`), where the CI-side term is a latency optimization, not the enforcement point of record. Only the thread term is disabled; evidence and changes-requested still fail closed. |
| `REVIEW_GATE_API_ATTEMPTS` | `1` | Bounded retries per evidence read in the predicate, and for throttled rerun POSTs in the refire. Default = single attempt (today's behavior); failing through every attempt is still exit 2 (no verdict). |
| `REVIEW_GATE_API_RETRY_DELAY_SECONDS` | `2` | Pause between retry attempts. |
| `REVIEW_GATE_CARRY_FORWARD` | (empty) | Carry-safe delta classes (`docs`, `comments`; `;` or `\|` separated; empty = off, exact-head evidence only). With NO evidence at head, a qualifying review object at an ancestor commit N satisfies the evidence term when the N→head diff classifies entirely into the enabled classes — docs-only files (`*.md`/`*.markdown` by extension — a directory rule would carry executable files like `docs/conf.py`), or comment-only changes to code files (conservative per-extension comment-token table; added/removed/renamed files, patch-less files, and unknown extensions refuse) — or the trees are identical (rebase residue). Only the NEWEST ancestor candidate decides. Never a waiver: real evidence must exist and only extends across a delta review would not re-examine; code changes always require fresh evidence, and changes-requested / unresolved threads still fail closed with carried evidence. The compare API caps its file list at 300 entries, so a delta at the cap refuses carry (completeness unprovable), and the `comments` classifier is line-lexical — blind to an enclosing heredoc or multiline string where a full-line `#`/`//`-prefixed change is data — so enable `comments` only where that residual risk is acceptable. |
| `REVIEW_GATE_MAX_RERUN_ATTEMPTS` | `5` | Refire rerun backstop for pathological ping-pong. |
| `REVIEW_GATE_TRUST_PR_WORKFLOWS` | `false` | Trust posture for the CI gate job (see Security below). Consumed by workflow wiring, not by the scripts. |

Two env-only PER-INVOCATION seams are deliberately NOT settings keys:

- `REVIEW_GATE_SETTINGS_FILE` — overrides the settings-file path (e.g. in
  tests, or a caller resolving settings for a different checkout). Which
  file to resolve from is a property of one invocation, never of the repo
  the file itself describes — a settings key naming its own settings file
  would be circular.
- `REVIEW_GATE_STATUS_SNAPSHOT_FILE` — path to a combined-status snapshot
  (JSON object with a `statuses` array and a top-level `sha` equal to the
  invocation's `HEAD_SHA` — the raw combined-status API response carries
  both) the CALLER already holds. When set, the predicate evaluates
  trusted-context and outage evidence against it instead of fetching the
  combined status itself — a converge-style sweep that reads the combined
  status for its own required-status projection stops paying that read
  twice per head. The snapshot is bound to one head at one moment, which is
  why it can never be a repo setting — and the `sha` requirement enforces
  that binding: a snapshot for another head is refused. An unreadable,
  malformed, or wrong-head snapshot gets the read contract: exit 2, no
  verdict.

# Security posture

Workflows that execute repository-controlled code with a write-capable token
are the gate's own attack surface: a malicious PR could edit the predicate,
read the token, or post an `approved` status. The safe posture (default,
`REVIEW_GATE_TRUST_PR_WORKFLOWS = "false"`) runs the predicate from the BASE
revision with a read-only token and posts the status from a separate
minimal-permission step; checkouts in jobs executing repo code set
`persist-credentials: false`. Setting `"true"` deliberately accepts
self-evaluation (PR-head predicate) for its bootstrap property — a PR that
fixes the gate can open its own gate — which is defensible only on private,
effectively single-author repos; the settings key exists so that choice is
explicit and visible, never an accident. Wiring for both postures:
[adoption.md](adoption.md).
