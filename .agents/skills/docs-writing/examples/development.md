# vsys development

Bun at the version in `.bun-version`, on a Linux host with cgroup v2.

## Run

```sh
bun install
bun run start              # the dashboard against this checkout
bun run start -- --once    # one sample, then exit: a quick read of a change
```

## Test

```sh
bun test                   # the unit suites
bun test --filter cgroup   # one suite
sudo bun run test:root     # the suites that need a real control group; skipped otherwise
```

## Debug

Set `VSYS_LOG=debug` to log every sample to stderr. `bun run start -- --fixture tests/fixtures/four-agents/` runs the dashboard against a recorded machine, which is how a layout change is checked without four agents running.

## Release

`scripts/release <version>` bumps the version, collates the changelog and tags; the tag starts the publish workflow.

---

## Not this

> ## Architecture
>
> The sampler (`src/sampler.ts`) calls `readCgroup()` for each watched slice, which opens `cpu.stat` and `memory.current` and hands the rows to `store.ts`, a ring buffer of 3600 samples; `render.ts` then reads the buffer on every tick and ...

A code walkthrough restates what the code shows and is stale on the next refactor; a maintainer wanted the commands the tooling does not show.
