//! The project's private env file, as a plan writes it.
//!
//! Apart from the settings pass beside it because what goes in this file
//! is decided by a different question and lands under different rules.
//! `kendex.settings.toml` is the consumer's committed configuration and a
//! seed may put a line in it; this file is the one git must not carry, and
//! nothing writes it except a person saving a credential they typed.
//!
//! The `.gitignore` line a new private file needs is not written here.
//! `.gitignore` is one file and [`super::posture`] owns it, so a plan that
//! creates the private file hands that pass the line and both go in
//! together — two passes writing the same file in one plan would have the
//! second bind to bytes the first replaced, and the whole apply would
//! refuse.
//!
//! Every check the destination is held to runs here again rather than
//! being carried over from the read the person saw. Between the two, a
//! `.gitignore` line can go, a file can be staged, and a path can become
//! a link — and a plan built on the older answer would write a credential
//! into a file git is about to commit. The read is what the person is
//! shown; this is what the write is allowed to find.
//!
//! What this pass never does is describe a value. The op's description
//! names the file and the keys, the notes name keys, and the refusals
//! name keys and lines — so a plan, an audit and an error can all be
//! shown without any of them carrying a credential.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::model::Scope;
use crate::settings_secret::{
    Destination, DestinationState, SecretRefusal, SecretsDraft, destination,
};

use super::desired::DesiredState;

/// What this pass writes into the project's private env file, and what it
/// has to do first to make that file safe.
///
/// Nothing at all where the save carries no secret half. Where it does,
/// the destination is re-derived and re-checked, the ignore entry is
/// planned ahead of the file it protects, and the credential write goes
/// last — so a refusal at any step leaves nothing written.
pub(super) fn plan_secrets(
    scope: &Scope,
    state: &DesiredState,
    options: &crate::engine::PlanOptions,
    target: Option<&Destination>,
    ops: &mut Vec<PlannedOp>,
) -> Result<Vec<String>> {
    let Some(draft) = options.secrets_draft.as_ref() else {
        return Ok(Vec::new());
    };
    let Scope::Project { root } = scope else {
        // Nothing global has a private file, so an edit here names a key
        // no package at this place declares — refused in the same words a
        // project would refuse it.
        if let Some(edit) = draft.edits.first() {
            return Err(SecretRefusal::Undeclared {
                skill: edit.skill.clone(),
                key: edit.key.clone(),
            }
            .into());
        }
        return Ok(Vec::new());
    };
    let Some(target) = target else {
        return Ok(Vec::new());
    };
    let DestinationState::Refused { problem, .. } = &target.state else {
        return write(root, state, draft, target, ops);
    };
    Err(SecretRefusal::Unavailable {
        file: target.file.clone(),
        problem: problem.clone(),
    }
    .into())
}

/// The file this save writes, checked as it stands now — resolved once for
/// the whole plan, because two passes act on the answer: the write itself,
/// and the `.gitignore` line the posture pass owes a file it is about to
/// create.
///
/// A save that is not choosing a destination is bound to the one its rows
/// were read against: a project pointed at another file between the read
/// and the save would take a value the person confirmed for one file and
/// put it in another, so that is refused and the page reads again.
pub(super) fn target(
    scope: &Scope,
    options: &crate::engine::PlanOptions,
) -> Result<Option<Destination>> {
    let Some(draft) = options.secrets_draft.as_ref() else {
        return Ok(None);
    };
    let Scope::Project { root } = scope else {
        return Ok(None);
    };
    if draft.edits.is_empty() {
        return Ok(None);
    }
    let settings = crate::fs::read_if_exists(&crate::settings_seed::settings_file_path(root))?;
    let want = draft.choose.then_some(draft.file.as_str());
    let target = destination(root, settings.as_deref(), want);
    if target.file != draft.file {
        return Err(SecretRefusal::Moved {
            then: draft.file.clone(),
            now: target.file,
        }
        .into());
    }
    Ok(Some(target))
}

/// The `.gitignore` line a plan owes the private file it is about to
/// create, where it owes one. A file already there, or one git already
/// ignores, owes none.
pub(super) fn owed_ignore(target: Option<&Destination>) -> Option<&str> {
    match &target?.state {
        DestinationState::Missing { ignore } => ignore.as_deref(),
        _ => None,
    }
}

/// The ops this save needs, in the order they have to run.
fn write(
    root: &std::path::Path,
    state: &DesiredState,
    draft: &SecretsDraft,
    target: &Destination,
    ops: &mut Vec<PlannedOp>,
) -> Result<Vec<String>> {
    let path = target.path(root);
    let declared = crate::settings_secret::declared(&state.settings_templates);
    let contested = crate::settings_secret::contested(&state.settings_templates);
    let current = crate::fs::read_if_exists(&path)?;
    let (text, changed) = crate::settings_secret::apply_edits(
        current.as_deref().unwrap_or_default(),
        &draft.edits,
        &declared,
        &contested,
        &path,
    )?;
    if current.as_deref() == Some(text.as_str()) || (current.is_none() && text.is_empty()) {
        return Ok(Vec::new());
    }
    ops.push(PlannedOp {
        description: format!("Store {} in {}", changed.join(", "), target.file).into(),
        op: Op::WritePrivateFile {
            // The copy the rows were read from, so a writer that landed
            // after the person opened the page is refused rather than
            // overwritten.
            pre: Pre::from(&draft.base),
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(vec![format!(
        "{} is stored in {}, which git does not carry",
        changed.join(", "),
        target.file
    )])
}
