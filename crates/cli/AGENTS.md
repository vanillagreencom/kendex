# crates/cli/

Thin verbs over `kendex-core`: a verb parses, calls core and prints. No domain logic lives here.

- Every human line leaves through `src/ui.rs`, escaped there; a payload is not, and stdout stays clean. `ui::intro` arms the framed rendering, and a verb that opened no frame prints the plain lines scripts parse. Framing needs a terminal on both streams; `KENDEX_UI=plain|pretty` overrides. Enforced by `tests/presentation/`.
- Non-interactive is a mode, not a fallback: every verb completes without a TTY, selection flags suppress prompts, and a verb needing input fails naming the flag before its first write.
- A writing run closes on the outcome ledger (`src/commands/ledger.rs`): wrote, skipped, flagged, and a next step under each nonzero part.
- No verb emits a pasteable command line; errors, hints and recovery present the verb and its parameters as data. The one exception is the session-start drift report, whose remedies come from the fixed template set in `crates/core/src/drift/report/`. Enforced by `tests/unmanaged_exits/refusals.rs::a_link_no_declared_tool_sits_at_offers_no_command`.
- `kendex check` exits 0 clean, 1 drift or unevaluated, 2 could not check; unknown outranks drift.
- A test that runs the binary against a fixture home sets `KENDEX_REAL_HOME=1` beside the `HOME` it sets (a `tools/guard` lane); `tests/dev_sandbox.rs` proves the sandbox.
