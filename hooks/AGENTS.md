# hooks/

Catalog hooks, one bash script per hook, each with its suite under `tests/<name>.test.sh`.

- A hook opens with a commented frontmatter block between `# ---` lines: `name`, `event` (a name from `crates/core/src/hook.rs::EVENTS`), `matcher`, `description`, `safety`, `timeout` (seconds) and an optional `harnesses: [..]` restricting delivery (Antigravity is reached only when named there, because its payload is `toolCall.args`, not `tool_input`); `crates/core/src/hook/spec.rs` reads it.
- Exit 0 allows; exit 2 refuses with the reason on stderr; a payload that cannot be read is a refusal, never a pass.
- A refusal states what it refused, why, and the preferred remedy first, before any exemption path.
- The first line of a refusal or a notice is spelled `<hook-name>: <key>=<value>` here; the rule it follows — a stable key, the value acted on, English below it, the text in one place, and what a suite may assert about it — is [`../skills/code-quality/SKILL.md`](../skills/code-quality/SKILL.md). A tool the hook runs writes to the same stream: drop its diagnostic where it would print ahead of that line.
- Two hooks have their keys fixed by what reads them, and they do not move. `block-bare-cd`: `missing-tools=<comma list, in check order jq,cat,grep,sed>`, `payload=invalid-json`, `refused=bare-cd`, each exit 2; a command with no bare cd exits 0 saying nothing. `pre-commit-check`: `missing-tools=<comma list, in check order jq,cat,grep>`, `payload=invalid-json`, `bypass=<the matched word, verbatim>`, `unarmed=<the directory judged>`, each exit 2; `judged=<the directory judged>` at exit 0 for the repository-moving notice; an armed repository with no bypass word exits 0 saying nothing.
- A change to `hooks/<n>` lands the copies under `.claude/hooks`, `.codex/hooks` and `.pi/kendex/hooks` only where those already track the file, judged per file by a `tools/guard` lane; `tests/*` renders nowhere.
- Shell stays Bash 3.2 compatible; `tools/bash32-lint` runs in the guard.
