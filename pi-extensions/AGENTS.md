# pi-extensions/

Pi extension packages, one npm package per directory, each a `pi-package`.

- Every package follows the policy `package-policy.test.mjs` asserts: the Pi Node baseline, the `pi-package` keyword, optional Pi peers with `>=x.y.z` ranges, the vendored append-system helper under each package's `scripts` directory identical across packages, and TypeScript that Node's strip-only parsing accepts. Run `node --test pi-extensions/package-policy.test.mjs`.
- Pi's real behaviour is read from `pi-update.audit.md` first and the mise-installed Pi second, never from a cached bundle.
- A package's CI entry point is `test:ci` when declared, else `test`; a step conditioned on a shard name `.github/workflows/skill-tests.yml` does not carry fails the policy test.
