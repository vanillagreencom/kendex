//! The verdicts on declarations sitting on files no record accounts for,
//! paid for once per state and read cheaply after: the one deep read the
//! session check makes, memoized beside the drift snapshot.
//!
//! The plan is the judge and it costs a whole scope; the state it judges
//! moves rarely — a copy is edited, a source is fetched, a declaration
//! changes. So each occupied installation's verdict is kept under a key
//! of exactly those inputs (the manifest, the record's entry for it,
//! every position it would take as the comparison reads it, and the
//! fetch state of its source's mirror), and the plan runs again only
//! when one of them moves. A run inside the session hook has one
//! deadline for every scope the check covers; a pass that outruns it is
//! finished by the detached background refresh, which writes the same
//! file for the next session to read.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::engine::{Measured, Occupied, UnmanagedCopies};
use crate::env::Env;
use crate::error::Result;
use crate::fs::{atomic_write, read_if_exists};
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::Scope;

/// Bumped when the shape changes; an older or newer file reads as absent,
/// which costs one plan.
pub const MEMO_SCHEMA: u32 = 1;

/// The memoized verdicts of one scope. Retired by every record write
/// (`apply::execute`), since what a plan proved it proved against the
/// record as it stood.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Memo {
    pub schema: u32,
    /// What the last plan proved and can record on its own, occupied or
    /// not: bound to each file's hash at the write, so an entry here that
    /// moved since refuses the record and costs one plan.
    pub proven: Lock,
    /// One verdict per occupied installation, by lock entry key, with the
    /// key of the inputs it was measured under.
    pub entries: BTreeMap<String, Memoed>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Memoed {
    pub inputs: String,
    #[serde(flatten)]
    pub measured: Measured,
}

/// One occupied installation as the check reports it.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// The render byte for byte, and now recorded as installed.
    Recorded,
    /// Not the render, by the count; `take_over_settles` says whether the
    /// scope-wide take-over is its fix or the plan is what to see next.
    Differs {
        files: u32,
        rendered_from: String,
        take_over_settles: bool,
    },
    /// What sits at the position would not read: the plan's own reason.
    Uncompared { reason: String },
    /// Left as the stat found it, with the plan as what to see next.
    Left,
}

/// What settling a scope's occupied installations came to.
#[derive(Debug)]
pub enum Settled {
    /// Every occupied installation judged. `record_failed` carries why
    /// the record write for the proven copies failed, when it did; those
    /// copies then read as left, since nothing was recorded.
    Judged {
        verdicts: BTreeMap<String, Verdict>,
        record_failed: Option<String>,
    },
    /// The plan did not finish inside the budget the session hook allows,
    /// one deadline over every scope the check covers; the plan is still
    /// owed, and the check's caller decides who finishes it.
    Overrun { budget: Duration },
    /// The plan could not be produced at all.
    Failed(String),
}

pub fn memo_path(env: &Env, scope: &Scope) -> PathBuf {
    let label = scope.canonical().label();
    let digest = &crate::hash::hash_bytes(label.as_bytes())[..16];
    env.drift_dir().join(format!("{digest}-copies.json"))
}

/// The memo, or `None` where there is none this build reads: a missing,
/// corrupt or other-schema file costs one plan, never a wrong verdict.
pub fn load(env: &Env, scope: &Scope) -> Option<Memo> {
    let text = read_if_exists(&memo_path(env, scope)).ok()??;
    serde_json::from_str::<Memo>(&text)
        .ok()
        .filter(|memo| memo.schema == MEMO_SCHEMA)
}

fn store(env: &Env, scope: &Scope, memo: &Memo) -> Result<()> {
    let mut text = serde_json::to_string_pretty(memo).unwrap_or_default();
    text.push('\n');
    atomic_write(&memo_path(env, scope), &text)
}

/// Drop the scope's memo: the next check plans again.
pub fn invalidate(env: &Env, scope: &Scope) -> Result<()> {
    match std::fs::remove_file(memo_path(env, scope)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(crate::error::CoreError::io(memo_path(env, scope), error)),
    }
}

