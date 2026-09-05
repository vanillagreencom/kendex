# Command safety hook

The `command-safety` bundle provides a shell command policy hook. It includes the hook and the growth-guards settings loader. It works without inspecting a desktop session or process list.

Configure `COMMAND_SAFETY_DENY_PATTERN` in `kendex.settings.toml` under `[env]`, then install the `command-safety` bundle. The value is a nonempty POSIX extended regular expression. The shared settings grammar and precedence are documented in [the growth-guards skill](../../skills/growth-guards/SKILL.md#configuration).

Claude Code, Codex, Gemini CLI, and GitHub Copilot execute the hook. Pi executes it while the `pi-hooks` carrier is registered. Cursor and OpenCode install advisory instructions instead of an executable check.

An absent setting leaves the hook inactive. This lets a global installation run in repositories with no command policy and outside Git worktrees. An explicitly empty value, invalid pattern, unreadable setting, or unreadable tool input refuses the command.

The hook matches tool command text. For an argument array, it joins the arguments with spaces. Quotes and comments are still text, so a matching literal example is also refused. Put isolated validation behind a script whose invocation does not match the pattern.

For a Quickshell project, this example blocks direct `qs -c vshell`, `qs -p quickshell/vshell`, and `pkill quickshell` calls. It allows `scripts/validate qml`.

```toml
[env]
COMMAND_SAFETY_DENY_PATTERN = "(^|[[:space:];|&])qs[[:space:]]+(-c[[:space:]]+vshell|-p[[:space:]]+quickshell/vshell)([[:space:];|&]|$)|(^|[[:space:];|&])pkill([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+quickshell([[:space:];|&]|$)"
```

Missing settings support refuses the command because the hook cannot determine whether a policy exists. Keep the pattern specific to the commands the project must prohibit. The hook does not classify commands hidden inside scripts.
