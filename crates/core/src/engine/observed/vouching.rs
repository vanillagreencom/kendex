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
use crate::model::{ItemKind, Scope};
use crate::quality::author::AuthorReview;
use crate::quality::reviews::SafetyReview;

/// What the catalog a lock-carried record names says about it.
pub(super) enum Vouched {
    /// The catalog publishes this record, and this is how many occurrences
    /// of each finding it names the publisher's own content carries.
    Carries(BTreeMap<String, u32>),
    /// It settles nothing, and this says why.
    Not(String),
}

impl Vouched {
    pub(super) fn why(&self) -> Option<&str> {
        match self {
            Vouched::Carries(_) => None,
            Vouched::Not(why) => Some(why),
        }
    }
}

/// The catalogs one audit has already read, and everything it needs to ask
/// them a question. Opening a source and parsing its review file is one
/// read per catalog, not one per installation: a scope carries dozens of
/// rows and most of them come from the same few catalogs.
pub(super) struct Vouching<'a> {
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a Manifest,
    read: HashMap<PathBuf, Option<BTreeMap<String, SafetyReview>>>,
    counted: HashMap<(PathBuf, ItemKind, String), Option<BTreeMap<String, u32>>>,
}

impl<'a> Vouching<'a> {
    pub(super) fn new(env: &'a Env, scope: &'a Scope, manifest: &'a Manifest) -> Vouching<'a> {
        Vouching {
            env,
            scope,
            manifest,
            read: HashMap::new(),
            counted: HashMap::new(),
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

    /// How many occurrences of each finding the publisher's own content
    /// carries for one item, counted from the catalog at the revision this
    /// installation came from.
    ///
    /// Counted here rather than read out of the lock, because a number in
    /// the lock is a number a pull request can edit — and this one buys the
    /// only thing a publisher's record buys, which is findings taken off
    /// the score. It reads the publisher's own bytes the way the rendering
    /// does: a skill through `render_authored`, which takes back out the
    /// marked blocks that are the project's to write, so a decoy planted in
    /// one earns nothing.
    ///
    /// What is *not* recovered here is which weight each occurrence ends up
    /// being read at — that is the renderer's answer, and it depends on
    /// where the split put it. `Budget::lightest` is what handles that,
    /// by spending on the lightest occurrences rather than guessing.
    fn carries(
        &mut self,
        root: &Path,
        kind: ItemKind,
        name: &str,
    ) -> Option<&BTreeMap<String, u32>> {
        self.counted
            .entry((root.to_path_buf(), kind, name.to_owned()))
            .or_insert_with(|| carried(root, kind, name))
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
    pub(super) fn vouched(&mut self, entry: &LockEntry, review: &AuthorReview) -> Vouched {
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
            return Vouched::Not(format!(
                "this project's install record carries a review in {publisher}'s name, but the project does not install {kind} {name} from {publisher} — nothing here can confirm whose review it is, so it settles nothing"
            ));
        }
        let Some(root) = self.catalog_root(source, entry) else {
            return Vouched::Not(format!(
                "{publisher}'s catalog is not on this machine at the commit {kind} {name} was installed from, so nothing here can confirm the review recorded in their name is theirs — fetch the source and it answers for itself"
            ));
        };
        let Some(published) = self.reviews(&root) else {
            return Vouched::Not(format!(
                "{publisher}'s own review file could not be read here, so nothing confirms the review recorded in their name is theirs — it settles nothing"
            ));
        };
        if !publishes(published, entry, review) {
            return Vouched::Not(format!(
                "{publisher} does not publish the review this install record carries in their name for {kind} {name} — it settles nothing"
            ));
        }
        // The catalog says what it dismissed. What that is worth is how
        // many of each the publisher's own content carries, counted from
        // the same revision rather than taken from the record.
        let Some(carries) = self.carries(&root, entry.kind, &entry.name) else {
            return Vouched::Not(format!(
                "{publisher}'s own {kind} {name} could not be read here, so there is nothing to measure their review against — it settles nothing"
            ));
        };
        Vouched::Carries(
            carries
                .iter()
                .filter(|(fingerprint, _)| review.dismissed.contains_key(*fingerprint))
                .map(|(fingerprint, count)| (fingerprint.clone(), *count))
                .collect(),
        )
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

/// One reading of a catalog's own item: how many occurrences of each
/// finding the publisher's own bytes carry.
///
/// The publisher's own, which for a skill means the tree `render_authored`
/// produces — the marked blocks a project writes are taken back out, so an
/// occurrence planted in one is not the publisher's and earns them nothing.
/// Every other kind renders from its own file, so its own file is what is
/// read.
fn carried(root: &Path, kind: ItemKind, name: &str) -> Option<BTreeMap<String, u32>> {
    let sealed = crate::source_read::SealedSource::open(root).ok()?;
    let config = crate::source::source_config(&sealed, name).ok()?;
    let path = crate::source::find_item(&sealed, &config, kind, name)?;
    let content = match kind {
        ItemKind::Skill => crate::quality::Content::SkillTree {
            files: crate::quality::observe::tree_files_from_bytes(
                &crate::render::skill::render_authored(&sealed, &path).ok()?,
            ),
        },
        _ => crate::quality::author::content(&sealed, kind, &path).ok()?,
    };
    let scored = crate::quality::audit(crate::quality::AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location: name.to_owned(),
        content,
    });
    let mut counts: BTreeMap<String, u32> = BTreeMap::new();
    for finding in &scored.findings {
        *counts.entry(finding.fingerprint()).or_default() += 1;
    }
    Some(counts)
}
