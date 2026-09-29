# pi-extensions/

Pi extension packages, one npm package per directory, each a `pi-package`.

- Every package follows the policy `package-policy.test.mjs` asserts: the Pi Node baseline, the `pi-package` keyword, optional Pi peers with `>=x.y.z` ranges, the vendored append-system helper under each package's `scripts` directory identical across packages, and TypeScript that Node's strip-only parsing accepts. Run `node --test pi-extensions/package-policy.test.mjs`.
- Lanes move to a new Pi release, and a Pi peer floor rises to it, only after the Pi update audit (`.pi/prompts/pi-update.md`) records it in `pi-update.audit.md` with verdict `roll`. A `### Breaking Changes` entry that names an event or call listed in `pi-hooks/pi-contract.json` is blocking: the verdict is `hold` until the pi-hooks change for it lands, or the record names the real Pi session check that shows pi-hooks needs none. A `hold` leaves the marker in `pi-update.state.json` at the last cleared release, so the next audit reads the held release's entries again. The policy test refuses a peer floor above the release the record clears, and a record that clears a release other than the state marker's.
- Pi's real behaviour is read from `pi-update.audit.md` first and the mise-installed Pi second, never from a cached bundle.
- A package's CI entry point is `test:ci` when declared, else `test`; a step conditioned on a shard name `.github/workflows/skill-tests.yml` does not carry fails the policy test.
