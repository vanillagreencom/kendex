# hooks/

Catalog hooks, one bash script per hook, each with its suite under `tests/<name>.test.sh`.

- A hook opens with a commented frontmatter block between `# ---` lines: `name`, `event` (a name from `crates/core/src/hook.rs::EVENTS`), `matcher`, `description`, `safety`, `timeout` (seconds) and an optional `harnesses: [..]` restricting delivery; `crates/core/src/hook/spec.rs` reads it.
- Exit 0 allows; exit 2 refuses with the reason on stderr; a payload that cannot be read is a refusal, never a pass.
- A change to `hooks/<n>` lands the copies under `.claude/hooks`, `.codex/hooks` and `.pi/kendex/hooks` only where those already track the file, judged per file by a `tools/guard` lane; `tests/*` renders nowhere.
- Shell stays Bash 3.2 compatible; `tools/bash32-lint` runs in the guard.
