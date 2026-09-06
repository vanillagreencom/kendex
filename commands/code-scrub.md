---
name: code-scrub
description: "Audit merged pull requests over a user-specified number of days."
summary: "Find unused code, duplicate logic, excess scope and unmet issue requirements in merged pull requests."
argument-hint: "<days>"
---

Audit every pull request merged into this repository's default branch during the last N days. Take N from the day count in `$ARGUMENTS` or the user's request; ask for it if absent. Record the window's dates and the default branch's head commit. Read each squash diff and its issue's Done-when and Not-in-scope. Check every PR regardless of review signals; read frozen, capped and repeatedly reviewed PRs in full. Judge dead ends, half-built mechanisms, duplicate logic already owned elsewhere, bloat for low-severity hypotheticals or edge cases below 1%, tests larger than the change, migration code for users who do not exist, and cuts that leave a Done-when clause unmet. Check the current code, real producers and consumers, relevant tests, accepted decisions and review replies before making a finding. State missing evidence; do not infer likelihood or an absent user population.

Output a table first, with one row per PR and these columns: PR, issue, what fails the bar, verdict, removable lines. Use only these verdicts: rip out, refactor, re-approach, keep. Measure removable lines from the code and avoid counting the same removal twice; mark an unmeasured value as unknown. Then suggest issues, removals, changes, additions and improvements supported by the findings. For every removal, name the consumer that keeps working and the code or test that supports that conclusion. For each recurring class, identify the rule that admits it and propose a root-cause rule change. Cite evidence with file paths and semantic anchors. Produce the audit only; do not change code or create tracker issues.
