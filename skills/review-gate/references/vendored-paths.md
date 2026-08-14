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
  has nothing to review, and both of its remaining outcomes are bad. It posts
  no review object at all — the gate sits at `awaiting` with no reviewer that
  can ever clear it. Or it posts a reviewed-nothing pass on a trusted
  check-run or status context, which the gate accepts as evidence and turns
  green.
- **`REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` does not close the second outcome.**
  It is a literal, case-insensitive substring match of the configured markers
  against the check's title plus summary; the shipped defaults are `rate
  limited`, `skipped`, and `queued`. A pass whose summary says only that it
  reviewed no files matches none of them and counts as full evidence. The
  filter catches a reviewer that announces WHY it did nothing, not a reviewer
  with nothing to do — so path exclusion trades a starved gate for a hollow
  green one, which is worse: nothing looks wrong.
- Mixed PRs still carry a repo-owned file, so the reviewer still produces a
  review and the configuration looks healthy. Both failures appear only on the
  pure class, after the change has shipped.

**Never exclude a path that can constitute an entire PR's diff.** The same rule
rules out narrowing a review trigger by path, for the same reason.

## The rule: route by remedy locus, not by path

Not every finding on a vendored file has an upstream remedy. Classify by where
the fix would land, and pick the surface from that:

| Where the fix lands | Surface |
|---|---|
| A repo-owned file — the vendor pin or checksum manifest, settings, CI wiring, adoption glue | Inline comment. In scope, keep it. |
| The vendored bytes themselves | Review body only. Upstream's call. |
| The vendored bytes, where the bump introduces a production-impacting regression that runs HERE — correctness, security, data loss | Inline comment, and it may block. See the carve-out below. |
| The upstream repo's own docs, config, or conventions | Review body only, or omit. |

The first row is the class worth protecting. A re-vendor PR that moves the
pinned bytes without updating the repo-owned checksum manifest is broken, and
that finding is repo-local, actionable, and a duplicate of nothing upstream. A
path-based silence rule suppresses it along with the noise; a remedy-based rule
keeps it.

The review-body rows are the duplication. They are not wrong — they are
un-actionable HERE: any local edit forks the pinned surface, which the
byte-identity check exists to prevent. Stating them in the review body keeps
the signal, costs no thread, and leaves one place to harvest them from.

The regression row is that reasoning applied honestly, not an exception to it.
"The remedy cannot happen in this PR" is TRUE for a defect whose only fix is an
upstream edit, and FALSE for one the bump introduces into what runs here:
holding or reverting the bump until upstream fixes it is a repo-owned action on
the pin, exercised by blocking the PR. Routing that to a non-blocking surface
ships a known defect. Keep the bar at a defect you would hold a release for —
correctness, security, data loss — because every softer reading (style, naming,
duplication, test layout, missing coverage) is exactly the inline traffic the
rule exists to stop, and a carve-out that admits them repeals it.

An instruction that constrains only the REMEDY ("flag it, but do not ask for
local edits") does not suppress anything: the reviewer still opens the thread,
and the thread still blocks the merge. Constrain the surface.

### Reviewer classes — where a review body exists, and where it does not

The routing above assumes the reviewer can put a finding somewhere other than a
file location. Not every one can, and the difference is per-reviewer, not
per-repo:

- **Summary-capable** — it authors its own review body: an overview, a per-file
  table, its own finding prose. An upstream-remedy finding goes there and costs
  no thread.
- **Location-bound** — every finding it emits is anchored to a file and line,
  and its review body, where it has one, is a fixed template it does not author
  findings into. Told to "use the summary body", such a reviewer can only drop
  the finding or leave it inline — and dropping it is the worse outcome.

For a location-bound reviewer the rule is a BOUND, not a surface change: at
most ONE consolidated comment per PR carrying every upstream-remedy finding
together, anchored anywhere in the vendored tree.

**Accepted residual — the bound is an instruction, not a mechanism.** A
reviewer whose output schema binds one finding to one location will still emit
one thread per finding, however the instruction is worded. Read the thread
count as an observable, not as compliance, and answer those threads like any
others: **a location-bound reviewer exceeding one thread is not by itself a
failed rollout.** What this doc buys for that class is remedy-locus routing —
each upstream-remedy finding stated once as upstream's to fix, so it is not
re-litigated in the next consumer or argued back into the upstream repo.

Do not solve this with an adapter that collects such findings and republishes
them as a summary. That is a second publisher on the review surface, carrying
its own trust and ordering questions, and out of scope for a
reviewer-instruction change.

Classify each of the repo's reviewers before wiring, by reading a review body
it posted on a recent PR: a body identical across PRs is a template, and that
reviewer is location-bound.

## The consumer session's half

The reviewer routes; the session captures. Once per re-vendor train, on ONE
consumer PR, collect upstream-remedy findings from BOTH surfaces: the review
bodies, AND EVERY vendored-path thread a location-bound reviewer left — one
consolidated thread where it honored the bound, one thread per finding where
its schema could not (the accepted residual above), which is why this is not
scoped to a consolidated thread. Reading only the bodies drops that class's
entire output — its findings are never anywhere else.

`vstack report --skill review-gate --title [TITLE] --body-file [PATH]` routes
the report upstream. The command is non-interactive and validates arguments
before doing anything: `--title` is required, and exactly one of `--body` or
`--body-file` must be given — with neither (or both) it exits without filing.
Two further preconditions, each silent when unmet:

- **The selector is required.** With no `--skill`/`--agent`/`--hook`/`--asset`,
  the CLI warns once that ownership could not be determined and files against
  the LOCAL repo.
- **For a skill, only the installed `SKILL.md` frontmatter decides.** A lock
  entry never opts a skill upstream — skills are self-attributing by design, so
  routing needs the vendored `SKILL.md` present at the install path and
  carrying `source: vstack` (or the upstream `repository` slug). A repo that
  vendored only the scripts subtree has no frontmatter to read and files
  locally. Check before relying on it, or open the upstream issue by hand.

Do not fix it locally, and do not file the same finding from each consumer:
reviewers have no cross-repo memory and will restate the same finding in every
one.

## Wiring a repo

1. Copy [`../templates/vendored-paths.instructions.md`](../templates/vendored-paths.instructions.md)
   into the repo's path-scoped reviewer instruction directory —
   `.github/instructions/`, as a `*.instructions.md` file — set `applyTo` to the
   repo's actual vendored glob, and fill the placeholders. Repo-owned after the
   copy, like the writer workflow.
2. Check the glob against the paths a real re-vendor PR touches. An `applyTo`
   that does not match the vendored tree is dead config that lints green.
3. **Replace any existing instruction scoped to the same tree — do not add
   alongside it.** A repo that already carries a vendored-tree clause almost
   certainly carries a remedy-only one ("flag them, but do not ask for local
   edits"), which permits exactly the inline comments this replaces. Two
   instructions over one glob leave the reviewer to pick, and it picks the
   permissive one. Merge any repo-specific carve-outs the old clause held into
   the new body rather than keeping both files.
4. Classify each reviewer the repo runs as summary-capable or location-bound
   (above). A repo whose reviewers are ALL location-bound gets a bounded
   improvement, not silence — decide whether that is worth the wiring before
   doing it.
5. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do
   not read path-scoped instructions.
6. Change no gate settings. Do not add the vendored tree to a carry class, do
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
# 1. Evidence AT HEAD. The reviews list shows a stale round exactly like a
#    fresh one, so read the head in the same call and compare per review.
gh pr view [PR] --repo [OWNER/REPO] --json reviews,headRefOid --jq '.headRefOid as $head | .reviews[] | {login: .author.login, state: .state, at_head: (.commit.oid == $head), body_chars: (.body | length)}'

# 2. Threads on the vendored tree, BEFORE resolving any of them: the flag
#    filters to isResolved == false, so a reviewer that ignored the
#    one-comment bound reads as zero once its threads have been answered.
.agents/skills/github/scripts/github.sh pr-threads [PR] --unresolved

# 3. The gate's own answer for this head.
gh pr checks [PR] --repo [OWNER/REPO]
```

