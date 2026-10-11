# Connect a fleet machine

Run when the user asks to connect a fleet machine.

Read [Secret transfer](../references/accounts-and-secrets.md#secret-transfer), [Message types](../references/communication.md#message-types) and [Authority](../references/decisions.md#authority) before acting.

## Steps

1. **Jarvis**: Read the user's instructions and private account ledger for the machine and permitted remote work. Request the SSH destination as a private decision request.
2. **Person**: Supply the SSH host and account. Complete account sign-in, SSH key authorization and host verification through the machine's supported setup. Keep any credential transfer under Secret transfer.
3. **Jarvis**: Check for the installed `orch` package. Ask before running `kendex add --skill orch`. Read the installed orch `README.md` § Setup, `schemas/lane-host.md` § Static SSH implementation and `scripts/lane-host-ssh --help` for host prerequisites and the inventory contract.
4. **Jarvis**: Check the supplied host with an SSH read, `ssh HOST uname -s`, using the person's SSH configuration. Resolve a failed connection or unknown host with the person. Confirm the host has the prerequisites named by the static SSH contract before declaring it ready for lanes.
5. **Jarvis**: Obtain the user's repository, item, remote clone and harness account paths needed by the inventory contract. Add the approved host entry to the project's inventory without changing other entries. Set `LANE_HOST_SSH_INVENTORY` to that file and `ORCH_LANE_HOST` to the installed `.agents/skills/orch/scripts/lane-host-ssh` executable in `kendex.settings.toml` under `[env]`. Resolve its path from the project, not from a machine-specific layout.
6. **Jarvis**: Run `.agents/skills/orch/scripts/lane-host capabilities`. Read the validated capabilities under `schemas/lane-host.md` § Host kinds. Confirm `kind=ssh`. Report the selected provider, the SSH connection result and the supported actions. This read checks provider configuration; the earlier SSH read proves host access. A failed read leaves setup unresolved.
