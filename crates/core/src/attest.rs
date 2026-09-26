//! What `verify` attests about a scope beyond its drift rows: the two
//! bookkeeping files a project commits about itself, and the shared files
//! kendex writes keys in.
//!
//! Every judgement here is the engine's own answer held up against the
//! file on disk. The inventory is held to the write the plan carries for
//! it and named against [`crate::engine::GeneratedPaths::relative`]; the
//! record is held to the serialization [`crate::lock::save`] lays down and
//! to the lock the pass would write; a shared file is held to kendex's own
//! edits applied over the file as a revision held it. Nothing here decides
//! what a render is, where it sits, or which keys are kendex's a second
//! time — a rule of that kind written beside the engine is a copy the next
//! release invalidates.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::apply::Op;
use crate::engine::{EngineReport, StoodIn};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{BundleRev, LOCK_FILE, Lock, LockEntry, SourceRev};
use crate::model::Scope;

/// Whether the part of a shared file kendex does not own moved between a
/// revision and the working tree.
///
/// `Unchanged` is the one answer that proves a change to that file is
/// confined to kendex's keys: the file as the revision held it, with
/// kendex's edits applied over it, is byte for byte the file on disk. A
/// reader granting anything on a `Keys` position needs this beside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Foreign {
    Unchanged,
    Changed,
    /// The comparison could not be made: the revision does not resolve, a
    /// copy could not be read, or an edit could not be applied to it.
    Unknown,
}

/// The shape of the document `kendex verify --json` prints. A reader pins
/// this number: a change to a row's fields or to what a state means bumps
/// it.
pub const DOCUMENT_VERSION: u32 = 1;

/// What one verify row concluded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum State {
    /// As kendex would write it.
    Ok,
    /// Not as kendex would write it; the row's detail says how.
    Failed,
    /// Declared by the scope and held by no record entry, so nothing was
    /// checked: the positions are where a render would land.
    Unrecorded,
}

impl State {
    /// `Ok` for a row that found no problem, `Failed` for one that did.
    pub fn of(ok: bool) -> State {
        match ok {
            true => State::Ok,
            false => State::Failed,
        }
    }
}

/// One position a verify row occupies, spelled relative to the scope's
/// root where it sits under it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placed {
    pub path: String,
    pub owns: crate::engine::Owns,
    /// For a `keys` position and only with a base revision: whether the
    /// rest of the file is as that revision held it. A reader granting
    /// anything on a `keys` position needs `unchanged` here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreign: Option<Foreign>,
}

/// One record of `kendex verify --json`: what the verb's human row
/// decided, with the positions the engine resolved. `kind` is the item
/// kind's name, or `shim`, `record` or `inventory`, none of which names an
/// item kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    #[serde(flatten)]
    pub scope: Scope,
    pub kind: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<crate::model::HarnessId>,
    pub state: State,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub positions: Vec<Placed>,
}

/// A repository source the record trails: the commit the record names
/// for it, and the one it resolves to now. Every render read at the
/// recorded commit is behind the source by the commits between the two.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stale {
    #[serde(flatten)]
    pub scope: Scope,
    pub source: String,
    pub recorded: String,
    pub resolved: String,
}

/// The whole document: the rows, the closing counts, whether the run
/// closed clean, which is its exit status as a field, and the sources
/// the record trails.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    pub version: u32,
    pub clean: bool,
    pub checked: usize,
    pub failed: usize,
    pub rows: Vec<Row>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stale: Vec<Stale>,
}

impl Document {
    pub fn new(
        clean: bool,
        checked: usize,
        failed: usize,
        rows: Vec<Row>,
        stale: Vec<Stale>,
    ) -> Document {
        Document {
            version: DOCUMENT_VERSION,
            clean,
            checked,
            failed,
            rows,
            stale,
        }
    }
}

/// What a verify pass renders each recorded package at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reading {
    /// The revision each declaration resolves to now.
    Current,
    /// The commit the record names for it. The render agrees with that
    /// commit by construction, so [`record`] holds the commit itself to
    /// the history of the one its source resolves to now: a record cannot
    /// pick a commit its source never published on the declared revision,
    /// though a mirror fetches every ref the remote serves.
    Recorded,
}

impl Reading {
    /// The plan this reading renders through.
    pub fn plan_options(self) -> crate::engine::PlanOptions {
        match self {
            Reading::Current => crate::engine::PlanOptions::default(),
            Reading::Recorded => crate::engine::PlanOptions::at_record(),
        }
    }
}

