# Review-gate settings

All keys resolve environment-first, then the repo's `vstack.settings.toml`,
then the built-in default (`REVIEW_GATE_SETTINGS_FILE` overrides the file
path, e.g. in tests). List values pack into one string with `;` separators.
Commented defaults ship in this skill's `vstack.settings.toml.example`;
per-repo wiring and values: [references/adoption.md](references/adoption.md).

| Key | Default | Meaning |
|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | Gate commit-status context (the required check name). |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | `Devin Review` | Clean-analysis check-run/status names; either API counts. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | `rate limited;skipped;queued` | Case-insensitive substrings marking a trusted "pass" as analysis-not-run → not evidence. Empty disables. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | (empty) | `login:binding-pattern` pairs; first `:` splits; pattern is a literal prefix. Empty disables the source. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | Shortest sha prefix a comment may bind (4–40). |
| `REVIEW_GATE_OUTAGE_CONTEXT` | `vstack-reviewer-outage` | Outage-attestation status context. Empty disables. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | Review-object trust list. Empty = any non-author (compatible default). |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` counts any accepted review row; `approved` requires an APPROVED not withdrawn by a later CHANGES_REQUESTED from the same login. |
| `REVIEW_GATE_MAX_RERUN_ATTEMPTS` | `5` | Refire rerun backstop for pathological ping-pong. |
| `REVIEW_GATE_TRUST_PR_WORKFLOWS` | `false` | Trust posture for the CI gate job (see Security below). Consumed by workflow wiring, not by the scripts. |

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
[references/adoption.md](references/adoption.md).
