# D011: A Copilot hook refusal reaches the model through the registered command, not the hook

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Applies to**: `crates/core/src/engine/targets.rs` (`copilot_answer`), every Copilot registration of a hook with a script (catalog hooks); a `[[custom-hooks]]` command is registered as written and not covered

## Context

A catalog hook refuses with its reason on stderr and exit 2. Copilot CLI denies a preToolUse call on that exit, but the tool result the model sees reads only `Denied by preToolUse hook: hook exited with code 2`: stderr goes to Copilot's debug log and never to the model. Copilot shows the model the `permissionDecisionReason` of a `{"permissionDecision":"deny",...}` object on stdout, and merges that object with the exit-2 denial. A measurement against Copilot CLI 1.0.88, recorded on KEN-1976, shows it: an exit 2 with that object denies the call, the harmless command never runs, and the model is shown `Denied by preToolUse hook: <reason>`.

## Decision

1. The Copilot registration of every hook with a script runs the script and captures its stdout, stderr and status. Where the script exits 2 with stderr and prints only whitespace on stdout, the command writes that stderr as the `permissionDecisionReason` of a deny object. Any other run's stdout passes through unchanged where it holds a non-space character, and stdout that is only whitespace is dropped. A `[[custom-hooks]]` command is the person's own and is registered as written, so its refusal still reads `hook exited with code 2`. The reason reaches the model for a preToolUse refusal only: at `permissionRequest` Copilot reads the denial from `behavior` and `message`.
2. The status is always the script's. A refusal stays a denial, and an unexpected failure stays Copilot's `hook errored` denial. Nothing moves to exit 0.
3. The wrapper applies at every event, because every reader of a registration (install, removal, the scan, delivery) asks `hook_target` for the command without naming an event. Only preToolUse reads those keys.

## Rationale

- One owner: no hook has to write a Copilot refusal answer of its own, and a hook added to the catalog is covered without a line of its own.
- The wrapper is POSIX `sh` plus `awk`, so a hook refusing because `jq` is missing still gets its reason through.
- An answer the script writes itself, such as the halt, deliver and stop answers in `lane-mail-check.sh`, passes unchanged, so the wrapper never writes a second JSON object, which Copilot would fail to parse.

## Alternatives Considered

- **A shared library each hook sources**: every guard would change, and delivery would have to carry the library beside each script.
- **A kendex-owned adapter script delivered beside the hooks**: a new artifact to install, record and remove, for work the command string can already do.
- **An event-specific command**: the registration readers that name no event would render a different command from the one installed, and stop recognising kendex's own entries.
- **Exit 0 with the deny object**: measured to deny as well, but a Copilot that ignored the object would then allow the call. Exit 2 denies either way.

**Revisit When**: Copilot starts carrying stderr into the tool result, or documents a preToolUse field other than `permissionDecisionReason` for the model-visible reason.

**Verification**: `cargo test -p kendex-core --lib engine::targets::tests::a_copilot_refusal_reaches_stdout_as_the_denial_reason_and_nothing_else_changes`. Live, `tools/harness-smoke --only copilot`: each trigger hook's row passes only where the `--share` transcript shows the model a denial that opens with the hook's keyed line.

**References**: [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference), [D008](D008-copilot-agent-model.md)
