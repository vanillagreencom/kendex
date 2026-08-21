//! Whether the catalog a lock-carried record names actually published it.
//!
//! Split out of `observed.rs`: this is the one question the audit asks that
//! the plan never has to, because only the audit reads a record out of a
//! file the project itself commits.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::lock::LockEntry;
use crate::manifest::Manifest;
use crate::model::Scope;
use crate::quality::author::AuthorReview;
use crate::quality::reviews::SafetyReview;

/// The catalogs one audit has already read, and everything it needs to ask
/// them a question. Opening a source and parsing its review file is one
/// read per catalog, not one per installation: a scope carries dozens of
/// rows and most of them come from the same few catalogs.
pub(super) struct Vouching<'a> {
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a Manifest,
    read: HashMap<PathBuf, Option<BTreeMap<String, SafetyReview>>>,
}

impl<'a> Vouching<'a> {
    pub(super) fn new(env: &'a Env, scope: &'a Scope, manifest: &'a Manifest) -> Vouching<'a> {
        Vouching {
            env,
            scope,
            manifest,
            read: HashMap::new(),
        }
    }

    fn reviews(&mut self, root: &Path) -> Option<&BTreeMap<String, SafetyReview>> {
        self.read
            .entry(root.to_path_buf())
            .or_insert_with(|| {
                let sealed = crate::source_read::SealedSource::open(root).ok()?;
                crate::check_catalog::dismissals::load(&sealed).ok()
            })
            .as_ref()
    }

    /// Why this record settles nothing here, or `None` where the catalog it
    /// claims to come from says the same thing this record says.
    ///
    /// Every other check on a lock-carried record answers a question about
    /// shape: is the hash this content's, is the fingerprint one this build
    /// could have written, is the timestamp a timestamp. None of those can
    /// answer authorship, and authorship is what this record trades on — it is
    /// the one decision a person did not make that removes findings from the
    /// score, where their own dismissal never unblocks anything. Nor can the
    /// name it carries be authenticated: corroborating it against the
    /// manifest's subscription only proves that whoever wrote the record named
    /// a catalog this project installs from, which is a string anyone editing
    /// the lock can copy out of `kendex.toml`.
    ///
    /// So the string is not what is checked. The catalog is on this machine —
    /// the checkout of the commit the entry names, or the directory a path
    /// source points at — and it publishes its own `kendex-reviews.toml`. Every
    /// fingerprint this record claims has to be one that file dismisses for
    /// this item, under the same rule set, with the same reason and the same
    /// date. A record claiming anything else is not the record that source
    /// published, whatever name it carries.
    ///
    /// Where the catalog is not on this machine the audit cannot fetch and does
    /// not guess: the record is reported under the name it carries and settles
    /// nothing until the source is here to answer for it. That is the whole
    /// standing of a record read out of a lock — evidence of what an apply
    /// read, never proof of who wrote it.
    pub(super) fn unvouched(&mut self, entry: &LockEntry, review: &AuthorReview) -> Option<String> {
        let publisher = &review.publisher;
        let kind = entry.kind.name();
        let name = &entry.name;
        let source = self
            .manifest
            .declared(entry.kind)
            .get(&entry.name)
            .map_or(entry.source.as_str(), |decl| decl.source.as_str());
        if crate::source::declared_provenance(self.env, self.scope, source, self.manifest)
            .as_deref()
            != Some(publisher.as_str())
        {
            return Some(format!(
                "this project's install record carries a review in {publisher}'s name, but the project does not install {kind} {name} from {publisher} — nothing here can confirm whose review it is, so it settles nothing"
            ));
        }
        let Some(root) = self.catalog_root(source, entry) else {
            return Some(format!(
                "{publisher}'s catalog is not on this machine at the commit {kind} {name} was installed from, so nothing here can confirm the review recorded in their name is theirs — fetch the source and it answers for itself"
            ));
        };
        let Some(carried) = self.reviews(&root) else {
            return Some(format!(
                "{publisher}'s own review file could not be read here, so nothing confirms the review recorded in their name is theirs — it settles nothing"
            ));
        };
        match publishes(carried, entry, review) {
            true => None,
            false => Some(format!(
                "{publisher} does not publish the review this install record carries in their name for {kind} {name} — it settles nothing"
            )),
        }
    }

    /// Where this installation's catalog sits on this machine: the checkout of
    /// the commit the entry came from, or the directory a path source points
    /// at. `None` where the cache does not hold it — an audit reads what is
    /// here and never fetches.
    fn catalog_root(&self, source: &str, entry: &LockEntry) -> Option<PathBuf> {
        if source == crate::manifest::LOCAL_SOURCE_NAME {
            return Some(crate::source::local_source_root(self.env, self.scope));
        }
        let decl = self.manifest.sources.get(source)?;
        if decl.path.is_some() {
            // A path source is the directory itself: there is no commit to
            // check out, and nothing cached in between to disagree with it.
            return crate::source::declared_provenance(self.env, self.scope, source, self.manifest)
                .map(PathBuf::from);
        }
        let repo = decl.repo.as_deref()?;
        let commit = entry.source_commit.as_deref()?;
        crate::remote::store::published(self.env, &crate::remote::cache_key(self.env, repo), commit)
    }
}

/// Whether the catalog's own review file says what this record says: the
/// same rule set, and every fingerprint the record claims dismissed there
/// for this item with the same reason on the same date. A subset, because
/// a claim the reader refuses never reaches the lock; anything the file
/// does not carry at all is a claim its publisher never made.
fn publishes(
    carried: &std::collections::BTreeMap<String, crate::quality::reviews::SafetyReview>,
    entry: &crate::lock::LockEntry,
    review: &crate::quality::author::AuthorReview,
) -> bool {
    let key = crate::quality::author::review_key(entry.kind, &entry.name);
    let Some(published) = carried.get(&key) else {
        return false;
    };
    published.ruleset == review.ruleset
        && review.dismissed.iter().all(|(fingerprint, claimed)| {
            published.dismissed.get(fingerprint).is_some_and(|theirs| {
                theirs.reason == claimed.reason
                    && theirs.dismissed_at == claimed.dismissed_at
                    && crate::quality::author::honest(fingerprint, theirs)
            })
        })
}
