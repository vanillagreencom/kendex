# Reviewing byte-pinned vendored paths

For consumers that vendor an upstream tree byte-for-byte and merge re-vendor
PRs. The delta on such a PR is bytes already reviewed upstream, yet every
reviewer re-reviews them, and every inline comment opens a review thread the
merge cannot clear until someone answers it. One upstream finding becomes one
merge-blocking thread per reviewer per consumer, and the answering sessions
carry the argument back into the upstream repo.

Suppressing that duplication is a reviewer-instruction problem. The
configuration answers break the gate.

## What suppression must not break

**Evidence.** The gate's evidence term needs a trusted non-author review object
at the exact head, or one of the other forms in [settings.md](settings.md).
Nothing manufactures it: `REVIEW_GATE_CARRY_FORWARD` extends evidence that
already exists to a later head, so it can never open a PR that was never
reviewed — and the vendored tree normally sits in
`REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, because vendored markdown is
agent-instruction content that is obeyed mechanically. That exclusion forces
fresh evidence on exactly this PR class, by design.

**Threads.** The predicate counts `reviewThreads`, and the zero-bypass
`required_review_thread_resolution` ruleset enforces the same threads
server-side. Threads come from INLINE review comments. A review submitted with
a body and no inline comments is full evidence and creates no thread — that is
the target shape, and it is what a reviewer already produces when it has
nothing file-specific to say.

**Honesty.** A review that examined nothing is not evidence that a review
happened. Never engineer a hollow review object to feed the gate. Where there
is genuinely nothing to review, the operator override is the term that says so
out loud, with a reason.

## The trap: reviewer path exclusion

Excluding the vendored tree in the reviewer's own configuration — content
exclusion, ignore-paths, a path filter on the review trigger — is the obvious
answer and the one that starves the gate:

- A pure re-vendor PR has no other files. With the tree excluded the reviewer
  has nothing to review and either posts no review object at all (the gate sits
  at `awaiting` with no reviewer that can ever clear it), or posts a
  reviewed-nothing pass on a check-run or status surface, which
  `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` correctly classifies as not-evidence.
- Mixed PRs still carry a repo-owned file, so the reviewer still produces a
  review and the configuration looks healthy. The starvation appears only on
  the pure class, after the change has shipped.

**Never exclude a path that can constitute an entire PR's diff.** The same rule
rules out narrowing a review trigger by path, for the same reason.

## The rule: route by remedy locus, not by path

Not every finding on a vendored file has an upstream remedy. Classify by where
the fix would land, and pick the surface from that:

| Where the fix lands | Surface |
|---|---|
| A repo-owned file — the vendor pin or checksum manifest, settings, CI wiring, adoption glue | Inline comment. In scope, keep it. |
| The vendored bytes themselves | Review body only. Upstream's call. |
| The upstream repo's own docs, config, or conventions | Review body only, or omit. |

The first row is the class worth protecting. A re-vendor PR that moves the
pinned bytes without updating the repo-owned checksum manifest is broken, and
that finding is repo-local, actionable, and a duplicate of nothing upstream. A
path-based silence rule suppresses it along with the noise; a remedy-based rule
keeps it.

The other two rows are the duplication. They are not wrong — they are
un-actionable HERE: any local edit forks the pinned surface, which the
byte-identity check exists to prevent. Stating them in the review body keeps
the signal, costs no thread, and leaves one place to harvest them from.

An instruction that constrains only the REMEDY ("flag it, but do not ask for
local edits") does not suppress anything: the reviewer still opens the thread,
and the thread still blocks the merge. Constrain the surface.

## The consumer session's half

The reviewer routes; the session captures. Once per re-vendor train, read the
review bodies on ONE consumer PR and file anything upstream-remedy at the
upstream repo — `vstack report` routes vstack-owned assets. Do not fix it
locally, and do not file the same finding from each consumer: reviewers have no
cross-repo memory and will restate the same finding in every one.

## Wiring a repo

1. Copy [`../templates/vendored-paths.instructions.md`](../templates/vendored-paths.instructions.md)
   into the repo's path-scoped reviewer instruction directory, set `applyTo` to
   the repo's actual vendored glob, and fill the placeholders. Repo-owned after
   the copy, like the writer workflow.
2. Check the glob against the paths a real re-vendor PR touches. An `applyTo`
   that does not match the vendored tree is dead config that lints green.
3. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do
   not read path-scoped instructions.
4. Change no gate settings. Do not add the vendored tree to a carry class, do
   not remove it from `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, and do not widen
   `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` to a CI check as a substitute for
   review — a context trusted for this PR class is trusted for every PR class.

Instruction text constrains what a reviewer says, never whether it reviews, so
this wiring cannot starve the gate. That is the reason to prefer it over every
configuration answer.

## Verifying on a real re-vendor PR

Instructions are advisory — a reviewer may ignore them — so the wiring is not
done until a real PR shows it took. Verify per repo, on the first re-vendor PR
after the change, and use a PURE one (vendored files only): the mixed class
hides every failure mode this check exists to catch.

```bash
# 1. Evidence at head: at least one trusted non-author review object.
gh pr view [PR] --repo [OWNER/REPO] --json reviews

# 2. Threads: expect none whose path is under the vendored tree.
.agents/skills/github/scripts/github.sh pr-threads [PR] --unresolved

# 3. The gate's own answer for this head.
gh pr checks [PR] --repo [OWNER/REPO]
```

**Pass**: a trusted non-author review object at head, no unresolved thread on a
vendored path, gate `success`. A repo-owned finding still arriving inline is
the control that proves the reviewer is still reading — not merely silent.

**Not a pass**: zero threads AND an empty review body. That is the exclusion
failure wearing a green badge; the review object may be evidence the gate
accepts while nothing was examined.

**On failure**, revert the instruction file and merge the PR through the
documented review path. A starved gate is a worse outcome than duplicate
threads, and the override exists for the gap, not for a standing posture.
