//! What the lock keeps about one installation, beside its name and its
//! source: what this pass wrote, and what it registered.
//!
//! Both are records of the past, and both exist because the alternative —
//! working them out again from what is rendered now — is right only until
//! something changes. A catalog moving a hook to another event, or an
//! upstream changing a file, is not the person's doing, and a pass that
//! could not tell the difference said it was.

use super::desired::{Artifact, Desired};

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
