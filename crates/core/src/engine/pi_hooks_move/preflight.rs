//! What the move may do about each hook's copy under the reserved name,
//! answered once before anything is planned.
//!
//! Both halves of the pass read this: the item pass, which must not write
//! and register a replacement for an installation that is holding, and
//! the move itself, which must not retire anything that installation
//! still needs. Deciding it twice would let the two halves disagree —
//! and a disagreement here is what leaves one hook registered twice, or a
//! registration pointing at a script that is no longer there.
//!
//! The answer is built from three readings that live here with it: why an
//! installation holds whole, which of its copies under the reserved name
//! are kendex's to take, and what the registry an earlier kendex wrote
//! beside them will give up.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use super::super::desired::DesiredState;
use super::migrated::{
    Identity, Moved, Registered, legacy_registration, linked_registry, moved, moved_by_hand,
    newly_installed, registered,
};
use super::{Found, LEGACY_DIR, Sink, legacy_files, look, plain_file, unreadable_note};
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
    /// Whether any installation of this scope's has yet to leave the
    /// reserved name. The lock naming pi hooks is not that question: once
    /// every one of them is on record as gone, the name is the person's,
    /// and what they put under it is theirs however empty it is.
    claims_reserved_name: bool,
    /// Installations the person named for removal. Nothing is written or
    /// registered for one of these, so a hold that exists to keep this
    /// pass from writing has nothing to keep it from.
    removing: BTreeSet<String>,
    /// Whether an installation of kendex's is still where the move has to
    /// take it from. While that is true the legacy registry is a place a
    /// hook runs from, and so a place to observe.
    lingering: bool,
    /// Why the legacy registry cannot give up an entry, when it cannot.
    /// A script is never retired while its registration has to stay, or
    /// the registration would point at a path with nothing at it. The
    /// document is the obstacle here, so this holds every hook needing an
    /// edit in it.
    pub(super) registry_block: Option<String>,
    /// Why one hook's own entry in that registry is not kendex's to take,
    /// for each hook that has such a reason. Evidence about one hook and
    /// no other, so it holds one hook and no other.
    conflicts: BTreeMap<String, String>,
}

impl Preflight {
    /// Why this hook's installation holds whole, or `None` when it does
    /// not hold at all.
    pub(crate) fn hold(&self, name: &str) -> Option<&Hold> {
        self.held.get(name)
    }

    /// Whether the person asked for this installation to go by name.
    /// A hold is kendex declining to act on evidence it cannot read; a
    /// removal they typed is them saying what to do about it.
    fn asked_to_remove(&self, name: &str) -> bool {
        self.removing.contains(name)
    }

    pub(super) fn discards(&self, name: &str) -> bool {
        self.discard.contains(name)
    }

    pub(super) fn moved_on(&self, name: &str) -> bool {
        self.migrated.contains(name)
    }

    /// Why this hook's own registration under the reserved name is not
    /// kendex's to take, when it is not. Read by both halves of the pass:
    /// the hold it causes, and the line the move prints about it.
    pub(super) fn conflict(&self, name: &str) -> Option<&String> {
        self.conflicts.get(name)
    }

    /// Whether this installation is on record as having left the reserved
    /// name. Everything there is somebody else's from then on — the move
    /// does not look, and does not ask whose the bytes are.
    pub(super) fn left_for_good(&self, name: &str) -> bool {
        self.recorded.contains(name)
    }

