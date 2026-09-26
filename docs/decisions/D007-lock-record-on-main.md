# D007: The install record is recorded on main after each merge, through one rolling pull request

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Refines**: [D001](D001-portable-lock.md), [D003](D003-one-merge-path.md)

**Applies to**: `.kendex-lock.json` in this repository, `tools/lock-record`, `.github/workflows/lock-record.yml`, `skills/AGENTS.md`, `docs/DEVELOPMENT.md` § The self-install

## Summary

A pull request never re-records `.kendex-lock.json`. After each push to `main`, `.github/workflows/lock-record.yml` builds kendex from that tree and runs `tools/lock-record`. Where `kendex verify --scope project` reports the record stale, the script re-records it with `kendex refresh`, commits what refresh wrote on the rolling branch `kendex/lock`, force-pushes it, opens the one pull request for that branch or updates it, and arms auto-merge with the lanes app's token. The merge queue lands it like every other change. A branch re-records the lock only when the kendex it builds cannot read the record on `main`, which is a change to the lock's own format.

## Context

Since KEN-1862, every change that moved what `kendex refresh` records re-recorded the lock in its own pull request, and CI failed the `record` row otherwise. Two open pull requests changing one package each rewrote the same `skill:<name>:<harness>` rows, and the lock's `sources.kendex.commit` line moved on every re-record. Whichever merged first made every other one a base conflict on `.kendex-lock.json`: the merge queue ejected it, and its lane restacked, rebuilt kendex, re-recorded, waited for the gate and CI again, and re-armed. PR 2935 was ejected three times on 2026-09-26 on that file alone, 30 to 40 minutes per ejection, and the cost grows with the square of the open pull requests on one package.

The record is a function of the merged tree. A copy written on a branch is stale the moment another branch on the same package lands ahead of it, so only a record written after the merge can be current.

## Decision

1. **Who records.** `tools/lock-record`, run by `.github/workflows/lock-record.yml` on every push to `main` and on `workflow_dispatch`, with a kendex built from the pushed tree, because the kendex code that hashes, renders and records is part of what moves the record. The run refreshes the source mirrors, judges the record with `kendex verify --scope project`, and stops with `current=<sha>` when the record matches. A stale record is re-recorded with `kendex refresh --scope project --yes --leave`, verified again, and committed with every path refresh wrote.
2. **How it lands.** On the rolling branch `kendex/lock`, force-pushed from the head just judged, as one pull request against `main` that the lanes app arms for the merge queue. A pull request already open on the branch is updated by the push. The workflow's token comes from the `kendex` environment's `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` through `actions/create-github-app-token`, scoped to this repository, as D003 step 2 prescribes for a consumer's refresh workflow. Nothing pushes to `main`: the organization ruleset takes every change through the queue with no bypass actor.
3. **What a pull request does.** It leaves `.kendex-lock.json` as `main` holds it. The `record` row check on pull requests is removed from `skill-tests.yml`; the workflow's second `kendex verify`, after the refresh, is the record row check, and it runs on `main`. A pull request that changes the lock format re-records in its own branch, because a kendex that cannot read the record on `main` can neither judge nor refresh it.
4. **Convergence.** The push the rolling pull request's merge makes runs the workflow again, which finds the record current and writes nothing. `kendex verify` holds the record to its entries and to the mirror serving the declared source commit, not to the `sources.<name>.commit` value itself, so a refresh that would only move that line is never opened. A merge landing while a rolling pull request is queued makes the next push re-record on top of it; the branch is force-pushed from `main`'s head, so it never conflicts with `main`, and a merge that moves no record leaves the rolling pull request untouched.

## Rationale

- Two branches re-recording one package's rows conflict by construction. A record written after each merge cannot.
- The queue and the ruleset admit no direct commit to `main` (D003), so the rolling pull request is the one route a post-merge record has. It changes who commits the record, from each lane to the lanes app, without a new credential or a bypass.
- Building kendex from the pushed tree keeps the KEN-1862 property that the record is judged by the code that would write it.
- The verify-first gate keeps the workflow from opening a pull request over a `sources` commit line alone, which would loop through the queue after every merge.

## Alternatives Considered

| Alternative | Why rejected |
| --- | --- |
| Keep the record on the pull request and lay the lock out one entry per line so git merges it | Two pull requests on one package change the same entry's line, and the `sources.kendex.commit` line moves on every record; the conflict is in the values, not the layout. CI cannot regenerate rows inside a merge group, because a check cannot amend the group's commit. |
| A workflow that commits the record straight to `main` | The organization ruleset requires the merge queue on the default branch with zero bypass actors (D003 step 3); a direct push is refused, and a bypass for it reopens the mixed merge path D003 retired. |
| Record the lock in the merge queue's own run | The queue run is a check on a commit GitHub built; it can fail the group, not change it. |
| Drop the in-place entries' hashes from the committed record and derive them on read | Changes what every clone reads as its record (D001) for a cost the post-merge route already removes. |

## Impact

- The KEN-1862 property becomes: `kendex verify` on `main` reads no stale row once the rolling pull request that follows a merge has merged, one queue cycle after that merge rather than inside its CI run. Between the two, a verify on `main` reports the rows the merge moved, and nothing on `main` runs `kendex verify` in that window: the push-to-`main` CI run stands its shards down, and the overseer's `post-merge` script refreshes its base checkout before it verifies.
- A branch's `kendex verify --scope project` reports the rows it moved as stale until its merge lands, and the session drift notice in a worktree says the same; neither is acted on there.
- The consumer refresh workflow KEN-1779 adds is the same shape with a pinned kendex; this repository builds its own because its record is judged by the code it changes.
- `tools/ci-job-set` no longer selects the `rest` shard for a path the install record covers, because that shard no longer judges the record.

**Revisit When**: the rolling pull request classifies `standard` and stalls at the review gate rather than merging as `render` or `small`, which the render proof's pinned kendex or the class ceiling decides; GitHub admits a workflow commit to a queue-protected branch without a bypass actor; or the record stops depending on the kendex build that writes it, at which point the consumer template's pinned kendex can record this repository too.

**Verification**: `crates/cli/tests/lock_record.rs`: two branches that each change one script of one package, merged in sequence with `tools/lock-record` recording after each, produce no conflict on the second and a record a fresh clone of `main` verifies clean. `tools/tests/ci-class-job-set.test.sh` holds the shard selection without the install-record rule.

**References**: KEN-1877, KEN-1862, KEN-1779, [D001](D001-portable-lock.md), [D003](D003-one-merge-path.md)
