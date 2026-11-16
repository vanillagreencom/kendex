# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run many issues at once, each in its own agent session, called a lane.

## Features

- `orch start` takes one issue from its worktree to merge.
- `orch oversee` launches one lane per unblocked issue and takes each pull request to merge. Its fleet watch reports merges, lane questions, stopped lanes, new Linear issues and GitHub security alerts, and the overseer runs the post-merge steps through the repository's declared refresh owner.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so a message needs no tmux pane and also reaches a lane on another machine.
- The orch runtime opens and replaces overseers, recovers a dead or walled one, and resumes a recorded session. [The overseer workflow](workflows/oversee.md#controller-start-and-adoption) gives the start and handoff steps; `orch-runtime register` records a session you opened by hand.
- The orch runtime reads each account's usage and picks the account a lane launches on; the watch reports usage limits and their resets.
- Lanes can run on another machine through a host provider, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends, and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- The orch runtime writes the overseer's status reports (`orch-runtime report`) and times each merge against its class target (`orch-runtime cycle`).
- A stopped lane is relaunched: it resumes its own agent session on the same account, or starts fresh from its handoff record on another. Workflow state and handoff files let a lane or an overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined under [the reviewer's disposition rules](../reviewer/references/finding-disposition.md); settings cap the review and CI-fix rounds.
- [references/secret-value.ere](references/secret-value.ere) matches GitHub and Slack tokens and private-key headers, so scripts can refuse to send matching text or files. Its header states how to read it.
- Lanes run on Claude Code, Codex, Pi and Copilot CLI, on this machine or another, alone or in a fleet.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

You start orch on an issue, or start an overseer for many. Each lane implements its issue, has it reviewed and fixed, opens the pull request, and arms auto-merge where your merge policy allows it. The lane merges its own pull request, past the merge queue or through it, as the github skill's `pr-merge --help` § Merge route says. Under harness-ci's queue-only default every change takes the queue, and a red merge-group run follows the re-queue rule of [workflows/merge-pr.md § 5](workflows/merge-pr.md#5-execute-the-merge).

The overseer's watch waits until a lane needs attention. The overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge. A directive from the overseer reaches the lane at its turn end where the harness runs hooks, and at the lane's next wait point where it does not.

Three owners split the work: orch decides what happens to each issue, agent-runtime starts, reads and stops the agent sessions, and the mailbox carries the messages between them. Why they are separate: [orchestration.md](https://github.com/vanillagreencom/kendex/blob/main/docs/architecture/orchestration.md).

## Packages

kendex installs these with orch.

| Package | What orch uses it for |
|---|---|
| agent-runtime | Launching, reading, messaging and stopping each harness session, and the accounts it runs on |
| mailbox | `lane-mail`, the messages between a lane, its overseer and you |
| communication | The wording of every message, question and report to you |
| github | Pull requests, reviews, CI reads and the merge |
| worktree | The worktree each lane works in |
| dev | The implementing agent's rules |
| reviewer | The review agents' rules and the finding dispositions |
| change-scope | The change class and branch measurement a tier, review depth and CI selection rest on |
| decider | The decision records a review checks against |

## Harnesses and platforms

| | Claude Code | Codex | Pi | Copilot CLI |
|---|---|---|---|---|
| Lanes | yes | yes | yes | yes |
| On Linux, a lane runs sandboxed | yes | yes | yes | no |
| On macOS, a lane runs sandboxed | no | no | no | no |

On Linux a sandboxed lane's writes are held to its checkout, its item's own records and the folders its launch grants. A Copilot CLI lane runs unsandboxed everywhere, since Copilot reads its sign-in over the session bus the sandbox hides. On macOS every lane runs unsandboxed. The package's suites run in CI on Linux and on macOS, against a stand-in harness.

## Setup

kendex installs the skills orch requires, agent-runtime among them. Build the runtime once per install:

```bash
.agents/skills/orch/scripts/setup
```

The build needs Rust 1.96 or later. orch also needs `tmux`, `git`, `setsid`, `gh`, `jq` and Bash 3.2 or later; the included SSH host provider needs Python 3 and `flock`. On Linux the lane sandbox needs `bwrap` with unprivileged user namespaces. `.agents/skills/orch/scripts/orch-runtime ready` names anything missing.

For Linear issues, add project-management and linear, and add the started states `In Review` and `Verifying` in the team settings. Second-opinion and review-gate are optional.

Name where and how often `/orch verify` runs with `ORCH_VERIFY_SCHEDULE`, and start an agent on the base checkout from a scheduler you already use; orch supplies none.

Dependabot security updates open the fix pull requests for the alerts the watch reports. An organization owner turns them on for every repository through an organization security configuration.

Settings: [references/settings.md](references/settings.md). Maintainer notes and the test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
