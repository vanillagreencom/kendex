//! What the lock keeps about one installation, beside its name and its
//! source: what this pass wrote, and what it registered.
//!
//! Both are records of the past, and both exist because the alternative —
//! working them out again from what is rendered now — is right only until
//! something changes. A catalog moving a hook to another event, or an
//! upstream changing a file, is not the person's doing, and a pass that
//! could not tell the difference said it was.

use std::path::PathBuf;

use crate::configedit::ConfigEdit;
use crate::lock::LockEntry;

use super::desired::{Artifact, Desired};

/// The entry this installation registered last time, when that is not the
/// entry it registers now — the removal a move needs before its install.
///
/// A catalog is free to move a hook to another event or narrow its
/// matcher, and what comes of that has to be one entry in its new place,
/// not two. Recording the new identity without taking the old one out
/// leaves the hook firing under both, and leaves the next pass looking at
/// a command carried twice, which it cannot tell its own copy of.
///
/// Nothing is retired where the record names what this pass renders
/// anyway, so a settled installation plans nothing. The edit goes to the
/// file this pass registers in; one written into a file kendex no longer
/// registers in — the old layout of a pi hook, say — is nothing this edit
/// would find, and belongs to whatever is retiring that file.
pub(super) fn retire_previous(
    item: &Desired,
    existing: Option<&LockEntry>,
) -> Option<(PathBuf, ConfigEdit)> {
    let recorded = existing?.registration.as_ref()?;
    let (path, edit) = registration_edit(item)?;
    let (event, matcher, command) = match edit {
        ConfigEdit::UpsertHook {
            event,
            matcher,
            command,
            ..
        }
        | ConfigEdit::UpsertCopilotHook {
            event,
            matcher,
            command,
            ..
        } => (event, matcher, command),
        _ => return None,
    };
    let matcher = matcher
        .as_deref()
        .filter(|matcher| !matcher.is_empty())
        .unwrap_or(crate::scan::hooks::ANY_MATCHER);
    let same = &recorded.event == event
        && &recorded.command == command
        && recorded
            .matcher
            .as_deref()
            .is_none_or(|kept| kept == matcher);
    if same {
        return None;
    }
    let removal = match edit {
        ConfigEdit::UpsertCopilotHook { .. } => ConfigEdit::RemoveCopilotHook {
            event: Some(recorded.event.clone()),
            command: recorded.command.clone(),
        },
        _ => ConfigEdit::RemoveHook {
            event: Some(recorded.event.clone()),
            command: recorded.command.clone(),
        },
    };
    Some((path.clone(), removal))
}

/// The one edit that registers this item, when it has one.
fn registration_edit(item: &Desired) -> Option<(&PathBuf, &ConfigEdit)> {
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return None;
    };
    edits.iter().find_map(|(path, edit)| {
        matches!(
            edit,
            ConfigEdit::UpsertHook { .. } | ConfigEdit::UpsertCopilotHook { .. }
        )
        .then_some((path, edit))
    })
}

/// The registry entry this installation wrote, for the record to keep.
///
/// Kept for every hook that registers one, not only for the script-less
/// kind. What a later pass has to find is what an earlier one wrote, and
/// what the catalog renders today is a different question — a catalog is
/// free to move a hook to another event, and a pass that answered "where
/// did we put it?" out of the current rendering called that an act of the
/// person's and held the hook for ever.
///
/// A hook with no script of its own is recorded for a second reason: its
/// command is the person's own and cannot be re-derived once the
/// declaration that carried it is gone. Which of the two shapes this is
/// reads off `rendered_hash`, which is set exactly when kendex wrote a
/// script.
pub(super) fn registration(item: &Desired) -> Option<crate::lock::HookRegistration> {
    use crate::configedit::ConfigEdit;
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return None;
    };
    if item.kind != crate::model::ItemKind::Hook {
        return None;
    }
    let record = |event: &String, matcher: Option<&String>, command: &String| {
        Some(crate::lock::HookRegistration {
            event: event.clone(),
            command: command.clone(),
            // Spelled the way the registry spells it, so the record and a
            // reading of the file are comparable without either guessing.
            matcher: Some(
                matcher
                    .map(String::as_str)
                    .filter(|matcher| !matcher.is_empty())
                    .unwrap_or(crate::scan::hooks::ANY_MATCHER)
                    .to_owned(),
            ),
        })
    };
    edits.iter().find_map(|(_, edit)| match edit {
        ConfigEdit::UpsertHook {
            event,
            matcher,
            command,
            ..
        }
        | ConfigEdit::UpsertCopilotHook {
            event,
            matcher,
            command,
            ..
        } => record(event, matcher.as_ref(), command),
        // A disabled hook renders the reversed registration, which names
        // the event its entry was written under; its matcher is not part
        // of that edit, so it stays unknown rather than assumed.
        ConfigEdit::RemoveHook {
            event: Some(event),
            command,
        }
        | ConfigEdit::RemoveCopilotHook {
            event: Some(event),
            command,
        } => Some(crate::lock::HookRegistration {
            event: event.clone(),
            command: command.clone(),
            matcher: None,
        }),
        _ => None,
    })
}

pub(super) fn rendered_hash(artifact: &Artifact) -> Option<String> {
    match artifact {
        Artifact::File { .. } | Artifact::Tree { .. } => {
            Some(super::desired::artifact_disk_hash(artifact))
        }
        // A hook's backing script is a file kendex alone writes, so it can
        // be anchored like any other. A registration with no script edits
        // only shared config, which holds other people's keys — nothing to
        // anchor there.
        Artifact::Registration {
            script: Some(_), ..
        } => Some(super::desired::artifact_disk_hash(artifact)),
        Artifact::Registration { script: None, .. } => None,
    }
}
