# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run many issues at once, each in its own agent session, called a lane.

## Features

- `orch start` takes one issue from its worktree to merge.
- `orch oversee` launches one lane per unblocked issue and takes each pull request to merge.
- The overseer's watch reports merges, lane questions, stopped lanes, new Linear issues and GitHub security alerts.
- A lane and the overseer exchange questions, notices and directives through a mailbox, also with a lane on another machine.
- orch starts and replaces overseers, recovers one that died or hit an account limit, and adopts an overseer session you opened by hand.
- orch reads each account's usage and picks the account a lane launches on. The watch reports usage limits and their resets.
- Lanes can run on another machine through a host provider, with the same mailbox and watch. `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends, and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- orch writes the overseer's status reports and times each merge against the target for its change class.
- orch relaunches a stopped lane. The lane resumes its own agent session on the same account, a local Claude Code lane also on another account whose home holds that session, and any other lane starts fresh from its handoff record.
- Each review finding is fixed, filed as an issue or declined under [the reviewer's disposition rules](../reviewer/references/finding-disposition.md). Settings cap the review and CI-fix rounds.
- [references/secret-value.ere](references/secret-value.ere) matches GitHub and Slack tokens and private-key headers, so scripts can refuse to send matching text or files.
- Lanes run on Claude Code, Codex, Pi and Copilot CLI.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

You start orch on an issue, or start an overseer for many. Each lane implements its issue, has it reviewed and fixed, and opens the pull request. It arms auto-merge where your merge policy allows. The lane merges its own pull request, directly or through the merge queue.

The overseer's watch waits until a lane needs attention. The overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge. A message from the overseer reaches the lane when the lane next pauses.

Three packages split the work. orch decides what happens to each issue. agent-runtime starts, reads and stops the agent sessions. The mailbox carries the messages between them.

## Packages

kendex installs these with orch.

| Package | What orch uses it for |
|---|---|
| agent-runtime | Launching, reading, messaging and stopping each harness session, and the accounts it runs on |
| mailbox | The messages between a lane, its overseer and you |
| communication | The wording of every message, question and report to you |
| github | Pull requests, reviews, CI reads and the merge |
| worktree | The worktree each lane works in |
| dev | The implementing agent's rules |
| reviewer | The review agents' rules and the finding dispositions |
| change-scope | Sizing each change, which sets its review depth and the CI checks it runs |
| decider | The decision records a review checks against |

## Harnesses and platforms

| | Claude Code | Codex | Pi | Copilot CLI |
|---|---|---|---|---|
| On Linux, a lane runs sandboxed | yes | yes | yes | no |
| On macOS, a lane runs sandboxed | no | no | no | no |

On Linux the sandbox limits a lane's writes to its checkout, its issue's own records and the folders its launch grants. Copilot CLI lanes run outside it because the sandbox would hide Copilot's sign-in.

The sandbox is not complete. A sandboxed lane can still write:

- the account folders' plugins and instruction files, and the session folders, among them the shell snapshots Claude Code runs before each command;
- four parts of the main checkout's git folder: its hooks folder when it has none at launch, its worktree settings, its submodule stores and its attributes file;
- the other lanes' worktree records.

Your own tools may later run or load what a lane wrote there.

## Setup

kendex installs the skills orch requires, agent-runtime among them. Build the runtime once per install:

```bash
.agents/skills/orch/scripts/setup
```

The build needs Rust 1.96 or later. orch also needs `tmux` 3.1 or later, `git`, `setsid`, `gh`, `jq` and Bash 3.2 or later. The included SSH host provider needs Python 3 and `flock`. On Linux the lane sandbox needs `bwrap` with unprivileged user namespaces. `.agents/skills/orch/scripts/orch-runtime ready` names anything missing.

For Linear issues, add project-management and linear, and add the started states `In Review` and `Verifying` in the team settings. Second-opinion and review-gate are optional.

`/orch verify` checks the issues in Verifying. orch supplies no scheduler: start an agent on the base checkout for `/orch verify` from one you already use, and name where and how often it runs in `ORCH_VERIFY_SCHEDULE`.

Dependabot security updates open the fix pull requests for the alerts the watch reports. An organization owner turns them on for every repository through an organization security configuration.

Settings: [references/settings.md](references/settings.md). Maintainer notes and the test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