/// The inputs one installation's verdict depends on, as one digest: the
/// manifest as declared, the record's entry for it if any, every position
/// it would take as the comparison reads it, and the fetch state of its
/// source's mirror where the source is a repository. A path source has
/// no fetch state, so a path source that moved is read at the next plan
/// something else provokes — the same reading the drift snapshot gives a
/// path source's packages.
fn inputs(
    env: &Env,
    manifest: &Manifest,
    manifest_digest: &str,
    lock: &Lock,
    key: &str,
    occupied: &Occupied,
) -> String {
    let mut parts = vec![
        manifest_digest.to_owned(),
        serde_json::to_string(&lock.entries.get(key)).unwrap_or_default(),
    ];
    for position in &occupied.positions {
        parts.push(crate::paths::slashed(position));
        parts.push(position_signature(position));
    }
    if let Some(repo) = manifest
        .sources
        .get(&occupied.source)
        .and_then(|decl| decl.repo.as_deref())
    {
        let stamp = super::stamps::load(env, &crate::remote::cache_key(env, repo));
        parts.push(stamp.refs_state.unwrap_or_default());
    }
    crate::hash::hash_bytes(parts.join("\n").as_bytes())
}

/// A position as the comparison reads it, through the one bounded walk
/// the plan itself makes (`engine::position_digest`); where that walk
/// refuses — a link, an entry that will not read, a tree past its bounds
/// — the refusal is keyed by what sits at the top: absent, a link and its
/// target, or the kind and the error, so the verdict for a position that
/// will not read holds until the read is fixed.
fn position_signature(path: &Path) -> String {
    if let Some(digest) = crate::engine::position_digest(path) {
        return digest;
    }
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => "absent".to_owned(),
        Err(error) => format!("unreadable ({error})"),
        Ok(meta) if meta.file_type().is_symlink() => match std::fs::read_link(path) {
            Ok(target) => format!("link {}", crate::paths::slashed(&target)),
            Err(error) => format!("link unreadable ({error})"),
        },
        Ok(meta) => format!("refused {:?}", meta.file_type()),
    }
}

fn manifest_digest(manifest: &Manifest) -> String {
    crate::hash::hash_bytes(&serde_json::to_vec(manifest).unwrap_or_default())
}

/// The key of every occupied installation, by lock entry key.
fn keys(
    env: &Env,
    manifest: &Manifest,
    lock: &Lock,
    occupied: &BTreeMap<String, Occupied>,
) -> BTreeMap<String, String> {
    let digest = manifest_digest(manifest);
    occupied
        .iter()
        .map(|(key, install)| {
            (
                key.clone(),
                inputs(env, manifest, &digest, lock, key, install),
            )
        })
        .collect()
}

/// The memoized verdicts, where the memo holds every occupied
/// installation under its current inputs.
fn memoized(memo: Option<Memo>, keys: &BTreeMap<String, String>) -> Option<UnmanagedCopies> {
    let memo = memo?;
    let mut measured = BTreeMap::new();
    for (key, inputs) in keys {
        let memoed = memo.entries.get(key)?;
        if &memoed.inputs != inputs {
            return None;
        }
        measured.insert(key.clone(), memoed.measured.clone());
    }
    Some(UnmanagedCopies {
        measured,
        proven: memo.proven,
    })
}

fn memo_of(keys: &BTreeMap<String, String>, copies: &UnmanagedCopies) -> Memo {
    Memo {
        schema: MEMO_SCHEMA,
        proven: copies.proven.clone(),
        entries: keys
            .iter()
            .filter_map(|(key, inputs)| {
                copies.measured.get(key).map(|measured| {
                    (
                        key.clone(),
                        Memoed {
                            inputs: inputs.clone(),
                            measured: measured.clone(),
                        },
                    )
                })
            })
            .collect(),
    }
}

/// The plan over the scope's occupied installations, unbudgeted, and its
/// memo for the next check to read — the background refresh's half. A
/// scope with nothing occupied writes nothing. Nothing is recorded here:
/// the record write is the check's, so the session that reads the memo
/// is the one that says what it did.
pub fn derive(env: &Env, scope: &Scope) -> Result<()> {
    let Ok(crate::manifest::ManifestFile::Current(manifest)) =
        crate::manifest::load(&crate::manifest::manifest_path(env, scope))
    else {
        return Ok(());
    };
    let lock = disk_lock(env, scope)?;
    let occupied = crate::engine::declared_over_existing_files(env, scope, &manifest, &lock);
    if occupied.is_empty() {
        return Ok(());
    }
    let keys = keys(env, &manifest, &lock, &occupied);
    if memoized(load(env, scope), &keys).is_some() {
        return Ok(());
    }
    let copies = crate::engine::compare_unmanaged_copies(env, scope, &manifest, &lock, &occupied)?;
    store(env, scope, &memo_of(&keys, &copies))
}

/// An absent record reads as empty: the state this module reports on most
/// often is a repository declaring what another tool already put on disk.
fn disk_lock(env: &Env, scope: &Scope) -> Result<Lock> {
    Ok(
        match crate::lock::load_file(&crate::lock::lock_path(env, scope))? {
            crate::lock::LockFile::Current(lock) => lock,
            crate::lock::LockFile::Absent => Lock::default(),
        },
    )
}

