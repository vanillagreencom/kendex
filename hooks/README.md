# hooks

The catalog's hooks, one script each. `crates/core/tests/hooks_readme.rs` renders this file from each hook's frontmatter through kendex's hook delivery decision, and fails when the committed file differs.

## Hooks

- `block-argv-kill`: Stops a command that kills processes by name. On a machine running several agents, one name matches every lane using that tool. Names the safe form: kill a process id you started.
- `block-bare-cd`: Stops a command whose whole line is a `cd`. Where the shell stays open between tool calls, that moves every later command with it. Names the scoped form to use instead.
- `block-repo-copy`: Stops a copy of a repository's `.git` folder or build output into a temporary folder, which can fill the disk. Suggests reading the source where it sits instead.
- `block-unsafe-rm`: Stops a delete whose path starts with a variable that may be empty. Refusing this shape lets the agent rewrite it before a harness prompt stalls the session.
- `block-worktree-refresh`: Stops a kendex command that writes a project from inside a linked git worktree, where the write would land somewhere the command does not name.
- `command-safety`: Refuses shell commands that match the deny pattern a project's settings declare. A project that declares none is unaffected.
- `doc-drift-check`: Stops an agent at the end of its turn when documents covering the code it changed did not change or an architecture topic names a path that does not exist, and hands it the list. Where some topic declares a Covers entry, changed code with no covering document is named too.
- `lane-mail-check`: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch. It also holds the turn end once the lane is near the end of its context window or its account's limit, until the lane records where it got to and exits, so the work resumes in a fresh session instead of stopping mid-round.
- `lane-mail-deliver`: Hands a working lane the messages its overseer sent as soon as a tool call finishes.
- `lane-mail-halt`: Stops a lane at its next tool call when its overseer sends a halt, until the lane reads it.
- `pre-commit-check`: Makes a commit go through the repository's own git hooks where they are armed, and refuses a commit carrying a word that would skip them.
- `reviewer-read-only`: Keeps a reviewer agent read-only: no edits, no commits, no pushes, no Git commands that discard work, only its review report.
- `reviewer-stop-check`: Stops a reviewer agent from finishing while the worktree it reviewed still holds files it left behind.
- `session-drift-check`: Tells a coding agent at the start of a session which installed packages no longer match their source, and what to run about it. Says nothing when everything matches.
- `skill-load-check`: Holds back edits and Linear commands until the agent making them has loaded the skill the repository ties to them, so the standard is applied rather than remembered.
- `task-completed-check`: Runs clippy before a task is marked complete whenever Rust files changed, and refuses the completion with the first errors it found.

## Harnesses

- `enforced`: the harness runs the hook on its event.
- `advisory`: OpenCode and Cursor run no hooks, so the hook's description reaches the agent as an instruction.
- `not named`: Antigravity is reached only by a hook that names it in its harnesses line; its payload is not the tool_input shape a hook written for the other tools reads.
- Any other cell is the hook's own reason that harness does not run it.

| Hook | claude | codex | pi | gemini | copilot | antigravity | opencode | cursor |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `block-argv-kill` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `block-bare-cd` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `block-repo-copy` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `block-unsafe-rm` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `block-worktree-refresh` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `command-safety` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `doc-drift-check` | enforced | enforced | enforced | it has no Stop event | its agentStop also fires at each subagent's end | its Stop payload carries no `stop_hook_active` and names the session `conversationId` | advisory | advisory |
| `lane-mail-check` | enforced | enforced | enforced | it has no Stop event | its agentStop also fires at each subagent's end | its Stop payload carries no `stop_hook_active` | advisory | advisory |
| `lane-mail-deliver` | enforced | enforced | enforced | the lane-mail-check hook it runs is not installed there, having no Stop event | its postToolUse output never reaches the model | any PostToolUse output replaces the tool result the model reads | advisory | advisory |
| `lane-mail-halt` | enforced | enforced | enforced | the lane-mail-check hook it runs is not installed there, having no Stop event | its preToolUse refusal reaches the model without the hook's words, so the lane never learns the halt or the command that acknowledges it | the lane-mail-check hook it runs is not installed there, and its command arrives as `toolCall.args.CommandLine` | advisory | advisory |
| `pre-commit-check` | enforced | enforced | enforced | enforced | enforced | not named | advisory | advisory |
| `reviewer-read-only` | enforced | a write is `apply_patch` with no `tool_input.file_path`, so the review artifact cannot be told from any other write | enforced | its tool-call payload is unmeasured | its preToolUse payload names no calling agent | its payload carries no agent field | advisory | advisory |
| `reviewer-stop-check` | enforced | it has no SubagentStop event | it has no SubagentStop event | it has no SubagentStop event | its subagentStop names the agent type `task`, the tool rather than the agent, and carries no `stop_hook_active` | it has no SubagentStop event | advisory | advisory |
| `session-drift-check` | enforced | enforced | the pi-hooks carrier runs its own drift report at session start | enforced | enforced | it has no SessionStart event | advisory | advisory |
| `skill-load-check` | enforced | a file write is `apply_patch`, whose payload carries no `tool_input.file_path`, and a skill load is a shell read of SKILL.md with no skill record | enforced | its tool-call payload and its record of a skill load are unmeasured | its preToolUse payload carries no transcript path and names the file as `toolArgs.path` | the file arrives as `toolCall.args.TargetFile` and a skill load is a `view_file` read with no skill record | advisory | advisory |
| `task-completed-check` | enforced | it has no TaskCompleted event | the pi-hooks carrier runs its own end-of-turn clippy check, and a second run is left out | it has no TaskCompleted event | it has no TaskCompleted event | it has no TaskCompleted event | advisory | advisory |
