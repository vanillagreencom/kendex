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
/// entry it names now — the removal a change of identity needs before
/// whatever this pass renders.
///
/// A catalog is free to move a hook to another event or narrow its
/// matcher, and what comes of that has to be one entry in its new place,
/// not two. It is the same when the hook is switched off in the same
/// breath: the pass renders the removal of the entry it would write
/// today, which is not the entry that is actually there, and recording
/// the new identity over the old one leaves what is there with nothing
/// naming it — running, and unfindable by every pass after.
///
/// Nothing is retired where the record names what this pass names anyway,
/// so a settled installation plans nothing. The edit goes to the file
/// this pass registers in; one written into a file kendex no longer
/// registers in — the old layout of a pi hook, say — is nothing this edit
/// would find, and belongs to whatever is retiring that file.
pub(super) fn retire_previous(
    item: &Desired,
    existing: Option<&LockEntry>,
) -> Option<(PathBuf, ConfigEdit)> {
    let recorded = existing?.registration.as_ref()?;
    let named = named(item)?;
    // A matcher neither side knows is not a difference. What renders a
    // removal names no matcher, and a record kept before matchers were
    // kept holds none either.
    let matcher = match (&recorded.matcher, named.matcher) {
        (Some(kept), Some(named)) => kept == named,
        _ => true,
    };
    if recorded.event == named.event && recorded.command == named.command && matcher {
        return None;
    }
    let event = Some(recorded.event.clone());
    // The key the identity was decided by, and no coarser: a command the
    // person also registered under a matcher of their own is theirs, and
    // retiring by the command alone would take it with kendex's. Where
    // the record kept no matcher there is nothing finer to retire by, and
    // the reach is what it always was.
    let matcher = recorded.matcher.clone();
    let command = recorded.command.clone();
    let removal = match named.copilot {
        true => ConfigEdit::RemoveCopilotHook {
            event,
            matcher,
            command,
        },
        false => ConfigEdit::RemoveHook {
            event,
            matcher,
            command,
        },
    };
    Some((named.path.clone(), removal))
}

/// The identity one edit names, and where it names it.
struct Named<'a> {
    path: &'a PathBuf,
    copilot: bool,
    event: &'a str,
    /// `None` where the edit names no matcher at all — a removal names an
    /// event and a command and no more. Unknown, never "every operation".
    matcher: Option<&'a str>,
    command: &'a str,
}

/// A matcher as a registry spells it: what the edit names, or the "every
/// operation" spelling where it names none.
fn spelled(matcher: &Option<String>) -> Option<&str> {
    matcher
        .as_deref()
        .filter(|matcher| !matcher.is_empty())
        .or(Some(crate::scan::hooks::ANY_MATCHER))
}

/// The identity this pass names for one item's registration, whichever
/// way round it names it.
///
/// Four edit shapes carry one: an upsert says where the entry is going, a
/// removal says where it is being taken from, in each of the two registry
/// formats. Everything else a registration artifact carries names no
/// entry — a codex feature flag, an opencode instruction reference, an
/// mcp server, a plugin toggle — so there is nothing about them for a
/// record to have named differently.
fn named(item: &Desired) -> Option<Named<'_>> {
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return None;
    };
    edits.iter().find_map(|(path, edit)| match edit {
        ConfigEdit::UpsertHook {
            event,
            matcher: named,
            command,
            ..
        } => Some(Named {
            path,
            copilot: false,
            event,
            matcher: spelled(named),
            command,
        }),
        ConfigEdit::UpsertCopilotHook {
            event,
            matcher: named,
            command,
            ..
        } => Some(Named {
            path,
            copilot: true,
            event,
            matcher: spelled(named),
            command,
        }),
        ConfigEdit::RemoveHook {
            event: Some(event),
            matcher: named,
            command,
        } => Some(Named {
            path,
            copilot: false,
            event,
            matcher: spelled(named),
            command,
        }),
        ConfigEdit::RemoveCopilotHook {
            event: Some(event),
            matcher: named,
            command,
        } => Some(Named {
            path,
            copilot: true,
            event,
            matcher: spelled(named),
            command,
        }),
        _ => None,
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
        // the event and matcher its entry was written under.
        ConfigEdit::RemoveHook {
            event: Some(event),
            matcher,
            command,
        }
        | ConfigEdit::RemoveCopilotHook {
            event: Some(event),
            matcher,
            command,
        } => record(event, matcher.as_ref(), command),
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
