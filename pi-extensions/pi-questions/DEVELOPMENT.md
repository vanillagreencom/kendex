# pi-questions development

For maintainers. What the package does for a consumer is [README.md](README.md); the calling rules the agent follows are `instructions.md`.

## Payload and result

The tool takes `{ id, header, questions: [{ header, question, options: [{ label, description }], multiple, customLabel, customPlaceholder }] }` and returns `{ requestId, answers }` with one array of labels per tab, or `{ requestId, cancelled: true }`. `extensions/question-model.ts::normalizeRequest` is the one place the request shape is judged and `normalizeAnswers` the one place an answer is; the `question` tool, the bridge and the RPC walker all go through them.

## Invariants

- The free-text row exists on every tab. `allowCustom` is read for compatibility and `allowCustom: false` does not remove the row; `extensions/__tests__/questions.test.ts` holds it. A typed answer that spells a control state arrives as an answer, never as that state.
- The submit tab is the UI's: it is added when a request has several questions or any multi-select, and a request that names a `Confirm`, `Submit`, `Review` or `Done` tab of its own is the agent's mistake, refused by `instructions.md` rather than repaired here.
- One route per request (`extensions/rpc-fallback.ts::presentQuestion`): the custom TUI when the host has one; the native dialog walker when `ctx.mode` is `rpc` or the custom UI resolved without a result; a clear error when the host has neither; and `undefined`, leaving the request pending for a bridge reply, only for a headless non-RPC context. An `external` outcome means the bridge already completed the request and the caller must not complete it again.
- The dialog walker never answers on its own. Out-of-range numbers re-prompt with an error, blank custom text re-shows the question, persistent blank input cancels after bounded attempts, and a dismissed dialog cancels the whole questionnaire the way Escape does in the TUI. A lone single-select question offers no skip row because the TUI cannot submit it empty either. `extensions/__tests__/rpc-fallback.test.ts` enumerates these.
- Answer steering (`extensions/answer-steer.ts::emitAnswerSteer`) is gated on `answersAsUserMessage`, off by default, and degrades silently on a Pi core without `sendUserMessage`; a rejected send promise is absorbed.
- Activity publication (`extensions/activity.ts`) goes through the broker at `Symbol.for("kendex.pi.activity")` when `pi-session-bridge` installed one and is silent otherwise; it never affects the question's outcome.
- The service is installed once on `globalThis` under `Symbol.for("kendex.pi-questions.service")` so the bridge reaches the same pending map the tool uses, and the questionnaire takes the shared modal lock at `Symbol.for("kendex.pi.modal-lock")` so it cannot open over another kendex popup.

## Tests

```bash
bun test ./extensions/__tests__
```
