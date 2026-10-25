# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run several issues at once, each in its own agent session, called a lane.

## Features

- Takes an issue through implementation, review, required checks and merge.
- Runs a fleet of lanes and reports questions, stopped work, merges and security alerts.
- Selects accounts with room for the chosen model and resumes stopped work on a suitable account.
- Carries questions and directives between the overseer and lanes on the same machine or another host.
- Runs lanes on Claude Code, Codex, OpenCode, Pi and Copilot CLI. Fleet and account-selection support varies by harness.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

The primary agent implements and reviews one issue through specialist agents. It opens the pull request and follows the repository's merge policy. A fleet overseer starts one lane per issue, answers lane questions and resumes stopped lanes. Each lane finishes its own pull request. After merge, the repository's declared owner runs the post-merge steps.

For a fleet on another machine, see [Hosted oversight](docs/hosted-oversight.html).

## Setup

Set defaults in `kendex.settings.toml` under `[env]` and secrets in `.env.local`. Installation adds no settings. The [settings guide](kendex.settings.toml.example) holds the configuration forms; each script's `--help` owns its command options and operational defaults. Runtime dependencies and required skills are listed in [SKILL.md](SKILL.md#configuration).

For Linear, add the started states `In Review` and `Verifying` in the team settings. Add the linear skill for Linear issues. Set `ORCH_VERIFY_SCHEDULE` to name where and how often an existing scheduler starts `/orch verify` on the base checkout. orch supplies no scheduler.

| Setting | Use |
| --- | --- |
| `ORCH_LANE_HOST` | Choose where lanes run. See [host kinds](schemas/lane-host.md#host-kinds). |
| `ORCH_LANE_PREFERENCE` | Choose lane model order and host policy. Grammar, implicit cloud selection, opt-outs and `:last`: [Lane preference](references/lane-directive.md#lane-preference). |
| `ORCH_MERGE_AUTONOMY` | Choose whether each merge needs your consent. See the settings guide's Talking to you section. |
| `ORCH_USER_MODE` | Choose the detail in questions and reports. See [communication modes](references/communication-modes.md). |
| `ORCH_PR_ORDER` | Choose publication order. See `pr-order --help`. |
| `ORCH_DELIVERY` | Choose pull requests or direct base delivery. See [base publication](workflows/submit-pr.md#21-base-publication). |

Dependabot security updates open the fleet's fix pull requests. An organization owner enables them through an organization security configuration.

For launch admission, file briefs, caps and recovery, read [Lane directive](references/lane-directive.md). For directive delivery and its host coverage, read [Watch delivery](references/watch-delivery.md). For merge and queue recovery, read [Merge](workflows/merge-pr.md#5-execute-the-merge).

Maintainer notes and the test entry point are in [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