/// Each repository source whose recorded commit is not the one the same
/// declaration resolves to now. A source recorded for another repository
/// or revision is not stale but a different declaration, which [`record`]
/// names.
pub fn stale(scope: &Scope, lock: &Lock, report: &EngineReport) -> Vec<Stale> {
    lock.sources
        .iter()
        .filter_map(|(name, recorded)| {
            let now = report.record.sources.get(name)?;
            (now.repo == recorded.repo && now.rev == recorded.rev && now.commit != recorded.commit)
                .then(|| Stale {
                    scope: scope.clone(),
                    source: name.clone(),
                    recorded: recorded.commit.clone(),
                    resolved: now.commit.clone(),
                })
        })
        .collect()
}

/// One bookkeeping file's standing: where it sits, and everything found
/// wrong with it. Empty `problems` is a file exactly as kendex writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Standing {
    pub path: PathBuf,
    pub problems: Vec<String>,
}

/// The committed inventory held to what this pass renders, or `None`
/// where the scope keeps none: a global scope, or a project the engine
/// has planned no inventory for and that has none.
///
/// The judge is the write the plan carries: the engine plans one exactly
/// where the file is not the document it would lay down, and that
/// decision is not made a second time here. The names are for the reader:
/// each path the file de-lists while the engine still renders it, and each
/// it lists that the engine does not, said as such.
pub fn inventory(scope: &Scope, report: &EngineReport) -> Result<Option<Standing>> {
    let Scope::Project { root } = scope else {
        return Ok(None);
    };
    let path = root.join(crate::engine::generated_paths::INVENTORY);
    let planned = report.plan.ops.iter().any(
        |planned| matches!(&planned.op, Op::WriteFile { path: written, .. } if *written == path),
    );
    let Some(text) = crate::fs::read_if_exists(&path)? else {
        return Ok(planned.then(|| Standing {
            path,
            problems: vec!["not written yet".to_owned()],
        }));
    };
    let mut problems = Vec::new();
    match serde_json::from_str::<BTreeSet<String>>(&text) {
        Ok(committed) => {
            let expected = report.generated.relative(root);
            problems.extend(
                expected
                    .difference(&committed)
                    .map(|path| format!("de-lists {path}, which this pass renders")),
            );
            problems.extend(
                committed
                    .difference(&expected)
                    .map(|path| format!("lists {path}, which this pass does not render")),
            );
        }
        Err(error) => problems.push(format!("not a JSON list of paths: {error}")),
    }
    if planned && problems.is_empty() {
        problems.push("not laid out as kendex writes it".to_owned());
    }
    Ok(Some(Standing { path, problems }))
}

