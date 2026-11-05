# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run many issues at once, each in its own agent session, called a lane.

## Features

- `orch start` takes one issue from its worktree to merge.
- `orch oversee` launches one lane per unblocked issue, reports merges, lane questions, stopped lanes, new Linear issues and GitHub security alerts as events through `oversee-watch`, takes each PR to merge, then runs the post-merge steps through the repository's declared refresh owner.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so messages need no tmux pane and also reach a lane on another machine.
- The orch runtime opens and replaces overseers, recovers a dead or walled controller and resumes a recorded native session. [The overseer workflow](workflows/oversee.md#controller-start-and-adoption) gives the start and handoff steps. `oversee register` records a session opened by hand.
- The orch runtime reads account usage and picks a launch's account on projected room weighted by time to reset, overseer seats last under their window reserve rule. The watch reports account usage limits and their resets.
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- `oversee-report` writes the overseer's status reports; `oversee-cycle` times each merge against its class target.
- `open-terminal --relaunch` resumes a stopped lane's own agent session, on the same account or another, and workflow state and handoff files let a lane or overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined by the rules in [references/finding-disposition.md](../reviewer/references/finding-disposition.md), settings cap the review and CI-fix rounds.
- [references/secret-value.ere](references/secret-value.ere) matches GitHub and Slack tokens and private-key headers for scripts to refuse to send matching text or files. Its header states how to read it.
- Lanes run on Claude Code, Codex, OpenCode, Pi and Copilot CLI, remotely and in a fleet on all but OpenCode (Copilot fleets local); account selection, succession and preference entries cover all but OpenCode.

Dependabot security updates open the fleet's fix pull requests; an organization owner turns them on for every repository through an organization security configuration.

A directive is handed over at the lane's turn end where the harness runs hooks, and at the lane's next wait point where it does not. Delivery is checked on every harness kendex installs the mailbox hook on. That check runs on one machine at a time and is started by hand, so run it on a fleet's control machine to cover it.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

The primary agent opens the PR and, by the merge policy, arms auto-merge where the base requires the review gate. `oversee-watch` waits until a lane needs attention, and the overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge.

## Setup

Requires jq, Bash 3.2, Python 3.8+, flock, setsid and timeout or gtimeout. Local lane-mail and the included SSH host provider use Python on the controlling machine. kendex installs the required skills, agent-runtime among them; run `.agents/skills/orch/scripts/setup` once per install to build the orch runtime, which needs Rust 1.96 or later. Add project-management and linear for Linear issues. Second-opinion, review-gate and project-management are optional.

For Linear, add the started states `In Review` and `Verifying` in the team settings. Name where and how often `/orch verify` runs with `ORCH_VERIFY_SCHEDULE`. Use an existing scheduler to start an agent on the base checkout. orch supplies no scheduler.

Settings: [references/settings.md](references/settings.md).

Every lane merges its own pull request, past the merge queue or through it, as the github skill's `pr-merge --help` § Merge route says. Under harness-ci's queue-only default every change takes the queue: the merge-group run proves the head, a red one returns the change to its lane, and an unchanged head never re-enters the queue, per [workflows/merge-pr.md § 5](workflows/merge-pr.md#5-execute-the-merge) Recovery cycle.

Maintainer notes and test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
