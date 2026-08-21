//! What the registry an earlier kendex wrote will and will not give up,
//! and how wide the answer reaches.
//!
//! Two obstacles live here and they are not the same size. The document
//! itself may be one kendex cannot edit at all, which is in the way of
//! every hook needing an edit in it. Or one hook's own entry may be one
//! kendex cannot pick out, which is in that hook's way and nobody else's
//! — a sibling whose entry is exactly where its record says has nothing
//! to do with it.

use super::Found;
use super::{Identity, Registered, legacy_registration, look, registered};
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::Scope;

/// Why nothing in the legacy registry can be given up at all, when
/// nothing can: it is a link kendex did not make, it could not be read,
/// or it holds an entry kendex has to take out in a shape its editor
/// cannot rewrite. The obstacle is the document, so it blocks every hook
/// that needs an edit in it — which is what makes this the scope-wide
/// half. Absence is no obstacle, and neither is a document holding
/// nobody's entries but somebody else's.
pub(super) fn registry_block(
    root: &std::path::Path,
    scope: &Scope,
    ours: &[&LockEntry],
) -> Option<String> {
    let path = pi::legacy_hook_registry(root);
    let say = |why: String| {
        Some(format!(
            "{} {why}, so nothing under the name pi reserved was retired — a hook's registration and the script it names have to go together",
            path.display()
        ))
    };
    match look(&path) {
        Found::Absent => return None,
        Found::Linked(_) => return say("is a link kendex did not create".to_owned()),
        Found::Unreadable(_, error) => return say(format!("could not be read ({error})")),
        Found::Plain(_) => {}
    }
    let entries = match crate::scan::hooks::read_registrations(&path) {
        Ok(entries) => entries,
        Err(message) => return say(format!("could not be read ({message})")),
    };
    // Whether anything of kendex's is in there to take out at all. An
    // entry kendex cannot pick out of the document is one hook's problem,
    // not the document's, and it holds that hook on its own below.
    let holds_ours = ours.iter().any(|entry| {
        matches!(
            registered(&entries, &legacy_registration(entry, scope, root)),
            Registered::Ours
        )
    });
    if !holds_ours {
        return None;
    }
    match crate::fs::read_if_exists(&path) {
        Err(error) => say(format!("could not be read ({error})")),
        Ok(text) => match serde_json::from_str::<serde_json::Value>(&text.unwrap_or_default()) {
            Ok(_) => None,
            Err(error) => say(format!(
                "holds an entry kendex has to take out but could not be parsed ({error})"
            )),
        },
    }
}

/// Why this hook's own registration under the reserved name is not
/// kendex's to take, when it is not: the record points at one entry and
/// the document does not hold exactly that one — moved to another event
/// or matcher, or carried twice. That is evidence about this hook and no
/// other, so it holds this hook and no other; a sibling whose own entry
/// is exactly where its record says still moves.
///
/// Identity has to resolve before anything is removed. The edit takes out
/// every handler answering to it, so one kendex cannot tell from another
/// is held, not guessed at.
pub(super) fn registration_conflict(
    root: &std::path::Path,
    scope: &Scope,
    entry: &LockEntry,
) -> Option<String> {
    let path = pi::legacy_hook_registry(root);
    let entries = crate::scan::hooks::read_registrations(&path).ok()?;
    let legacy = legacy_registration(entry, scope, root);
    let command = &legacy.command;
    let say = |why: String| {
        Some(format!(
            "{} {why} — that entry is not kendex's to take, so this hook stays where it is; move it back, or take it out yourself",
            path.display()
        ))
    };
    match registered(&entries, &legacy) {
        Registered::Absent => None,
        // Found, and only once — but found is not gone. What the removal
        // will really leave behind is read back before a single byte of
        // this hook's is planned for the trash.
        Registered::Ours => survives_its_own_removal(&path, &legacy).then(|| {
            format!(
                "{} writes {command} in a shape kendex cannot take it out of — a handler standing directly under its event, rather than inside a matcher group — so this hook stays where it is; take that entry out yourself, and the script goes with it on the next refresh",
                path.display()
            )
        }),
        Registered::Elsewhere => say(format!(
            "no longer registers {command} where kendex recorded it"
        )),
        // Only the new path's reading answers these two, and only about
        // its own document: the reserved name's entry is proven reachable
        // the same way a line above, and a link where it lives is what
        // `registry_block` is for.
        Registered::Unreachable | Registered::Linked => None,
        Registered::Ambiguous => say(format!(
            "registers {command} more than once, so kendex cannot tell its own entry from the others"
        )),
    }
}

/// Whether the document really gives this entry up — proven by taking it
/// out and reading the document back, never by the edit reporting that it
/// ran. A handler written directly under its event is a shape the edit
/// reaches past: it succeeds, removes nothing, and the script would then
/// go to the trash while what runs it stayed, pointing at a path with
/// nothing at it.
///
/// Anything this cannot establish reads as surviving. A document that
/// will not take the edit is one kendex cannot express this removal in,
/// which is the same answer by a shorter road.
fn survives_its_own_removal(path: &std::path::Path, identity: &Identity) -> bool {
    let Ok(Some(text)) = crate::fs::read_if_exists(path) else {
        return true;
    };
    let edit = crate::configedit::ConfigEdit::RemoveHook {
        event: identity.event.clone(),
        command: identity.command.clone(),
    };
    let Ok(after) = edit.apply(&text) else {
        return true;
    };
    crate::scan::hooks::registrations_text(&after)
        .is_ok_and(|entries| !matches!(registered(&entries, identity), Registered::Absent))
}