/// The committed record held to what this pass would record, or `None`
/// where the scope has no record file at all — that absence is the
/// caller's own refusal, said where the record was looked for.
///
/// Four readings, each the engine's. The bytes are the serialization the
/// record writer lays down for the parsed record, so a hand-written key,
/// a hand-laid layout or a field this build does not carry is a
/// difference. A source or set served from the record's own commit is
/// named, because everything rendered from it was measured against a
/// commit the record chose; so is one the pass resolved nothing for,
/// because its entry was carried forward unread and a comparison with the
/// record would be the record against itself. Each entry the pass also
/// records is compared with the entry it would write, this machine's half
/// aside, in the record the pass computed whether or not its plan writes
/// one. The sources and sets are compared both ways: one recorded that
/// the pass records nothing for (undeclared, disabled, or read from a
/// path), and one the pass would record that the record does not carry,
/// are each named, so a provenance entry deleted by hand fails the row
/// as a planted one does. Each recorded commit
/// — an entry's source commit, a source's, a set's — must be the one the
/// declaration resolves to or on that commit's history in the mirror: an
/// honest record is behind a moving branch and stays honest, and a commit
/// the mirror never held is one no resolution produced. A mirror that
/// cannot answer for a commit is named as such, so the reader fetches it
/// rather than searching the record for an edit nobody made. Under
/// [`Reading::Recorded`] an entry's and a set's commit is also held to
/// the history of the commit its source resolves to now.
pub fn record(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    report: &EngineReport,
    reading: Reading,
) -> Result<Option<Standing>> {
    let path = crate::lock::lock_path(env, scope);
    let Some(text) = crate::fs::read_if_exists(&path)? else {
        return Ok(None);
    };
    let mut problems = Vec::new();
    if text != crate::lock::committed_text(&path, lock)? {
        problems.push("not laid out as kendex writes it".to_owned());
    }
    let stood_in = (report
        .stood_in
        .sources
        .iter()
        .map(|(name, why)| ("source", name, why)))
    .chain(
        report
            .stood_in
            .sets
            .iter()
            .map(|(name, why)| ("set", name, why)),
    );
    for (subject, name, why) in stood_in {
        problems.push(match why {
            StoodIn::RecordedCommit => format!(
                "{subject} {name}: the mirror cannot serve the declared revision, and the recorded commit stood in"
            ),
            StoodIn::Unserved => format!(
                "{subject} {name}: the mirror cannot serve the declared revision, so nothing holds the record to it — fetch it with kendex source refresh"
            ),
        });
    }
    let planned = &report.record;
    for (key, entry) in &lock.entries {
        // The key is what every reader looks an entry up by, and the
        // fields are what the entry says of itself; an entry the plan
        // copies from the record by kind and name carries an edited
        // harness through under its unchanged key, so the two are held
        // to each other before the plan is asked.
        if *key != crate::lock::entry_key(entry.kind, &entry.name, entry.harness) {
            problems.push(format!("{key}: not the entry it names"));
            continue;
        }
        let Some(would_record) = planned.entries.get(key) else {
            continue;
        };
        if let Some(field) = differs(entry, would_record) {
            problems.push(format!("{key}: {field} is not what this pass records"));
        }
        problems.extend(entry_commit_problem(env, key, entry, would_record));
        if let (Reading::Recorded, Some(commit)) = (reading, &entry.source_commit) {
            problems.extend(published_problem(
                env,
                &format!("{key}: sourceCommit {commit}"),
                commit,
                planned.sources.get(&entry.source),
            ));
        }
    }
    for (name, recorded) in &lock.sources {
        problems.extend(source_problem(
            env,
            name,
            recorded,
            planned.sources.get(name),
        ));
    }
    for name in planned.sources.keys() {
        if !lock.sources.contains_key(name) {
            problems.push(format!(
                "source {name}: declared, and the record does not carry it"
            ));
        }
    }
    for (name, recorded) in &lock.bundles {
        problems.extend(bundle_problem(
            env,
            name,
            recorded,
            planned.bundles.get(name),
        ));
        if reading == Reading::Recorded {
            problems.extend(published_problem(
                env,
                &format!("set {name}: commit {}", recorded.commit),
                &recorded.commit,
                planned.sources.get(&recorded.source),
            ));
        }
    }
    for name in planned.bundles.keys() {
        if !lock.bundles.contains_key(name) {
            problems.push(format!(
                "set {name}: declared, and the record does not carry it"
            ));
        }
    }
    Ok(Some(Standing { path, problems }))
}

/// The first field on which a recorded entry is not the one the pass
/// would record, named as the record spells it. Every field is
/// destructured so one added to the entry has to be placed here: in the
/// comparison, or beside those left out. The kind, name and harness are
/// the key, which [`record`] holds the entry to before it comes here, and
/// the planned entry under the same key spells them the same way. The
/// source commit is judged by history rather than equality, in
/// [`entry_commit_problem`], because a source's branch moves under an
/// honest record. This machine's half is never in the committed record.
fn differs(recorded: &LockEntry, would_record: &LockEntry) -> Option<&'static str> {
    let LockEntry {
        name: _,
        kind: _,
        harness: _,
        source,
        source_repo,
        source_hash,
        source_commit: _,
        rendered_hash,
        enabled,
        upstream_skills,
        emitted,
        registration,
        reasons,
        machine: _,
    } = recorded;
    [
        ("source", *source != would_record.source),
        ("sourceRepo", *source_repo != would_record.source_repo),
        ("sourceHash", *source_hash != would_record.source_hash),
        ("renderedHash", *rendered_hash != would_record.rendered_hash),
        ("enabled", *enabled != would_record.enabled),
        (
            "upstreamSkills",
            *upstream_skills != would_record.upstream_skills,
        ),
        ("emitted", *emitted != would_record.emitted),
        ("registration", *registration != would_record.registration),
        ("reasons", *reasons != would_record.reasons),
    ]
    .into_iter()
    .find_map(|(field, moved)| moved.then_some(field))
}

/// The recorded entry's source commit held to the one the pass resolved:
/// equal, or on its history in the mirror of the repository the pass
/// rendered the entry from, which the entry it would write names as its
/// `sourceRepo` — the same provenance the source's own revision carries,
/// so no lookup by source name stands between the entry and its mirror.
/// A commit on one side only is a field this pass does not record, or
/// one it records that the entry lacks, and is named as the record spells
/// it.
fn entry_commit_problem(
    env: &Env,
    key: &str,
    recorded: &LockEntry,
    would_record: &LockEntry,
) -> Option<String> {
    let (recorded_commit, resolved) = match (&recorded.source_commit, &would_record.source_commit) {
        (None, None) => return None,
        (Some(recorded), Some(resolved)) if recorded == resolved => return None,
        (Some(recorded), Some(resolved)) => (recorded, resolved),
        (None, Some(_)) | (Some(_), None) => {
            return Some(format!("{key}: sourceCommit is not what this pass records"));
        }
    };
    history_problem(
        env,
        &would_record.source_repo,
        recorded_commit,
        resolved,
        &format!("{key}: sourceCommit {recorded_commit}"),
    )
}