**Steps 2 and 3 cannot come from the same snapshot under
`REVIEW_GATE_THREADS=enforce`** (the default): the predicate reads
`reviewThreads` and fails closed on any unresolved one, so the gate cannot
reach `success` while threads are open, and resolving them to reach it empties
step 2. Record step 2's threads and their authors first, resolve them, then
read step 3.

Under `REVIEW_GATE_THREADS=off` the predicate skips that read entirely and
never emits `threads-open`, so step 3 is already green independent of step 2:
read both from ONE snapshot and resolve nothing. Do not clear real repo-owned
threads merely to finish a verification. A server-side thread ruleset is not
the trigger either — it blocks the MERGE, never this status context, which is
the only thing step 3 reads.

Step 1 answers the evidence question only for rows with `at_head` true whose
login is non-author AND in the repo's
`REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` (empty list = any non-author), and
only at the repo's `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE`. Under the `any`
default every such row counts. Under `approved` a login contributes evidence
only when its newest `APPROVED` at head is not followed by a newer
`CHANGES_REQUESTED` from that same login — a trailing `COMMENTED` never
withdraws an approval, but a `COMMENTED` row on its own is not evidence there.
Read the `state` field against the repo's setting: counting a bare `COMMENTED`
as evidence under `approved` passes a verification the predicate's review-object
term fails, while the gate is green off a different evidence surface. This
view reports bot logins WITHOUT the `[bot]` suffix the trusted list carries —
compare on the base name, or read the same reviews from the REST
`pulls/[PR]/reviews` endpoint, which returns the suffixed login and
`commit_id`.

**Pass**: a trusted non-author review object at the current head; on the
vendored tree, no unresolved thread from a summary-capable reviewer; gate
`success`. A repo-owned finding still arriving inline is the control that
proves the reviewer is still reading rather than merely silent — and so is an
inline thread raising a carve-out regression: read what a thread SAYS before
grading it, because that one is the rule working. Hold or revert the bump, or
resolve it on an upstream fix, then re-read; it is a blocked re-vendor, never a
failed rollout. Threads from a location-bound reviewer are counted and
recorded, not graded — one consolidated thread is what the instruction asks
for, and more than one is the accepted residual above, not a failure.

**Suspect, not proven**: threads at zero with `body_chars` also at zero. Body
length cannot establish whether anything was examined — a reviewer with
genuinely nothing to say reads the same, and the gate accepts a trusted review
at head without inspecting its body at all. Treat it as a prompt to check, not
a verdict, and confirm with a signal that actually distinguishes exclusion:
a summary-capable reviewer states its own reviewed-file count in the body
(reviewed N of N changed files), and the reviewer's configuration either
carries a path exclusion over the vendored tree or does not. The check-run twin
is a trusted context passing with a reviewed-nothing summary; the skip patterns
do not catch that (see the trap above), so read the check's own output rather
than trusting the green.

**On confirmed failure**, revert the instruction file and merge the PR through
the documented review path. A starved gate is a worse outcome than duplicate
threads, and the override exists for the gap, not for a standing posture.
