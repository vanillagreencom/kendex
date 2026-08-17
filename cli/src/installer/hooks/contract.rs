//! The hook execution contract: one matrix of event × harness that decides
//! what installing a hook means, which artifact carries it, and what the
//! consumer is told about it.
//!
//! Every install path, every `vstack list`/`check` label, and the published
//! table in `README.md` derive from [`CONTRACT`]. Nothing restates it.

use crate::harness::Harness;

/// Banner every advisory artifact carries — a rule file opens with it, the
/// Codex prose block leads with it under its `## Safety:` header — so none
/// can be read as a guard.
pub const ADVISORY_BANNER: &str = "advisory — this harness cannot execute hooks";

/// Pi package that carries hook behavior for Pi. Pi has no per-hook install
/// artifact; without this package installed, nothing on Pi enforces.
pub const PI_HOOKS_PACKAGE: &str = "@vanillagreen/pi-hooks";

/// What vstack writes, and what runs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mechanism {
    /// Script under `<scope>/.claude/hooks/`, registered in `settings.json`.
    ClaudeSettingsHook,
    /// Script under `<scope>/.codex/hooks/`, registered in `hooks.json`.
    CodexHooksJson,
    /// Safety prose inside each Codex agent's `developer_instructions`.
    CodexInstructions,
    /// `<scope>/.cursor/rules/safety-<name>.mdc`.
    CursorRule,
    /// `<scope>/.opencode/instructions/vstack-hook-<name>.md`, referenced
    /// from `opencode.json`.
    OpenCodeInstruction,
    /// Native TypeScript listener in the `@vanillagreen/pi-hooks` package.
    PiHooksExtension,
}

impl Mechanism {
    /// The harness whose install path writes this artifact. A cell may only
    /// name a mechanism belonging to its own column.
    #[cfg(test)]
    pub fn harness(self) -> Harness {
        match self {
            Mechanism::ClaudeSettingsHook => Harness::ClaudeCode,
            Mechanism::CodexHooksJson | Mechanism::CodexInstructions => Harness::Codex,
            Mechanism::CursorRule => Harness::Cursor,
            Mechanism::OpenCodeInstruction => Harness::OpenCode,
            Mechanism::PiHooksExtension => Harness::Pi,
        }
    }

    /// Short label for rendered tables and CLI output.
    #[cfg(test)]
    pub fn label(self) -> &'static str {
        match self {
            Mechanism::ClaudeSettingsHook => "settings.json hook",
            Mechanism::CodexHooksJson => "hooks.json entry",
            Mechanism::CodexInstructions => "agent instructions",
            Mechanism::CursorRule => "rule file",
            Mechanism::OpenCodeInstruction => "instruction file",
            Mechanism::PiHooksExtension => "pi-hooks extension",
        }
    }
}

/// One cell of the contract: what the harness does with this event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cell {
    /// The harness runs the hook itself. A refusal is deterministic.
    Enforced(Mechanism),
    /// The harness only reads text. Compliance is the model's.
    Advisory(Mechanism),
    /// Nothing is installed for this pair.
    Unsupported,
}

impl Cell {
    pub fn level(self) -> &'static str {
        match self {
            Cell::Enforced(_) => "enforced",
            Cell::Advisory(_) => "advisory",
            Cell::Unsupported => "unsupported",
        }
    }

    pub fn mechanism(self) -> Option<Mechanism> {
        match self {
            Cell::Enforced(mechanism) | Cell::Advisory(mechanism) => Some(mechanism),
            Cell::Unsupported => None,
        }
    }
}

/// One event's row, with one cell per harness in [`Harness::ALL`] order.
pub struct Row {
    pub event: &'static str,
    pub cells: [Cell; Harness::COUNT],
}

use Cell::{Advisory, Enforced, Unsupported};
use Mechanism::{
    ClaudeSettingsHook, CodexHooksJson, CodexInstructions, CursorRule, OpenCodeInstruction,
    PiHooksExtension,
};

/// Columns are [`Harness::ALL`]: Claude Code, Cursor, OpenCode, Codex, Pi.
///
/// Codex runs every event it maps natively; `TaskCompleted` has no Codex
/// equivalent, so it degrades to instruction prose. Pi's listeners cover
/// `tool_call`, `tool_result` and `turn_end` only — `turn_end` is what
/// carries `TaskCompleted`.
pub const CONTRACT: &[Row] = &[
    Row {
        event: "PreToolUse",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Enforced(PiHooksExtension),
        ],
    },
    Row {
        event: "PostToolUse",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Enforced(PiHooksExtension),
        ],
    },
    Row {
        event: "PermissionRequest",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "SessionStart",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "UserPromptSubmit",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "PreCompact",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "PostCompact",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "Stop",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Enforced(CodexHooksJson),
            Unsupported,
        ],
    },
    Row {
        event: "TaskCompleted",
        cells: [
            Enforced(ClaudeSettingsHook),
            Advisory(CursorRule),
            Advisory(OpenCodeInstruction),
            Advisory(CodexInstructions),
            Enforced(PiHooksExtension),
        ],
    },
];

