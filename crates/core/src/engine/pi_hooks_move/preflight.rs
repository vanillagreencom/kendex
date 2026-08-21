//! What the move may do about each hook's copy under the reserved name,
//! answered once before anything is planned.
//!
//! Both halves of the pass read this: the item pass, which must not write
//! and register a replacement for an installation that is holding, and
//! the move itself, which must not retire anything that installation
//! still needs. Deciding it twice would let the two halves disagree —
//! and a disagreement here is what leaves one hook registered twice, or a
//! registration pointing at a script that is no longer there.

use std::collections::{BTreeMap, BTreeSet};

use super::super::desired::DesiredState;
use super::claims::Held;
use super::migrated::{moved, moved_by_hand};
use super::{
    Found, LEGACY_DIR, Registered, legacy_files, legacy_registration, look, plain_file, provenance,
    registered,
};
use crate::env::Env;
use crate::harness::pi;
use crate::lock::{Lock, LockEntry};
use crate::model::{HarnessId, ItemKind, Scope};

/// Why one installation holds whole, in the terms the person needs: what
/// they can do about it differs, and a remedy that cannot work is worse
/// than none. Discarding edits settles an edit and settles nothing else.
pub(crate) enum Hold {
    /// Bytes that are not the ones apply wrote, or a copy from before the
    /// record that says what it wrote. A discard releases it.
    Edits,
    /// Something no discard can change — a link, a file that cannot be
    /// read, a registration somebody moved. Carries the line the conflict
    /// row shows.
    ByHand(String),
}

impl Hold {
    /// The conflict row this hold produces, wherever it is reported: one
    /// rendering for every path that reports one, so a cause cannot come
    /// out named on the declared path and flattened on the orphan path.
    /// `edits` is the line for the one cause a discard settles, which is
    /// the only half that reads differently between them.
    pub(crate) fn row(&self, edits: &str) -> (String, Option<crate::engine::DriftCause>) {
        match self {
            Hold::Edits => (edits.to_owned(), Some(crate::engine::DriftCause::LocalEdit)),
            Hold::ByHand(why) => (why.clone(), None),
        }
    }
}

pub(crate) struct Preflight {
    /// Installations that hold whole: nothing is written or registered
    /// for them this pass, and nothing of theirs is retired. Each with
    /// the cause, because the conflict row has to name it.
    held: BTreeMap<String, Hold>,
    /// Bytes the person asked to be rid of, so bytes that would
    /// otherwise hold are exactly the ones they told kendex to discard.
    discard: BTreeSet<String>,
    /// Hooks whose current rendering already sits at the new path. Their
    /// installation lives there now, so a same-named file left under the
    /// reserved name is nobody's copy of it.
    migrated: BTreeSet<String>,
    /// Hooks whose record says the move finished. Stronger than
    /// `migrated`, which a reading of the disk can also answer: this is
    /// the fact a pass wrote down, so nothing under the reserved name is
    /// theirs any more and no question about bytes is asked about it.
    recorded: BTreeSet<String>,
    /// Whether an installation of kendex's is still where the move has to
    /// take it from. While that is true the legacy registry is a place a
    /// hook runs from, and so a place to observe.
    lingering: bool,
    /// Why the legacy registry cannot give up an entry, when it cannot.
    /// A script is never retired while its registration has to stay, or
    /// the registration would point at a path with nothing at it.
    pub(super) registry_block: Option<String>,
}

impl Preflight {
    /// Why this hook's installation holds whole, or `None` when it does
    /// not hold at all.
    pub(crate) fn hold(&self, name: &str) -> Option<&Hold> {
        self.held.get(name)
    }

    pub(super) fn discards(&self, name: &str) -> bool {
        self.discard.contains(name)
    }

    pub(super) fn moved_on(&self, name: &str) -> bool {
        self.migrated.contains(name)
    }

    /// Whether this installation is on record as having left the reserved
    /// name. Everything there is somebody else's from then on — the move
    /// does not look, and does not ask whose the bytes are.
    pub(super) fn left_for_good(&self, name: &str) -> bool {
        self.recorded.contains(name)
    }

    /// Whether the registry beside the reserved directory still runs
    /// something of kendex's — the question the observation surface asks,
    /// so a held hook is listed while it is the copy that fires, and the
    /// legacy path stops being read once nothing of kendex's is there.
    pub(crate) fn legacy_registry_lives(&self) -> bool {
        self.lingering
    }
}

