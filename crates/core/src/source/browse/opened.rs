//! One catalog opened for reading, and what it knows about this scope.
//!
//! Split out of `browse.rs`. Opening a catalog is one question — which
//! bytes, at which revision, joined against whose records — and the pages
//! above read the answer rather than each assembling it.

use std::borrow::Cow;

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

use super::super::{ResolvedSource, SourceConfig, find_item, require_ready, source_config_for};
use super::catalog::browsable;
use super::{Catalog, InstallState};

/// One catalog opened for reading, with the browsed scope's own records.
pub(crate) struct Browsed {
    records: Records,
    pub(crate) source: ResolvedSource,
    pub(crate) sealed: SealedSource,
    pub(crate) config: SourceConfig,
    /// The subscription's name when there is one — see [`Browsed::owned_here`].
    subscription: Option<String>,
}

/// One scope's records, as every installed-state join reads them: what is
/// installed there, and what the person kept removed there.
///
/// Which scope's is the question this type exists to keep answerable. The
/// browsed catalog's own scope answers unless a page redirects the install
/// into a project, and then that project's records do —
/// [`crate::engine::ops::add_seeded`] mutates the scope it is handed, so a
/// surface reading anything else offers a button the engine refuses on a
/// record the reader was never shown.
///
/// `Clone` is [`Cow`]'s bound in [`landing`].
#[derive(Clone)]
pub(crate) struct Records {
    pub(crate) manifest: Manifest,
    /// `None` where this scope's lock could not be read — a damaged record
    /// or one an older kendex wrote. What a source offers is a fact about
    /// the source, so listing goes ahead without it; every answer the lock
    /// alone can give is [`InstallState::Unknown`] instead of a guess.
    lock: Option<Lock>,
}

/// Which scope's records one read answers for: the destination's where a
/// page redirects the install into one, the browsed catalog's own where it
/// does not. Resolved here rather than at each read, so a destination-aware
/// read added later inherits the rule instead of restating it.
pub(crate) fn landing<'a>(
    env: &Env,
    browsed: &'a Browsed,
    destination: Option<&Scope>,
) -> Result<Cow<'a, Records>> {
    Ok(match destination {
        Some(scope) => Cow::Owned(records(env, scope)?),
        None => Cow::Borrowed(browsed.records()),
    })
}

/// The scope records the installed-state join reads. The manifest decides
/// which source resolves at all, so it stays a hard error; the lock only
/// answers what is already installed, and an unreadable one is carried as
/// its absence so one place's broken record never hides what every
/// subscribed catalog offers. The Problems page is where that record is
/// explained and fixed.
fn records(env: &Env, scope: &Scope) -> Result<Records> {
    let manifest = crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))?
        .unwrap_or_default();
    Ok(Records {
        manifest,
        lock: lock_of(env, scope),
    })
}

impl Records {
    /// Whether this scope's lock could NOT be read at all.
    pub(super) fn lock_unreadable(&self) -> bool {
        self.lock.is_none()
    }

    /// An installation of this package recorded here, from `source`.
    fn locked_from(&self, source: Option<&str>, kind: ItemKind, name: &str) -> bool {
        self.lock.as_ref().is_some_and(|lock| {
            lock.entries.values().any(|entry| {
                entry.kind == kind && entry.name == name && source == Some(entry.source.as_str())
            })
        })
    }
}

/// This scope's lock, or `None` where it could not be read. The one place
/// that decides what "unreadable" means, so every carrier of the fact —
/// [`Records::lock_unreadable`] and [`records_unreadable`] — answers alike.
fn lock_of(env: &Env, scope: &Scope) -> Option<Lock> {
    crate::lock::load(&crate::lock::lock_path(env, scope)).ok()
}

/// Whether this scope's lock could NOT be read, asked without opening a
/// catalog: a listing carries the fact for the scope each row lives in, so
/// the answer arrives with the rows it describes rather than from a read on
/// another clock.
pub fn records_unreadable(env: &Env, scope: &Scope) -> bool {
    lock_of(env, scope).is_none()
}

pub(crate) fn open(env: &Env, catalog: &Catalog) -> Result<Browsed> {
    match catalog {
        Catalog::Subscription { scope, source } => {
            let records = records(env, scope)?;
            let resolved = require_ready(env, scope, source, &records.manifest)?;
            browsed(records, resolved, Some(source.clone()))
        }
        Catalog::Repo { repo } => {
            let key = browsable(repo)?;
            // The store answers without the network when it already holds
            // the repository; otherwise this is the one fetch.
            let resolution = match crate::remote::cached(env, &key, None)? {
                Some(resolution) => resolution,
                None => crate::remote::sync(env, &key, None)?,
            };
            open_repo(env, key, resolution)
        }
    }
}

/// A repository nobody subscribes to, at the resolution the caller already
/// holds — `summary` refreshes first and reads what it fetched.
pub(crate) fn open_repo(
    env: &Env,
    key: String,
    resolution: crate::remote::Resolution,
) -> Result<Browsed> {
    // Collisions are judged against the personal scope: that is where
    // Subscribe lands by default, so the warning shown here is the refusal
    // an install there would meet.
    let records = records(env, &Scope::Global)?;
    let source = ResolvedSource {
        name: key.clone(),
        root: resolution.root,
        provenance: key,
        commit: Some(resolution.commit),
    };
    browsed(records, source, None)
}

