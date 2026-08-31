# Reviewing byte-pinned vendored paths

For consumers that vendor an upstream tree byte-for-byte and merge re-vendor
PRs. Suppressing duplicate upstream findings is a reviewer-instruction
problem; configuration answers break the gate.

A committed `kendex refresh` tree is the other case, and every section here
covers it with the two changes in § The harness-render variant at the foot.

## What suppression must not break

**Evidence.** The gate's evidence term needs a trusted non-author review object
at the exact head, or one of the other forms in [settings.md](settings.md).
`REVIEW_GATE_CARRY_FORWARD` only extends evidence that already exists. A tree
kendex renders carries under the `vendored` class when
`REVIEW_GATE_VENDORED_PATHS` names it; any other byte-pinned tree sits in
`REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, forcing fresh evidence on this PR class.

**Threads.** The predicate counts `reviewThreads`, and the zero-bypass
`required_review_thread_resolution` ruleset enforces the same threads
server-side. Threads come from INLINE review comments. A review submitted with
a body and no inline comments is full evidence and creates no thread — that is
the target shape.

**Honesty.** Never engineer a hollow review object to feed the gate. Where there
is genuinely nothing to review, post the operator override with a reason.

## The trap: reviewer path exclusion

Never exclude the vendored tree in the reviewer's own configuration (content
exclusion, ignore-paths, a path filter on the review trigger):

- A pure re-vendor PR has no other files. With the tree excluded the reviewer
  posts no review object (gate stuck at `awaiting`) or posts a
  reviewed-nothing pass on a trusted context (hollow green).
- **`REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` does not close the second outcome.**
  It is a literal, case-insensitive substring match against the check's title
  plus summary (defaults `rate limited`, `skipped`, `queued`); a summary
  saying only that it reviewed no files matches none of them.
- Mixed PRs still produce a review, so the failure appears only on the pure
  class.

**Never exclude a path that can constitute an entire PR's diff.** The same rule
rules out narrowing a review trigger by path.

## The rule: route by remedy locus, not by path

Classify each finding by where the fix would land, and pick the surface:

| Where the fix lands | Surface |
|---|---|
| A repo-owned file — the vendor pin or checksum manifest, settings, CI wiring, adoption glue | Inline comment. In scope, keep it. |
| The vendored bytes themselves | Review body only. Upstream's call. |
| The vendored bytes, where the bump introduces a production-impacting regression that runs HERE — correctness, security, data loss | Inline comment, and it may block. See the carve-out below. |
| The upstream repo's own docs, config, or conventions | Review body only, or omit. |

The regression carve-out admits only a defect you would hold a release for —
correctness, security, data loss. Style, naming, duplication, test layout,
missing coverage stay in the review body.

An instruction that constrains only the REMEDY ("flag it, but do not ask for
local edits") suppresses nothing: the thread still opens and still blocks.
Constrain the surface.

### Reviewer classes — where a review body exists, and where it does not

Classify per reviewer, not per repo:

- **Summary-capable** — it authors its own review body. An upstream-remedy
  finding goes there and costs no thread.
- **Location-bound** — every finding is anchored to a file and line; its
  review body, where it has one, is a fixed template.

For a location-bound reviewer the rule is a BOUND: at most ONE consolidated
comment per PR carrying every upstream-remedy finding together, anchored
anywhere in the vendored tree.

**Accepted residual.** A reviewer whose output schema binds one finding to one
location will still emit one thread per finding. Read the thread count as an
observable, not as compliance, and answer those threads like any others: **a
location-bound reviewer exceeding one thread is not by itself a failed
rollout.**

Do not build an adapter that collects such findings and republishes them as a
summary.

Classify each of the repo's reviewers before wiring, by reading a review body
it posted on a recent PR: a body identical across PRs is a template, and that
reviewer is location-bound.

## The consumer session's half

Once per re-vendor train, on ONE consumer PR, collect upstream-remedy findings
from BOTH surfaces: the review bodies, AND EVERY vendored-path thread a
location-bound reviewer left.

`kendex report --skill [NAME] --title [TITLE] --body-file [PATH]` files the
report. The command is non-interactive: `--title` is required, and exactly one
of `--body` or `--body-file` must be given — with neither (or both) it exits
without filing. `--dry-run` prints the decision and the `gh` command it would
run.

The lock is the one judge, and it records provenance for every kind — skills,
agents, hooks and Pi extensions alike. A name routes upstream when the lock
holds at least one entry for it, narrowed to the kind the selector names, and
EVERY matching entry's `source_repo` is kendex's own repo, the one candidate
the comparison holds — an item vendored from anywhere else files against the
LOCAL repo, and its issue is opened by hand. One entry recorded from somewhere
else makes the name ambiguous and keeps the report local, which is also what an
unlocked name gets. How the manifest spelled the repo does not decide it: a
shorthand, an https URL and a `git@` reference fold to one identity. `--skill`,
`--agent`, `--hook` and `--asset` are the selectors; with none of them the CLI
warns once that ownership could not be determined and files against the LOCAL
repo.

A repo that vendored only a scripts subtree, with no lock entry over it, has
no name to select — open the upstream issue by hand. Confirm with `--dry-run`
before relying on any of it.

Do not fix it locally, and do not file the same finding from each consumer.

## Wiring a repo

1. Copy [`../templates/vendored-paths.instructions.md`](../templates/vendored-paths.instructions.md)
   into the repo's path-scoped reviewer instruction directory —
   `.github/instructions/`, as a `*.instructions.md` file — set `applyTo` to the
   repo's actual vendored glob, and fill the placeholders. Repo-owned after the
   copy.
2. Check the glob against the paths a real re-vendor PR touches.
3. **Replace any existing instruction scoped to the same tree — do not add
   alongside it.** Merge any repo-specific carve-outs the old clause held into
   the new body.
4. Classify each reviewer the repo runs as summary-capable or location-bound
   (above). A repo whose reviewers are ALL location-bound gets a bounded
   improvement, not silence — decide whether that is worth the wiring.
5. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do
   not read path-scoped instructions.
6. Change no gate settings. A kendex render tree carries only through the
   `vendored` class and `REVIEW_GATE_VENDORED_PATHS`; any other vendored
   tree stays in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, and
   `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` never widens to a CI check as a
   substitute for review.

## Verifying on a real re-vendor PR

Verify per repo, on the first re-vendor PR after the change, and use a PURE
one (vendored files only).

```bash
# 1. Evidence AT HEAD. Read the head in the same call and compare per review.
gh pr view [PR] --repo [OWNER/REPO] --json reviews,headRefOid --jq '.headRefOid as $head | .reviews[] | {login: .author.login, state: .state, at_head: (.commit.oid == $head), body_chars: (.body | length)}'

