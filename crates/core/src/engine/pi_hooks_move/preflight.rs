//! What the move may do about each hook's copy under the reserved name,
//! answered once before anything is planned.
//!
//! Both halves of the pass read this: the item pass, which must not write
//! and register a replacement for an installation that is holding, and
//! the move itself, which must not retire anything that installation
//! still needs. Deciding it twice would let the two halves disagree —
//! and a disagreement here is what leaves one hook registered twice, or a
//! registration pointing at a script that is no longer there.

use std::collections::BTreeSet;

use super::{Found, LEGACY_DIR, LEGACY_REGISTRY, legacy_files, look, provenance};
use crate::env::Env;
use crate::harness::pi;
use crate::lock::{Lock, LockEntry};
use crate::model::{HarnessId, ItemKind, Scope};

pub(crate) struct Preflight {
    /// Installations that hold whole: nothing is written or registered
    /// for them this pass, and nothing of theirs is retired.
    held: BTreeSet<String>,
    /// Bytes the person asked to be rid of, so bytes that would
    /// otherwise hold are exactly the ones they told kendex to discard.
    discard: BTreeSet<String>,
    /// Hooks whose current rendering already sits at the new path. Their
    /// installation lives there now, so a same-named file left under the
    /// reserved name is nobody's copy of it.
    migrated: BTreeSet<String>,
    /// Why the legacy registry cannot give up an entry, when it cannot.
    /// A script is never retired while its registration has to stay, or
    /// the registration would point at a path with nothing at it.
    pub(super) registry_block: Option<String>,
}

impl Preflight {
    pub(crate) fn holds(&self, name: &str) -> bool {
        self.held.contains(name)
    }

    pub(super) fn discards(&self, name: &str) -> bool {
        self.discard.contains(name)
    }

    pub(super) fn moved_on(&self, name: &str) -> bool {
        self.migrated.contains(name)
    }
}

pub(crate) fn preflight(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    options: &crate::engine::PlanOptions,
) -> Preflight {
    let root = pi::scope_root(env, scope);
    let dir = root.join(LEGACY_DIR);
    // Nothing under either reserved name means nothing to hold and
    // nothing to ask about — the same answer everything below reaches,
    // reached without reading a registry per hook on every later plan.
    if matches!(look(&dir), Found::Absent)
        && matches!(look(&root.join(LEGACY_REGISTRY)), Found::Absent)
    {
        return Preflight {
            held: BTreeSet::new(),
            discard: BTreeSet::new(),
            migrated: BTreeSet::new(),
            registry_block: None,
        };
    }
    let ours: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    let discard: BTreeSet<String> = ours
        .iter()
        .filter(|entry| discarding(options, &entry.name))
        .map(|entry| entry.name.clone())
        .collect();
    let migrated: BTreeSet<String> = ours
        .iter()
        .filter(|entry| moved(env, scope, &root, entry))
        .map(|entry| entry.name.clone())
        .collect();
    let mut this = Preflight {
        held: BTreeSet::new(),
        discard,
        migrated,
        registry_block: registry_block(&root, scope, &ours),
    };
    // A directory kendex cannot look inside is one it cannot install
    // beside either: a replacement written there would run alongside
    // whatever is still under the reserved name, and nobody would have
    // been told there are now two.
    let opaque = !matches!(look(&dir), Found::Absent | Found::Plain(_));
    this.held = ours
        .iter()
        .filter(|entry| !this.moved_on(&entry.name))
        .filter(|entry| {
            if opaque {
                return true;
            }
            // A registry that cannot give up an entry holds every hook
            // it might be holding one for — including a command-bodied
            // one, which has no file under the reserved name at all and
            // exists there only as that registration.
            if this.registry_block.is_some() {
                return true;
            }
            let files = legacy_files(&dir, &entry.name);
            if files.is_empty() {
                return false;
            }
            files.iter().any(|found| match found {
                Found::Plain(path) => provenance(entry, path)
                    .is_err_and(|_| !this.discards(&entry.name) || !discardable(path)),
                Found::Linked(_) | Found::Unreadable(..) => true,
                Found::Absent => false,
            })
        })
        .map(|entry| entry.name.clone())
        .collect();
    this
}

