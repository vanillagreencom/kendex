# Connect Slack

Run when the user asks to connect Slack.

Read [Secret transfer](../references/accounts-and-secrets.md#secret-transfer), [Message types](../references/communication.md#message-types) and [Authority](../references/decisions.md#authority) before acting.

## Steps

1. **Jarvis**: Read the user's instructions and private account ledger for the intended Slack account and project. Resolve missing values with a decision request.
2. **Jarvis**: Check for the installed `slack` package. Ask before running `kendex add --skill slack`. It also installs the required `orch` package. Read the installed Slack `SKILL.md` and `README.md` § Slack app and § Setup.
3. **Person**: In the intended Slack account, create an app from the installed `.agents/skills/slack/app-manifest.yaml`. Install it to the intended workspace. Create an app-level token with the `connections:write` scope under Basic Information.
4. **Jarvis**: Resolve the project's private env file from `KENDEX_ENV_FILE`, including the project's settings layers. Use `.env.local` when no other file is selected. Check that Git ignores the file and does not track it. If needed, add its path to `.gitignore` and check again before writing. If Git tracks it or the checks fail, resolve that problem before accepting credentials. Create or protect the destination with mode 600 before the transfer.
5. **Jarvis**: Send a private decision request for `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`. Request their password-manager references or a protected transfer file under Secret transfer.
6. **Person**: Supply the bot token and app-level token through that private transfer route. Supply the test channel ID. Invite the app to that channel.
7. **Jarvis**: Write both values to the selected private env file through Secret transfer. Preserve other entries. Check file permissions without reading the values into output.
8. **Jarvis**: Prepare a test message. Get approval for its exact text and channel under Authority. Run `.agents/skills/slack/scripts/slack post --channel ID --text TEXT` with the approved values. Read the returned channel and message timestamp. A failed or uncertain post remains unresolved.
9. **Jarvis**: Read that message in Slack through the supported browser interface. Confirm its text and channel match the approved test. Report the channel, message timestamp, observed text match and private file permission check.
