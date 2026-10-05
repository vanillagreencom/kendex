# hooks

The catalog's hooks, one script each. `crates/core/tests/hooks_readme.rs` renders this file from each hook's frontmatter, and fails when the committed file differs. The tools a hook does not run on, each with its reason, are on its package page and in `kendex show hook <name>` and `kendex index --json`.

- `block-argv-kill`: Stops a command that kills processes by name. On a machine running several agents, one name matches every lane using that tool. Names the safe form: kill a process id you started.
- `block-bare-cd`: Stops a command whose whole line is a `cd`. Where the shell stays open between tool calls, that moves every later command with it. Names the scoped form to use instead.
- `block-repo-copy`: Stops a copy of a repository's `.git` folder or build output into a temporary folder, which can fill the disk. Suggests reading the source where it sits instead.
- `block-unsafe-rm`: Stops deletes of shared directory roots, their direct globs or child paths with . or .. segments, and paths that start with a variable that may be empty. The refusal gives a safe cleanup pattern.
- `block-worktree-refresh`: Stops a kendex command that writes a project from inside a linked git worktree, where the write would land somewhere the command does not name.
- `command-safety`: Refuses shell commands matching a project's deny pattern, a kilobyte or megabyte systemd-run memory cap by default, and every command while its settings file cannot be read.
- `critical-path-deny`: In an unattended orch lane, turns down Claude Code's prompt for an rm it could not check at once, with the rewrite that passes, instead of leaving the lane waiting on an answer nobody gives.
- `lane-mail-check`: Hands lanes their overseer's mail and holds turn ends for handoff or idle checks, plus a `wake=unarmed` refusal for the registered overseer without its repeat follow or a master whose `ORCH_WAKE_PROCESS` does not match, printing `ORCH_WAKE_START`; empty master keys with no watch claim disable the check, and a running single pass is its own wake. Pi's wake check is partial; a continued turn or an unavailable check only warns.
- `lane-mail-compact`: Marks a Copilot lane or overseer for handoff when Copilot starts compacting it automatically before its context reading could hand it off, so its next turn end holds it until it hands the work to a fresh session.
- `lane-mail-deliver`: Hands a working lane the messages its overseer sent as soon as a tool call finishes, and the notes another repository's overseer sent to the one session the checkout's fleet record names. It also tells the session running the fleet, at its next tool call, that it has used enough of its context to hand over.
- `lane-mail-halt`: Stops a lane at its next tool call when its overseer sends a halt, until the lane reads it, and refuses the harness question tool in a lane, naming lane mail as the route.
- `lane-mail-prompt`: Hands a Copilot lane the messages its overseer sent with each prompt it is handed, and the notes another repository's overseer sent to the one session the checkout's fleet record names.
- `lane-mail-start`: Hands a Copilot lane the messages its overseer sent as soon as its session starts, and the notes another repository's overseer sent to the one session the checkout's fleet record names.
- `pre-commit-check`: Makes a commit run the repository's armed git hooks and refuses one carrying a word that skips them. Unarmed, it refuses only a line whose command is git commit.
- `reviewer-read-only`: Keeps a reviewer agent read-only: no edits, no commits, no pushes, no Git commands that discard work, only its review report.
- `reviewer-stop-check`: Stops a reviewer agent from finishing while the worktree it reviewed still holds files it left behind.
- `session-drift-check`: Tells a coding agent at the start of a session which installed packages no longer match their source, and what to run about it. A lane gets the install rule instead of kendex fix advice, and a lane launched to refresh gets the whole report.
- `session-end-row`: Writes down that a session ended, so a fleet's overseer that exits is seen to have exited without anyone reading its screen.
- `session-start-row`: Writes down that a session started, and on which account and model, so the fleet's overseer is judged from what its harness said rather than from its screen.
- `skill-load-check`: Holds back edits and Linear commands until the agent making them has loaded the skill the repository ties to them, so the standard is applied rather than remembered.
- `skill-load-record`: Remembers which skills each Copilot agent has loaded, so the skill-load check can let that agent's edits and Linear commands through once it has.
- `stop-failure-row`: Writes down that a turn stopped on an error such as a usage limit, so a fleet's overseer that hits its limit is seen to be stuck without anyone reading its screen.
- `task-completed-check`: Runs clippy before a task is marked complete whenever Rust files changed, and refuses the completion with the first errors it found.
- `worktree-session-claim`: Claims a git worktree the worktree skill created or adopted for the worktree session guard when a session starts in it.