fn source_problem(
    env: &Env,
    name: &str,
    recorded: &SourceRev,
    declared: Option<&SourceRev>,
) -> Option<String> {
    let Some(declared) = declared else {
        return Some(format!(
            "source {name}: recorded, and the manifest declares no enabled repository source by that name"
        ));
    };
    if recorded.repo != declared.repo || recorded.rev != declared.rev {
        return Some(format!(
            "source {name}: recorded for {} at {}, declared as {} at {}",
            recorded.repo,
            selector(recorded.rev.as_deref()),
            declared.repo,
            selector(declared.rev.as_deref()),
        ));
    }
    history_problem(
        env,
        &declared.repo,
        &recorded.commit,
        &declared.commit,
        &format!("source {name}: commit {}", recorded.commit),
    )
}

fn bundle_problem(
    env: &Env,
    name: &str,
    recorded: &BundleRev,
    declared: Option<&BundleRev>,
) -> Option<String> {
    let Some(declared) = declared else {
        return Some(format!(
            "set {name}: recorded, and the manifest declares no such set from an enabled repository source"
        ));
    };
    if recorded.source != declared.source || recorded.source_repo != declared.source_repo {
        return Some(format!(
            "set {name}: recorded from {} ({}), declared from {} ({})",
            recorded.source, recorded.source_repo, declared.source, declared.source_repo
        ));
    }
    history_problem(
        env,
        &declared.source_repo,
        &recorded.commit,
        &declared.commit,
        &format!("set {name}: commit {}", recorded.commit),
    )
}

/// A commit a held pass rendered at, held to the history of the commit
/// its source resolves to now. A source this pass resolved nothing for
/// leaves nothing to hold the commit to, which is named rather than
/// passed.
fn published_problem(
    env: &Env,
    subject: &str,
    recorded: &str,
    source: Option<&SourceRev>,
) -> Option<String> {
    let Some(source) = source else {
        return Some(format!(
            "{subject}: its source resolved to nothing this pass could hold the commit to"
        ));
    };
    history_problem(env, &source.repo, recorded, &source.commit, subject)
}

fn selector(rev: Option<&str>) -> &str {
    rev.unwrap_or("the source's own revision")
}

/// The sentence that fails a recorded commit, after `subject` names it:
/// one that is no commit pin, one off the declared revision's history,
/// or one the mirror cannot place. Equal commits are answered without a
/// git call, which is also the only answer a path source ever needs; the
/// rest is the mirror this declaration fetches into, asked through
/// [`crate::remote::store::is_ancestor`]. Only a pin is asked about: git
/// reads any revision expression the record could be edited to hold,
/// and `HEAD` names the declared tip itself, so the ancestry answer for
/// a value that is not a pin would vouch for the edit.
fn history_problem(
    env: &Env,
    repo: &str,
    recorded: &str,
    resolved: &str,
    subject: &str,
) -> Option<String> {
    if recorded == resolved {
        return None;
    }
    if !crate::remote::store::is_pin(recorded) {
        return Some(format!("{subject} is not a commit pin"));
    }
    let key = crate::remote::cache_key(env, repo);
    let mirror = crate::remote::store::mirror_dir(env, &key);
    match crate::remote::store::is_ancestor(&mirror, recorded, resolved) {
        Some(true) => None,
        Some(false) => Some(format!(
            "{subject} is not on the declared revision's history"
        )),
        None => Some(format!(
            "{subject} cannot be placed: the mirror of {repo} does not answer for it — fetch it with kendex source refresh"
        )),
    }
}

