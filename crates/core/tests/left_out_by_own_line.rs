//! `EngineReport::left_out_by_own_line`: whether a planned package is left
//! off every tool it is planned for by the hook's own harnesses line.
//!
//! Each row but the first reaches one rule and answers `false`; removing
//! that rule turns the row `true`. The hook-kind rule is the skill row,
//! the name rule the sibling hook row, the planned-for-no-tool rule the
//! empty row, and the every-tool rule the Claude-and-Codex row.

use kendex_core::apply::Plan;
use kendex_core::engine::{EngineReport, ExcludedHook};
use kendex_core::model::{HarnessId, ItemKind, Scope};

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_is_left_out_only_when_its_own_line_leaves_off_every_planned_tool() {
    let mut report = EngineReport::observed(Plan::landed(Scope::Global, Vec::new()).unwrap());
    report.excluded_hooks.push(ExcludedHook {
        name: "claude-only".into(),
        harness: HarnessId::Codex,
    });
    // (kind, name, tools it is planned for, left out)
    let rows: [(ItemKind, &str, &[HarnessId], bool); 5] = [
        (ItemKind::Hook, "claude-only", &[HarnessId::Codex], true),
        (ItemKind::Skill, "claude-only", &[HarnessId::Codex], false),
        (ItemKind::Hook, "everywhere", &[HarnessId::Codex], false),
        (ItemKind::Hook, "claude-only", &[], false),
        (
            ItemKind::Hook,
            "claude-only",
            &[HarnessId::Claude, HarnessId::Codex],
            false,
        ),
    ];
    for (kind, name, harnesses, left_out) in rows {
        assert_eq!(
            report.left_out_by_own_line(kind, name, harnesses),
            left_out,
            "{kind:?} {name} on {harnesses:?}"
        );
    }
}
