# D027: The merge-queue run proves every kendex change

[← Decision Index](INDEX.md)

**Date**: 2026-10-17

**Status**: Active (bypass actors → D029)

**Research**: [KEN-4220](https://linear.app/vanillagreen/issue/KEN-4220), [KEN-4218](https://linear.app/vanillagreen/issue/KEN-4218), [KEN-4217](https://linear.app/vanillagreen/issue/KEN-4217), [KEN-3648](https://linear.app/vanillagreen/issue/KEN-3648); the owner's ruling in Slack thread 1792195437, messages 1792196004, 1792197483 and 1792197507

**Supersedes**: [D013](D013-admin-merge-green-prs.md) in full; [D024](D024-skill-tests-time-budgets.md) and [D026](D026-macos-native-contracts.md) in part, their matching patch proof.

**Decision**: The owner ruled that the merge-queue run is the only proof of a kendex change, and that a pull-request push runs no product CI. Every change takes the queue: `kendex.settings.toml` names no `HARNESS_CI_PER_PUSH_REASON`, so `change-class` reads every change queue-only and `pr-merge` never takes `--admin`. An unchanged head never re-enters the queue after a red run: the change returns to its lane, which re-arms only a new head or hands back to the overseer. The three rulesets and their bypass actors stay as D013 set them; kendex no longer uses the lanes app's queue bypass. KEN-4218 removes the pull-request product CI and the merge group's reuse of pull-request macOS patch proof. Fleet's D066, admin merge beside the queue, must follow in FLT-1350.

**Why**: The owner asked whether CI needs to run on every pull request, given its cost. With one proof per head, a pull request spends no CI minutes before review, and once the patch-proof reuse is gone, the merge group tests the integrated tree on every leg. A red queue run that re-enters on the same head repeats a known failure: on 2026-10-16 fleet counted three hyprtrade pull requests that entered the queue three times each, for 5,071 minutes.

**Rejected**: D013's admin merge of a green pull request: it needs a full pull-request run, which the owner removed. Keeping the pull-request run as a second proof: it runs CI twice for each change that merges.

**Revisit when**: The merge queue's wait or failure rate makes a lane wait longer than a pull-request run did, or a served repository cannot use a merge queue.
