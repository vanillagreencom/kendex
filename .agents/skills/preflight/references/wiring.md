# Hook and CI wiring

Read when wiring preflight into a Git hook, the commit-guards pre-commit chain or CI.

## Commit hooks

Where `commit-guards` is installed, its pre-commit chain runs `preflight --staged` itself. Any other hook calls the script with `--staged`.

## CI

- Run `preflight --base origin/<default-branch>` on the PR head.
- Commit the installed skill: a CI checkout sees tracked files only, never a machine-local `.agents` symlink.
