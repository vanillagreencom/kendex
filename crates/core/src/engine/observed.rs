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
            // The installation this observation belongs to, which is not
            // always the one its own kind and name spell: a Codex command
            // is written and scanned back as a skill tree, and its records
            // were made under the command it is declared as.
            let key = installation_key(&lock, item);
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
            // What the record earned was measured by the apply that wrote
            // these bytes and written down beside it. The audit reads that
            // answer rather than deriving it a second time: a live record
            // proves the bytes are the ones that apply measured, and two
            // derivations of one number are two chances to disagree.
            let by_author = author_review(
                env,
                &scope,
                &manifest,
                &lock,
                item,
                scored.review.as_deref(),
                result.findings.len(),
            );
            // Only a record this project can vouch for pays for anything.
            let budget = by_author
                .as_ref()
                .filter(|found| found.unvouched.is_none())
                .map(|found| found.review.recorded_budget())
                .unwrap_or_default();
            let scored_findings = crate::quality::author::score(&result.findings, &budget);
            let (verdict, reasons) = crate::quality::verdict(
                &scored_findings.counted,
                &scored_findings.safety,
                settings.safety,
            );
            let override_state = crate::quality::overrides::state(
                manifest.safety_overrides.get(&key),
                scored.review.as_deref(),
                &result.findings,
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
                    author_review: by_author.as_ref().map(|found| found.review),
                    unvouched: by_author
                        .as_ref()
                        .and_then(|found| found.unvouched.as_deref()),
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
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &'a crate::lock::Lock,
    item: &crate::model::ObservedItem,
    review_hash: Option<&str>,
    counted: usize,
) -> Option<Published<'a>> {
    let review_hash = review_hash?;
    lock.entries
        .values()
        .filter(|entry| names(entry, item))
        // Every check on one record before the next record is looked at.
        // The lock travels in the project repository and a pull request can
        // edit it, so what comes back out of it gets the checks the
        // catalog's own file gets — and a record that fails them settles
        // nothing, which is the same answer as no record. Asking after the
        // first match had been picked let one bad entry hide a good one:
        // several entries carry a record for one shared tree, and only one
        // of them has to hold up.
        .filter_map(|entry| {
            let review = entry.author_review.as_ref()?;
            (review.stale_why(Some(review_hash)).is_none() && review.is_honest(counted)).then(
                || Published {
                    unvouched: unvouched(env, scope, manifest, entry, review),
                    review,
                },
            )
        })
        // A record this project vouches for outranks one it does not, so a
        // forged entry beside a real one cannot take the real one's place.
        .min_by_key(|found| usize::from(found.unvouched.is_some()))
}

/// The publisher's record for one observation, and its standing here.
struct Published<'a> {
    review: &'a crate::quality::author::AuthorReview,
    /// Why this record settles nothing, when the manifest does not vouch
    /// for where it came from. `None` when it does.
    unvouched: Option<String>,
}

/// Whether this project's own manifest vouches for where the record came
/// from, and the sentence to show when it does not.
///
/// Every other check on a lock-carried record answers a question about
/// shape: is the hash this content's, is the fingerprint one this build
/// could have written, is the timestamp a timestamp. None of those can
/// answer provenance, and provenance is what this record trades on — it is
/// the one decision a person did not make that removes findings from the
/// score, where their own dismissal never unblocks anything. So a forged
/// entry with a correct hash, a real fingerprint, a plausible name and an
/// in-range count passes everything a shape can be asked and still buys
/// what it wanted.
///
/// What it cannot forge in the same file is the subscription. The manifest
/// declares the item and names the source; the source names the repository
/// or the path (`source::declared_provenance`). Both are read here from the
/// manifest alone — never from the lock, which is the file under suspicion
/// — so a forged record has to be accompanied by a visible subscription to
/// the publisher it names, which is a change a person reviewing the pull
/// request is looking straight at.
///
/// An installation nothing declares by name — a dependency, a bundle's
/// member — is asked of the source its entry names instead, which the
/// manifest still has to declare for the lookup to answer at all. That is
/// weaker: it lets the entry choose among the catalogs this project already
/// subscribes to. It is not nothing, and re-deriving the whole closure to
/// name a derived item's source would be the same subscription list read a
/// second way.
///
/// A record that cannot be corroborated is still reported, under the name
/// it carries, with this sentence beside it. It just does not spend.
fn unvouched(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    entry: &crate::lock::LockEntry,
    review: &crate::quality::author::AuthorReview,
) -> Option<String> {
    let publisher = &review.publisher;
    let source = manifest
        .declared(entry.kind)
        .get(&entry.name)
        .map_or(entry.source.as_str(), |decl| decl.source.as_str());
    let subscribed = crate::source::declared_provenance(env, scope, source, manifest);
    if subscribed.as_deref() == Some(publisher.as_str()) {
        return None;
    }
    Some(format!(
        "this project's install record carries a review in {publisher}'s name, but the project does not install {} {} from {publisher} — nothing here can confirm whose review it is, so it settles nothing",
        entry.kind.name(),
        entry.name
    ))
}

/// The key this observation's records live under. An entry that emitted
/// this artifact under another kind's name is the installation it belongs
/// to — every decision about it, the person's own included, was made there.
fn installation_key(lock: &crate::lock::Lock, item: &crate::model::ObservedItem) -> String {
    lock.entries
        .iter()
        .find(|(_, entry)| {
            entry.harness == item.harness
                && entry
                    .emitted
                    .as_ref()
                    .is_some_and(|emitted| emitted.kind == item.kind && emitted.name == item.name)
        })
        .map(|(key, _)| key.clone())
        .unwrap_or_else(|| crate::lock::entry_key(item.kind, &item.name, item.harness))
}

/// Whether this lock entry is about this observation. The harness is left
/// out on purpose — one shared skill tree is what several tools load, each
/// scored as its own row, while only the tool it was installed for has an
/// entry. The kind and name are not: a review hash is sealed by kind, so
/// two same-kind items carrying identical bytes hash alike, and `publisher`
/// is a name a person is asked to weigh — being told one catalog reviewed
/// another's copy would be a lie about who answered for it. Rendering
/// writes an installed skill's own name into its frontmatter, so that
/// collision is hard to reach today; the record still belongs to the item
/// it was recorded for, and matching on the bytes alone would make that an
/// accident rather than a rule. An entry that emitted this artifact under
/// another kind's name is the one that wrote it, so it answers for it.
fn names(entry: &crate::lock::LockEntry, item: &crate::model::ObservedItem) -> bool {
    if entry.kind == item.kind && entry.name == item.name {
        return true;
    }
    entry
        .emitted
        .as_ref()
        .is_some_and(|emitted| emitted.kind == item.kind && emitted.name == item.name)
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
