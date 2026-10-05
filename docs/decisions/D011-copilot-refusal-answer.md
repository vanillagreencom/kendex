# D011: A Copilot hook refusal reaches the model through the registered command, not the hook

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: KEN-1976

**Decision**: The Copilot registration of every catalog hook with a script runs the script and captures its output; where the script exits 2 with stderr and prints only whitespace on stdout, the command writes that stderr as the `permissionDecisionReason` of a deny object on stdout. The status stays the script's. Any other stdout passes through unchanged, so a hook that writes its own Copilot answer is never wrapped twice. A `[[custom-hooks]]` command is registered as written. The wrapper, `copilot_answer` in `crates/core/src/engine/targets.rs`, is POSIX `sh` plus `awk` and applies at every event, because every reader of a registration asks for the command without naming one.

**Why**: Copilot hands the model only `hook exited with code 2` and sends stderr to its debug log, but shows the model the reason of a deny object on stdout. One owner in the registration covers every catalog hook, a hook added later included, without a line of its own, and a hook refusing because `jq` is missing still gets its reason through.

**Rejected**: A shared library each hook sources, or an adapter script delivered beside the hooks: every guard changes, or a new artifact to install and remove, for work the command string already does. Exit 0 with the deny object: a Copilot that ignored the object would then allow the call.

**Revisit when**: Copilot carries stderr into the tool result, or documents a preToolUse field other than `permissionDecisionReason` for the model-visible reason.
