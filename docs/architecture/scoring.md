# Safety and quality scoring

Covers: crates/core/src/quality/, crates/core/src/engine/scoring.rs, crates/core/src/source/browse/safety.rs

Two advisory scores over an item's own bytes: safety answers "is this dangerous", quality answers "is this well made". `quality::AuditResult` (safety, quality, findings, skipped, ruleset) is the one shape every scored surface embeds, and the bound shapes flatten it so the UI reads fields at top level.

## Boundaries

- Rules read typed per-kind inputs and say when they cannot read: a skill carries its whole tree, a hook its registration and script, an MCP server its command, args, env and headers, a plugin its manifest and lifecycle scripts; a rule whose bytes are not in the input reports itself not applicable. Enforced by `crates/core/tests/quality/kinds.rs` and `crates/core/tests/quality/reading.rs`.
- The outcome is a function of exactly kind, path and name (`quality::observe::same_reading`), plus the harness for a hook in a shared config file whose parser is the harness's; no rule reads the harness. Not mechanically enforced beyond the signature.

## Invariants

1. Neither score holds anything back: severity is named in words, never colour-only, and install, update and apply proceed regardless. Enforced by `crates/core/tests/authoring_check.rs::a_safety_finding_is_reported_and_fails_nothing`.
2. Safety is `100 − Σ deductions` (Critical 25, High 15, Medium 8, Low 3), first hit per rule at full weight, repeats a point each up to as much again. Enforced by `crates/core/tests/quality/scoring.rs`.
3. A matched token never appears in any message, log or record, only a fingerprint. Enforced by `crates/core/tests/quality/scoring.rs::a_secret_finding_never_repeats_the_token` and `crates/core/tests/quality/rules.rs::an_mcp_rule_never_echoes_a_token_it_happened_to_quote`.
4. The file a harness loads is scanned at full weight, fences included: a fenced `sh` block in a SKILL.md is the instruction, and a switch counts wherever it stands as code rather than in a markdown code span. One severity less for a blockquote and for a skill's supporting files (`tests`, `fixtures`, `references`); secrets never weigh less anywhere. Enforced by `crates/core/tests/quality/rules_blocks.rs` and `crates/core/tests/quality/advisory.rs`.
5. Bytes that will not decode as text are read lossily and the replacements reported; a binary asset is not reported as undecodable. Enforced by `crates/core/tests/quality/reading.rs`.
6. Deobfuscation reports only what has no typographic use (invisible and bidirectional characters, letters imitating other letters) and normalizes emoji and compatibility forms silently; the confusables table in `crates/core/src/quality/homoglyph.rs` is not the whole of Unicode's data and says so. Enforced by `crates/core/tests/quality/reading.rs::confusables_outside_the_original_table_are_folded_and_reported`.

## Decisions

- Quality is wshobson's weighted-dimension model, static layer only: no LLM judge, no simulation, no letter grades.
- Rule severities are calibrated against real catalogs, so a rule that fires on ordinary writing is wrong, not strict.
- The CLI prints a score line then one finding per line with no fix line, and groups identical printed safety results.