pub(crate) fn preflight(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    options: &crate::engine::PlanOptions,
    state: &DesiredState,
) -> Preflight {
    let root = pi::scope_root(env, scope);
    let dir = root.join(LEGACY_DIR);
    // Nothing under either reserved name means nothing to hold and
    // nothing to ask about — the same answer everything below reaches,
    // reached without reading a registry per hook on every later plan.
    if matches!(look(&dir), Found::Absent)
        && matches!(look(&pi::legacy_hook_registry(&root)), Found::Absent)
    {
        return Preflight {
            held: BTreeMap::new(),
            discard: BTreeSet::new(),
            migrated: BTreeSet::new(),
            recorded: BTreeSet::new(),
            lingering: false,
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
        .filter(|entry| moved(env, scope, &root, entry, state))
        .map(|entry| entry.name.clone())
        .collect();
    let recorded: BTreeSet<String> = ours
        .iter()
        .filter(|entry| entry.left_pi_reserved_name)
        .map(|entry| entry.name.clone())
        .collect();
    // An installation the move has not finished is one whose registration
    // is still the legacy one — a hold is only ever that, since nothing is
    // written or registered at the new path behind one. Without a lock
    // entry to claim by, kendex has nothing under the reserved name at all.
    let lingering = ours.iter().any(|entry| !migrated.contains(&entry.name));
    let registry_block = registry_block(&root, scope, &ours);
    let mut this = Preflight {
        held: BTreeMap::new(),
        discard,
        migrated,
        recorded,
        lingering,
        registry_block,
    };
    this.held = ours
        .iter()
        .filter(|entry| !this.moved_on(&entry.name))
        .filter_map(|entry| {
            holding(env, scope, &root, &dir, entry, &this, state)
                .map(|hold| (entry.name.clone(), hold))
        })
        .collect();
    this
}

/// Why one hook's installation holds whole, when it does — asked of every
/// hook the move has not finished with, and answered in the order the
/// person would have to fix things in.
fn holding(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    dir: &std::path::Path,
    entry: &LockEntry,
    pre: &Preflight,
    state: &DesiredState,
) -> Option<Hold> {
    // A directory kendex cannot look inside is one it cannot install
    // beside either: a replacement written there would run alongside
    // whatever is still under the reserved name, and nobody would have
    // been told there are now two.
    if !matches!(look(dir), Found::Absent | Found::Plain(_)) {
        return Some(Hold::ByHand(format!(
            "kendex cannot see inside {}, so nothing was written beside it — fix its permissions, or move it aside, then refresh again",
            dir.display()
        )));
    }
    // A registry that cannot give up an entry holds every hook it might
    // be holding one for — including a command-bodied one, which has no
    // file under the reserved name at all and exists there only as that
    // registration.
    if pre.registry_block.is_some() {
        return Some(Hold::ByHand(format!(
            "its registration under the name pi reserved is not kendex's to change — {} says what is in the way",
            pi::legacy_hook_registry(root).display()
        )));
    }
    // Registering the fresh rendering beside a registration somebody
    // moved by hand would leave the hook firing twice, under two events.
    if moved_by_hand(env, scope, root, entry, state) {
        return Some(Hold::ByHand(format!(
            "its registration in {} sits under an event kendex did not put it under — registering it again would fire the hook twice; move it back or take it out",
            pi::hook_registry(root).display()
        )));
    }
    let files = legacy_files(dir, &entry.name);
    if files.is_empty() {
        return None;
    }
    let discard = pre.discards(&entry.name);
    files.iter().find_map(|found| match found {
        Found::Plain(path) => match provenance(entry, path) {
            Ok(_) => None,
            // What the person asked to be rid of is not held back at all.
            Err(_) if discard && discardable(path) => None,
            Err(Held::Edited | Held::Unprovable) => Some(Hold::Edits),
            Err(Held::Unreadable(_)) => Some(Hold::ByHand(format!(
                "kendex could not read {}, so that copy is still what runs — fix its permissions, then refresh again",
                path.display()
            ))),
            Err(Held::NotAFile) => Some(Hold::ByHand(format!(
                "{} is not a plain file, so it is nothing kendex can replace — move it aside yourself, then refresh again",
                path.display()
            ))),
        },
        Found::Linked(path) => Some(Hold::ByHand(format!(
            "{} is a link kendex did not create, so that copy is still what runs — move it yourself, then refresh again",
            path.display()
        ))),
        Found::Unreadable(path, error) => Some(Hold::ByHand(format!(
            "kendex could not read {path} ({error}), so that copy is still what runs — fix its permissions, then refresh again",
            path = path.display()
        ))),
        Found::Absent => None,
    })
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
/// file kendex cannot read at all — and never permission to take a
/// directory tree somebody put where the script was, which `hash_tree`
/// would hash as happily as a file.
fn discardable(path: &std::path::Path) -> bool {
    plain_file(path) && crate::hash::hash_tree(path).is_ok()
}

/// Why the legacy registry cannot give up kendex's own entry, when it
/// cannot. Absent is no obstacle, and neither is a document holding
/// nobody's entries but somebody else's — there is nothing there to take
/// out, so nothing is blocked by it.
fn registry_block(root: &std::path::Path, scope: &Scope, ours: &[&LockEntry]) -> Option<String> {
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
    let entries = match crate::scan::hooks::read(&path) {
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
        let legacy = legacy_registration(entry, scope, root);
        let command = &legacy.command;
        match registered(&entries, &legacy) {
            Registered::Ours => holds_ours = true,
            Registered::Absent => {}
            Registered::Elsewhere => {
                return say(format!(
                    "no longer registers {command} where kendex recorded it, so what is there now is not kendex's to take"
                ));
            }
            Registered::Ambiguous => {
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
