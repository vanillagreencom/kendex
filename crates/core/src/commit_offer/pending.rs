//! Which pending change one action made, and which was already there.
//!
//! A project can hold kendex's changes for days: a person leaves them as
//! diffs, does something else, and writes again. The offer after that
//! second write has to say what the second write did, not hand over
//! everything that has piled up under one label. Names alone cannot do it —
//! two writes reach the same render — so the answer is a reading of the
//! project taken **before** the action ([`Before::read`]) compared with the
//! reading taken after it.
//!
//! What is compared is the content, never the path list. A file both the
//! action and earlier work changed reads as [`Attribution::Both`], and a
//! commit of "only this action" that took it would carry the earlier work
//! too: git commits whole files. That case is named rather than papered
//! over — [`Pending::tangled`] says which file stops the separation, and
//! the surfaces make the reader choose.
//!
//! The same two readings decide what a commit carries beside the files
//! kendex owns whole. A file the action may write ([`Baseline::writes`])
//! that it changed from a state matching the last commit holds the action's
//! change alone, and rides every commit made after it
//! ([`Pending::carried`]); one that held a change then stays out and is
//! named ([`Pending::left_out`]); one the action left as it found it is the
//! person's. Without a reading before the action none is carried.
//! [`super::Scan::carry`] holds that answer, made once per scan, and every
//! count, list and commit on both surfaces reads it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::engine::GeneratedPaths;
use crate::engine::generated_paths::companions;
use crate::model::Scope;

use super::{Failed, Owned};

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
    /// Something stood there and what it was is not known: it could not be
    /// read, or it is a path the reading had no cause to expect a write at
    /// and recorded by name alone. Nothing may be claimed about it either:
    /// a comparison against this never reports "unchanged".
    Unreadable,
}

/// What a project's pending changes held before an action ran.
///
/// Every path git reported changed then has a row, and a path with no row
/// was clean: git reports every change in the checkout, so a row absent
/// from a reading that ran is a path that matched the last commit. The
/// files kendex owns whole and the ones the action may write carry a
/// reading of what stood there; every other path is recorded by name as
/// [`Held::Unreadable`], so a file an action first writes into after it —
/// a shared configuration file a newly installed hook registers in — reads
/// as holding an earlier change rather than as clean.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Baseline {
    pub held: BTreeMap<String, Held>,
    /// The files the action may write beside the ones kendex owns whole, as
    /// `git status` spells them. Only one of these, or a shared edit target
    /// the plan after the action names, is ever the action's.
    pub writes: BTreeSet<String>,
}

/// What was read of a project before an action: the one input, beside the
/// reading after it, that a commit of the action's work is judged by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Before {
    /// Read before the action.
    Read(Baseline),
    /// The read before the action would not run. No file the action wrote
    /// beside its renders is carried, and each changed one is named with
    /// the refusal rather than as the person's earlier change.
    Unread {
        failed: Failed,
        writes: BTreeSet<String>,
    },
    /// No read was taken: a person opened the offer, or the write ran where
    /// no reading could be handed on. Nothing is attributed to an action,
    /// and nothing beside the files kendex owns whole is kendex's.
    Untaken,
}

impl Before {
    /// Read `scope` before an action that renders `generated` and writes
    /// `writes` beside its renders: every path the action's plan touches
    /// where the caller holds the plan, and otherwise every file such an
    /// action can write into ([`GeneratedPaths::beside`]). A scope that is
    /// not a project, or a project that is not a checkout, has nothing to
    /// read.
    pub fn read(
        scope: &Scope,
        generated: &GeneratedPaths,
        writes: impl IntoIterator<Item = PathBuf>,
    ) -> Before {
        let Scope::Project { root } = scope else {
            return Before::Untaken;
        };
        if !root.join(".git").exists() {
            return Before::Untaken;
        }
        let writes: BTreeSet<String> = writes
            .into_iter()
            .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
            .collect();
        let sorted = match super::paths::sort(root, generated, Some(&writes)) {
            Ok(sorted) => sorted,
            Err(failed) => return Before::Unread { failed, writes },
        };
        let read = sorted
            .owned
            .iter()
            .chain(&sorted.beside)
            .map(|one| (one.path.clone(), held(root, &one.path)));
        let named = sorted
            .others
            .into_iter()
            .map(|path| (path, Held::Unreadable));
        Before::Read(Baseline {
            held: read.chain(named).collect(),
            writes,
        })
    }

