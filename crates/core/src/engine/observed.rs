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
    // The plan that produced what is on disk, rebuilt from the catalogs at
    // the revisions the lock names. Everything a publisher's record says is
    // read out of a catalog here rather than out of the lock, and a
    // reconstruction that does not equal what is installed answers for
    // nothing. A pass that cannot be built at all — a source that is not on
    // this machine, a manifest that will not resolve — leaves no
    // reconstruction, and then no record settles anything.
    let planned =
        super::desired::desired_as_installed(env, &scope, &manifest, &lock).unwrap_or_default();
    // Keyed by what a rebuild produced, so finding one *is* the check that
    // the bytes on disk are that rebuild. Not by harness: one shared tree is
    // what several tools load, each scanned as its own row, while the plan
    // built it once. Kind and name stay in the key — a review hash is sealed
    // by kind but not by name, and `publisher` is a name a person is asked
    // to weigh, so one catalog must never be named as the reviewer of
    // another's identical bytes.
    let rebuilt: std::collections::HashMap<Rebuild<'_>, &super::desired::Desired> = planned
        .iter()
        .filter_map(|item| {
            let (kind, name) = written_as(item);
            Some(((kind, name, super::review_hash::desired(item)?), item))
        })
        .collect();
    // And the same items by name alone: where the item comes from, and what
    // says so when a rebuild exists and is not what is installed.
    let carried: std::collections::HashMap<
        (crate::model::ItemKind, &str),
        &super::desired::Desired,
    > = planned
        .iter()
        .map(|item| (written_as(item), item))
        .collect();
    let reading = Reading {
        scope: &scope,
        manifest: &manifest,
        lock: &lock,
        thresholds: settings.safety,
        rebuilt,
        carried,
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
    rebuilt: std::collections::HashMap<Rebuild<'a>, &'a super::desired::Desired>,
    carried:
        std::collections::HashMap<(crate::model::ItemKind, &'a str), &'a super::desired::Desired>,
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
        let key = self.installation_key(item);
        let root = item.path.display().to_string();
        // Where the bytes came from, as the rebuild resolved it — never the
        // scanner's guess, which is a remote url read out of a `.git/config`
        // sitting inside the very content being judged. The lock answers
        // only for an installation no rebuild covers, which is one nothing
        // declares any more.
        let provenance = self
            .carried
            .get(&(item.kind, item.name.as_str()))
            .map(|planned| planned.provenance.clone())
            .or_else(|| {
                self.lock
                    .entries
                    .get(&key)
                    .map(|entry| entry.source_repo.clone())
            });
        let by_author = published_by(&self.rebuilt, &self.carried, item, scored.review.as_deref());
        let budget = by_author
            .as_ref()
            .and_then(|found| found.earned.as_ref())
            .map(|earned| earned.budget.clone())
            .unwrap_or_default();
        let scored_findings = crate::quality::author::score(&result.findings, &budget);
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

/// The publisher's record for this installation, and what it earned.
///
/// Both come from the rebuilt plan, which read the record out of the
/// catalog it resolved and measured it against the item rendered from the
/// publisher's own inputs — the same derivation the gate does, on the same
/// bytes. Nothing here reads the lock: a record kept there would be a claim
/// about a catalog, and this has the catalog.
///
/// The record is honoured only where a rebuild *is* what is installed, and
/// that is the lookup rather than a comparison after it. Content no rebuild
/// produced is content the publisher never saw — replaced, edited, or
/// simply something else — and a rebuild that exists and does not match
/// says so, because a record carried onto other content is exactly the
/// thing a person reading this needs told.
fn published_by<'a>(
    rebuilt: &std::collections::HashMap<Rebuild<'_>, &'a super::desired::Desired>,
    carried: &std::collections::HashMap<
        (crate::model::ItemKind, &str),
        &'a super::desired::Desired,
    >,
    item: &crate::model::ObservedItem,
    observed: Option<&str>,
) -> Option<Published<'a>> {
    let here = (item.kind, item.name.as_str());
    if let Some(planned) = observed.and_then(|hash| rebuilt.get(&(here.0, here.1, hash.to_owned())))
    {
        let review = planned.author_review.as_ref()?;
        let authored = crate::quality::audit(super::gate::input::authored_for(planned));
        return Some(Published {
            review,
            earned: Some(crate::quality::author::Budget::earned(
                review,
                &authored.findings,
            )),
            unbuilt: None,
        });
    }
    let planned = carried.get(&here)?;
    let review = planned.author_review.as_ref()?;
    Some(Published {
        review,
        earned: None,
        unbuilt: Some(format!(
            "what is installed here is not what {} publishes as {} {} — the review recorded in their name is about content this is not, so it settles nothing",
            review.publisher,
            planned.kind.name(),
            planned.name
        )),
    })
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
    /// Why it settles nothing, when it does. `None` when it stands.
    unbuilt: Option<String>,
}

/// The key this observation's records live under. An artifact written under
/// another kind's name belongs to the installation that wrote it — every
/// decision about it, the person's own included, was made there.
///
/// The rebuild says which that is; the lock answers only for an
/// installation no rebuild covers, which is one nothing declares any more.
impl Reading<'_> {
    fn installation_key(&self, item: &crate::model::ObservedItem) -> String {
        self.carried
            .get(&(item.kind, item.name.as_str()))
            .map(|planned| planned.key.clone())
            .unwrap_or_else(|| emitted_under(self.lock, item))
    }
}

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
