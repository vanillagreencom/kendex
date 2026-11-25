# Fixed hook keys

Read when changing what `block-bare-cd` or `pre-commit-check` writes, or the suite that pins it. Each first line is `<hook-name>: <key>=<value>` ([AGENTS.md](AGENTS.md)), and these two hooks hold their keys to the fixed sets below.

## `block-bare-cd`

- Payload or tool errors warn once at exit 0.
- `missing-tools` lists jq,cat,grep,sed in that order.
- `refused=bare-cd` exits 2.
- No bare cd exits 0 silently.

## `pre-commit-check`

- `bypass=<matched word, verbatim>` exits 2.
- `missing-tools=<comma list, order jq,cat,grep>`, `payload=invalid-json`, `payload=read-failed`, `command=unresolved`, `unarmed=<directory judged>` and `judged=<directory judged>` exit 0.
- An unarmed notice adds `setup=consent` or `setup=<main checkout path>`.