fn browsed(
    records: Records,
    source: ResolvedSource,
    subscription: Option<String>,
) -> Result<Browsed> {
    let sealed = SealedSource::open(&source.root)?;
    let config = source_config_for(&sealed, &source.provenance)?;
    Ok(Browsed {
        records,
        source,
        sealed,
        config,
        subscription,
    })
}

impl Browsed {
    /// Whether an installation or declaration belongs to this catalog. A
    /// bare repository is subscribed as nothing, so nothing is installed
    /// "from here" and every declared name is a collision.
    pub(super) fn owned_here(&self, source: &str) -> bool {
        self.subscription.as_deref() == Some(source)
    }

    /// The subscription this catalog is browsed as, for a join reading
    /// another scope's records: an install redirected into a project
    /// installs from that same subscription name.
    pub(super) fn subscription(&self) -> Option<&str> {
        self.subscription.as_deref()
    }

    /// The browsed scope's own records — what every read joins against
    /// unless the caller was handed a destination to redirect into.
    pub(super) fn records(&self) -> &Records {
        &self.records
    }

    /// The lock+manifest join behind every state column: an installation
    /// recorded from here, or the package on offer.
    ///
    /// `landing` is the scope the answer is about — [`Browsed::records`]
    /// for a page that installs where it browses, the destination's
    /// [`Records`] for one redirecting into a project. Only the records
    /// move: the subscription an installation must have come from is the
    /// catalog's, and a redirected install installs from that same name.
    ///
    /// This and [`Browsed::member_state`] are the only two answers to
    /// "where does this stand there", and both open with the same refusal:
    /// where the lock could not be read, every standing it alone could
    /// have given is [`InstallState::Unknown`]. Every surface offering an
    /// install for ONE package reads that state rather than deciding for
    /// itself, so a new one inherits the rule instead of needing its own
    /// arm. The set page's Install all asks about the set rather than a
    /// package and reads [`super::BundleDetail::records_unreadable`].
    pub(super) fn state(&self, landing: &Records, kind: ItemKind, name: &str) -> InstallState {
        if landing.lock_unreadable() {
            return InstallState::Unknown;
        }
        match landing.locked_from(self.subscription(), kind, name) {
            true => InstallState::Installed,
            false => InstallState::Available,
        }
    }

    /// One curated-set member's standing in `landing`. A member the catalog
    /// names but no longer carries is a row, not a hard error: one bad
    /// entry must not sink the whole page.
    ///
    /// Where the lock could not be read the whole join goes first, ahead of
    /// suppression: "you removed this" is the manifest's word, but the row
    /// it draws offers Restore, and a restore lands on the same record this
    /// read could not open. A member the catalog no longer carries needs no
    /// lock to say so and offers nothing, so it answers NotOffered either
    /// way; with a readable lock, suppression still outranks it — that a
    /// removal was the user's own choice is worth saying about a member the
    /// catalog has since dropped.
    pub(super) fn member_state(
        &self,
        landing: &Records,
        kind: ItemKind,
        name: &str,
    ) -> InstallState {
        let offered = find_item(&self.sealed, &self.config, kind, name).is_some();
        if landing.lock_unreadable() {
            return match offered {
                true => InstallState::Unknown,
                false => InstallState::NotOffered,
            };
        }
        if landing.locked_from(self.subscription(), kind, name) {
            return InstallState::Installed;
        }
        // Removed by the user, and recorded so the bundle cannot derive it
        // back — their choice, shown as such with a way to reverse it.
        if landing.manifest.is_suppressed(kind, name) {
            return InstallState::RemovedByYou;
        }
        match offered {
            true => InstallState::Available,
            false => InstallState::NotOffered,
        }
    }

    /// The source a name is already taken by in `landing`, when it is not
    /// this one. A fork counts too — `local` is a source like any other
    /// here.
    ///
    /// `landing` is the scope the answer is about, the same parameter
    /// [`Browsed::state`] takes: the engine judges invariant 4 against the
    /// scope [`crate::engine::ops::add_seeded`] mutates, so the warning
    /// shown before the click reads that scope's records. Only the records
    /// move — whether a name is "ours" is the catalog's subscription name,
    /// which is [`Browsed::owned_here`].
    ///
    /// A collision only the lock records goes unseen where the lock could
    /// not be read; nothing acts on that, because no row in such a scope
    /// offers an install for the engine to refuse — every standing the
    /// lock could have answered is [`InstallState::Unknown`], and the
    /// install surfaces gate on it.
    pub(super) fn collision(
        &self,
        landing: &Records,
        kind: ItemKind,
        name: &str,
    ) -> Option<String> {
        if let Some(decl) = landing.manifest.declared(kind).get(name)
            && !self.owned_here(&decl.source)
        {
            return Some(decl.source.clone());
        }
        landing
            .lock
            .iter()
            .flat_map(|lock| lock.entries.values())
            .find(|entry| {
                entry.kind == kind && entry.name == name && !self.owned_here(&entry.source)
            })
            .map(|entry| entry.source.clone())
    }

    /// The source a set's name is already taken by in `landing`, read the
    /// same way and for the same reason as [`Browsed::collision`].
    pub(super) fn bundle_collision(&self, landing: &Records, name: &str) -> Option<String> {
        landing
            .manifest
            .bundles
            .get(name)
            .filter(|decl| !self.owned_here(&decl.source))
            .map(|decl| decl.source.clone())
    }
}
