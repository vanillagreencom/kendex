# D007: The install record is recorded on main after each merge, through one rolling pull request

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: KEN-1877

**Refines**: [D001](D001-portable-lock.md), [D003](D003-one-merge-path.md)

**Decision**: A pull request never re-records `.kendex-lock.json`. After each push to `main`, `.github/workflows/lock-record.yml` builds kendex from that tree and runs `tools/lock-record`: where `kendex verify --scope project` reports the record stale, it re-records with `kendex refresh`, commits on the rolling branch `kendex/lock`, opens or updates the one pull request for that branch and arms auto-merge with the lanes app's token. A branch re-records only when the kendex it builds cannot read the record on `main`, which is a change to the lock's own format. In a checkout whose HEAD is not the default branch, `kendex check` writes nothing to the committed record, and every session-start hook runs `kendex check --quiet --report-only`, which never writes a tracked file anywhere. The rolling pull request's render proof runs the rolling main build, selected by `REVIEW_GATE_LOCK_KENDEX = "main"`, because a pinned release cannot read a record written by a kendex built from `main`. kendex stays excluded from consumer refresh while its record depends on the kendex build that writes it.

**Why**: Two open pull requests changing one package each rewrote the same lock rows, and whichever merged first ejected every other from the queue, with the cost growing as the square of the open pull requests on one package. The record is a function of the merged tree, so only a record written after the merge can be current, and the queue admits no direct commit to `main`.

**Rejected**: Laying the lock out one entry per line so git merges it: the conflict is in the values, not the layout, and a check cannot amend a merge group's commit. A workflow committing straight to `main`: refused by the zero-bypass ruleset, and a bypass reopens the mixed merge path.

**Revisit when**: The rolling pull request stalls at the review gate, GitHub admits a workflow commit to a queue-protected branch without a bypass actor, or the record stops depending on the kendex build that writes it.
