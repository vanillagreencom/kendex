//! Which pending change one action made, and which was already there.
//!
//! A project can hold kendex's changes for days: a person leaves them as
//! diffs, does something else, and writes again. The offer after that
//! second write has to say what the second write did, not hand over
//! everything that has piled up under one label. Names alone cannot do it —
//! two writes reach the same render — so the answer is a reading of the
//! project taken **before** the action ([`baseline`]) compared with the
//! reading taken after it.
//!
//! What is compared is the content, never the path list. A file both the
//! action and earlier work changed reads as [`Attribution::Both`], and a
//! commit of "only this action" that took it would carry the earlier work
//! too: git commits whole files. That case is named rather than papered
//! over — [`Pending::tangled`] says which file stops the separation, and
//! the surfaces make the reader choose.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::engine::GeneratedPaths;
use crate::engine::generated_paths::companions;
use crate::model::Scope;

use super::{Failed, Scan};

/// What stood at one path at the moment a reading was taken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Held {
    /// The thing standing there, named by a digest of what it is: a file's
    /// bytes, or a link's own target text. Two readings that name the same
    /// digest are the same content.
    At(String),
    /// Nothing stood there. A path kendex has yet to write, or one a sweep
    /// has taken away.
    Gone,
    /// Something stood there and could not be read. Nothing is known about
    /// it, so nothing may be claimed about it either: a comparison against
    /// this never reports "unchanged".
    Unreadable,
}

/// What a project's pending kendex changes held before an action ran.
///
/// The paths that already had a pending change are recorded, and so is the
/// project's manifest, whose reading is taken whether it was pending or
/// not: a manifest that was clean before and is clean now is the case the
/// offer must stay quiet about, and only a reading taken then tells it from
/// one this action wrote. A path absent from [`Baseline::held`] was clean,
/// which is the whole of what a later reading needs to know about an owned
/// path; an absent manifest row is a reading never taken, and nothing is
/// claimed about it either way.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Baseline {
    pub held: BTreeMap<String, Held>,
}

/// Read what this project's pending kendex changes hold now, to compare a
/// later reading against.
///
/// Taken before the action runs. A scope that is not a project holds
/// nothing, and a project where nothing kendex owns has changed holds its
/// manifest's reading alone: an empty set of pending paths rather than a
/// missing one, so every path the action then changes reads as clean
/// before it.
pub fn baseline(scope: &Scope, generated: &GeneratedPaths) -> Result<Baseline, Failed> {
    let Scope::Project { root } = scope else {
        return Ok(Baseline::default());
    };
    let mut readings: BTreeMap<String, Held> = super::paths::declaration(root)
        .map(|path| {
            let reading = held(root, &path);
            (path, reading)
        })
        .into_iter()
        .collect();
    if let Some(scan) = super::scan(scope, generated)? {
        readings.extend(
            scan.owned
                .iter()
                .map(|owned| (owned.path.clone(), held(&scan.root, &owned.path))),
        );
    }
    Ok(Baseline { held: readings })
}

/// What stands at one path now.
///
/// Read as it sits, never through a link: kendex writes links itself, and a
/// link whose target moves has not changed. A read the machine refuses is
/// not absence — [`Held::Unreadable`] says so, and every comparison against
/// it is inconclusive rather than false.
fn held(root: &Path, path: &str) -> Held {
    let whole = root.join(path);
    match std::fs::symlink_metadata(&whole) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Held::Gone,
        Err(_) => Held::Unreadable,
        Ok(_) => match crate::hash::hash_tree_as_is(&whole) {
            Ok(digest) => Held::At(digest),
            Err(_) => Held::Unreadable,
        },
    }
}

/// What one action did to a path that has a pending change now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attribution {
    /// This path was clean before the action and carries a change now. The
    /// change is the action's, whole.
    Action,
    /// This path already carried a pending change before the action, and
    /// the action changed it again. git commits whole files, so a commit of
    /// this path carries both.
    Both,
    /// The action left this path exactly as it found it. It was pending
    /// before and is pending still.
    Older,
}