/// Judge every occupied installation and record the proven copies: the
/// memo where it answers for all of them, else one plan, memoized for
/// the next check. Every read this makes — the keys, the plan, the hashes
/// the record write binds to — runs against `deadline`, one instant for
/// every scope of one check, so however many scopes are occupied the
/// check as a whole gives up at that instant; `budget` is what the
/// deadline was set from, for the line that names it. The record write
/// is bound to each proven file's hash, so a copy that moved since the
/// plan refuses the record rather than misfiling the change — and moves
/// the key, so the next check plans again.
pub fn settle(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    occupied: &BTreeMap<String, Occupied>,
    deadline: Instant,
    budget: Duration,
) -> Settled {
    let keys = keys(env, manifest, lock, occupied);
    let copies = match memoized(load(env, scope), &keys) {
        Some(copies) => copies,
        None => {
            let planned = {
                let (env, scope, manifest, lock, occupied) = (
                    env.clone(),
                    scope.clone(),
                    manifest.clone(),
                    lock.clone(),
                    occupied.clone(),
                );
                within(deadline, move || {
                    crate::engine::compare_unmanaged_copies(
                        &env, &scope, &manifest, &lock, &occupied,
                    )
                })
            };
            match planned {
                Some(Ok(copies)) => {
                    // A memo that will not write costs the next check one
                    // plan; the verdicts in hand are still this check's.
                    let _ = store(env, scope, &memo_of(&keys, &copies));
                    copies
                }
                Some(Err(error)) => return Settled::Failed(error.to_string()),
                None => return Settled::Overrun { budget },
            }
        }
    };
    // The write binds to every proven file's hash, a read of its own that
    // the deadline covers like the plan where there is anything to bind;
    // the write itself is journaled and runs to its end.
    let record = match copies.proven.entries.is_empty() {
        true => Some(Ok(None)),
        false => {
            let (env, scope, manifest, lock, copies) = (
                env.clone(),
                scope.clone(),
                manifest.clone(),
                lock.clone(),
                copies.clone(),
            );
            within(deadline, move || {
                crate::engine::claim_plan(&env, &scope, &manifest, &lock, &copies)
            })
        }
    };
    let Some(record) = record else {
        return Settled::Overrun { budget };
    };
    let record = record.and_then(|record| {
        record
            .map(|record| crate::apply::execute(env, &record))
            .transpose()
    });
    let (recorded, record_failed) = match record {
        Ok(Some(_)) => {
            // The record write retired the memo, as every record write
            // does; the verdicts in hand still stand for the copies the
            // record did not gain, so they are kept for the next check
            // with nothing left to prove.
            let settled = UnmanagedCopies {
                measured: copies.measured.clone(),
                proven: Lock::default(),
            };
            let _ = store(env, scope, &memo_of(&keys, &settled));
            (true, None)
        }
        Ok(None) => (false, None),
        // Evidence that moved under the memo — a proven file a stat never
        // saw, a hook's script, edited since the plan — is re-measured by
        // the next check; a record that will not write is not, since the
        // verdicts stand and only the write is owed.
        Err(error @ crate::error::CoreError::PlanStale { .. }) => {
            let _ = invalidate(env, scope);
            (false, Some(error.to_string()))
        }
        Err(error) => (false, Some(error.to_string())),
    };
    let verdicts = copies
        .measured
        .into_iter()
        .map(|(key, measured)| {
            let verdict = match measured {
                Measured::Proven if recorded => Verdict::Recorded,
                Measured::Proven => Verdict::Left,
                Measured::Differs {
                    files,
                    rendered_from,
                    take_over_settles,
                } => Verdict::Differs {
                    files,
                    rendered_from,
                    take_over_settles,
                },
                Measured::Uncompared { reason } => Verdict::Uncompared { reason },
                Measured::Left => Verdict::Left,
            };
            (key, verdict)
        })
        .collect();
    Settled::Judged {
        verdicts,
        record_failed,
    }
}

/// Run `work` on its own thread and wait for it until `deadline`. `None`
/// when the deadline passed, or had passed already, in which case nothing
/// is started: the thread is left to finish on its own, and the process
/// it lives in ends before it does — the session hook's check exits on
/// its verdict, and the same work is the background refresh's to finish.
/// A thread that dies without answering reads as having answered nothing.
fn within<T: Send + 'static>(
    deadline: Instant,
    work: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return None;
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(work());
    });
    receiver.recv_timeout(remaining).ok()
}