/// Whether this pass was told to be rid of what is here — by discarding
/// edits, globally or for this item, exactly as the item pass reads it,
/// or by naming this hook for removal. Naming it is the person saying
/// they mean to take these bytes: the hold exists so an automatic
/// cleanup cannot take what nobody asked it to, and a removal they typed
/// is the opposite of that. The trash keeps what it takes either way.
fn discarding(options: &crate::engine::PlanOptions, name: &str) -> bool {
    let named_for_removal = match &options.removal_filter_typed {
        Some(names) => names
            .iter()
            .any(|(kind, n)| *kind == ItemKind::Hook && n == name),
        None => options
            .removal_filter
            .as_ref()
            .is_some_and(|names| names.iter().any(|n| n == name)),
    };
    named_for_removal
        || options.overwrite_edited
        || options
            .overwrite_edited_names
            .as_ref()
            .is_some_and(|names| {
                names
                    .iter()
                    .any(|(kind, n)| *kind == ItemKind::Hook && n == name)
            })
}

/// Bytes a discard covers: a plain file that is readable. Discarding is
/// permission to replace someone's edits, never permission to guess at a
/// file kendex cannot read at all.
fn discardable(path: &std::path::Path) -> bool {
    crate::hash::hash_tree(path).is_ok()
}

/// Whether this hook's installation has already finished moving. Two
/// things have to be true, and bytes are only the first: the copy apply
/// last wrote is at the new path, AND the new registration is the one
/// that runs it — either the new registry names it, or nothing of
/// kendex's is registered under the reserved name any more. A clean copy
/// at the new path while the old registration still runs is a migration
/// half done, not one finished.
///
/// Once both hold, a same-named file under the reserved name is a
/// stranger's, and a stranger must never freeze a working installation.
fn moved(env: &Env, scope: &Scope, root: &std::path::Path, entry: &LockEntry) -> bool {
    lives_at_the_new_path(root, entry) && new_registration_runs_it(env, scope, root, entry)
}

fn lives_at_the_new_path(root: &std::path::Path, entry: &LockEntry) -> bool {
    let Some(rendered) = entry.rendered_hash.as_ref() else {
        return false;
    };
    let path = pi::hook_path(root, &entry.name);
    [super::disabled_name(&path), path].iter().any(|path| {
        matches!(look(path), Found::Plain(_))
            && crate::hash::hash_tree(path).is_ok_and(|disk| &disk == rendered)
    })
}

/// Whether execution has moved with the bytes: the new registry carries
/// this hook's registration, or the legacy one carries nothing of its.
fn new_registration_runs_it(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
) -> bool {
    let (event, command) = super::legacy_registration(entry, scope, root);
    let live = |path: &std::path::Path, command: &str| {
        crate::scan::hooks::read(path).is_ok_and(|entries| {
            matches!(
                super::registered(&entries, event.as_deref(), command),
                super::Registered::Ours
            )
        })
    };
    let new = match crate::engine::targets::hook_target(env, scope, HarnessId::Pi, &entry.name) {
        Some(crate::engine::targets::HookTarget::Script { command, .. }) => command,
        _ => command.clone(),
    };
    let recorded = entry
        .registration
        .as_ref()
        .map_or(new, |recorded| recorded.command.clone());
    live(&pi::hook_registry(root), &recorded)
        || !matches!(
            look(&root.join(LEGACY_REGISTRY)),
            Found::Plain(_) | Found::Linked(_)
        )
        || crate::scan::hooks::read(&root.join(LEGACY_REGISTRY)).is_ok_and(|entries| {
            matches!(
                super::registered(&entries, event.as_deref(), &command),
                super::Registered::Absent
            )
        })
}

/// Why the legacy registry cannot give up kendex's own entry, when it
/// cannot. Absent is no obstacle, and neither is a document holding
/// nobody's entries but somebody else's — there is nothing there to take
/// out, so nothing is blocked by it.
fn registry_block(root: &std::path::Path, scope: &Scope, ours: &[&LockEntry]) -> Option<String> {
    let path = root.join(LEGACY_REGISTRY);
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
    let registered = match crate::scan::hooks::read(&path) {
        Ok(entries) => entries,
        Err(message) => return say(format!("could not be read ({message})")),
    };
    // Identity has to resolve to exactly one registration before anything
    // is removed. The edit takes out every handler answering to it, so
    // one kendex cannot tell from another — a second matcher wearing the
    // command, or the command moved to an event the record does not name
    // — is held, not guessed at.
    let mut holds_ours = false;
    for entry in ours {
        let (event, command) = super::legacy_registration(entry, scope, root);
        match super::registered(&registered, event.as_deref(), &command) {
            super::Registered::Ours => holds_ours = true,
            super::Registered::Absent => {}
            super::Registered::Elsewhere => {
                return say(format!(
                    "no longer registers {command} where kendex recorded it, so what is there now is not kendex's to take"
                ));
            }
            super::Registered::Ambiguous => {
                return say(format!(
                    "registers {command} more than once, so kendex cannot tell its own entry from the others"
                ));
            }
        }
    }
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
