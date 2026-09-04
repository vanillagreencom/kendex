# pi-caveman development

For maintainers. What it does for a consumer is [README.md](README.md); the directive text and its rendering rules are `extensions/prompt.ts::instructions`, and the snapshot matrix under `tests/__snapshots__/` is the record of what each mode renders.

## Invariants

- The rendered directive is a single block with no blank-line split. `pi-claude-bridge` anchors on the block's opening line, `You MUST respond in caveman`, to forward it under `includeCavemanHook`, and a split block forwards half a directive. `tests/unit-instructions.ts` holds both the anchor and the absence of a split.
- No mode teaches a `Caveman <verb>` labeling pattern, and the clarity-escape branch emits no resume sentinel; both leaked into model output as literal lines. The snapshot cases hold them.
- The clarity escape fires only for an irreversible destructive operation, `extensions/prompt.ts::shouldClarityEscape`; widening it to confusion or security questions is the regression the narrowed test guards.
- Session state is a sidecar file, `<Pi root>/kendex/sessions/<session id>/pi-caveman/state.json`, written with mode `0600`, read at `session_start` and written on every change; `extensions/caveman.ts::sidecarStatePath`. A session with no sidecar and a non-`off` configured mode snapshots that mode as its override, which is what keeps a resumed session on the mode it started with after the default changes. A `mode` change through the settings event drops the override.
- `pi-qol` reaches the mode through `Symbol.for("kendex.pi.caveman")`, the `CavemanBridge` interface in `extensions/caveman.ts`; a change to that shape is a change to `pi-qol`'s `extensions/qol/bridges.ts` in the same commit.
- Settings resolution and the bridge-hook check read `extensions/prompt.ts::configurationSource` and `bridgeCavemanHookEnabled`, which read the project scope only when Pi reports it trusted.

## Tests

```bash
npm test
```

`tests/unit-instructions.ts` runs under Node's test runner through `tsx`; `bun` is not used here.
