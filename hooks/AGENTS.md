# hooks/

Catalog hooks, one bash script per hook, each with its suite under `tests/<name>.test.sh`.

- A hook opens with a commented frontmatter block between `# ---` lines: `name`, `event` (a name from `crates/core/src/hook.rs::EVENTS`), `matcher`, `description`, `safety`, `timeout` (seconds) and an optional `harnesses: [..]` restricting delivery (Antigravity is reached only when named there, because its payload is `toolCall.args`, not `tool_input`); `crates/core/src/hook/spec.rs` reads it.
- Exit 0 allows; exit 2 refuses with the reason on stderr; a payload that cannot be read is a refusal, never a pass.
- A refusal states what it refused, why, and the preferred remedy first, before any exemption path.
- Every refusal and notice opens with the stable line `<hook-name>: <key>=<value>`. `<key>` is a short word for the condition, not a sentence (`tools`, `payload`, `refused`, `bypass`, `armed`, `git`, `path`, `exit`); `<value>` is what the reader acts on: a path, a count, an exit status, the matched word, or a short enum such as `empty`, `unreadable`, `invalid-json`, `no`. The key and the value are the contract and do not move with the wording; the English explanation, the remedy and any passthrough follow on later lines.
- One function per hook owns every line the hook writes, so a key and its value have a single definition. Where a hook also writes a machine-read protocol, such as `doc-drift-check`'s lone `{systemMessage}` object on stdout, that function states the contract and holds that text too. A tool the hook runs writes to the same stderr: drop its diagnostic where it would print ahead of the keyed line, so that line is the first the hook writes.
- A suite asserts the first line's key, its value and the exit status. It never asserts an English sentence; a remedy the message must carry is pinned as the literal command or option it names.
- A change to `hooks/<n>` lands the copies under `.claude/hooks`, `.codex/hooks` and `.pi/kendex/hooks` only where those already track the file, judged per file by a `tools/guard` lane; `tests/*` renders nowhere.
- Shell stays Bash 3.2 compatible; `tools/bash32-lint` runs in the guard.
