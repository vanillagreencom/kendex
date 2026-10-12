# Command safety hook

The `command-safety` bundle provides a shell command policy hook. It includes the hook and the commit-guards settings loader. It works without inspecting a desktop session or process list.

Install the `command-safety` bundle; it applies the default pattern below with no setting. To replace the default, set `COMMAND_SAFETY_DENY_PATTERN` in `kendex.settings.toml` under `[env]`, or in the install with `kendex add --bundle command-safety --setting COMMAND_SAFETY_DENY_PATTERN=<pattern>`; the bundle's commit-guards skill declares the key. The value is a nonempty POSIX extended regular expression. The shared settings grammar and precedence are documented in [the commit-guards skill](../../skills/commit-guards/SKILL.md#configuration).

Claude Code, Codex, Gemini CLI, and GitHub Copilot execute the hook. Pi executes it while the `pi-hooks` carrier is registered. Cursor and OpenCode install advisory instructions instead of an executable check. Antigravity executes hooks but does not receive this one: it sends the command as `toolCall.args.CommandLine`, not the `tool_input` this hook reads, and a hook reaches Antigravity only by naming it in its `harnesses` line.

An absent setting applies the shipped host-safety pattern, so a fresh install refuses a `systemd-run` memory cap measured in kilobytes or megabytes, quoted or not:

```text
(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)
```

A cap that small starved a build's cgroup into a kernel allocation failure inside a filesystem transaction, and the host's root volume went read-only. A cap in gigabytes, or a run with no cap, passes. A project that sets the key replaces this pattern, so its own pattern keeps this rule where it still wants it; the value `^$` turns matching off, and the warnings below still apply. Outside a Git worktree the hook stays inactive, which lets a global installation run there. Patterns match from executable command positions. Ordinary quoted arguments and proven simple data-reader here-document bodies pass. Here-documents with groups, control operators, redirection ampersands, substitutions or pending pipe receivers can warn or refuse when their bodies hold guarded text. Shell program arguments and a shell's standard input remain command text. An explicitly empty value, invalid pattern, unreadable setting, missing tool, or unreadable tool input produces one warning and allows the command. Repair the named settings file, tool installation or payload adapter.

A malformed value on any `[env]` key produces one warning and allows the call. The settings loader reads the whole file, so it cannot supply a policy after a malformed line. The warning includes the loader's diagnostic with the file, line and key to repair.

The reader joins backslash-newline continuations before selecting commands. For an argument array, it joins the arguments with spaces. A matching command is refused. A quoted literal example or a comment does not become an executable command.

For a Quickshell project, this example blocks direct `qs -c vshell`, `qs -p quickshell/vshell`, and `pkill quickshell` calls. It allows `scripts/validate qml`.

```toml
[env]
COMMAND_SAFETY_DENY_PATTERN = "(^|[[:space:];|&])qs[[:space:]]+(-c[[:space:]]+vshell|-p[[:space:]]+quickshell/vshell)([[:space:];|&]|$)|(^|[[:space:];|&])pkill([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+quickshell([[:space:];|&]|$)"
```

Missing settings support produces one warning and allows the call because the hook cannot determine the policy. Repair the installed commit-guards dependency. Keep the pattern specific to the commands the project must prohibit. The hook does not classify commands hidden inside scripts.
