//! Scoring what is on disk, as opposed to what a plan would write.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;

use super::gate::{self, ItemSafety};

/// The other scoring path: the safety of what is on disk in this scope
/// right now, declared or not. The plan-time path scores content nobody has
/// installed yet, which is what gates a fresh install; this scores what a
/// tool would load if it started this second, which is what an audit is
/// about. Same rules, different bytes.
pub fn observed_safety(env: &Env, scope: &Scope) -> Result<Vec<ItemSafety>> {
    Ok(observed_rows(env, scope)?
        .into_iter()
        .filter(|row| {
            !row.findings.is_empty()
                || !row.skipped.is_empty()
                || row.verdict != crate::quality::Verdict::Clean
        })
        .collect())
}

/// Every installation in this scope, scored — the clean ones included. The
/// decision registry reads this: a recorded decision about an item that is
/// still installed but no longer has the finding is stale, not obsolete,
/// and telling those apart needs the clean rows too.
pub fn observed_rows(env: &Env, scope: &Scope) -> Result<Vec<ItemSafety>> {
    let scope = scope.canonical();
    let settings = crate::settings::load(env)?;
    let scan = crate::scan::scan_scopes(env, &settings.harness_roots, std::slice::from_ref(&scope));
    // The decisions recorded for this scope. An item that is installed
    // *because* someone read its findings and accepted them is not the same
    // thing as one nobody has looked at, and an audit that calls the first
    // one held back is telling the user the opposite of the truth.
    let manifest = match manifest::load(&manifest::manifest_path(env, &scope))? {
        ManifestFile::Current(manifest) => *manifest,
        _ => Manifest::default(),
    };
    // A lock this build cannot read is a note on the audit page, not a
    // reason to score nothing: the bytes on disk are still what a tool
    // would load. Without it, provenance falls back to the scanner's word.
    let lock = match crate::lock::load_file(&crate::lock::lock_path(env, &scope))? {
        crate::lock::LockFile::Current(lock) => lock,
        _ => crate::lock::Lock::default(),
    };
    // Content a tool ships itself is that tool's to answer for: the reader
    // never chose it and cannot change it, so an audit that asks them to
    // rule on it is asking a question with no answer.
    let items: Vec<&crate::model::ObservedItem> = scan
        .items
        .iter()
        .filter(|item| item.vendor.is_none())
        .collect();
    let scored = score_each(&items);
    Ok(items
        .into_iter()
        .zip(scored)
        .map(|(item, scored)| {
            let result = scored.result;
            let key = crate::lock::entry_key(item.kind, &item.name, item.harness);
            let root = item.path.display().to_string();
            // Only the lock's word on where the bytes came from: what kendex
            // itself declared and resolved. The scanner's guess is a remote
            // url read out of a `.git/config` sitting inside the very
            // content being judged, which is not something to trust a
            // source by.
            let provenance = lock
                .entries
                .get(&key)
                .map(|entry| entry.source_repo.clone());
            let by_author = author_review(&lock, scored.review.as_deref());
            let budget =
                crate::quality::author::AuthorReview::budget(by_author, scored.review.as_deref());
            let scored_findings = crate::quality::author::score(&result.findings, &root, &budget);
            let (verdict, reasons) = crate::quality::verdict(
                &scored_findings.counted,
                &scored_findings.safety,
                settings.safety,
            );
            let override_state = crate::quality::overrides::state(
                manifest.safety_overrides.get(&key),
                scored.review.as_deref(),
                &result.findings,
                &root,
            );
            let decisions = super::decisions::decisions(
                &super::decisions::Installation {
                    manifest: &manifest,
                    scope: &scope,
                    key: &key,
                    root: &root,
                    review_hash: scored.review.as_deref(),
                    provenance: provenance.as_deref(),
                    override_state: &override_state,
                    author_review: by_author,
                    settled: &scored_findings.settled,
                    held_back: verdict == crate::quality::Verdict::Block
                        && !override_state.unblocks(),
                },
                &result.findings,
            );
            ItemSafety {
                kind: item.kind,
                name: item.name.clone(),
                harness: item.harness,
                scope: item.scope.clone(),
                location: root,
                safety: scored_findings.safety,
                quality: result.quality,
                override_state,
                findings: result.findings,
                skipped: result.skipped,
                verdict,
                reasons,
                content_hash: scored.content,
                review_hash: scored.review,
                provenance,
                decisions,
            }
        })
        .collect())
}

/// What the item's publisher had settled when the apply ran, for the bytes
/// in front of us now.
///
/// Found by the bytes, not by the installation. A record binds to a review
/// hash and that hash is sealed by kind, so a record whose hash is this
/// content's hash is a record about this content — whichever entry happens
/// to hold it. That is what the lookup needs: one shared skill tree is what
/// several tools load, each scored as its own row, while only the tool it
/// was installed for has a lock entry; and a hook is scanned back under a
/// synthesized `event:matcher:name`, which no lock key spells. Comparing
/// names would miss both. An edited install moves the hash and every record
/// for it stops applying, the rule every other review answers to.
fn author_review<'a>(
    lock: &'a crate::lock::Lock,
    review_hash: Option<&str>,
) -> Option<&'a crate::quality::author::AuthorReview> {
    let review_hash = review_hash?;
    lock.entries
        .values()
        .filter_map(|entry| entry.author_review.as_ref())
        .find(|review| review.stale_why(Some(review_hash)).is_none())
        .map(|review| review as &crate::quality::author::AuthorReview)
}

/// Every observation's score, one reading per distinct set of bytes, spread
/// over the machine's cores.
///
/// Scoring is the slowest thing an audit does and the readings share
/// nothing, so they run side by side; `crate::parallel::map` hands them back
/// in the order they were given, which is the order the rows are built in.
fn score_each(items: &[&crate::model::ObservedItem]) -> Vec<crate::quality::observe::Scored> {
    use crate::quality::observe::same_reading;
    let mut first = std::collections::HashMap::new();
    let mut distinct: Vec<&crate::model::ObservedItem> = Vec::new();
    let mut reading: Vec<usize> = Vec::with_capacity(items.len());
    for item in items {
        let at = *first.entry(same_reading(item)).or_insert_with(|| {
            distinct.push(item);
            distinct.len() - 1
        });
        reading.push(at);
    }
    let scored = crate::parallel::map(&distinct, |item| {
        crate::quality::observe::score(item, gate::content_hash, super::review_hash::observed)
    });
    reading.into_iter().map(|at| scored[at].clone()).collect()
}
