# Connect a fleet machine

Run when the user asks to connect a fleet machine.

Before acting, read [Secret transfer](../references/accounts-and-secrets.md#secret-transfer), [Message types](../references/communication.md#message-types) and [Authority](../references/decisions.md#authority).

## Steps

1. **Jarvis**: Read the user's instructions and private account ledger for the machine and its permitted remote work.
   - Ask for the SSH destination as a private decision request.
2. **Person**: Supply the SSH host and account.
   - Complete account sign-in, SSH key authorization and host verification through the machine's supported setup.
   - Keep any credential transfer under Secret transfer.
3. **Jarvis**: Check for the installed `orch` package.
   - Ask before running `kendex add --skill orch`.
   - For the host prerequisites and the inventory contract, read the installed orch `README.md` § Setup, `schemas/lane-host.md` § Static SSH provider and `scripts/lane-host-ssh --help`.
4. **Jarvis**: Check the supplied host with an SSH read, `ssh HOST uname -s`, through the person's SSH configuration.
   - Resolve a failed connection or an unknown host with the person.
   - Before declaring the host ready for lanes, confirm it has the prerequisites the static SSH contract names.
5. **Jarvis**: Get the user's repository, item, remote clone and harness account paths the inventory contract needs.
   - Add the approved host entry to the project's inventory, and change no other entry.
   - In `kendex.settings.toml` under `[env]`, set `LANE_HOST_SSH_INVENTORY` to that file and `ORCH_LANE_HOST` to the installed `.agents/skills/orch/scripts/lane-host-ssh` executable.
   - Resolve the executable path from the project.
6. **Jarvis**: Run `.agents/skills/orch/scripts/orch-runtime host list` with the saved project settings.
   - Match the returned repository and item, and the SSH target, to the approved inventory entry.
   - Confirm the state is `hosted` or `available`.
   - A failed read, missing row or mismatch leaves setup unresolved.
7. **Jarvis**: Run `.agents/skills/orch/scripts/orch-runtime host capabilities`.
   - Read the validated capabilities under `schemas/lane-host.md` § Host kinds, and confirm `kind=ssh`.
   - Report the selected provider, inventory row match, host state, SSH connection result and supported actions.
   - A failed read leaves setup unresolved.