    /// Whether kendex still claims the name pi reserved in this scope —
    /// asked of the directory itself, which is taken only for the sake of
    /// an installation that has not left it.
    pub(super) fn claims_reserved_name(&self) -> bool {
        self.claims_reserved_name
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
    let ours: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    // The one file every pi hook in this scope registers in, asked about
    // once and before anything reads it. Whether kendex may write it is a
    // property of the scope, not of any hook's history — so no entry set
    // decides whether the question is asked, and nothing reads through a
    // link on the way to finding out.
    let linked = linked_registry(&root);
    // Which installations are on record as having left the reserved name,
    // worked out once. Three questions read it — whether kendex claims
    // that name at all, which hooks the legacy registry can be in the way
    // of, and whether one hook's copies there are still anybody's
    // business — and a consumer deriving its own answer is how a finished
    // move came to be re-opened three separate times.
    let recorded: BTreeSet<String> = ours
        .iter()
        .filter(|entry| entry.left_pi_reserved_name)
        .map(|entry| entry.name.clone())
        .collect();
    // A hook on record as having left the reserved name has no
    // registration of kendex's there to identify: what wears its command
    // now is the person's, by the very fact the record states. It has no
    // business blocking anything, and neither has a document that is only
    // in anybody's way for its sake.
    let unfinished: Vec<&LockEntry> = ours
        .iter()
        .copied()
        .filter(|entry| !recorded.contains(&entry.name))
        .collect();
    let claims_reserved_name = !unfinished.is_empty();
    // What the person typed the name of. Every hold a typed removal
    // releases reads the one answer, so the reserved name's copies and
    // the registration at the new path cannot disagree about whether it
    // was asked for.
    let removing: BTreeSet<String> = ours
        .iter()
        .filter(|entry| options.named_for_removal(ItemKind::Hook, &entry.name))
        .map(|entry| entry.name.clone())
        .collect();
    // Nothing under either reserved name means nothing to work out about
    // what is there — the same answer everything below reaches, reached
    // without hashing a hook's bytes or reading a legacy path per hook on
    // every later plan. What still has to be asked, of every hook and
    // wherever the old layout has got to, is asked once at the end.
    if matches!(look(&dir), Found::Absent)
        && matches!(look(&pi::legacy_hook_registry(&root)), Found::Absent)
    {
        let mut this = Preflight {
            held: BTreeMap::new(),
            discard: BTreeSet::new(),
            migrated: BTreeSet::new(),
            recorded,
            claims_reserved_name,
            removing,
            lingering: false,
            registry_block: None,
            conflicts: BTreeMap::new(),
        };
        this.held = held(
            env,
            scope,
            &Places::new(&root, &dir, linked),
            &ours,
            &this,
            state,
        );
        return this;
    }
    let discard: BTreeSet<String> = ours
        .iter()
        .filter(|entry| discarding(options, &entry.name))
        .map(|entry| entry.name.clone())
        .collect();
    let migrated: BTreeSet<String> = ours
        .iter()
        .filter(|entry| moved(env, scope, &root, entry, state, linked))
        .map(|entry| entry.name.clone())
        .collect();
    // An installation the move has not finished is one whose registration
    // is still the legacy one — a hold is only ever that, since nothing is
    // written or registered at the new path behind one. Without a lock
    // entry to claim by, kendex has nothing under the reserved name at all.
    let lingering = ours.iter().any(|entry| !migrated.contains(&entry.name));
    let registry_block = (!unfinished.is_empty())
        .then(|| registry_block(&root, scope, &unfinished))
        .flatten();
    let conflicts: BTreeMap<String, String> = unfinished
        .iter()
        .filter_map(|entry| {
            registration_conflict(&root, scope, entry).map(|why| (entry.name.clone(), why))
        })
        .collect();
    let mut this = Preflight {
        held: BTreeMap::new(),
        discard,
        migrated,
        recorded,
        claims_reserved_name,
        removing,
        lingering,
        registry_block,
        conflicts,
    };
    this.held = held(
        env,
        scope,
        &Places::new(&root, &dir, linked),
        &ours,
        &this,
        state,
    );
    this
}

/// Whether this pass was told to be rid of what is here — by discarding
/// edits, globally or for this item, exactly as the item pass reads it,
/// or by naming this hook for removal. Naming it is the person saying
/// they mean to take these bytes: the hold exists so an automatic
/// cleanup cannot take what nobody asked it to, and a removal they typed
/// is the opposite of that. The trash keeps what it takes either way.
fn discarding(options: &crate::engine::PlanOptions, name: &str) -> bool {
    options.named_for_removal(ItemKind::Hook, name)
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

// Why a hook's installation holds whole, when it does.
//
// Asked of every hook this pass has anything to do with — which is not
// the same as every hook the lock names, since one being installed for
// the first time is written just the same — and answered in the order
// the person would have to fix things in: the scope's own files first,
// then this hook's entry at the new path, then what is under the name pi
// reserved.

/// The scope's own two files, and what this pass already knows about
/// them. Read once, before any hook is asked about: whether kendex may
/// write the registry they all share is a property of the file, and no
/// entry set decides whether that question gets asked.
struct Places<'a> {
    root: &'a std::path::Path,
    dir: &'a std::path::Path,
    linked: bool,
}

impl<'a> Places<'a> {
    fn new(root: &'a std::path::Path, dir: &'a std::path::Path, linked: bool) -> Self {
        Places { root, dir, linked }
    }

