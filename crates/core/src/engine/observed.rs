//! Scoring what is on disk, as opposed to what a plan would write.
//!
//! **An installation is the unit of every answer here: one row, one lock
//! entry, one revision, one record, one decision.** The same item installed
//! for two tools is two installations, and the lock can hold them at two
//! revisions — a refresh applies per installation, so one tool's new
//! rendering can go through while another's is held back. Anything keyed by
//! the item alone therefore collapses two answers into one and hands
//! whichever survived to both: an unreviewed installation inheriting a
//! dismissal, or a person's acceptance of one tool's copy reading as an
//! acceptance of another's, or a token that records a click against an
//! installation nobody was looking at. If something here is keyed by item
//! and not by installation, that is the bug.
//!
//! The one thing bytes may answer for is a row that is no installation at
//! all: one tree under `.agents/` is read by every tool that looks there
//! and scanned as a row each time, while only the tools it was installed
//! for have an entry. A record binds to bytes, so those rows are answered
//! by the bytes — and only where every installation carrying them agrees,
//! since two revisions can render alike and review differently.

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
    // The plan that produced what is on disk, rebuilt from the catalogs at
    // the revisions the lock names. Everything a publisher's record says is
    // read out of a catalog here rather than out of the lock, and a
    // reconstruction that does not equal what is installed answers for
    // nothing. A pass that cannot be built at all — a source that is not on
    // this machine, a manifest that will not resolve — leaves no
    // reconstruction, and then no record settles anything.
    let planned =
        super::desired::desired_as_installed(env, &scope, &manifest, &lock).unwrap_or_default();
    // An installation is the unit of every answer here: one row, one lock
    // entry, one revision, one record. So the rebuilds are keyed by the
    // installation they are — the artifact's kind and name on disk, and the
    // tool it was written for. Keying by the item alone collapses two
    // installations of one item into one answer, and once the lock can pin
    // them to different revisions that is two tools sharing whichever
    // answer the hash ordering happened to keep.
    let mine: std::collections::HashMap<Installed<'_>, &super::desired::Desired> = planned
        .iter()
        .map(|item| {
            let (kind, name) = written_as(item);
            ((kind, name, item.harness), item)
        })
        .collect();
    // And by the bytes they produced, for a row that is no installation of
    // its own: one tree under `.agents/` is read by every tool that looks
    // there, and each is scanned as its own row while only the tools it was
    // installed for have an entry. A record binds to bytes, so bytes are
    // what answers those — but only where every installation carrying them
    // says the same thing, since two revisions can render alike and review
    // differently, and picking one of those would be the collapse again.
    let mut shared: std::collections::HashMap<Rebuild<'_>, Vec<&super::desired::Desired>> =
        std::collections::HashMap::new();
    for item in &planned {
        let (kind, name) = written_as(item);
        if let Some(hash) = super::review_hash::desired(item) {
            shared.entry((kind, name, hash)).or_default().push(item);
        }
    }
    let reading = Reading {
        scope: &scope,
        manifest: &manifest,
        lock: &lock,
        thresholds: settings.safety,
        mine,
        shared,
    };
    Ok(items
        .into_iter()
        .zip(scored)
        .map(|(item, scored)| reading.row(item, scored))
        .collect())
}

/// Everything one scope's reading shares across its rows.
struct Reading<'a> {
    scope: &'a Scope,
    manifest: &'a Manifest,
    lock: &'a crate::lock::Lock,
    thresholds: crate::quality::Thresholds,
    /// Every rebuilt installation, by the installation it is.
    mine: std::collections::HashMap<Installed<'a>, &'a super::desired::Desired>,
    /// The same rebuilds by the bytes they produced, for rows that are no
    /// installation of their own.
    shared: std::collections::HashMap<Rebuild<'a>, Vec<&'a super::desired::Desired>>,
}

