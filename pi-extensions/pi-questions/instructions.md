## pi-questions — `question` tool

For explicit clarification when the answer materially changes the plan. Prose questions buried in your reply are easier to miss and harder to act on.

Use when: the next action depends on a choice only the user can make (which file, which approach, which environment); the request is ambiguous in a way prose paraphrasing won't resolve; you need confirmation before an irreversible/high-blast-radius action (deletes, force-pushes, sending external messages).

Do not use for: simple yes/no that fits in conversation; anything you can determine yourself by reading the code; speculative "would you like me to also…" follow-ups — finish the asked work first.

Calling rules:

- Provide a clear `header`, per-tab `question` text, and concise mutually-exclusive `options`.
- `multiple: true` only when several answers can co-exist; default is single-select.
- Group related sub-questions as separate `questions[]` tabs in one call rather than chaining tool calls.
- Do not add a final `Confirm`, `Submit`, `Review`, or `Done` tab; pi-questions adds its own submit tab when needed.
