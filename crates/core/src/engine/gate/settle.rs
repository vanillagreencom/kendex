//! Two things the gate says once per pass rather than once per harness.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::ItemKind;

use crate::engine::desired::DesiredState;

/// One item declared for four tools raises one thing to say, not four. The
/// publisher's own check stays green either way, so this is the only place
/// anybody learns that a review was carried and did not apply.
pub(super) fn warn_unapplied(
    unapplied: BTreeMap<(ItemKind, String, String), BTreeSet<String>>,
    state: &mut DesiredState,
) {
    for ((kind, name, publisher), fingerprints) in unapplied {
        state.warnings.push(crate::engine::ItemWarning {
            kind,
            name: name.clone(),
            harness: None,
            message: format!(
                "{} of {publisher}'s reviewed findings do not appear in what {name} installs here, so they settle nothing",
                fingerprints.len()
            ),
            remediation: Some(
                "re-run `kendex check --catalog` in the source and re-record the tokens it prints now"
                    .to_owned(),
            ),
        });
    }
}

/// A skill held back on every harness also loses its say over the project's
/// settings file: what it would seed or refresh there is content the gate
/// refused.
pub(super) fn drop_settings_from_blocked_skills(state: &mut DesiredState) {
    let surviving: std::collections::BTreeSet<&str> = state
        .items
        .iter()
        .filter(|item| item.kind == ItemKind::Skill)
        .map(|item| item.name.as_str())
        .collect();
    let blocked: std::collections::BTreeSet<String> = state
        .refused
        .iter()
        .filter(|refused| refused.kind == ItemKind::Skill)
        .filter(|refused| !surviving.contains(refused.name.as_str()))
        .map(|refused| refused.name.clone())
        .collect();
    state
        .settings_env
        .retain(|seeded| !blocked.contains(&seeded.owner));
}
