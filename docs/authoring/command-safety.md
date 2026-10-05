# Command safety hook

The `command-safety` bundle provides a shell command policy hook. It includes the hook and the commit-guards settings loader. It works without inspecting a desktop session or process list.

Install the `command-safety` bundle; it applies the default pattern below with no setting. To replace the default, set `COMMAND_SAFETY_DENY_PATTERN` in `kendex.settings.toml` under `[env]`, or in the install with `kendex add --bundle command-safety --setting COMMAND_SAFETY_DENY_PATTERN=<pattern>`; the bundle's commit-guards skill declares the key. The value is a nonempty POSIX extended regular expression. The shared settings grammar and precedence are documented in [the commit-guards skill](../../skills/commit-guards/SKILL.md#configuration).

Claude Code, Codex, Gemini CLI, and GitHub Copilot execute the hook. Pi executes it while the `pi-hooks` carrier is registered. Cursor and OpenCode install advisory instructions instead of an executable check. Antigravity executes hooks but does not receive this one: it sends the command as `toolCall.args.CommandLine`, not the `tool_input` this hook reads, and a hook reaches Antigravity only by naming it in its `harnesses` line.

An absent setting applies the shipped host-safety pattern, so a fresh install refuses a `systemd-run` memory cap measured in kilobytes or megabytes, quoted or not:

```text
(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)
```

A cap that small starved a build's cgroup into a kernel allocation failure inside a filesystem transaction, and the host's root volume went read-only. A cap in gigabytes, or a run with no cap, passes. A project that sets the key replaces this pattern, so its own pattern keeps this rule where it still wants it; the value `^$` turns matching off, and the refusals below still apply. Outside a Git worktree the hook stays inactive, which lets a global installation run there. An explicitly empty value, invalid pattern, unreadable setting, or unreadable tool input refuses the command.

A malformed value on any `[env]` key refuses every command, not only a malformed pattern. The settings loader reads the file whole, like every kendex settings reader, so a policy read past the bad line would come from a file the rest of the toolchain rejects. The refusal replays the loader's line naming the file, the line and the key to rewrite.

The hook matches tool command text both as received and with backslash-newline pairs removed. For an argument array, it joins the arguments with spaces. Quotes and comments are still text, so a matching literal example is also refused. Put isolated validation behind a script whose invocation does not match the pattern.

For a Quickshell project, this example blocks direct `qs -c vshell`, `qs -p quickshell/vshell`, and `pkill quickshell` calls. It allows `scripts/validate qml`.

```toml
[env]
COMMAND_SAFETY_DENY_PATTERN = "(^|[[:space:];|&])qs[[:space:]]+(-c[[:space:]]+vshell|-p[[:space:]]+quickshell/vshell)([[:space:];|&]|$)|(^|[[:space:];|&])pkill([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+quickshell([[:space:];|&]|$)"
```

Missing settings support refuses the command because the hook cannot determine whether a policy exists. Keep the pattern specific to the commands the project must prohibit. The hook does not classify commands hidden inside scripts.
