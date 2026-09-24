# Communication modes

`ORCH_USER_MODE` names who an orch session is talking to. This file owns the ask set and the wording of the questions in it; nothing outside it narrows or widens that set, and a gate citing it states neither.

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

| Value | Meaning |
|-------|---------|
| `ceo` | The session owns every technical decision. The user states intent and outcomes. Only a question in § Ask set reaches the user, worded as § The ceo question template requires |
| `engineer` | The package's original behaviour: the same ask set, worded as § The engineer question template requires |

## Standing rulings

| Ruling | What it means for a session |
|--------|------------------------------|
| Technical decisions belong to the session | The user is told the outcome, never asked to pick a mechanism |
| The user is informed at a high level | A decision report names the outcome and its cost, not the parts that produced it |
| A question is asked only where § Ask set puts it | Everything else is decided and recorded per § Recording |
| A question is framed as outcomes | Each path carries its gain, its cost and its odds, per path, in the template below |

## Ask set

These questions reach the user in both modes. Nothing else does.

| Question | Reached by |
|----------|-----------|
| Scope expansion beyond the issue | Work the issue's Done-when does not carry |
| Revisiting a recorded decision | A change that contradicts a decision record |
| A destructive action | Deleting or discarding work that is not recoverable from the tracker or git |
| A change to user experience, workflow, outcome, cost or risk | A product question a finding or a lane raises |
| An action spending the owner's standing outside this repository | A lane's question about filing or commenting in another repository's tracker, or about retiring a reviewer |

A gate also asks where its own autonomy key is set to `ask`: `ORCH_MERGE_AUTONOMY` for merge consent, `PM_CREATE_AUTONOMY` for the audit's creations and every row of its Cancel section, `ORCH_DECISION_MODE` for the post-PR choices. Which gate asks is that key's answer. Under a composed `auto` those creations and cancellations are recorded per § Recording rather than asked. The audit asks under its own key alone, so a composed `auto` covers its filings wherever its tracker resolves, and the row above is a lane's question.

## Composition

Under `ceo` a composed key the settings ladder leaves unset takes the value below instead of its caller default. A key the ladder sets wins in both modes. `scripts/orch-env` decides this; no workflow re-derives it.

| Key | Value under `ceo` when the ladder sets none |
|-----|---------------------------------------------|
| `ORCH_DECISION_MODE` | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` |
| `PM_CREATE_AUTONOMY` | `auto` |

Under `engineer` every key keeps its own default, listed in [README.md](../README.md) § Settings.

## The ceo question template

```text
[WHAT THIS CHANGES FOR THE USER, ONE SENTENCE]

A. [OUTCOME OF THE FIRST PATH]
   Gains: [WHAT THE USER GETS]
   Costs: [WHAT THE USER GIVES UP]
   Odds: [HOW LIKELY THAT COST IS]
B. [OUTCOME OF THE SECOND PATH]
   Gains: [WHAT THE USER GETS]
   Costs: [WHAT THE USER GIVES UP]
   Odds: [HOW LIKELY THAT COST IS]

Recommended: [A OR B], because [ONE SENTENCE IN OUTCOME TERMS].
```

The template carries outcomes only. A question in the set names no mechanism the user does not act on, and no option by its internal name. A gate outside the set keeps its own option list under both modes and asks only where its autonomy key is set to `ask`.

## The engineer question template

```text
[QUESTION]: [OPTION_A] | [OPTION_B], with [RECOMMENDED_OPTION] recommended.
```

## Status report

```text
Landed: [WHAT SHIPPED AND WHAT IT CHANGES FOR THE USER]
Running: [WHAT IS IN FLIGHT AND WHEN IT LANDS]
Next: [WHAT STARTS AFTER THAT]
Waiting on you: [EACH OPEN QUESTION, OR none]
```

Under `engineer` a report is the same shape with the session's own vocabulary. A report the overseer writes to the user takes this shape whatever produced its rows.

## Handoff

```text
Standing rulings: [EACH STANDING RULING AND WHO MADE IT]
In flight: [ITEM, ITS PULL REQUEST, ITS NEXT STEP]
Open questions: [EACH QUESTION SENT AND NOT ANSWERED]
Traps: [WHAT WOULD BREAK IF THE NEXT SESSION MISSED IT]
Watch: [THE WAKE MECHANISM IN FORCE, ITS RE-ARM RULE, THE WATCH RUN DIRECTORY AND THE NEXT LOG LINE]
```

The overseer handoff file [oversee.md](../workflows/oversee.md) § 5 rewrites carries this shape. The stance itself is this file and is never copied into a handoff.

## Recording

| Decision | Record |
|----------|--------|
| Taken without asking | One `ruling` record in the fleet log, whose shape and append command are [oversee-events.md](oversee-events.md) § Judgement rules |
| Answered by the user | The same `ruling` record, plus whatever the answering gate already writes, such as `## Merge decision` in the pull request body |
| Refused or blocked | One `ruling` record naming the blocker and the option the session took |

The fleet log is the overseer's record, the oversee state's `fleet_log[]`. A standalone `submit-pr`, `merge-pr` or `audit-issues` session runs without that state, so its row is whatever its own answering gate already writes durably, on the second row's pattern: `## Merge decision` in the pull request body, the audit's § 8 report.

`engineer` records the same rows. The mode changes the wording, never what is written down.
