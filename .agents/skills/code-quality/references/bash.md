# Bash

## Status and output

- Check every effectful command substitution's status, including in test position.
- Put `--` before path arguments from configuration, argv or the environment. Paths the script constructed itself do not need that boundary.
- Do not assume `[A-Za-z]` ranges behave identically under arbitrary locales.
- Resolve a command in the script's own shell and PATH before using an interactive observation as evidence. Name the shell and implementation; an alias or function at the prompt can hide the executable.
- Do not put unescaped backticks in a double-quoted diagnostic. They execute and can remove the intended message while the outer command succeeds.
- In a `pipefail` script, never pipe a shell writer into an early-closing reader such as `head`, `grep -q` or `grep -m N`. SIGPIPE can abort an `errexit` branch or appear as false in condition position. Capture the whole output and window it in-shell, or feed the reader a here-string.

## Suites

- A script surface is one script, function or command verb. Keep one file per surface, named for it, so input-based selection can find it.
- Suites sharing a runner contract use that tree's assertion library. Put shared test helpers there instead of duplicating them in suites.
- A suite makes its scratch root with these lines, replacing `NAME` with its name. Resolve the root before comparing or printing a derived path.

```bash
TMP_ROOT="$(mktemp -d)" || { echo "NAME: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "NAME: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "NAME: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
```

- Check `mktemp -d` alone, never nested inside `cd`. A failed creation can make `cd` select the caller's directory and put it under the cleanup trap.
