# Command safety hook

The `command-safety` bundle refuses recognized whole-environment reads in submitted shell command text unless a proven direct pipe filters named variables. It also applies a project command pattern. The bundle includes the hook and the commit-guards settings loader. It does not inspect a desktop session or process list.

Install the `command-safety` bundle; its environment-dump check needs no setting and cannot be disabled by the project pattern. The pattern defaults to the host-safety rule below. To replace that pattern, set `COMMAND_SAFETY_DENY_PATTERN` in `kendex.settings.toml` under `[env]`, or in the install with `kendex add --bundle command-safety --setting COMMAND_SAFETY_DENY_PATTERN=<pattern>`; the bundle's commit-guards skill declares the key. The value is a nonempty POSIX extended regular expression. The shared settings grammar and precedence are documented in [the commit-guards skill](../../skills/commit-guards/SKILL.md#configuration).

Claude Code, Codex, Gemini CLI, and GitHub Copilot execute the hook. Pi executes it while the `pi-hooks` carrier is registered. Cursor and OpenCode install advisory instructions instead of an executable check. Antigravity executes hooks but does not receive this one: it sends the command as `toolCall.args.CommandLine`, not the `tool_input` this hook reads, and a hook reaches Antigravity only by naming it in its `harnesses` line.

The fixed check recognizes unnamed `env` and `printenv` reads, `export -p`, bare `set`, unnamed `declare -p`, `declare -x` and `typeset -x`, `systemctl show-environment` with or without `--user`, and the supported reads of `/proc/*/environ`. Read a named variable with `printenv NAME`, or use a direct pipe such as `systemctl --user show-environment | grep '^NAME='`. Direct `grep NAME` and `grep -E '^(A|B)='` filters also pass. A proc read can use a literal NUL-to-newline tr stage before the named filter. `env NAME=value command` is a launcher; its target is checked separately.

The fixed check reads ordinary literal quoting, supported env, command and sudo prefixes, and direct pipe and list boundaries. A grep in another list command does not permit a dump. A stdout redirect or an intermediate program such as tee cannot prove direct filtering. Nested dumps can refuse conservatively even with an inner or outer grep. General heredocs, process substitutions, shell programs and env split strings have no interpretation guarantee. The check does not inspect unseen programs, aliases, functions, PATH replacements or runtime-built names. An unanchored `grep NAME` can also match NAME in a value; permitted filtering is not output redaction.

The fixed check runs before cwd, Git and project settings. It also runs outside a Git worktree. An argument array keeps each argument; a pipe character in one argument does not establish a shell pipe. A missing payload reader or unreadable payload produces an advisory warning and allows the call.

An absent setting applies the shipped host-safety pattern, so a fresh install refuses a `systemd-run` memory cap measured in kilobytes or megabytes, quoted or not:

```text
(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)
```

A cap that small starved a build's cgroup into a kernel allocation failure inside a filesystem transaction, and the host's root volume went read-only. A cap in gigabytes, or a run with no cap, passes. A project that sets the key replaces this pattern, so its own pattern keeps this rule where it still wants it; `^$` turns only project-pattern matching off. The project-pattern part stays inactive outside a Git worktree. An explicitly empty value, invalid pattern, missing policy tool or unreadable setting produces one keyed warning and allows that pattern check. These conditions do not disable the earlier fixed check.

A malformed value on any `[env]` key produces one keyed warning and allows the pattern check, not only a malformed pattern. The settings loader reads the file whole, like every kendex settings reader, so a policy read past the bad line would come from a file the rest of the toolchain rejects. The warning replays the loader's line naming the file, the line and the key to rewrite.

The project pattern matches tool command text both as received and with backslash-newline pairs removed. For that pattern alone, an argument array is joined with spaces. Quotes and comments remain text, so a matching literal example is also refused. Put isolated validation behind a script whose invocation does not match the pattern.

For a Quickshell project, this example blocks direct `qs -c vshell`, `qs -p quickshell/vshell`, and `pkill quickshell` calls. It allows `scripts/validate qml`.

```toml
[env]
COMMAND_SAFETY_DENY_PATTERN = "(^|[[:space:];|&])qs[[:space:]]+(-c[[:space:]]+vshell|-p[[:space:]]+quickshell/vshell)([[:space:];|&]|$)|(^|[[:space:];|&])pkill([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+quickshell([[:space:];|&]|$)"
```

Missing settings support produces one keyed warning and allows the pattern check because the hook cannot determine whether a policy exists. Repair the installed commit-guards support. Keep the pattern specific to the commands the project must prohibit. The hook does not classify commands hidden inside scripts.
