# Filing tracked items

Read before you judge, write, split or file a tracked item, and at a launch read.

- Write an issue body from [templates/issue-description-template.md](../templates/issue-description-template.md).
- Write a parent's body from [templates/parent-issue-template.md](../templates/parent-issue-template.md).

These rules decide whether an item can be filed. They do not approve a create: [audit-issues § 6](../workflows/audit-issues.md#6-approve-creations-and-cancellations) approves the creates and cancellations of this skill's workflows, and [orch skill-rules.md § Tracked issue creation](../../orch/references/skill-rules.md#tracked-issue-creation) governs an orchestration session.

## Judge the approach

At every filing and every launch read, judge the approach against the item's own outcome sentence. Answer three questions:

1. Why does this approach produce the stated outcome, and what source evidence will show it? An outcome sentence and a measurement do not show that the work helps.
2. Can you remove or simplify something instead of adding this?
   - Name the existing owner or the simpler alternative.
   - Say why it meets or fails the same need. A name alone is no answer.
   - Do not force a new requirement into a removal.
3. Is this a workaround of a limit, a rule or a tool? If it is, does the limit or rule still have a reason?
   - Correct or remove a stale rule at its owning place.
   - Fix the cause.
   - Escalate only a boundary the owner reserves.
   - Apply [orch SKILL.md § Skill Rules](../../orch/SKILL.md#skill-rules) and the code-quality skill's SKILL.md § Correctness and § Over-Engineering.

Then:

1. Decide go, change or drop.
2. Write the short cause-and-effect answer in the item's existing outcome, evidence or ruling text.

- If the need is valid and the text is weak, repair the same item from its source request, and keep its date.
- Drop an item only when its need is absent, duplicated, satisfied or superseded.

## Creation bar

File an issue only when all three tests hold:

- It changes what a user or operator experiences, or it blocks work that does.
- No open issue, active branch or one-line fix already covers it.
- Someone can pick it up and finish it without a new investigation.

A reproducible anomaly with evidence in hand passes all three tests as an investigation issue.

- A container is a parent with children in the tracker, or with children its body names by identifier.
- A container has no work of its own, so the three tests do not apply to it. § Group by project or label, never by parent says when one is filed.
- A child that shares the container's subject is no duplicate: each child faces the bar itself.
- A parent with no child and none named is a work item.

Decline every other candidate with one line in the report: no issue, no placeholder, no tracking artifact. These fail the bar, whatever source the candidate came from:

- a severe-sounding edge case that no real input reaches;
- a coverage ask for a path that has not regressed;
- a refactor that neither changes behavior nor unblocks user-visible work;
- the classes in [reviewer finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow), Step 0.

## Group by project or label, never by parent

- Related items share their project ([project-map.md](project-map.md)).
- Where no project says what they share, they share one existing label.
- The grouping adds no label and no field.
- An audit, a holistic pass, a redesign or any other pass files no parent for its subject.
- Such a pass files each item it produces in the project its route names.
- Items that share an outcome, a mechanism or a subject the owner reads in one place form no parent either.

A parent exists only when its children are the parts of one deliverable accepted as one thing. Examples: a design and its build of one feature, the domain parts research-complete splits from one implementation issue, and the review audit's in-PR bundle.

## Name what reaches it

Every issue carries a `Reached by:` line. It names the user action, run, check or shipped producer that arrives at the defect. An owner-directed item names the ask.

- These are not a reach: the thread a finding came from, a shape such as "a name containing a quote", and something true only in theory. An item with nothing to name is a decline, not an issue.
- The author judges the reach. Linear `issues create` refuses only a body with no `Reached by:` line, and counts a placeholder or a null token as no line, unless `LINEAR_REQUIRE_REACH` is set empty. The GitHub route checks nothing.
- A filing whose source is a review round carries, at priority 2, a `Symptom:` line. It names the run, the user or the red check that already showed the defect.
- A Linear `issues create` for that filing passes `--review-born`. The GitHub route is [audit-issues § 7.2](../workflows/audit-issues.md#72-execute-approved-creations-and-cancellations).

## Requirements

1. Write each requirement, Done-when box and test plan against the code-quality skill's SKILL.md § Tests and § Over-Engineering, and against the repository's compatibility policy under § Cleanup.
2. Before filing, cut what those sections do not admit.

## Estimate

The numeric estimate is a size class within the team: 1 for its smallest work, through 5 for its largest. It is never a unit of time. An estimate already set stays valid: replace it only when the item's scope changes.

## Done when

Prove every box the branch can prove before the change is published, by a merge or by a push to the base branch.

Add a post-merge box on the same item only when all three conditions hold:

1. The box needs something the branch cannot give: a deployment or installation (a release, a consumer refresh or a host), live use over time, or a person's screen or hands. `Why after merge:` names that class.
2. `Where:` names the evidence location and its reader, under [orch communication-modes.md § Owner-only verification](../../orch/references/communication-modes.md#owner-only-verification).
   - For owner-side account, browser and home steps, write "Jarvis, the owner's delegate" in `Where:`, only where the jarvis skill is installed.
3. The repository's normal traffic produces the sample inside the window.
   - A release trigger names a release the repository publishes within 72 hours of merge.
   - A count names its sample size.

- Admit a count or a rare-event check only when an existing query or counter answers it inside the window.
- If a box fails a condition, make it a pre-merge test or drop it.

Write each post-merge box on one line:

```markdown
- [ ] Post-merge: <check>; Where: <location or command>; Why after merge: <why the branch cannot prove it>; Trigger: <trigger>; Deadline: <deadline>
```

- `Post-merge:` states the check's pass condition. The absence of an event passes only when the check states absence as its pass condition.
- `Trigger:` takes one of three forms: `merge`, a UTC time at or after merge, or `release OWNER/REPO TAG-GLOB`, the first matching GitHub release published after merge whose tag contains the item's latest merge commit, where the item merged in OWNER/REPO.
- `Deadline:` is `+Nh`, with N from 1 through 72, counted from the trigger: the merge, the stated time, or the release publication.
  - Write a merge trigger's deadline as `+Nh`, because the merge time is unknown when the box is written.
  - A merge or time trigger also takes a real UTC deadline after its trigger and at most 72 hours later.
  - A release trigger takes only `+Nh`.
- Example: `Trigger: release example/widget v*; Deadline: +24h`.

Do not create a separate item to carry the verification check.

## One landing per subsystem

A body that lists batches, each able to land alone, is filed as one item per batch.

An item whose work changes more than one subsystem is filed as one item per subsystem, each able to land and take review alone. The change-scope skill's SKILL.md § Classes defines a subsystem, under the `small` class.

- Between the items, add a blocking relation only where one item needs another's change.
- An item that cannot land in parts says why in its body.
