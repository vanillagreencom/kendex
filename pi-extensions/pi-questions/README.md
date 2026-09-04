# @vanillagreen/pi-questions

Structured questions for Pi. The agent's `question` tool opens a multiple-choice questionnaire in the editor area, one tab per question with a free-text fallback row, and the answer comes back as selected labels or typed text.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-questions"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-questions):

```bash
pi install npm:@vanillagreen/pi-questions
```

Restart Pi after installation.

## What it does

- The `question` tool asks one or more single-select or multi-select questions in one call, each on its own tab, with a submit tab added when more than one answer is needed.
- Every question carries a bottom free-text row, labelled `Something else` unless the agent renames it, so there is always an escape hatch.
- The questionnaire renders in the editor area by default or as a floating overlay, with tab hints and highlighted rows; a wrapped option stays readable in a narrow pane.
- The answered tool output lists every answer compactly and expands inline to show each question with its choice marked.
- In an RPC host that cannot render a custom TUI, the questions are walked one at a time through the host's native select and input dialogs; a host with neither returns an error instead of hanging.
- With `pi-session-bridge` loaded, pending questions can be listed, answered and rejected from outside the session, and each open, answer and rejection publishes a `question.*` activity event.
- With `answersAsUserMessage` on, every answered question is also delivered to the agent as one user message quoting the question and the answers, for observer extensions that read the conversation stream and ignore tool output.
- A `pi-qol` notification fires before a question opens.

## How it works

The tool normalises the request, opens the questionnaire through Pi's custom UI, and resolves with the answers, a cancellation, or a completion that arrived through the bridge while the questionnaire was open. Headless sessions leave the request pending for a bridge reply. Answers keep one shape in every mode: an array of selected labels per tab.

## Bridge control

With `pi-session-bridge` installed, from any shell:

```bash
pi-bridge questions
pi-bridge answer --request-id que_example --answers '[["Stop here"]]'
pi-bridge reject --request-id que_example
```

## Customise

Open `/extensions:settings`; settings appear under the **Questions** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle.
- `renderMode`, `popupWidth`, `popupMaxHeight`, `optionRows`, `defaultHeader`, `glyphStyle`: where and how the questionnaire renders.
- `bridgeRepliesEnabled`: whether `pi-session-bridge` may answer or reject a pending question.
- `answersAsUserMessage`: mirror each answer into the conversation as a user message.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
