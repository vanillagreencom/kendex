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
use crate::engine::{EngineReport, planned_record};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{BundleRev, Lock, LockEntry, SourceRev};
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

/// The whole document: the rows, the closing counts, and whether the run
/// closed clean, which is its exit status as a field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    pub version: u32,
    pub clean: bool,
    pub checked: usize,
    pub failed: usize,
    pub rows: Vec<Row>,
}

impl Document {
    pub fn new(clean: bool, checked: usize, failed: usize, rows: Vec<Row>) -> Document {
        Document {
            version: DOCUMENT_VERSION,
            clean,
            checked,
            failed,
            rows,
        }
    }
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
/// difference. A source served from the record's own commit is named,
/// because everything rendered from it was measured against a commit the
/// record chose. Each entry the pass also records is compared with the
/// entry it would write, the commit cache and this machine's half aside.
/// Each recorded source and set is compared with the declaration it is
/// recorded for, and its commit must be the one the declaration resolves
/// to or on that commit's history in the mirror: an honest record is
/// behind a moving branch and stays honest, and a commit the mirror never
/// held is one no resolution produced.
pub fn record(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    report: &EngineReport,
) -> Result<Option<Standing>> {
    let path = crate::lock::lock_path(env, scope);
    let Some(text) = crate::fs::read_if_exists(&path)? else {
        return Ok(None);
    };
    let mut problems = Vec::new();
    if text != crate::lock::committed_text(&path, lock)? {
        problems.push("not laid out as kendex writes it".to_owned());
    }
    for name in &report.sources_from_record {
        problems.push(format!(
            "source {name}: the mirror cannot serve the declared revision, and the recorded commit stood in"
        ));
    }
    let planned = planned_record(report).unwrap_or_else(|| lock.clone());
    for (key, entry) in &lock.entries {
        let Some(would_record) = planned.entries.get(key) else {
            continue;
        };
        if let Some(field) = differs(entry, would_record) {
            problems.push(format!("{key}: {field} is not what this pass records"));
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
    for (name, recorded) in &lock.bundles {
        problems.extend(bundle_problem(
            env,
            name,
            recorded,
            planned.bundles.get(name),
        ));
    }
    Ok(Some(Standing { path, problems }))
}

/// The first field on which a recorded entry is not the one the pass
/// would record, named as the record spells it. The commit cache is left
/// out: a source's branch moves under an honest record, and the entry's
/// bytes are what the drift rows compare. This machine's half is never in
/// the committed record.
fn differs(recorded: &LockEntry, would_record: &LockEntry) -> Option<&'static str> {
    [
        ("source", recorded.source != would_record.source),
        (
            "sourceRepo",
            recorded.source_repo != would_record.source_repo,
        ),
        (
            "sourceHash",
            recorded.source_hash != would_record.source_hash,
        ),
        (
            "renderedHash",
            recorded.rendered_hash != would_record.rendered_hash,
        ),
        ("enabled", recorded.enabled != would_record.enabled),
        (
            "upstreamSkills",
            recorded.upstream_skills != would_record.upstream_skills,
        ),
        ("emitted", recorded.emitted != would_record.emitted),
        (
            "registration",
            recorded.registration != would_record.registration,
        ),
        ("reasons", recorded.reasons != would_record.reasons),
    ]
    .into_iter()
    .find_map(|(field, moved)| moved.then_some(field))
}

fn source_problem(
    env: &Env,
    name: &str,
    recorded: &SourceRev,
    declared: Option<&SourceRev>,
) -> Option<String> {
    let Some(declared) = declared else {
        return Some(format!(
            "source {name}: recorded, and the manifest declares no such source"
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
    on_history(env, &declared.repo, &recorded.commit, &declared.commit)
        .then_some(())
        .map_or_else(
            || {
                Some(format!(
                    "source {name}: commit {} is not on the declared revision's history",
                    recorded.commit
                ))
            },
            |()| None,
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
            "set {name}: recorded, and the manifest declares no such set"
        ));
    };
    if recorded.source != declared.source || recorded.source_repo != declared.source_repo {
        return Some(format!(
            "set {name}: recorded from {} ({}), declared from {} ({})",
            recorded.source, recorded.source_repo, declared.source, declared.source_repo
        ));
    }
    on_history(
        env,
        &declared.source_repo,
        &recorded.commit,
        &declared.commit,
    )
    .then_some(())
    .map_or_else(
        || {
            Some(format!(
                "set {name}: commit {} is not on the declared revision's history",
                recorded.commit
            ))
        },
        |()| None,
    )
}

fn selector(rev: Option<&str>) -> &str {
    rev.unwrap_or("the source's own revision")
}

/// Whether `recorded` is `resolved` or on its history in the mirror this
/// declaration fetches into. Equal commits are answered without a git
/// call, which is also the only answer a path source ever needs.
fn on_history(env: &Env, repo: &str, recorded: &str, resolved: &str) -> bool {
    if recorded == resolved {
        return true;
    }
    let key = crate::remote::cache_key(env, repo);
    let mirror = crate::remote::store::mirror_dir(env, &key);
    crate::remote::store::is_ancestor(&mirror, recorded, resolved)
}

/// For each shared file this pass writes keys in, whether the rest of that
/// file is as revision `rev` of the project held it.
///
/// The file as the revision held it — nothing, where it had none — with
/// every edit this pass plans for it applied in turn, is compared byte for
/// byte with the file on disk. Equal, every difference between the two
/// copies is one of kendex's edits. The edits are the plan's own list, so
/// a file two registrations write is judged once, with both. A revision
/// that does not resolve answers `Unknown` for every file rather than
/// reading an absent copy as an empty one.
pub fn foreign_since(root: &Path, rev: &str, report: &EngineReport) -> BTreeMap<PathBuf, Foreign> {
    let mut by_file: BTreeMap<PathBuf, Vec<&crate::configedit::ConfigEdit>> = BTreeMap::new();
    for edits in report.registrations.values() {
        for (path, edit) in edits {
            by_file.entry(path.clone()).or_default().push(edit);
        }
    }
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
    by_file
        .into_iter()
        .map(|(path, edits)| {
            let standing = resolves
                .then(|| foreign_of(root, rev, &path, &edits))
                .flatten()
                .unwrap_or(Foreign::Unknown);
            (path, standing)
        })
        .collect()
}

fn foreign_of(
    root: &Path,
    rev: &str,
    path: &Path,
    edits: &[&crate::configedit::ConfigEdit],
) -> Option<Foreign> {
    let relative = path.strip_prefix(root).ok()?;
    let spec = format!("{rev}:./{}", crate::paths::slashed(relative));
    let base = match crate::commit_offer::git::read(root, &["show", &spec]) {
        Ok(Some(bytes)) => String::from_utf8(bytes).ok()?,
        Ok(None) => String::new(),
        Err(_) => return None,
    };
    let head = crate::fs::read_if_exists(path).ok()?.unwrap_or_default();
    let applied = edits
        .iter()
        .try_fold(base, |text, edit| edit.apply(&text))
        .ok()?;
    Some(match applied == head {
        true => Foreign::Unchanged,
        false => Foreign::Changed,
    })
}
