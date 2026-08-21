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
        .filter(|entry| lives_at_the_new_path(&root, entry))
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

/// Whether this hook's installation has already finished moving: the
/// bytes apply last wrote are at the new path. Once that is true, a
/// same-named file under the reserved name is a stranger's, and a
/// stranger must never freeze a working installation.
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
    // Identity has to be exact before anything is removed: the edit takes
    // out every handler carrying the command, so a second entry wearing
    // it — a matcher somebody added by hand — cannot be told from
    // kendex's own. Ambiguous means held, not guessed at.
    let mut holds_ours = false;
    for entry in ours {
        let (_, command) = super::legacy_registration(entry, scope, root);
        let carrying = registered
            .iter()
            .filter(|entry| entry.description.as_deref() == Some(command.as_str()))
            .count();
        if carrying > 1 {
            return say(format!(
                "registers {command} more than once, so kendex cannot tell its own entry from the others"
            ));
        }
        holds_ours |= carrying == 1;
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
