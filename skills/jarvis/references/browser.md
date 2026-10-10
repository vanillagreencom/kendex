# Browser

## Profile and tabs

- Use a separate automation browser profile owned by the assistant. Never use the user's browser profile or attach to the user's browsing session.
- Open only the tabs needed for the delegated task. Close them when the work ends.
- Apply [computer-use.md:Desktop and terminal](computer-use.md#desktop-and-terminal) if browser work needs the user's input devices.

## Forms and captures

- Check the site, signed-in account and destination before filling a form. Fill from the approved source values. Leave an unknown value unresolved rather than guessing it.
- Read back entered values before submission without revealing protected fields. Apply [decisions.md:Authority](decisions.md#authority) to submission and any external commitment.
- Keep secrets out of snapshots and screenshots. Disable capture while a protected field, recovery code or credential is visible. Move the value through [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer).
- Check the form's result at the service. An entered field alone does not prove that submission succeeded.

## Bot checks

- On a bot check, slow down first. Reduce request frequency and use the site's supported access route.
- If the check remains, hand that step to the user. Explain which site and action need their input through [communication.md:Message types](communication.md#message-types).
- Resume only after the user completes the check and the service shows access. Do not bypass the check.
