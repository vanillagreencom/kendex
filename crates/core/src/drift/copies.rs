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
pub const MEMO_SCHEMA: u32 = 2;

/// The memoized verdicts of one scope. Retired by every record write
/// (`apply::execute`), since what a plan proved it proved against the
/// record as it stood.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Memo {
    pub schema: u32,
    /// What the last plan proved and can record on its own, occupied or
    /// not: bound to each file's hash at the write, so an entry here that
    /// moved or vanished since refuses the record and costs one plan.
    pub proven: Lock,
    /// The settings edits the plan held in place for each proven entry
    /// that registers one, held in place again at the write: a
    /// registration taken out since refuses the record the same way.
    pub registrations: crate::engine::Registrations,
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

/// Every position read for a key, counted so a test can hold that a
/// deadline already past reads none: the one observation the gate's
/// start rule leaves, since a thread that should not have started
/// leaves no other trace.
#[cfg(test)]
static POSITIONS_READ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// A position as the comparison reads it, through the one bounded walk
/// the plan itself makes (`engine::position_digest`); where that walk
/// refuses — a link, an entry that will not read, a tree past its bounds
/// — the refusal is keyed by what sits at the top: absent, a link and its
/// target, or the kind and the error, so the verdict for a position that
/// will not read holds until the read is fixed.
fn position_signature(path: &Path) -> String {
    #[cfg(test)]
    POSITIONS_READ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
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
        registrations: memo.registrations,
    })
}

