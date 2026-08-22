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

/// What the last pass registered, when that is not what this one names —
/// the removal a change of identity needs before whatever it renders.
///
/// A catalog is free to move a hook to another event or narrow its
/// matcher, and what comes of that has to be one entry in its new place,
/// not two. It is the same when the hook is switched off in the same
/// breath: the pass renders the removal of the entry it would write
/// today, which is not the entry that is actually there, and recording
/// the new identity over the old one leaves what is there with nothing
/// naming it — running, and unfindable by every pass after.
///
/// Where the record cannot name the old entry — one written before the
/// record kept a registration at all, or before it kept a matcher — the
/// document is asked instead: the entry is there to be read even when the
/// record does not describe it. What is read is the document's own event
/// and matcher, never this pass's; the rendered command is only what the
/// entry is looked up by, and one carried more than once is one nothing
/// here can tell apart.
///
/// Nothing is retired where the record names what this pass names anyway,
/// so a settled installation plans nothing. The edit goes to the file
/// this pass registers in; one written into a file kendex no longer
/// registers in — the old layout of a pi hook, say — is nothing this edit
/// would find, and belongs to whatever is retiring that file.
pub(super) enum Previous {
    /// Nothing of this installation's is registered anywhere but where
    /// this pass is about to write.
    Settled,
    /// The entry to take out first, named exactly.
    Retire(PathBuf, ConfigEdit),
    /// More than one entry runs this command, and nothing here can say
    /// which was kendex's. Writing beside them would add a third.
    Ambiguous(String),
}

pub(super) fn retire_previous(item: &Desired, existing: Option<&LockEntry>) -> Previous {
    let Some(named) = named(item) else {
        return Previous::Settled;
    };
    // Nothing kendex has installed here has nothing kendex left behind.
    // A hook going in for the first time has no past of its own, so
    // whatever else in the document happens to run the command it is
    // about to register — a `[[custom-hooks]]` command is the person's
    // own words, and they may already have registered it — is theirs,
    // and looking for it would only find something to take.
    let Some(entry) = existing else {
        return Previous::Settled;
    };
    let previous = match &entry.registration {
        // The record names an entry. Whether it is still there is the
        // document's to say, not the record's: trusting the record here
        // is how a registration somebody moved by hand came to be left
        // alone while a second one went in beside it.
        Some(recorded) => found(
            &named,
            Some(&recorded.event),
            recorded.matcher.as_deref(),
            &recorded.command,
        ),
        // A record too old to name what it registered, over an
        // installation kendex did make: the command is what there is to
        // look one up by, and the document says the rest.
        None => found(&named, None, None, named.command),
    };
    let previous = match previous {
        Found::One(entry) => entry,
        Found::None => return Previous::Settled,
        Found::Several(why) | Found::Moved(why) => return Previous::Ambiguous(why),
    };
    if previous.event == named.event
        && previous.command == named.command
        && named
            .matcher
            .is_none_or(|named| previous.matcher == crate::configedit::spelled(Some(named)))
    {
        return Previous::Settled;
    }
    let event = Some(previous.event);
    let matcher = Some(previous.matcher);
    let command = previous.command;
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
    Previous::Retire(named.path.clone(), removal)
}

/// One registration, as something that knows all three of its parts.
struct Recorded {
    event: String,
    matcher: String,
    command: String,
}

/// What the document says about the entry kendex left.
enum Found {
    One(Recorded),
    None,
    Several(String),
    Moved(String),
}

/// The entry kendex left, read out of the document this pass registers
/// in, by everything there is to look it up by: the command, and the
/// event and matcher wherever the record kept them.
///
/// Exactly one answering is the answer. More than one is a question
/// nothing here can settle, since what the record kept cannot tell them
/// apart. And nothing answering, while something else runs that command,
/// is an entry somebody moved: it is not kendex's to take, and writing
/// beside it would leave the hook firing twice — so it waits for them.
fn found(named: &Named, event: Option<&str>, matcher: Option<&str>, command: &str) -> Found {
    let Ok(Some(text)) = crate::fs::read_if_exists(named.path) else {
        return Found::None;
    };
    let read = match named.copilot {
        true => crate::scan::copilot::registrations_text(&text),
        false => crate::scan::hooks::registrations_text(&text),
    };
    let Ok(entries) = read else {
        return Found::None;
    };
    let mut answering = entries.iter().filter(|entry| {
        entry.command == command
            && event.is_none_or(|event| entry.event == event)
            && matcher.is_none_or(|matcher| entry.matcher == matcher)
    });
    let Some(only) = answering.next() else {
        return match entries.iter().any(|entry| entry.command == command) {
            true => Found::Moved(format!(
                "{} no longer runs {command} where kendex left it, and what runs it now is not kendex's to take — move it back, or take it out, and the next refresh settles this",
                named.path.display()
            )),
            false => Found::None,
        };
    };
    if answering.next().is_some() {
        return Found::Several(format!(
            "{} runs {command} more than once and the record does not say which entry is kendex's — take the ones you did not put there out, and the next refresh settles the rest",
            named.path.display()
        ));
    }
    Found::One(Recorded {
        event: only.event.clone(),
        matcher: only.matcher.clone(),
        command: only.command.clone(),
    })
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
            matcher: Some(crate::configedit::spelled(named.as_deref())),
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
            matcher: Some(crate::configedit::spelled(named.as_deref())),
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
            matcher: Some(crate::configedit::spelled(named.as_deref())),
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
            matcher: Some(crate::configedit::spelled(named.as_deref())),
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
            // Spelled the way the registry spells it, through the one
            // canonicalization every comparison goes through, so the
            // record and a reading of the file cannot say the same thing
            // differently.
            matcher: Some(crate::configedit::spelled(matcher.map(String::as_str)).to_owned()),
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
