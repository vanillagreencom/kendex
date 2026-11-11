# Hook and CI wiring

Read when wiring preflight into a Git hook, the commit-guards pre-commit chain or CI.

## Commit hooks

Where `commit-guards` is installed, its pre-commit chain runs `preflight --staged` itself. Any other hook calls the script with `--staged`; the chain's `COMMIT_GUARDS_PRE_COMMIT_LOCAL` lane runs its executable with no arguments, so wiring preflight there needs a wrapper that adds the flag.

## CI

Run `preflight --base origin/<default-branch>` on the PR head. The installed skill must be committed: a CI checkout sees tracked files only, never a machine-local `.agents` symlink.