/// One changed path kendex owns, and what the action did to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingFile {
    pub path: String,
    /// git reports this path as untracked: the change is that it now
    /// exists.
    pub untracked: bool,
    /// Nothing stands at this path now: the change is that it is gone.
    pub gone: bool,
    pub attribution: Attribution,
}

/// Why the action's work cannot be committed on its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tangle {
    pub path: String,
    pub reason: Tangled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tangled {
    /// The action changed this file and it already carried a change before
    /// the action. Committing the file commits both.
    CarriesEarlier,
    /// The action adds or takes away a path kendex renders, and the file
    /// that records what kendex renders here carries a change of its own
    /// that the action did not make. Leaving it out commits a set that no
    /// longer matches the tree; taking it in commits that earlier change.
    DeclaresWhatChanged,
}

/// A project's pending kendex changes, each with what the action did to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pending {
    /// Every changed path kendex owns, in the scan's order.
    pub files: Vec<PendingFile>,
    /// The path that records what kendex renders here — the inventory — as
    /// the scan spells it. A commit that adds or takes away a render carries
    /// it too. The manifest is not among them: kendex edits keys in it and
    /// owns none of its bytes, so it is neither committed nor restored
    /// whole. `crate::engine::generated_paths::companions` is the one place
    /// that decides this.
    declarations: BTreeSet<String>,
    /// The project's manifest, where this action wrote it and what it
    /// wrote is not committed. The commit leaves that change behind, so
    /// the offer says so and the person commits the file themselves.
    manifest: Option<String>,
}

/// Compare a reading of the project against the one taken before the
/// action.
pub fn pending(scan: &Scan, since: &Baseline) -> Pending {
    let files = scan
        .owned
        .iter()
        .map(|owned| {
            let now = held(&scan.root, &owned.path);
            PendingFile {
                path: owned.path.clone(),
                untracked: owned.untracked,
                gone: now == Held::Gone,
                attribution: attribute(since.held.get(&owned.path), &now),
            }
        })
        .collect();
    Pending {
        files,
        manifest: wrote_the_manifest(scan, since),
        declarations: companions(&scan.root)
            .iter()
            .filter_map(|path| {
                path.strip_prefix(&scan.root)
                    .ok()
                    .map(crate::paths::slashed)
            })
            .collect(),
    }
}

/// What the action did to one path, from the two readings of it.
///
/// An unreadable side on either reading is not a match. Reporting one as
/// unchanged would put an older change into a commit labelled as the
/// action's, which is the one thing this comparison exists to stop.
fn attribute(before: Option<&Held>, now: &Held) -> Attribution {
    match before {
        None => Attribution::Action,
        Some(Held::Unreadable) => Attribution::Both,
        Some(_) if *now == Held::Unreadable => Attribution::Both,
        Some(before) if before == now => Attribution::Older,
        Some(_) => Attribution::Both,
    }
}

/// The project's manifest where this action wrote it and the write is not
/// committed, read the way every other path is: the content before the
/// action against the content now.
///
/// Three answers are silence, each for its own reason. git reports the file
/// unchanged, so the declaration these renders need is already committed
/// and nothing is left behind. No reading was taken before the action, so
/// what changed the file is not known and nothing may be claimed about it.
/// Or the action left the file exactly as it found it, and the pending
/// change in it is somebody else's to commit.
fn wrote_the_manifest(scan: &Scan, since: &Baseline) -> Option<String> {
    let path = scan.manifest.as_ref()?;
    let before = since.held.get(path.as_str())?;
    match attribute(Some(before), &held(&scan.root, path)) {
        Attribution::Older => None,
        Attribution::Action | Attribution::Both => Some(path.clone()),
    }
}

impl Pending {
    /// Whether the action changed anything kendex owns here. An action that
    /// changed nothing in this project has nothing to offer about it,
    /// whatever else is pending.
    pub fn acted(&self) -> bool {
        self.files
            .iter()
            .any(|file| file.attribution != Attribution::Older)
    }

