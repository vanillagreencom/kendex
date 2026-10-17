# Connect Linear

Run when the user asks to connect Linear.

Read [Secret transfer](../references/accounts-and-secrets.md#secret-transfer), [Message types](../references/communication.md#message-types) and [Authority](../references/decisions.md#authority) before acting.

Use the [home layout](../references/home-layout.md) for home paths.

## Steps

1. **Jarvis**: Read the user's instructions and private account ledger for the intended Linear account, project and team. Resolve missing values with a decision request.
2. **Jarvis**: Check for the installed `linear` package. Ask before running `kendex add --skill linear`. Read the installed Linear `README.md` § Setup for tool requirements and credential selection.
3. **Jarvis**: Resolve the project's private env file from `KENDEX_ENV_FILE`, including the project's settings layers. Use `.env.local` when no other file is selected. Check that Git ignores the file and does not track it. If needed, add its path to `.gitignore` and check again before writing. If Git tracks it or the checks fail, resolve that problem before accepting credentials. Create or protect the destination with mode 600 before the transfer.
4. **Jarvis**: Request one credential choice privately under Message types. Use the README's order: `LINEAR_APP_TOKEN`, then the complete `LINEAR_CLIENT_ID` and `LINEAR_CLIENT_SECRET` pair, then `LINEAR_API_KEY`. Request password-manager references or a protected transfer file under Secret transfer.
5. **Person**: Supply the selected credential through that private transfer route. For the client pair, enable client credentials tokens in the application's Linear settings.
6. **Jarvis**: Write the chosen credential to the selected private env file through Secret transfer. Preserve other entries. Check for a different credential or inherited value that would take precedence under the README's rules. Resolve an actor conflict with the person before using it. Check file permissions without displaying values. Record the user-selected `LINEAR_TEAM` in `kendex.settings.toml` under `[env]` when team-targeted writes are needed.
7. **Jarvis**: Run `.agents/skills/linear/scripts/linear.sh auth-check`. Read `ok`, `credential`, `actor`, `team`, `writes_enabled` and `warnings`. Compare the actor with the private account ledger. Report the selected credential type, actor, team and whether team-targeted writes are enabled. A failed check or account mismatch leaves the connection unresolved.
