//! Taking the shims back from a project that no longer installs to their
//! harness. The lock records no shim, so what proves one is kendex's is
//! the inventory on disk listing its position, which an earlier pass wrote
//! there, and what the position holds: the exact bytes, or the exact value
//! the shim's edit wrote. Either alone is something a person writes by
//! hand, and stays.

use std::collections::BTreeSet;
use std::path::Path;

use super::observe::{agents_files, gemini_retirement, relative_name, uncomparable};
use super::{AGENTS_FILE, CLAUDE_SHIM, CLAUDE_SHIM_FILE, GEMINI_KEY};
use crate::apply::{Description, PlannedOp};
use crate::engine::config_edits::ConfigEditPlan;
use crate::engine::generated_paths::{INVENTORY, inventory_paths};
use crate::engine::removal::trash;
use crate::engine::{DriftRow, DriftState};
use crate::env::Env;
use crate::error::Result;
use crate::model::{HarnessId, ItemKind, Scope};

/// Plan the retirement of every shim whose harness `harnesses` no longer
/// names, with a row for each: orphaned where it goes, a conflict where
/// the file it sits in cannot be read.
pub(super) fn retire(
    env: &Env,
    scope: &Scope,
    harnesses: &[HarnessId],
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut ConfigEditPlan,
) -> Result<Vec<DriftRow>> {
    let Scope::Project { root } = scope else {
        return Ok(Vec::new());
    };
    // An inventory that will not parse lists nothing; the attestation
    // reports it.
    let listed = crate::fs::read_if_exists(&root.join(INVENTORY))?
        .and_then(|text| inventory_paths(text.as_bytes()).ok())
        .unwrap_or_default();
    let mut drift = Vec::new();
    if !harnesses.contains(&HarnessId::Claude) {
        drift.extend(claude(scope, root, &listed, ops)?);
    }
    if !harnesses.contains(&HarnessId::Gemini) {
        drift.extend(gemini(env, scope, root, &listed, config_edits));
    }
    Ok(drift)
}

/// Each `CLAUDE.md` beside a tracked `AGENTS.md` that holds exactly the
/// shim and that the inventory on disk lists, so an earlier pass wrote it.
/// The bytes alone are not proof: one import line is also what a person
/// writes by hand to point Claude Code at their `AGENTS.md`.
fn claude(
    scope: &Scope,
    root: &Path,
    listed: &BTreeSet<String>,
    ops: &mut Vec<PlannedOp>,
) -> Result<Vec<DriftRow>> {
    let mut drift = Vec::new();
    for agents in agents_files(root)? {
        let path = agents.parent().unwrap_or(root).join(CLAUDE_SHIM_FILE);
        let name = relative_name(root, &path);
        if !listed.contains(&name) || path.is_symlink() {
            continue;
        }
        match std::fs::read(&path) {
            Ok(bytes) if bytes == CLAUDE_SHIM.as_bytes() => {}
            Ok(_) => continue,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                drift.push(row(
                    scope,
                    name.clone(),
                    HarnessId::Claude,
                    DriftState::Conflict,
                    uncomparable(&name, &crate::error::CoreError::io(&path, error)),
                ));
                continue;
            }
        }
        ops.push(trash(
            Description::around(
                "Move the Claude Code shim ",
                " to the trash — this project no longer installs to Claude Code",
            ),
            path,
        )?);
        drift.push(row(
            scope,
            name,
            HarnessId::Claude,
            DriftState::Orphaned,
            format!(
                "the {CLAUDE_SHIM_FILE} shim serves Claude Code, which this project no longer installs to"
            ),
        ));
    }
    Ok(drift)
}

/// The Gemini settings file where the inventory on disk lists it, so an
/// earlier pass wrote into it, and it still holds exactly what the shim's
/// edit wrote. The value alone is not proof: Gemini's default file and
/// `AGENTS.md` is also what a person sets by hand to have Gemini read it.
/// A file that will not read or parse proves nothing either way, so it is
/// left as it is and named as a conflict in the words the shim's own
/// standing uses.
fn gemini(
    env: &Env,
    scope: &Scope,
    root: &Path,
    listed: &BTreeSet<String>,
    config_edits: &mut ConfigEditPlan,
) -> Option<DriftRow> {
    let path = crate::harness::gemini::settings::settings_file(env, scope);
    let name = relative_name(root, &path);
    if !listed.contains(&name) || !path.is_file() {
        return None;
    }
    let refused = |detail: String| {
        Some(row(
            scope,
            name.clone(),
            HarnessId::Gemini,
            DriftState::Conflict,
            detail,
        ))
    };
    let current = match crate::fs::read_if_exists(&path) {
        Ok(Some(current)) => current,
        Ok(None) => return None,
        Err(error) => return refused(uncomparable(&name, &error)),
    };
    let retirement = gemini_retirement();
    let updated = match retirement.apply(&current) {
        Ok(updated) => updated,
        Err(message) => {
            return refused(format!(
                "{} could not be edited: {message}",
                crate::names::shown(&name)
            ));
        }
    };
    let parsed = |text: &str| serde_json::from_str::<serde_json::Value>(text).ok();
    if parsed(&updated) == parsed(&current) {
        return None;
    }
    config_edits.push(
        path,
        format!("stop naming {AGENTS_FILE} as a context file"),
        retirement,
    );
    Some(row(
        scope,
        name,
        HarnessId::Gemini,
        DriftState::Orphaned,
        format!(
            "{GEMINI_KEY} names {AGENTS_FILE} for Gemini, which this project no longer installs to"
        ),
    ))
}

fn row(
    scope: &Scope,
    name: String,
    harness: HarnessId,
    state: DriftState,
    detail: String,
) -> DriftRow {
    DriftRow {
        kind: ItemKind::Skill,
        name,
        harness,
        scope: scope.clone(),
        state,
        detail,
        cause: None,
        compared: None,
        also_in_the_way: Vec::new(),
    }
}