    /// The paths a commit of only this action's work carries: the ones the
    /// action changed, and the declarations a change to which paths exist
    /// cannot stand without.
    pub fn action_set(&self) -> BTreeSet<String> {
        let mut chosen: BTreeSet<String> = self
            .files
            .iter()
            .filter(|file| file.attribution != Attribution::Older)
            .map(|file| file.path.clone())
            .collect();
        if self.changes_which_paths_exist() {
            chosen.extend(
                self.files
                    .iter()
                    .filter(|file| self.declarations.contains(&file.path))
                    .map(|file| file.path.clone()),
            );
        }
        chosen
    }

    /// Every pending path kendex owns — what "all pending kendex changes"
    /// covers.
    pub fn every_path(&self) -> BTreeSet<String> {
        self.files.iter().map(|file| file.path.clone()).collect()
    }

    /// Whether committing only the action's work and committing everything
    /// pending would make the same commit. Where they would, there is no
    /// choice to put to a reader.
    pub fn same(&self) -> bool {
        self.action_set() == self.every_path()
    }

    /// What stops the action's work from being committed on its own. Empty
    /// where it can be.
    pub fn tangled(&self) -> Vec<Tangle> {
        let mut tangled: Vec<Tangle> = self
            .files
            .iter()
            .filter(|file| file.attribution == Attribution::Both)
            .map(|file| Tangle {
                path: file.path.clone(),
                reason: Tangled::CarriesEarlier,
            })
            .collect();
        if self.changes_which_paths_exist() {
            tangled.extend(
                self.files
                    .iter()
                    .filter(|file| {
                        self.declarations.contains(&file.path)
                            && file.attribution == Attribution::Older
                    })
                    .map(|file| Tangle {
                        path: file.path.clone(),
                        reason: Tangled::DeclaresWhatChanged,
                    }),
            );
        }
        tangled.sort_by(|a, b| a.path.cmp(&b.path));
        tangled.dedup_by(|a, b| a.path == b.path);
        tangled
    }

    /// The manifest this action wrote that the commit does not carry, and
    /// nothing where every declaration these renders need is committed
    /// already.
    ///
    /// kendex folds keys into that file and owns none of its bytes, so no
    /// commit kendex makes can include it. A commit of renders whose
    /// declaration stays in the working tree leaves a checkout that asks
    /// for something else: the trees are there and work without kendex,
    /// and a later apply in that checkout sweeps these renders or leaves
    /// them unmanaged.
    pub fn manifest_not_carried(&self) -> Option<&str> {
        self.manifest.as_deref()
    }

    /// Whether the action's own work adds or takes away a path kendex
    /// renders, rather than only rewriting one that stays. Only then does
    /// the declaration of what kendex renders here have to travel with it.
    fn changes_which_paths_exist(&self) -> bool {
        self.files.iter().any(|file| {
            file.attribution != Attribution::Older
                && !self.declarations.contains(&file.path)
                && (file.untracked || file.gone)
        })
    }
}

/// Which of a project's pending kendex changes a step is about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selection {
    /// Every pending change kendex owns in this project.
    All,
    /// Exactly these paths, as the scan spells them. A path the fresh
    /// reading no longer covers is dropped and reported, never guessed at.
    Only(BTreeSet<String>),
}

impl Selection {
    /// Narrow a freshly read set to what this selection asks for, and say
    /// which of the named paths the reading no longer covers.
    pub fn over<'a>(&self, owned: &'a [super::Owned]) -> (Vec<&'a super::Owned>, Vec<String>) {
        match self {
            Selection::All => (owned.iter().collect(), Vec::new()),
            Selection::Only(paths) => {
                let taken: Vec<&super::Owned> = owned
                    .iter()
                    .filter(|owned| paths.contains(&owned.path))
                    .collect();
                let covered: BTreeSet<&str> =
                    owned.iter().map(|owned| owned.path.as_str()).collect();
                let dropped = paths
                    .iter()
                    .filter(|path| !covered.contains(path.as_str()))
                    .cloned()
                    .collect();
                (taken, dropped)
            }
        }
    }
}
