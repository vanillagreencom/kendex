# pi-caveman development

Consumer setup is in [README.md](README.md). Cross-package changes follow [../AGENTS.md](../AGENTS.md).

## Test

Run from this package directory:

```sh
npm test
```

The prompt suite uses Node with `tsx`, not Bun. When changing the directive, inspect the bridge text contract beside `extensions/prompt.ts::instructions` and the complete prompt snapshots in `tests/__snapshots__/`. `tests/unit-instructions.ts` updates those snapshots when `UPDATE_SNAPSHOTS=1`; inspect their diff before accepting a prompt change.

## Debug

Run `/caveman debug` in Pi to see the effective mode, session override, settings source and rendered prompt. A session override can keep the mode different from the current default. Changing `mode` through the settings editor clears that override.

For a Claude bridge session, check `includeCavemanHook` in the bridge configuration. The debug report reads the extension-manager setting; it does not read the bridge's separate `claude-bridge.json` file. Native Pi providers need no bridge setting.
