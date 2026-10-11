# Connect GitHub

Run when the user asks to connect GitHub.

Read [Secret transfer](../references/accounts-and-secrets.md#secret-transfer), [Message types](../references/communication.md#message-types) and [Authority](../references/decisions.md#authority) before acting.

Use the [home layout](../README.md#home-layout) for home paths.

## Steps

1. **Jarvis**: Read the user's instructions and [Account ledger](../references/accounts-and-secrets.md#account-ledger) for the intended GitHub account and local tool home. Resolve missing values with a decision request.
2. **Jarvis**: Check for the installed `github` package and its required tools. Ask before running `kendex add --skill github`. Read the installed GitHub `README.md` § Setup and `scripts/github.sh --help` § Token selection and § Auth preflight.
3. **Jarvis**: Offer `gh auth login` or a supplied `GH_TOKEN` as a private decision request. Use the tool home recorded in the ledger. Check whether inherited or project credentials would select a different account before sign-in.
4. **Person**: Run `gh auth login` and complete sign-in in the intended account. Alternatively, supply a `GH_TOKEN` through a password-manager reference or protected transfer file under Secret transfer.
5. **Jarvis**: For a supplied token, resolve the project's private env file through `KENDEX_ENV_FILE` and the project's settings layers, defaulting to `.env.local`. Check that Git ignores the file and does not track it before writing. Add an ignore entry if needed and check again. Resolve a tracked file or failed check before accepting the token. Create or protect the destination with mode 600, then write `GH_TOKEN` through Secret transfer. Preserve other entries.
6. **Jarvis**: Prepare the proof process with the selected token in its environment through Secret transfer, or the signed-in `gh` home for the login route. A bare `gh` process does not load the project's private env file. Resolve any different account selected by the GitHub package's credential routing before proceeding.
7. **Jarvis**: Run `gh api user --jq .login` in that process. Compare the returned account and tool home with the Account ledger. Report the signed-in account, tool home and ledger match. A failed read or mismatch leaves the connection unresolved.
