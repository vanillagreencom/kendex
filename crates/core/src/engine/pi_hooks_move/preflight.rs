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
use super::holding::{Places, held};
use super::migrated::{linked_registry, moved};
use super::registry::{registration_conflict, registry_block};
use super::{Found, LEGACY_DIR, look};
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