impl Reading<'_> {
    fn row(
        &self,
        item: &crate::model::ObservedItem,
        scored: crate::quality::observe::Scored,
    ) -> ItemSafety {
        let result = scored.result;
        // The installation this observation belongs to, which is not always
        // the one its own kind and name spell: a Codex command is written
        // and scanned back as a skill tree, and its records were made under
        // the command it is declared as.
        // This row's own installation, and nothing else's: the rebuild for
        // this tool, this item, this revision.
        let mine = self.mine.get(&here(item)).copied();
        let key = match mine {
            Some(planned) => planned.key.clone(),
            None => emitted_under(self.lock, item),
        };
        let root = item.path.display().to_string();
        // Where the bytes came from, as the rebuild resolved it — never the
        // scanner's guess, which is a remote url read out of a `.git/config`
        // sitting inside the very content being judged. The lock answers
        // only for an installation no rebuild covers, which is one nothing
        // declares any more.
        let provenance = mine.map(|planned| planned.provenance.clone()).or_else(|| {
            self.lock
                .entries
                .get(&key)
                .map(|entry| entry.source_repo.clone())
        });
        let by_author = self.published_by(
            item,
            mine,
            scored.review.as_deref(),
            &result.findings,
            &root,
        );
        let budget = by_author
            .as_ref()
            .and_then(|found| found.earned.as_ref())
            .map(|earned| earned.budget.clone())
            .unwrap_or_default();
        let scored_findings = crate::quality::author::score(
            &result.findings,
            &budget,
            by_author.as_ref().and_then(|found| found.theirs.as_deref()),
        );
        let (verdict, reasons) = crate::quality::verdict(
            &scored_findings.counted,
            &scored_findings.safety,
            self.thresholds,
        );
        let override_state = crate::quality::overrides::state(
            self.manifest.safety_overrides.get(&key),
            scored.review.as_deref(),
            &result.findings,
        );
        let decisions = super::decisions::decisions(
            &super::decisions::Installation {
                manifest: self.manifest,
                scope: self.scope,
                key: &key,
                root: &root,
                review_hash: scored.review.as_deref(),
                provenance: provenance.as_deref(),
                override_state: &override_state,
                author_review: by_author.as_ref().map(|found| found.review),
                unvouched: by_author
                    .as_ref()
                    .and_then(|found| found.unbuilt.as_deref()),
                settled: &scored_findings.settled,
                held_back: verdict == crate::quality::Verdict::Block && !override_state.unblocks(),
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
    }
}

/// What this installation is on disk, in the kind and name a scan reads
/// back: a Codex command is written and scanned as a skill tree, so the
/// artifact it emitted is what an observation of it matches.
fn written_as(item: &super::desired::Desired) -> (crate::model::ItemKind, &str) {
    match &item.emitted {
        Some(emitted) => (emitted.kind, emitted.name.as_str()),
        None => (item.kind, item.name.as_str()),
    }
}

impl<'a> Reading<'a> {
    fn published_by(
        &self,
        item: &crate::model::ObservedItem,
        mine: Option<&'a super::desired::Desired>,
        observed: Option<&str>,
        findings: &[crate::quality::Finding],
        at: &str,
    ) -> Option<Published<'a>> {
        // This row's own installation answers for it. A rebuild that is not
        // what is installed says so — a record carried onto other content is
        // exactly the thing a person reading this needs told.
        if let Some(planned) = mine {
            let review = planned.author_review.as_ref()?;
            if super::review_hash::desired(planned).as_deref() != observed {
                return Some(Published {
                    review,
                    earned: None,
                    theirs: None,
                    unbuilt: Some(format!(
                        "what is installed here is not what {} publishes as {} {} — the review recorded in their name is about content this is not, so it settles nothing",
                        review.publisher,
                        planned.kind.name(),
                        planned.name
                    )),
                });
            }
            return Some(earned_by(planned, review, findings, at));
        }
        // No installation of its own: one tree under `.agents/` is read by
        // every tool that looks there, and a record binds to bytes, so the
        // bytes answer. Only where every installation carrying them says the
        // same thing — two revisions can render alike and review
        // differently, and choosing between them would be the collapse this
        // module exists to avoid.
        let (kind, name) = (item.kind, item.name.as_str());
        let carrying = self.shared.get(&(kind, name, observed?.to_owned()))?;
        let planned = carrying.first()?;
        let agreed = carrying
            .iter()
            .all(|other| other.author_review == planned.author_review);
        let review = agreed.then_some(planned.author_review.as_ref()).flatten()?;
        Some(earned_by(planned, review, findings, at))
    }
}

/// What one rebuild's record earned, and which occurrences in front of us
/// are the publisher's — the same two derivations the gate does, on the
/// same bytes.
fn earned_by<'a>(
    planned: &'a super::desired::Desired,
    review: &'a crate::quality::author::AuthorReview,
    findings: &[crate::quality::Finding],
    at: &str,
) -> Published<'a> {
    let authored = super::gate::input::authored_for(planned);
    // Read at the path these bytes are *here*, not the one the plan would
    // write them to. A finding names the file it was found in, and the same
    // tree is loaded by several tools from several places — an alignment
    // against the plan's own path would match none of them.
    let here = |input: crate::quality::AuditInput| crate::quality::AuditInput {
        location: at.to_owned(),
        ..input
    };
    Published {
        review,
        earned: Some(crate::quality::author::Budget::earned(
            review,
            &crate::quality::audit(authored.clone()).findings,
        )),
        theirs: Some(crate::quality::authored_by(
            here(super::gate::input::input_for(planned)),
            here(authored),
            findings,
        )),
        unbuilt: None,
    }
}

/// One rebuilt artifact, as the observation that matches it spells itself:
/// the kind and name it is on disk, and the hash of the bytes.
type Rebuild<'a> = (crate::model::ItemKind, &'a str, String);

/// The publisher's record for one observation, and its standing here.
struct Published<'a> {
    review: &'a crate::quality::author::AuthorReview,
    /// What it earned against the item rendered from the publisher's own
    /// inputs. `None` where the rebuild is not what is installed.
    earned: Option<crate::quality::author::Earned>,
    /// Which of the findings in front of us the publisher's own rendering
    /// produced. `None` where the rebuild is not what is installed.
    theirs: Option<Vec<bool>>,
    /// Why it settles nothing, when it does. `None` when it stands.
    unbuilt: Option<String>,
}

/// Which installation this observation is: the artifact's kind and name on
/// disk, and the tool that reads it.
fn here(item: &crate::model::ObservedItem) -> Installed<'_> {
    (item.kind, item.name.as_str(), item.harness)
}

/// One installation, as the observation and the rebuild both spell it.
type Installed<'a> = (crate::model::ItemKind, &'a str, crate::model::HarnessId);

/// The key an observation's records live under where no rebuild covers it —
/// an artifact written under another kind's name belongs to the
/// installation that wrote it, and that entry is the only thing left that
/// says which.
fn emitted_under(lock: &crate::lock::Lock, item: &crate::model::ObservedItem) -> String {
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
