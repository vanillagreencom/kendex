# Browser

## Browser guide

- Before a browser step, run `agent-browser skills get core`. Read the guide that the installed CLI returns.
- Use kendex to manage the Jarvis package. The browser guide comes from the CLI and needs no separate skill installation.

## Profile and tabs

- Use a separate automation browser profile owned by the assistant. Never use the user's browser profile or attach to the user's browsing session.
- Use the packaged [jarvis-browser](../scripts/jarvis-browser) to open the task's URL. Platform: Linux and macOS. Read its `--help` for configuration and command syntax.
- Set `JARVIS_BROWSER_PROFILE` to the absolute path of the assistant's profile. Set `JARVIS_BROWSER_COMMAND` when the browser needs an explicit executable. Set `JARVIS_BROWSER_DOWNLOADS` to an absolute downloads directory and `JARVIS_BROWSER_CLASS` to the window's app id when the home needs them. The downloads directory applies when the driver opens a closed profile. Keep profile paths and machine-specific settings in the consumer's local configuration.
- With no configured executable, the driver detects Chromium, Chrome, Brave or Edge. Use the plain invocation as the service form: the browser replaces the driver as the unit's main process. Pass `--detach` from a terminal when the task must continue there: the driver checks the request, starts the browser in its own session and returns. Use the plain form in a service unit.
- Connect `agent-browser` to the port `jarvis-browser --port` prints. Follow the installed browser guide for the connection command. Check the site and account after connection.
- For a vendor CLI's browser sign-in, put the directory `jarvis-browser --shim` prints first on that CLI's `PATH`. Its `xdg-open`, `x-www-browser` and `www-browser` open the sign-in page in the assistant profile and return at once. A refused request prints the driver's `jarvis-browser: key=value` line and exits with its status. Platform: Linux.
- Open only the tabs needed for the delegated task. Close them when the work ends.
- After a vendor CLI's browser sign-in, remove query strings from every URL in a tab list, including URLs used as titles, before logging or reporting it. Sign-in URLs can contain `state` and `code` parameters. Sanitize the list before any raw tool output reaches a log.
- Apply [computer-use.md:Desktop and terminal](computer-use.md#desktop-and-terminal) if browser work needs the user's input devices.

## Forms and captures

- Use an absolute capture path under the home's scratch folder in [computer-use.md:Scratch files](computer-use.md#scratch-files).
- Check the site, signed-in account and destination before filling a form. Fill from the approved source values. Leave an unknown value unresolved rather than guessing it.
- Read back entered values before submission without revealing protected fields. Apply [decisions.md:Authority](decisions.md#authority) to submission and any external commitment.
- Keep secrets out of snapshots and screenshots. Disable capture while a protected field, recovery code or credential is visible. Move the value through [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer).
- Check the form's result at the service. An entered field alone does not prove that submission succeeded.

## Desktop input

- For an approved mouse, keyboard or capture action, use the packaged [human-input](../scripts/human-input). Platform: Linux Wayland. Read its `--help` for command syntax and the tools each action requires.
- Apply [computer-use.md:Desktop and terminal](computer-use.md#desktop-and-terminal) before using the user's input devices. Check the target window before sending input.
- Supply text through standard input to the `type` action, which prints nothing. To type a secret, run `human-input type < FILE` on a mode-600 file from [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer). Give `shot` an absolute path under the home's scratch folder. It creates a protected capture file and refuses to overwrite an existing file.
- Apply [Forms and captures](#forms-and-captures) to input and screenshots. The input driver does not change the [bot-check handoff](#bot-checks).

## Bot checks

- On a bot check, slow down first. Reduce request frequency and use the site's supported access route.
- If the check remains, hand that step to the user. Explain which site and action need their input through [communication.md:Message types](communication.md#message-types).
- Resume only after the user completes the check and the service shows access. Do not bypass the check.
