# @vanillagreen/pi-hooks

First-class Pi port of the kendex safety hooks listed below. Each hook is independently toggleable.

## Hooks

| Hook | Pi event | Behavior |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (bash) | Blocks bare `cd /path` commands with no subshell or chaining. Use `(cd /path && command)` instead. |
| Block repo copy into scratch | `tool_call` (bash) | Refuses a recursive copy (`cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, `tar` create-to-extract pipe) when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root. Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. |
| Pre-commit gate | `tool_call` (bash) | On a bash command whose live words name a git commit, defers to the working directory's git hooks when kendex armed them (`kendex guard install`: `pre-commit` and `commit-msg` both executable and marked, `core.hooksPath` unset), so git validates the commit exactly once. Refuses a commit whose live words include one that sidesteps an armed hook (`--no-verify`, `-n`, `-c`, `--config-env`, a `GIT_CONFIG_*` assignment, a `core.hooksPath` key) and a commit in a repository nothing armed, naming `kendex guard install`. Never runs a check of its own. The command splits into simple commands and only its live words are judged, so a heredoc body and a comment tail are text and a quoted word is a live word whose text is its unquoted content. A bypass is a word whose WHOLE content is one, so `git commit "--no-verify"` refuses while `cat -n` in a heredoc and a commit message naming `--no-verify` pass. It models no argv, so a construct it does not recognise leaves the words standing and is judged; whole words decide, so `-mnote` is a message and `--grep=commit` is not a commit. Constructs it cannot read are the exception, refused unread rather than parsed where the command names git and carries a commit, either in its text with the quote characters removed or in a live word, so a spelling the shell assembles counts and an anchored grep for something else passes; an alias config key carried inline (`-c alias.x=...`) needs only the git, since it renames the subcommand of that invocation, while one written to the config is judged behind the commit word like any other text. Its blind spot is the other way round: text a shell would run but this drops, inside quotes (`sh -c '…'`) or a heredoc body. Gates the working directory only; a commit aimed at another repository is that repository's own hook's to gate: an armed working directory defers silently, an unarmed one refuses naming the directory it judged, and a working directory that is not a repository passes with a TUI notice naming it. |
| End-of-turn clippy | `turn_end` | If `.rs` files were touched during the turn, runs workspace clippy once. The summary steers the run, so the agent reads it in the turn that follows in every mode, headless included; an interactive session also gets a UI notification. Every failing turn reports, including one whose errors are unchanged: an agent stuck on an error hears the same advisory each turn, and a turn touching no Rust runs no clippy and reports nothing. A run that established nothing — no workspace root, a timeout, a clippy failure printing no error line — says so rather than passing as clean. Advisory only. |
| Session-start drift report | `session_start` | On a fresh start (startup, new, fork — not resume or reload) runs `kendex check --quiet` in the background and hands the agent the drift report: outdated items (`kendex refresh`), items removed upstream (`kendex remove <name>`, `-g` in a global section), unreachable sources, and packages not yet evaluated against their sources (a background refresh settles them). Silent when the install is current; one line when no `kendex` binary is on `PATH`, the session directory is unreadable, or the check fails unexpectedly. Never blocks startup. Informational only — never installs or removes anything and never touches the project's git; the check never waits on the network (its only writes are kendex's own cache bookkeeping under `~/.kendex/cache`), and a source cache there older than its TTL is refreshed by a detached background process nobody waits on. |

`block-unsafe-rm` has no Pi port; it declares `harnesses:` without `pi`, so kendex reports Pi as `unsupported` for it rather than claiming enforcement that does not exist.

These implement the same safety goals as their matching bash hooks in `kendex/hooks/`, with Pi-specific mechanics where the in-process event loop needs different handling. The pre-commit gate carries the bash hook's contract exactly; this package's `tests/bash-guards.test.ts` runs the fixtures and commands of `kendex/hooks/tests/pre-commit-check.test.sh` and adds foreign-hooks fixtures and a long-command check.

## Install

```bash
kendex add --pi-extension pi-hooks
```

Or as part of `kendex add --all`. Refresh with `kendex refresh`.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-hooks):

```bash
pi install npm:@vanillagreen/pi-hooks
```

## Settings

Open `/extensions:settings`; settings appear under the **Hooks** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, kendex Pi extensions read user/global settings only.

| Setting | What it does |
| --- | --- |
| Enable hooks | Master toggle. Disable to make the extension inert without uninstalling. |
| Block bare cd | Toggle the bare-cd block hook. |
| Block repo copy into scratch | Toggle the recursive-copy-into-scratch block. |
| Pre-commit gate | Toggle the pre-commit gate. |
| End-of-turn clippy | Toggle the end-of-turn advisory hook. |
| Session-start drift report | Toggle the session-start `kendex check` report. |
| Drift check timeout | Max ms the session-start `kendex check` may run before it is abandoned. |
| Clippy timeout | Max ms for the whole end-of-turn check: the workspace lookup takes up to a quarter, clippy the rest. |
