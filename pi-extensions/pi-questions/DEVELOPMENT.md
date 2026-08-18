# pi-questions — development notes

Internals, design, and maintenance for the pi-questions Pi extension. Consumer docs live in [`README.md`](./README.md).

## `question` tool payload

```json
{
  "id": "que_example",
  "header": "Choose next action",
  "questions": [
    {
      "header": "Issue Missing",
      "question": "How should I proceed?",
      "options": [
        { "label": "Use current branch", "description": "Continue without a tracker issue." },
        { "label": "Stop here", "description": "Wait for operator guidance." }
      ],
      "multiple": false,
      "customLabel": "Something else"
    }
  ]
}
```

Result:

```json
{ "requestId": "que_example", "answers": [["Stop here"]] }
```

Cancelled:

```json
{ "requestId": "que_example", "cancelled": true }
```

Every tab includes a bottom free-text fallback row by default, labelled `Something else` unless `customLabel` overrides it. Agents no longer need to set `allowCustom` for a basic escape hatch; the legacy flag is still accepted for compatibility, and `allowCustom: false` does not disable the fallback. `customPlaceholder` customizes the input hint.

When the user types fallback text, the result uses the same answer shape as fixed options:

```json
{ "requestId": "que_example", "answers": [["Use issue ABC-123 instead"]] }
```

Do not include a final `Confirm`, `Submit`, `Review`, or `Done` question tab in the payload; the UI adds its own submit tab when needed.