# 2. Threads on the vendored tree, BEFORE resolving any of them.
.agents/skills/github/scripts/github.sh pr-threads [PR] --unresolved

# 3. The gate's own answer for this head.
gh pr checks [PR] --repo [OWNER/REPO]
```

**Under `REVIEW_GATE_THREADS=enforce`** (the default), record step 2's threads
and their authors first, resolve them, then read step 3.

**Under `REVIEW_GATE_THREADS=off`**, read both from ONE snapshot and resolve
nothing. Do not clear real repo-owned threads merely to finish a verification.

Step 1 answers the evidence question only for rows with `at_head` true whose
login is non-author AND in the repo's
`REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` (empty list = any non-author), and
only at the repo's `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE`. Under `any` every
such row counts. Under `approved` a login contributes evidence only when its
newest `APPROVED` at head is not followed by a newer `CHANGES_REQUESTED` from
that same login; a bare `COMMENTED` is not evidence there. This view reports
bot logins WITHOUT the `[bot]` suffix the trusted list carries — compare on
the base name, or read the REST `pulls/[PR]/reviews` endpoint, which returns
the suffixed login and `commit_id`.

**Pass**: a trusted non-author review object at the current head; on the
vendored tree, no unresolved thread from a summary-capable reviewer; gate
`success`. A repo-owned finding arriving inline is fine, and so is an inline
thread raising a carve-out regression — read what a thread SAYS before grading
it. Hold or revert the bump, or resolve it on an upstream fix, then re-read; it
is a blocked re-vendor, never a failed rollout. Threads from a location-bound
reviewer are counted and recorded, not graded.

**Suspect, not proven**: threads at zero with `body_chars` also at zero. Treat
it as a prompt to check, and confirm with a signal that distinguishes
exclusion: a summary-capable reviewer's own reviewed-file count in the body
(reviewed N of N changed files), and whether the reviewer's configuration
carries a path exclusion over the vendored tree. For a trusted check-run
passing with a reviewed-nothing summary, read the check's own output rather
than trusting the green.

**On confirmed failure**, revert the instruction file and merge the PR through
the documented review path.

## The harness-render variant

For consumers that commit `kendex refresh` output and merge refresh PRs. No
pin covers that tree: an edit under it does not land, because the next refresh
finds bytes no apply wrote and holds the item as a conflict, planning no write
until someone forks it or discards the edit. Two things change; everything
above holds.

**The rule is flat, with no carve-out.** The vendored rule routes
upstream-remedy findings to the review summary body and keeps one carve-out
for a correctness, security, or data-loss regression the bump introduces. One
refresh lands in several repos at once, so that thread blocks the merge in
each of them for a fix that can land in none. Over a render both go: no
finding over the render on any surface, and a defect that would ship goes to
the catalog repo and to the PR author out of band. Under a flat rule there is
no on-PR surface left, which also removes the consolidated-comment fallback
the vendored template gives a location-bound reviewer.

**The report files against the catalog repo**, by the same `kendex report`
route and the same lock ownership rule as § The consumer session's half. An
item rendered from a third-party catalog carries that catalog in its lock
entries and reports here instead, so open that issue by hand.

Wire it with the vendored template: copy it, set `applyTo` to the render
trees, and apply its RENDER VARIANT block, which carries the replacement text
for every paragraph the flat rule changes. Deleting the carve-out alone is not
enough — the byte-pin opening, the summary-body route, the repo-owned bullet's
pin clause and the consolidated-comment fallback all survive that one deletion
and each contradicts the rule above. The trees kendex writes are `.agents/skills`,
`.claude`, `.codex`, `.cursor`, `.gemini`, `.opencode`, `.pi`, and for Copilot
the `agents`, `hooks`, and `skills` subtrees of `.github`. Each can also hold
files kendex never writes, so the file list of a real refresh PR is the
authority on the glob. Four shapes it must not take: the rest of `.github`;
the harness memory files `CLAUDE.md`, `AGENTS.md` and `GEMINI.md`, which
kendex writes none of; every `.agents/skills/<name>` an item declares
`source = "in-place"`, whose content of record is edited here; and every path
kendex merges its own entries into while the repo owns the rest, such as
`.claude/settings.json`, `.codex/config.toml`, `.cursor/hooks.json`,
`.mcp.json`, and the root `opencode.json`. That last shape is the one most
worth keeping out: the instruction file the variant yields asserts that
nothing under the glob is edited here, and over a merged path that is false —
a glob one shape too wide silently suppresses correctness and security
findings over a settings file this repo owns and can fix.

Verify per § Verifying on a real re-vendor PR, reading the render trees rather
than the vendored one. **Pass** is stricter in one term: no unresolved thread
over the render from a summary-capable reviewer, including none raising a
correctness, security, or data-loss defect, which the flat rule routes to the
catalog repo and the vendored carve-out would have admitted.
