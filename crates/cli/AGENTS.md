# crates/cli/

Thin verbs over `kendex-core`: a verb parses, calls core and prints. No domain logic lives here.

- Every human line leaves through `src/ui.rs`, escaped there.
  - A payload is not escaped.
  - Stdout stays clean.
  - A converted verb draws with the components in § Output.
  - A verb not yet converted uses the framed calls, where `ui::intro` arms the framing.
  - A verb that opened no frame prints the plain lines scripts parse.
  - Framing needs a terminal on both streams. `KENDEX_UI=plain|pretty` overrides.
  - `tests/presentation/` enforces this.
  - The `cli-raw-output` lane of `tools/guard` refuses an escape sequence or a stdout/stderr handle under `src/` outside `src/ui`.
  - Clippy's `print_stdout` and `print_stderr` refuse `println!` and `eprintln!`.
- Non-interactive is a mode, not a fallback.
  - Every verb completes without a TTY.
  - Selection flags suppress prompts.
  - A verb needing input fails naming the flag before its first write.
- A writing run reports its outcome through `src/commands/ledger.rs`.
  - [OUTPUT.md](OUTPUT.md) owns presentation.
- Before changing command hints or recovery text, read [engine.md](../../docs/architecture/engine.md), including its pasteable-command rule and notice exceptions.
  - The commit offer may show git and gh lines for a step it leaves to the person (`src/commands/commit_offer/block.rs`).
- Before changing install destinations or project registration, read [engine.md](../../docs/architecture/engine.md).
  - `src/commands/mod.rs::install_destination` and `src/commands/project.rs` own those decisions.
  - Verbs call them.
- Before changing conflict or check results, read [OUTPUT.md](OUTPUT.md) and the command's owner.
- A session-start check uses `--report-only` and never writes a project's committed install record.
- Keep private values out of output, including test diagnostics; the shared rule is in [../AGENTS.md](../AGENTS.md).
- A separate `[[test]]` target follows the macOS partition in [skill-tests.yml](../../.github/workflows/skill-tests.yml).
  - `tools/tests/orch-shard-partition.test.sh` checks that partition.

## Output

Before changing CLI output, read [OUTPUT.md](OUTPUT.md).

- Converted verbs draw with `ui::Style` and print through `ui::stdout` or `ui::stderr`.
  - `check --quiet` is the exception: core spells the session hook's bounded report.
