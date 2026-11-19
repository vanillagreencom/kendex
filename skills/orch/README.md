# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run many issues at once, each in its own agent session, called a lane.

## Features

- `orch start` takes one issue from its worktree to merge.
- `orch oversee` launches one lane per unblocked issue and takes each pull request to merge.
- The fleet watch reports merges, lane questions, stopped lanes, new Linear issues and GitHub security alerts. The overseer runs the post-merge steps through the repository's declared refresh owner.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree. A message needs no tmux pane, and it also reaches a lane on another machine.
- The orch runtime opens and replaces overseers, recovers a dead or walled one, and resumes a recorded session. [The overseer workflow](workflows/oversee.md#controller-start-and-adoption) gives the start and handoff steps. `orch-runtime register` records a session you opened by hand.
- The orch runtime reads each account's usage and picks the account a lane launches on. The watch reports usage limits and their resets.
- Lanes can run on another machine through a host provider, with the same mailbox and watch. `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends, and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- The orch runtime writes the overseer's status reports (`orch-runtime report`) and times each merge against its class target (`orch-runtime cycle`).
- orch relaunches a stopped lane. The lane resumes its own agent session on the same account, or starts fresh from its handoff record on another. Workflow state and handoff files let a lane or an overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined under [the reviewer's disposition rules](../reviewer/references/finding-disposition.md). Settings cap the review and CI-fix rounds.
- [references/secret-value.ere](references/secret-value.ere) matches GitHub and Slack tokens and private-key headers, so scripts can refuse to send matching text or files. Its header states how to read it.
- Lanes run on Claude Code, Codex, Pi and Copilot CLI, on this machine or another, alone or in a fleet.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

You start orch on an issue, or start an overseer for many. Each lane implements its issue, has it reviewed and fixed, and opens the pull request. It arms auto-merge where your merge policy allows. The lane merges its own pull request, past the merge queue or through it, as the github skill's `pr-merge --help` § Merge route says.

The overseer's watch waits until a lane needs attention. The overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge. A directive from the overseer reaches the lane at its turn end where the harness runs hooks, and at the lane's next wait point where it does not.

Three owners split the work. orch decides what happens to each issue. agent-runtime starts, reads and stops the agent sessions. The mailbox carries the messages between them. Why they are separate: [orchestration.md](https://github.com/vanillagreencom/kendex/blob/main/docs/architecture/orchestration.md).

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

On Linux the sandbox holds a lane's writes to its checkout, its item's own records and the folders its launch grants. A Copilot CLI lane runs unsandboxed everywhere: Copilot reads its sign-in over the session bus the sandbox hides. On macOS every lane runs unsandboxed. CI runs the package's suites on Linux and on macOS, against a stand-in harness.

The sandbox is not complete. A sandboxed lane can still write:

- the shared Cargo and npm caches and the wider cache folder;
- the account folders' plugins and instruction files;
- four git folders of the main checkout: its hooks folder where none stands at launch, its worktree configuration, its submodule stores and its attributes file;
- the other lanes' worktree records.

An operator process may later run or load what a lane wrote there.

## Setup

kendex installs the skills orch requires, agent-runtime among them. Build the runtime once per install:

```bash
.agents/skills/orch/scripts/setup
```

The build needs Rust 1.96 or later. orch also needs `tmux`, `git`, `setsid`, `gh`, `jq` and Bash 3.2 or later. The included SSH host provider needs Python 3 and `flock`. On Linux the lane sandbox needs `bwrap` with unprivileged user namespaces. `.agents/skills/orch/scripts/orch-runtime ready` names anything missing.

For Linear issues, add project-management and linear, and add the started states `In Review` and `Verifying` in the team settings. Second-opinion and review-gate are optional.

Set where and how often `/orch verify` runs with `ORCH_VERIFY_SCHEDULE`. orch supplies no scheduler: start an agent on the base checkout from one you already use.

Dependabot security updates open the fix pull requests for the alerts the watch reports. An organization owner turns them on for every repository through an organization security configuration.

Settings: [references/settings.md](references/settings.md). Maintainer notes and the test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