fn memo_of(keys: &BTreeMap<String, String>, copies: &UnmanagedCopies) -> Memo {
    Memo {
        schema: MEMO_SCHEMA,
        proven: copies.proven.clone(),
        registrations: copies.registrations.clone(),
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

/// What the gated thread hands back, stage by stage: the verdicts as
/// soon as they are in hand — read off the memo or measured by the plan —
/// and then the record write bound to every proven file's hash. Two
/// stages so a deadline that runs out during the binding still leaves
/// the verdicts with the check that asked.
enum Stage {
    Judged {
        keys: BTreeMap<String, String>,
        copies: UnmanagedCopies,
        /// Measured by this plan rather than read off the memo, so the
        /// memo is owed the verdicts.
        fresh: bool,
    },
    Bound(Result<Option<crate::apply::Plan>>),
    Failed(String),
}

/// Judge every occupied installation and record the proven copies: the
/// memo where it answers for all of them, else one plan, memoized for
/// the next check. Every judgement read this makes — the keys that read
/// each position, the memo lookup, the plan, the hashes the record write
/// binds to — runs on the one thread [`gated`] starts, so no judgement
/// reads outside `deadline` by construction: one instant for every scope
/// of one check, so however many scopes are occupied the check as a
/// whole gives up at that instant; `budget` is what the deadline was set
/// from, for the line that names it. The record write is bound to each
/// proven file's hash, so a copy that moved since the plan refuses the
/// record rather than misfiling the change — and moves the key, so the
/// next check plans again. That write revalidates its own preconditions
/// on the main thread, a warm re-hash of the proven set the apply's
/// journal owes every write (invariant 7): the one read past the gate,
/// made only after the binding fit the deadline, and gone once the
/// record holds the copies.
pub fn settle(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    occupied: &BTreeMap<String, Occupied>,
    deadline: Instant,
    budget: Duration,
) -> Settled {
    let stages = {
        let (env, scope, manifest, lock, occupied) = (
            env.clone(),
            scope.clone(),
            manifest.clone(),
            lock.clone(),
            occupied.clone(),
        );
        gated(deadline, move |sender| {
            let keys = keys(&env, &manifest, &lock, &occupied);
            let (copies, fresh) = match memoized(load(&env, &scope), &keys) {
                Some(copies) => (copies, false),
                None => match crate::engine::compare_unmanaged_copies(
                    &env, &scope, &manifest, &lock, &occupied,
                ) {
                    Ok(copies) => (copies, true),
                    Err(error) => {
                        let _ = sender.send(Stage::Failed(error.to_string()));
                        return;
                    }
                },
            };
            let _ = sender.send(Stage::Judged {
                keys,
                copies: copies.clone(),
                fresh,
            });
            let record = match copies.proven.entries.is_empty() {
                true => Ok(None),
                false => crate::engine::claim_plan(&env, &scope, &manifest, &lock, &copies),
            };
            let _ = sender.send(Stage::Bound(record));
        })
    };
    resolve(env, scope, stages, deadline, budget)
}

/// What the stages the gate hands back come to: the verdicts, the record
/// write executed where the binding arrived in time, and the memo kept
/// current with both. Everything here is a write or a wait; every
/// judgement read happened on the gated thread, and the write's own
/// precondition revalidation is the apply's.
fn resolve(
    env: &Env,
    scope: &Scope,
    stages: Stages,
    deadline: Instant,
    budget: Duration,
) -> Settled {
    let (keys, copies) = match stages.next(deadline) {
        Some(Stage::Judged {
            keys,
            copies,
            fresh,
        }) => {
            if fresh {
                // A memo that will not write costs the next check one
                // plan; the verdicts in hand are still this check's.
                let _ = store(env, scope, &memo_of(&keys, &copies));
            }
            (keys, copies)
        }
        Some(Stage::Failed(error)) => return Settled::Failed(error),
        Some(Stage::Bound(_)) => unreachable!("the verdicts are sent before the binding"),
        None => return Settled::Overrun { budget },
    };
    // The verdicts are in hand from here: a binding the deadline cuts
    // short costs this check the record write and nothing else — the
    // copies it would have recorded stand as the stat found them, and the
    // next check binds again off the memo — never the lines it can print.
    let record = match stages.next(deadline) {
        Some(Stage::Bound(record)) => record.and_then(|record| {
            record
                .map(|record| crate::apply::execute(env, &record))
                .transpose()
        }),
        Some(Stage::Judged { .. }) => unreachable!("the verdicts are sent once"),
        Some(Stage::Failed(error)) => unreachable!("a failure ends the thread: {error}"),
        None => Err(crate::error::CoreError::io(
            crate::lock::lock_path(env, scope),
            std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!(
                    "binding the record to the files it proves did not fit inside the {} s the session hook allows",
                    budget.as_secs()
                ),
            ),
        )),
    };
    let (recorded, record_failed) = match record {
        Ok(Some(_)) => {
            // The record write retired the memo, as every record write
            // does; the verdicts in hand still stand for the copies the
            // record did not gain, so they are kept for the next check
            // with nothing left to prove. A copy the record gained is not
            // kept: its verdict sits under the key of the lock as it stood
            // before the write, so a lock removed after the claim — a
            // checkout to the branch that lacks it — would hit the memo
            // with nothing left to record and read the copy as blocked at
            // every check, where a plan proves and records it again.
            let settled = UnmanagedCopies {
                measured: copies
                    .measured
                    .iter()
                    .filter(|(_, measured)| !matches!(measured, Measured::Proven))
                    .map(|(key, measured)| (key.clone(), measured.clone()))
                    .collect(),
                proven: Lock::default(),
                registrations: Default::default(),
            };
            let _ = store(env, scope, &memo_of(&keys, &settled));
            (true, None)
        }
        Ok(None) => (false, None),
        // Evidence that moved under the memo — a proven file a stat never
        // saw, a hook's script, edited since the plan, or a proven
        // registration's settings file taken out of sync or out of
        // shape — is re-measured by the next check; a record that will
        // not write is not, since the verdicts stand and only the write
        // is owed.
        Err(
            error @ (crate::error::CoreError::PlanStale { .. }
            | crate::error::CoreError::ConfigEdit { .. }),
        ) => {
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

/// The one gate every judgement read of a scope's check passes through:
/// `work` runs on its own thread and hands its stages back through the sender,
/// and [`Stages::next`] waits for each until `deadline`. Nothing is
/// started once the deadline has passed. A stage that never arrives
/// leaves the thread to finish on its own, and the process it lives in
/// ends before it does — the session hook's check exits on its verdict,
/// and the same work is the background refresh's to finish. A thread
/// that dies without answering reads as having answered nothing.
fn gated(
    deadline: Instant,
    work: impl FnOnce(std::sync::mpsc::Sender<Stage>) + Send + 'static,
) -> Stages {
    let (sender, receiver) = std::sync::mpsc::channel();
    if !deadline.saturating_duration_since(Instant::now()).is_zero() {
        std::thread::spawn(move || work(sender));
    }
    Stages { receiver }
}

struct Stages {
    receiver: std::sync::mpsc::Receiver<Stage>,
}

impl Stages {
    /// The next stage, or `None` when `deadline` passes first or the
    /// thread ended without one.
    fn next(&self, deadline: Instant) -> Option<Stage> {
        self.receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::time::{Duration, Instant};

    use super::*;
    use crate::env::FakeOs;
    use crate::lock::{LockEntry, Reason};
    use crate::model::{HarnessId, ItemKind};

    /// A deadline already past reads no position: the keys are read on
    /// the gated thread, and the gate starts none once the deadline has
    /// passed. Held on the count of positions read, since a thread that
    /// should not have started leaves no other trace; the wait after the
    /// call gives one that did start time to leave its trace.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_deadline_already_past_reads_no_position() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::paths::canonical(tmp.path()).unwrap();
        let env = Env::fake(&home, FakeOs::Linux);
        let scope = Scope::Project {
            root: home.join("app"),
        };
        let position = home.join("app/.claude/agents/scout.md");
        std::fs::create_dir_all(position.parent().unwrap()).unwrap();
        std::fs::write(&position, "the tool that came before").unwrap();
        let occupied = BTreeMap::from([(
            "agent:scout:claude".to_owned(),
            Occupied {
                kind: ItemKind::Agent,
                name: "scout".into(),
                harness: HarnessId::Claude,
                source: "cat".into(),
                positions: vec![position],
            },
        )]);
        let manifest = Manifest::default();
        let lock = Lock::default();
        let before = POSITIONS_READ.load(std::sync::atomic::Ordering::Relaxed);
        let settled = settle(
            &env,
            &scope,
            &manifest,
            &lock,
            &occupied,
            Instant::now() - Duration::from_secs(1),
            Duration::from_secs(8),
        );
        assert!(matches!(settled, Settled::Overrun { .. }), "{settled:?}");
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(
            POSITIONS_READ.load(std::sync::atomic::Ordering::Relaxed),
            before,
            "a position was read past the deadline"
        );

        let settled = settle(
            &env,
            &scope,
            &manifest,
            &lock,
            &occupied,
            Instant::now() + Duration::from_secs(60),
            Duration::from_secs(60),
        );
        assert!(
            !matches!(settled, Settled::Overrun { .. }),
            "the control: a deadline ahead reads: {settled:?}"
        );
        assert!(
            POSITIONS_READ.load(std::sync::atomic::Ordering::Relaxed) > before,
            "the count is what it claims: a read counts"
        );
    }

    /// A judgement in hand: one copy that differs, one the record would
    /// gain.
    fn judged() -> UnmanagedCopies {
        let proven = LockEntry {
            name: "scout".into(),
            kind: ItemKind::Agent,
            harness: HarnessId::Claude,
            source: "cat".into(),
            source_repo: "./catalog".into(),
            source_hash: "a".repeat(64),
            source_commit: None,
            rendered_hash: Some("b".repeat(64)),
            enabled: true,
            upstream_skills: None,
            emitted: None,
            registration: None,
            reasons: BTreeSet::from([Reason::Requested]),
            machine: None,
        };
        UnmanagedCopies {
            measured: BTreeMap::from([
                ("agent:scout:claude".to_owned(), Measured::Proven),
                (
                    "skill:deploy:claude".to_owned(),
                    Measured::Differs {
                        files: 1,
                        rendered_from: "source 'cat'".into(),
                        take_over_settles: true,
                    },
                ),
            ]),
            proven: Lock {
                version: crate::lock::LOCK_VERSION,
                entries: BTreeMap::from([("agent:scout:claude".to_owned(), proven)]),
                sources: BTreeMap::new(),
                bundles: BTreeMap::new(),
            },
            registrations: BTreeMap::new(),
        }
    }

    /// The binding stage never arrives before the deadline — the thread
    /// is still hashing the files the record would prove — while the
    /// verdicts already did. The verdicts are the check's: the differing
    /// copy keeps its count, the copy the record would have gained stands
    /// as the stat found it, and the record write's failure names the
    /// binding and the budget, not the comparison.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_binding_the_deadline_cuts_short_keeps_the_verdicts_in_hand() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::paths::canonical(tmp.path()).unwrap();
        let env = Env::fake(&home, FakeOs::Linux);
        let scope = Scope::Project {
            root: home.join("app"),
        };
        let (sender, receiver) = std::sync::mpsc::channel();
        sender
            .send(Stage::Judged {
                keys: BTreeMap::new(),
                copies: judged(),
                fresh: false,
            })
            .unwrap();
        let settled = resolve(
            &env,
            &scope,
            Stages { receiver },
            Instant::now() + Duration::from_millis(50),
            Duration::from_secs(8),
        );
        let Settled::Judged {
            verdicts,
            record_failed,
        } = settled
        else {
            panic!("the verdicts in hand are the answer: {settled:?}");
        };
        assert_eq!(verdicts["agent:scout:claude"], Verdict::Left);
        assert!(matches!(
            verdicts["skill:deploy:claude"],
            Verdict::Differs { files: 1, .. }
        ));
        let failed = record_failed.unwrap();
        assert!(
            failed.contains("binding the record to the files it proves did not fit inside the 8 s"),
            "{failed}"
        );
        assert!(
            !memo_path(&env, &scope).exists(),
            "nothing was memoized off a memo hit"
        );
    }
}
