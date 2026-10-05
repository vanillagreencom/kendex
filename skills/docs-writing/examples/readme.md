The repository's `README.md`:

````markdown
# vsys

A Linux terminal dashboard for people who run several AI coding agents on one machine. It shows each agent with its control group, build processes and resource use, and can freeze or stop an agent you choose.

![vsys showing four agents and their resource use](docs/images/vsys-tour.gif)

## Features

- Lists each agent with its tool, account, branch, process id and tmux pane.
- Shows CPU, memory, disk I/O and resource pressure per agent and per systemd slice.
- Finds agents running outside the agent slice or under a memory limit below the floor.
- Attributes compiler and linker processes to the agent that started them.
- Records agent starts, stops and resource alerts.
- Freezes, thaws or stops an agent after you enable write mode and confirm.

## Install

```sh
bun install -g vsys
```

```sh
paru -S vsys
```

Linux with cgroup v2 only.

## How it works

vsys reads the kernel's process and control-group files with your own permissions. It groups each agent's processes by control group, samples their use every second, and keeps the history for the charts. Nothing on the machine changes until you turn write mode on and confirm an action.

## Setup

Settings live in `~/.config/vsys/config.toml`. Edit them from the Settings screen or in the file.

| Setting | What it changes |
| --- | --- |
| `watchedSlices` | The control groups shown in the agent list. |
| `agentTools` | The program names vsys treats as agents. |
| `writeMode` | Allows freeze, thaw and stop. Off by default. |

## Licence

[MIT](LICENSE)
````

---

## Not this

> | `agentTools` | The program names that vsys treats as agents. The default comes from `data/agent-tools.json`. Settings saves machine-local additions in `~/.config/vsys/agent-tools.json`, which the warden also reads. A program counts as an agent only when its executable or script sits where that tool installs itself: a `paths` fragment, an `executables` path or a `mise` install directory its entry lists. For an agent installed somewhere else, add an overlay entry with the shipped name and the location, such as `{"name": "codex", "executables": ["/usr/local/bin/codex"]}`. A name you add in Settings carries no install location, so it matches by program name alone; add `paths` or `executables` to its entry in the overlay to match it only there. The warden never matches `paths`, so an entry the warden must move automatically needs `executables` or a `mise` directory. ... |

A person choosing the tool is handed the matching algorithm: the detail belongs to `--help` and the code, and the README was overwritten by the work instead of describing the thing.