/// The contract cell for one event on one harness. `None` for an event the
/// contract does not cover — no harness column can be honestly filled in for
/// it, so callers must refuse rather than guess.
pub fn cell(event: &str, harness: Harness) -> Option<Cell> {
    CONTRACT
        .iter()
        .find(|row| row.event == event)
        .map(|row| row.cells[harness.index()])
}

/// Whether the contract routes this event to Codex's instruction prose rather
/// than a native registration.
pub fn is_codex_prose(event: &str) -> bool {
    matches!(
        cell(event, Harness::Codex),
        Some(Cell::Advisory(Mechanism::CodexInstructions))
    )
}

/// Events the contract covers, in table order.
pub fn events() -> impl Iterator<Item = &'static str> {
    CONTRACT.iter().map(|row| row.event)
}

/// Refuse a hook whose event the contract does not cover.
///
/// Called before the first mutation of an install as well as inside it: a
/// refusal that fired only in the install loop would leave the items written
/// before it behind.
pub fn validate_event(hook_name: &str, event: &str) -> anyhow::Result<()> {
    if CONTRACT.iter().any(|row| row.event == event) {
        return Ok(());
    }
    anyhow::bail!(unknown_event_error(hook_name, event))
}

/// The message a hook naming an uncovered event is refused with.
pub fn unknown_event_error(hook_name: &str, event: &str) -> String {
    format!(
        "hook {hook_name} declares event `{event}`, which the hook execution contract does not \
         cover, so no harness can be told what it enforces. Supported events: {}.",
        events().collect::<Vec<_>>().join(", ")
    )
}

/// Text between the generated-block markers for `name`, trimmed. `None` when
/// the block is absent or unterminated.
#[cfg(test)]
pub fn generated_block<'a>(content: &'a str, name: &str) -> Option<&'a str> {
    let start = format!("<!-- generated: {name} -->");
    let end = format!("<!-- /generated: {name} -->");
    let after = content.split_once(&start)?.1;
    Some(after.split_once(&end)?.0.trim())
}

/// The contract rendered as the markdown table published in `README.md`.
#[cfg(test)]
pub fn render_markdown_table() -> String {
    let mut out = String::from("| Event |");
    for harness in Harness::ALL {
        out.push_str(&format!(" {} |", harness.name()));
    }
    out.push_str("\n|---|");
    for _ in Harness::ALL {
        out.push_str("---|");
    }
    out.push('\n');
    for row in CONTRACT {
        out.push_str(&format!("| `{}` |", row.event));
        for cell in &row.cells {
            let text = match cell.mechanism() {
                Some(mechanism) => format!("{} — {}", cell.level(), mechanism.label()),
                None => cell.level().to_string(),
            };
            out.push_str(&format!(" {text} |"));
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_event_row_covers_every_harness() {
        for row in CONTRACT {
            for harness in Harness::ALL {
                assert_eq!(
                    cell(row.event, *harness),
                    Some(row.cells[harness.index()]),
                    "{} × {} did not round-trip",
                    row.event,
                    harness.id()
                );
            }
        }
    }

    #[test]
    fn every_cell_names_a_mechanism_from_its_own_column() {
        for row in CONTRACT {
            for harness in Harness::ALL {
                let Some(mechanism) = row.cells[harness.index()].mechanism() else {
                    continue;
                };
                assert_eq!(
                    mechanism.harness(),
                    *harness,
                    "{} × {} names {mechanism:?}, which belongs to {}",
                    row.event,
                    harness.id(),
                    mechanism.harness().id()
                );
            }
        }
    }

    #[test]
    fn event_rows_are_unique() {
        let mut seen: Vec<&str> = Vec::new();
        for row in CONTRACT {
            assert!(!seen.contains(&row.event), "duplicate row {}", row.event);
            seen.push(row.event);
        }
    }

    #[test]
    fn an_uncovered_event_has_no_cell() {
        assert!(cell("Notification", Harness::ClaudeCode).is_none());
    }

    #[test]
    fn the_shipped_hooks_all_declare_a_covered_event() {
        let hooks_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../hooks");
        let hooks = crate::hook::discover_hooks(&hooks_dir).unwrap();
        assert!(!hooks.is_empty(), "no shipped hooks discovered");
        for hook in hooks {
            assert!(
                cell(&hook.event, Harness::ClaudeCode).is_some(),
                "shipped hook {} declares uncovered event {}",
                hook.name,
                hook.event
            );
        }
    }

    #[test]
    fn the_readme_table_is_the_rendered_matrix() {
        let readme = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../README.md");
        let content = std::fs::read_to_string(&readme).unwrap();
        let published = generated_block(&content, "hook-contract")
            .expect("README carries the generated hook-contract block");
        assert_eq!(
            published,
            render_markdown_table().trim(),
            "README hook contract table is stale — it is generated from CONTRACT"
        );
    }
}