    /// The files the action may write beside its renders, or `None` where
    /// nothing was read and none is the action's.
    pub(super) fn writes(&self) -> Option<&BTreeSet<String>> {
        match self {
            Before::Read(baseline) => Some(&baseline.writes),
            Before::Unread { writes, .. } => Some(writes),
            Before::Untaken => None,
        }
    }
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

/// One changed path kendex wrote, and what the action did to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingFile {
    pub path: String,
    /// The last commit holds nothing at this path: the change is that it
    /// now exists. True for a path git has never seen and for one staged
    /// as an addition, because a person staging kendex's new render does
    /// not make it older than the commit.
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
    /// Every changed path kendex owns whole, in the scan's order.
    pub files: Vec<PendingFile>,
    /// Every changed file the action wrote beside them, in the scan's
    /// order: [`super::Scan::beside`]. One it changed from a clean state
    /// ([`Attribution::Action`]) holds the action's change alone and rides
    /// the commit; one that held a change before stays out.
    pub beside: Vec<PendingFile>,
    /// The paths that say what kendex renders here — the inventory of
    /// what it owns and the record of what each render is — as the scan
    /// spells them. A commit that adds or takes away a render carries
    /// them too. The manifest is not among them: it is one of the files
    /// kendex writes into, carried only as [`Pending::beside`] allows.
    /// `crate::engine::generated_paths::companions` is the one place that
    /// decides this.
    declarations: BTreeSet<String>,
    /// The project's manifest, as the scan spells it.
    manifest: Option<String>,
}

impl Pending {
    /// Compare the reading after the action against the one taken before
    /// it. `beside` is every changed file the action may have written; one
    /// it left as it found it is the person's, and is not kept.
    pub(super) fn read(
        root: &Path,
        owned: &[Owned],
        beside: &[Owned],
        since: &Baseline,
    ) -> Pending {
        let read = |one: &Owned| {
            let now = held(root, &one.path);
            PendingFile {
                path: one.path.clone(),
                untracked: one.added,
                gone: now == Held::Gone,
                attribution: attribute(since.held.get(&one.path), &now),
            }
        };
        Pending {
            files: owned.iter().map(read).collect(),
            beside: beside
                .iter()
                .map(read)
                .filter(|file| file.attribution != Attribution::Older)
                .collect(),
            manifest: super::paths::declaration(root),
            declarations: companions(root)
                .iter()
                .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
                .collect(),
        }
    }

    /// Whether a commit of only the action's work carries anything here.
    /// An action whose only change is to a file it leaves out
    /// ([`Pending::left_out`]) has nothing of its own to commit, and an
    /// offer about it would put only earlier work in front of the reader.
    pub fn acted(&self) -> bool {
        !self.action_set().is_empty()
    }

    /// The files the action wrote beside the ones kendex owns whole that a
    /// commit of its work carries: each one it changed from a clean state,
    /// so committing the whole file commits nothing but the action's
    /// change. Every commit either surface makes after the action carries
    /// them.
    pub fn carried(&self) -> BTreeSet<String> {
        self.beside
            .iter()
            .filter(|file| file.attribution == Attribution::Action)
            .map(|file| file.path.clone())
            .collect()
    }

    /// The files the action wrote that no commit carries, because each
    /// held a change before the action that a commit of the whole file
    /// would carry too. The offer names each one, and the person commits
    /// it.
    pub fn left_out(&self) -> Vec<&str> {
        self.beside
            .iter()
            .filter(|file| file.attribution == Attribution::Both)
            .map(|file| file.path.as_str())
            .collect()
    }

    /// The paths a commit of only this action's work carries: the ones the
    /// action changed, the files it wrote into from a clean state, and the
    /// declarations a change to which paths exist cannot stand without.
    pub fn action_set(&self) -> BTreeSet<String> {
        let mut chosen: BTreeSet<String> = self
            .files
            .iter()
            .filter(|file| file.attribution != Attribution::Older)
            .map(|file| file.path.clone())
            .chain(self.carried())
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

    /// Every pending path kendex owns, and the files it wrote into from a
    /// clean state — what "all pending kendex changes" covers.
    pub fn every_path(&self) -> BTreeSet<String> {
        self.files
            .iter()
            .map(|file| file.path.clone())
            .chain(self.carried())
            .collect()
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

    /// The manifest where the action wrote it and no commit carries it: it
    /// held a change before the action, so it is one of
    /// [`Pending::left_out`]. Nothing where the commit carries it or the
    /// action left it as it found it.
    ///
    /// What a commit of renders without it costs is reproducibility and,
    /// in a clone, the renders: the lock rides the same commit and names
    /// them, both sweeps judge by the written lock, and a recorded install
    /// the committed manifest does not ask for is an orphan the next apply
    /// there removes. The declaration that asks for them is what this
    /// names.
    pub fn manifest_not_carried(&self) -> Option<&str> {
        let manifest = self.manifest.as_deref()?;
        self.left_out().into_iter().find(|path| *path == manifest)
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