    /// The scope's own answer, before any hook's: nothing is written to a
    /// document kendex may not write, whatever else is true of the hook
    /// that would have been written there.
    fn scope_wide(&self) -> Option<Hold> {
        self.linked.then(|| {
            Hold::ByHand(format!(
                "{} is a link kendex did not create, so nothing is written through it — move it aside yourself, then refresh again",
                pi::hook_registry(self.root).display()
            ))
        })
    }
}

/// Why each of this scope's hooks is holding whole, for the ones that
/// are. One place, so the answer cannot depend on which way the pass
/// arrived at it.
///
/// Asked of every hook this pass has anything to do with, which is not
/// the same as every hook the lock names: one being installed for the
/// first time has no record to look up and is written just the same, so
/// a question about the file they all register in has to reach it too.
fn held(
    env: &Env,
    scope: &Scope,
    places: &Places,
    ours: &[&LockEntry],
    pre: &Preflight,
    state: &DesiredState,
) -> BTreeMap<String, Hold> {
    let named = ours.iter().map(|entry| (entry.name.clone(), Some(*entry)));
    let fresh = newly_installed(ours, state)
        .into_iter()
        .map(|name| (name, None));
    named
        .chain(fresh)
        .filter_map(|(name, entry)| {
            let hold = match entry {
                Some(entry) => places
                    .scope_wide()
                    .or_else(|| holding(env, scope, places, entry, pre, state)),
                // Nothing kendex has installed, so nothing of its own
                // history to ask about — only the scope's answer.
                None => places.scope_wide(),
            };
            hold.map(|hold| (name, hold))
        })
        .collect()
}

/// The hold a registration somebody moved by hand at the new path earns:
/// registering the fresh rendering beside it would leave the hook firing
/// twice, under two events. Asked wherever the question comes up — with
/// the old layout still on disk and with it long gone — from the one
/// place, so the two cannot answer differently.
///
/// `removing` is the person naming this hook to be rid of it. Nothing is
/// written for one of those, so there is nothing for their entry to be
/// doubled by, and the removal names the command wherever they moved it
/// to — the same reading a typed removal gets under the reserved name.
fn doubled(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
    removing: bool,
) -> Option<Hold> {
    let registry = pi::hook_registry(root);
    match moved_by_hand(env, scope, root, entry, state) {
        Moved::No => None,
        Moved::Elsewhere if removing => None,
        Moved::Elsewhere => Some(Hold::ByHand(format!(
            "its registration in {} sits under an event kendex did not put it under — registering it again would fire the hook twice; move it back or take it out",
            registry.display()
        ))),
        // Not even then: this is the shape kendex's own edits step over,
        // so the removal would take the script and the record and leave
        // their entry running a path with nothing at it. Taking that
        // entry out is theirs to do, here as under the reserved name.
        Moved::Unreachable => Some(Hold::ByHand(format!(
            "its registration in {} is written in a shape kendex cannot edit — a handler standing directly under its event, rather than inside a matcher group — so refreshing it would add a second entry beside it and the hook would fire twice; move it inside a matcher group, or take it out",
            registry.display()
        ))),
    }
}

/// Why one hook's installation holds whole, when it does — asked of every
/// hook, and answered in the order the person would have to fix things
/// in.
fn holding(
    env: &Env,
    scope: &Scope,
    places: &Places,
    entry: &LockEntry,
    pre: &Preflight,
    state: &DesiredState,
) -> Option<Hold> {
    let (root, dir) = (places.root, places.dir);
    // Asked of every hook, whatever the record says: the record settles
    // the reserved name and says nothing about the new path, where a
    // registration somebody moved would be doubled by the fresh one this
    // pass writes.
    if let Some(hold) = doubled(
        env,
        scope,
        root,
        entry,
        state,
        pre.asked_to_remove(&entry.name),
    ) {
        return Some(hold);
    }
    // Everything below is about the reserved name, which an installation
    // on record as having left it has left for good.
    if pre.moved_on(&entry.name) {
        return None;
    }
    // A directory kendex cannot look inside is one it cannot install
    // beside either: a replacement written there would run alongside
    // whatever is still under the reserved name, and nobody would have
    // been told there are now two.
    if !matches!(look(dir), Found::Absent | Found::Plain(_)) {
        return Some(Hold::ByHand(format!(
            "kendex cannot see inside {}, so nothing is written beside it — fix its permissions, or move it aside, then refresh again",
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
    // And this hook's own entry, which says nothing about anybody
    // else's: a sibling with a clean identity moves while this one waits.
    if let Some(why) = pre.conflict(&entry.name) {
        return Some(Hold::ByHand(why.clone()));
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

/// Bytes a discard covers: a plain file that is readable. Discarding is
/// permission to replace someone's edits, never permission to guess at a
/// file kendex cannot read at all — and never permission to take a
/// directory tree somebody put where the script was, which `hash_tree`
/// would hash as happily as a file.
fn discardable(path: &std::path::Path) -> bool {
    plain_file(path) && crate::hash::hash_tree(path).is_ok()
}

// Which of one hook's copies under the reserved name this pass may
// take, and why one of them is not its to take.
//
// Both gates a deletion passes ask the same question in the same words:
// `provenance` here, which the move goes through, and the preflight's
// `discardable`, which decides whether a hold is released. Neither is
// satisfied by anything but a plain file, so they cannot disagree about
// what a discard covers.

/// Why a file kendex's lock names is still not kendex's to move.
pub(super) enum Held {
    Edited,
    Unprovable,
    Unreadable(String),
    /// Something that is not a file at all sits where the script does.
    NotAFile,
}

/// Whether the bytes at `path` are the ones apply last wrote there — a
/// record from before `rendered_hash` existed proves nothing, exactly as
/// `removal::edit_holds` reads the same evidence. The hash that proved it
/// comes back out, so the deletion binds to the state ownership was read
/// from rather than to a later one.
fn provenance(entry: &LockEntry, path: &Path) -> std::result::Result<String, Held> {
    // Asked before the hash, because `hash_tree` answers for a directory
    // too: a tree somebody put where the script was would otherwise read
    // as an edit, and an edit is something a discard may take.
    if !plain_file(path) {
        return Err(Held::NotAFile);
    }
    let Some(rendered) = entry.rendered_hash.as_ref() else {
        return Err(Held::Unprovable);
    };
    match crate::hash::hash_tree(path) {
        Err(error) => Err(Held::Unreadable(error.to_string())),
        Ok(disk) if &disk == rendered => Ok(disk),
        Ok(_) => Err(Held::Edited),
    }
}

/// What of one hook's copies this pass may take, and whether any of them
/// is not its to take. That question comes before whether anything is
/// coming to replace them: a file that is not kendex's to move keeps its
/// registration too, or holding it back would leave it on disk with
/// nothing running it — the same installation held whole, said per file.
pub(super) fn claims(
    entry: &LockEntry,
    found: &[&Found],
    root: &Path,
    pre: &Preflight,
    sink: &mut Sink,
) -> (Vec<(PathBuf, String)>, bool) {
    let mut mine = Vec::new();
    let mut holds = false;
    for found in found {
        match found {
            Found::Linked(path) => {
                holds = true;
                sink.notes.push(format!(
                    "{} is a link kendex did not create, so it stays in the directory pi reserved — move it yourself and pi stops warning",
                    path.display()
                ));
            }
            Found::Plain(path) => match claim(entry, path, pre.discards(&entry.name)) {
                Ok(proven) => mine.push((path.clone(), proven)),
                Err(held) => {
                    holds = true;
                    sink.notes.push(held_note(&held, path, root));
                }
            },
            Found::Absent | Found::Unreadable(..) => {}
        }
    }
    (mine, holds)
}

/// What this pass may take of one file: bytes it can prove it wrote, or
/// bytes the person told it to be rid of — a discard settles a difference
/// it can see, never a file it cannot read at all. The hash that answered
/// comes back out, so the deletion binds to what was read.
pub(super) fn claim(
    entry: &LockEntry,
    path: &Path,
    discard: bool,
) -> std::result::Result<String, Held> {
    match provenance(entry, path) {
        Ok(proven) => Ok(proven),
        Err(Held::Edited | Held::Unprovable) if discard => {
            crate::hash::hash_tree(path).map_err(|error| Held::Unreadable(error.to_string()))
        }
        Err(held) => Err(held),
    }
}

/// Why one file stayed under the reserved name, said in its own cause —
/// a file kendex could not read is never reported as one somebody edited.
/// The destination is derived from the file's own name, so the twin a
/// disabled hook keeps its bytes under is not sent to the enabled one.
fn held_note(held: &Held, path: &Path, root: &Path) -> String {
    let new = match path.file_name() {
        Some(file) => pi::hook_dir(root).join(file),
        None => pi::hook_dir(root),
    };
    match held {
        Held::Unreadable(error) => unreadable_note(path, error),
        Held::NotAFile => format!(
            "{} is not a plain file, so it is nothing kendex wrote there and it stays in the directory pi reserved — move it aside yourself, then refresh again",
            path.display()
        ),
        Held::Unprovable => format!(
            "{} predates the record kendex keeps of what it writes, so it stays in the directory pi reserved — compare it with {} and delete the old file once you are happy",
            path.display(),
            new.display()
        ),
        Held::Edited => format!(
            "{} was edited on disk, so it stays in the directory pi reserved — copy your changes into {} and delete the old file",
            path.display(),
            new.display()
        ),
    }
}

// What the registry an earlier kendex wrote will and will not give up,
// and how wide the answer reaches.
//
// Two obstacles live here and they are not the same size. The document
// itself may be one kendex cannot edit at all, which is in the way of
// every hook needing an edit in it. Or one hook's own entry may be one
// kendex cannot pick out, which is in that hook's way and nobody else's
// — a sibling whose entry is exactly where its record says has nothing
// to do with it.

/// Why nothing in the legacy registry can be given up at all, when
/// nothing can: it is a link kendex did not make, it could not be read,
/// or it holds an entry kendex has to take out in a shape its editor
/// cannot rewrite. The obstacle is the document, so it blocks every hook
/// that needs an edit in it — which is what makes this the scope-wide
/// half. Absence is no obstacle, and neither is a document holding
/// nobody's entries but somebody else's.
fn registry_block(root: &std::path::Path, scope: &Scope, ours: &[&LockEntry]) -> Option<String> {
    let path = pi::legacy_hook_registry(root);
    let say = |why: String| {
        Some(format!(
            "{} {why}, so nothing under the name pi reserved is retired — a hook's registration and the script it names have to go together",
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
fn registration_conflict(
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
        // Found, and exactly what the record describes — which is not
        // the same as gone. What the removal will really leave behind is
        // read back before a byte of this hook's is planned for the
        // trash.
        Registered::Ours => survives_its_own_removal(&path, &legacy).then(|| {
            format!(
                "{} writes {command} in a shape kendex cannot take it out of — a handler standing directly under its event, rather than inside a matcher group — so this hook stays where it is; take that entry out yourself, and the script goes with it on the next refresh",
                path.display()
            )
        }),
        Registered::Elsewhere => say(format!(
            "no longer registers {command} where kendex recorded it"
        )),
        // Only the new path's reading answers this, and only about its
        // own document; the reserved name's entry is proven reachable the
        // same way a line above.
        Registered::Unreachable => None,
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
        matcher: identity.matcher.clone(),
        command: identity.command.clone(),
    };
    let Ok(after) = edit.apply(&text) else {
        return true;
    };
    // What has to be gone is the entry the record names. Something else
    // still running that command is not this registration — the question
    // of whether taking the script out from under it is fair is asked
    // above, and answered differently.
    crate::scan::hooks::registrations_text(&after).is_ok_and(|entries| {
        matches!(
            registered(&entries, identity),
            Registered::Ours | Registered::Ambiguous
        )
    })
}