/// For each shared file this pass writes keys in, whether the rest of that
/// file is as revision `rev` of the project held it.
///
/// The file as the revision held it — nothing, where it had none — with
/// every edit this pass plans for it applied in turn, is compared byte for
/// byte with the file on disk. Equal, every difference between the two
/// copies is one of kendex's edits. The edits are the writer's own
/// sequence, [`crate::engine::edit_sequence`] read against the record and
/// the files as the revision held them, registration by registration in
/// the order the pass walks them and the shims after, so a file two
/// registrations write is judged once, with both, its keys come out the
/// way round the writer put them, and an entry the writer moved since is
/// retired first as the writer retired it. The files are every `keys`
/// position the pass prints: each registration's edit targets and each
/// instruction shim that is an edit, read off the same standings `verify`
/// prints rows for, so no position is printed as keys with nothing here
/// to judge it. A revision that does not resolve, or whose record this
/// build cannot read, answers `Unknown` for every file rather than reading
/// an absent copy as an empty one or a moved entry as never moved.
pub fn foreign_since(root: &Path, rev: &str, report: &EngineReport) -> BTreeMap<PathBuf, Foreign> {
    let base = Base { root, rev };
    let resolves = matches!(
        crate::commit_offer::git::read(
            root,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{rev}^{{commit}}")
            ]
        ),
        Ok(Some(_))
    );
    let record = resolves.then(|| base.record()).flatten();
    let previous = |key: &str| match &record {
        Some(BaseRecord::Held(lock)) => lock
            .entries
            .get(key)
            .and_then(|entry| entry.registration.as_ref()),
        Some(BaseRecord::Absent) | None => None,
    };
    let document = |path: &Path| match record.is_some().then(|| base.copy(path)) {
        Some(BaseCopy::Held(text)) => Some(text),
        Some(BaseCopy::Absent | BaseCopy::Unreadable) | None => None,
    };
    let mut by_file: BTreeMap<PathBuf, Vec<crate::configedit::ConfigEdit>> = BTreeMap::new();
    for (key, edits) in &report.registrations {
        for (path, edit) in crate::engine::edit_sequence(edits, previous(key), &document) {
            by_file.entry(path).or_default().push(edit);
        }
    }
    for shim in &report.instruction_shims {
        if let Some(edit) = shim.edit() {
            by_file.entry(shim.path.clone()).or_default().push(edit);
        }
    }
    by_file
        .into_iter()
        .map(|(path, edits)| {
            let standing = record
                .is_some()
                .then(|| foreign_of(&base, &path, &edits))
                .flatten()
                .unwrap_or(Foreign::Unknown);
            (path, standing)
        })
        .collect()
}

/// The project as one revision held it, read through git for the replay.
struct Base<'a> {
    root: &'a Path,
    rev: &'a str,
}

/// One file as the revision held it.
enum BaseCopy {
    Held(String),
    /// The revision had no such file.
    Absent,
    /// Git could not answer, or the bytes are not text.
    Unreadable,
}

/// The record as the revision held it, which names what each registration
/// was written under then. Read as the head's record is read, so a record
/// another lock version wrote is one this build cannot read here too: a
/// field the other shape lacks is a wrong answer rather than a missing
/// one, and a replay over it would vouch for files it never judged.
enum BaseRecord {
    Held(Lock),
    /// The revision had no record: nothing of kendex's was there to move.
    Absent,
}

impl Base<'_> {
    fn copy(&self, path: &Path) -> BaseCopy {
        let Ok(relative) = path.strip_prefix(self.root) else {
            return BaseCopy::Unreadable;
        };
        let spec = format!("{}:./{}", self.rev, crate::paths::slashed(relative));
        match crate::commit_offer::git::read(self.root, &["show", &spec]) {
            Ok(Some(bytes)) => match String::from_utf8(bytes) {
                Ok(text) => BaseCopy::Held(text),
                Err(_) => BaseCopy::Unreadable,
            },
            Ok(None) => BaseCopy::Absent,
            Err(_) => BaseCopy::Unreadable,
        }
    }

    /// `None` where the record is there and this build cannot read it.
    fn record(&self) -> Option<BaseRecord> {
        let path = self.root.join(LOCK_FILE);
        match self.copy(&path) {
            BaseCopy::Held(text) => crate::lock::parse_text(&path, &text)
                .ok()
                .map(BaseRecord::Held),
            BaseCopy::Absent => Some(BaseRecord::Absent),
            BaseCopy::Unreadable => None,
        }
    }
}

fn foreign_of(
    base: &Base,
    path: &Path,
    edits: &[crate::configedit::ConfigEdit],
) -> Option<Foreign> {
    let text = match base.copy(path) {
        BaseCopy::Held(text) => text,
        BaseCopy::Absent => String::new(),
        BaseCopy::Unreadable => return None,
    };
    let head = crate::fs::read_if_exists(path).ok()?.unwrap_or_default();
    let applied = edits
        .iter()
        .try_fold(text, |text, edit| edit.apply(&text))
        .ok()?;
    Some(match applied == head {
        true => Foreign::Unchanged,
        false => Foreign::Changed,
    })
}
