//! Versioned JSON records with one OS-backed writer lock per file, atomic
//! replacement and an explicit revision check.
//!
//! A record is one JSON object carrying `record_version` and `revision`.
//! Every write takes the file's lock, reads the current revision, refuses
//! a stale expectation, writes a temporary file beside the target that this
//! process created exclusively, and renames it over the target. Unknown
//! fields survive a read and a write: a newer writer's fields are not this
//! build's to drop.

use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::error::{Error, Result};

pub const RECORD_VERSION_KEY: &str = "record_version";
pub const REVISION_KEY: &str = "revision";

/// A record read from disk: its typed body, the revision the file held, and
/// every field the type did not name.
#[derive(Debug, Clone)]
pub struct Loaded<T> {
    pub body: T,
    pub revision: u64,
    pub extra: Map<String, Value>,
}

/// What a writer expects to find in the file before it replaces it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Expect {
    /// The file must not exist yet.
    Absent,
    /// The file must hold exactly this revision.
    Revision(u64),
    /// No check: the caller holds the only writer by other means.
    Any,
}

/// The lock file beside a record, held for the span of one write or one
/// read-modify-write.
pub struct Lock {
    _file: fd_lock::RwLock<File>,
    _guard: Option<()>,
}

/// The lock file beside a record: `<file>.lock`, the path the legacy shell
/// writers take their `flock(1)` on.
pub fn lock_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".lock");
    path.with_file_name(name)
}

/// The directory the legacy shell writers take as a `mkdir` mutex where
/// `flock(1)` is absent: `<file>.lock.d` (mailbox's `lib/file-lock.sh`).
pub fn mutex_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".lock.d");
    path.with_file_name(name)
}

/// The clock a bounded wait reads and the sleep it pauses with. Production
/// is [`SystemTimer`]; a test passes a fake that advances on each sleep, so
/// a timeout row runs without real time passing.
pub trait Timer: Sync {
    fn now(&self) -> Instant;
    fn sleep(&self, duration: Duration);
}

/// The process clock and `std::thread::sleep`.
#[derive(Debug)]
pub struct SystemTimer;

impl Timer for SystemTimer {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// How long a lock acquisition may wait before it refuses `lock-timeout`,
/// how often it retries, and the timer it waits on. The legacy writers wait
/// 10 s and poll every 100 ms; a test passes a shorter limit and a fake
/// timer.
#[derive(Clone, Copy)]
pub struct Wait {
    pub limit: Duration,
    pub poll: Duration,
    pub timer: &'static dyn Timer,
}

impl std::fmt::Debug for Wait {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Wait")
            .field("limit", &self.limit)
            .field("poll", &self.poll)
            .finish_non_exhaustive()
    }
}

impl Wait {
    /// The legacy writers' bound: `orch_take_lock ... 10`.
    pub const LEGACY: Wait = Wait {
        limit: Duration::from_secs(10),
        poll: Duration::from_millis(100),
        timer: &SystemTimer,
    };

    /// Start the wait: the deadline `limit` from now, which every
    /// acquisition made under it shares, so two locks taken in turn never
    /// wait longer than one limit together.
    pub fn start(&self) -> Deadline {
        Deadline {
            at: self.timer.now() + self.limit,
            wait: *self,
        }
    }
}

/// One wait in progress: the instant it refuses at, and the pauses up to
/// it. A pause is one poll, clamped to the time left, so the wait never
/// runs past the deadline by more than the acquisition attempt after it.
#[derive(Debug, Clone, Copy)]
pub struct Deadline {
    at: Instant,
    wait: Wait,
}

impl Deadline {
    /// Pause before the next attempt on `lock`, or refuse `lock-timeout`
    /// once the deadline has passed.
    fn pause(&self, lock: &Path) -> Result<()> {
        let now = self.wait.timer.now();
        if now >= self.at {
            return Err(lock_timeout(lock, self.wait.limit));
        }
        self.wait.timer.sleep(self.wait.poll.min(self.at - now));
        Ok(())
    }
}

fn lock_timeout(lock: &Path, limit: Duration) -> Error {
    Error::refused(
        "lock-timeout",
        &[
            ("path", &lock.display().to_string()),
            ("wait_s", &limit.as_secs().to_string()),
        ],
    )
}

/// Whether `flock(1)` is on the given `PATH` value, which decides the lock
/// mechanism the legacy shell writers of a host resolve (`file-lock.sh`).
/// `None` is an unset `PATH`, where no executable is found.
pub fn flock_on_path(path_var: Option<&OsStr>) -> bool {
    let Some(path_var) = path_var else {
        return false;
    };
    std::env::split_paths(path_var).any(|dir| {
        let candidate = dir.join("flock");
        fs::metadata(&candidate).is_ok_and(|m| m.is_file()) && is_executable(&candidate)
    })
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(_path: &Path) -> bool {
    true
}

/// The legacy `mkdir` mutex `<file>.lock.d`, held while the value lives and
/// removed on drop. Acquisition retries `mkdir` every poll until the
/// deadline passes, then refuses `lock-timeout`, as `file-lock.sh`'s
/// `orch_take_lock` does; like it, this takes no view on a standing
/// directory's age, since a holder that died leaves one only an operator
/// removes.
#[derive(Debug)]
pub struct MutexDir {
    dir: PathBuf,
}

impl Drop for MutexDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.dir);
    }
}

/// Take the legacy `mkdir` mutex beside `path`, waiting up to `deadline`.
pub fn mutex_lock(path: &Path, deadline: &Deadline) -> Result<MutexDir> {
    let dir = mutex_path(path);
    loop {
        match fs::create_dir(&dir) {
            Ok(()) => return Ok(MutexDir { dir }),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => deadline.pause(&dir)?,
            Err(e) => return Err(Error::io("mkdir-lock", &dir, e)),
        }
    }
}

/// Take the exclusive lock beside `path`, creating the lock file if needed.
/// The guard is released when the returned value is dropped.
pub fn lock(path: &Path) -> Result<Guard> {
    let lock_file = lock_path(path);
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_file)
        .map_err(|e| Error::io("open-lock", &lock_file, e))?;
    let rw = fd_lock::RwLock::new(file);
    Ok(Guard {
        rw,
        path: lock_file,
    })
}

/// An exclusive lock on a record's lock file, held while the guard lives.
pub struct Guard {
    rw: fd_lock::RwLock<File>,
    path: PathBuf,
}

impl Guard {
    /// Run `f` while holding the lock. The flock is taken here rather than
    /// at construction so the guard's lifetime and the lock's coincide.
    pub fn with<R>(&mut self, f: impl FnOnce() -> Result<R>) -> Result<R> {
        let path = self.path.clone();
        let _held = self.rw.write().map_err(|e| Error::io("flock", &path, e))?;
        f()
    }

    /// Run `f` while holding the lock, waiting up to `deadline` for it and
    /// refusing `lock-timeout` once that passes. The lock is polled, so the
    /// wait never outlives a holder by more than one poll.
    pub fn with_wait<R>(
        &mut self,
        deadline: &Deadline,
        f: impl FnOnce() -> Result<R>,
    ) -> Result<R> {
        let path = self.path.clone();
        loop {
            match self.rw.try_write() {
                Ok(_held) => return f(),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => deadline.pause(&path)?,
                Err(e) => return Err(Error::io("flock", &path, e)),
            }
        }
    }
}

/// Read the file as one JSON value, `None` when it does not exist. A typed
/// reader that must see a record before it carries a version (orch-runtime's
/// legacy workflow state) starts here and then hands a versioned value to
/// [`split_meta`].
pub fn read_value(path: &Path) -> Result<Option<Value>> {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::io("open", path, e)),
    };
    let mut text = String::new();
    file.read_to_string(&mut text)
        .map_err(|e| Error::io("read", path, e))?;
    let value: Value = serde_json::from_str(&text).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(Some(value))
}

/// Take `record_version` and `revision` off a record value, refusing a
/// version outside `supported`; the remaining map is the body plus unknown
/// fields, in the file's own order.
pub fn split_meta(
    path: &Path,
    value: Value,
    supported: &'static [u64],
) -> Result<(u64, u64, Map<String, Value>)> {
    let Value::Object(mut map) = value else {
        return Err(Error::RecordShape {
            path: path.to_path_buf(),
            reason: "the record is not a JSON object".to_owned(),
        });
    };
    // `shift_remove`, not `remove`: under `preserve_order` a plain remove
    // swaps the last entry into the hole and the fields change places.
    let version = map
        .shift_remove(RECORD_VERSION_KEY)
        .and_then(|v| v.as_u64())
        .ok_or_else(|| Error::RecordShape {
            path: path.to_path_buf(),
            reason: format!("no numeric {RECORD_VERSION_KEY}"),
        })?;
    if !supported.contains(&version) {
        return Err(Error::RecordVersion {
            path: path.to_path_buf(),
            found: version,
            supported,
        });
    }
    let revision = map
        .shift_remove(REVISION_KEY)
        .and_then(|v| v.as_u64())
        .ok_or_else(|| Error::RecordShape {
            path: path.to_path_buf(),
            reason: format!("no numeric {REVISION_KEY}"),
        })?;
    Ok((version, revision, map))
}

/// Read a record. `supported` lists the record versions this reader knows.
pub fn read<T: DeserializeOwned + Serialize>(
    path: &Path,
    supported: &'static [u64],
) -> Result<Option<Loaded<T>>> {
    let Some(value) = read_value(path)? else {
        return Ok(None);
    };
    let (_, revision, map) = split_meta(path, value, supported)?;
    // Deserialize the typed body from the whole map, then keep the fields
    // the type does not name, in their order, so a later write preserves
    // them as the file held them.
    let body: T =
        serde_json::from_value(Value::Object(map.clone())).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })?;
    let named: Value = serde_json::to_value(&body).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    let extra = match named {
        Value::Object(named) => map
            .into_iter()
            .filter(|(key, _)| !named.contains_key(key))
            .collect(),
        _ => map,
    };
    Ok(Some(Loaded {
        body,
        revision,
        extra,
    }))
}

/// Write `body` as the record at `path`, under the file's lock, after
/// checking `expect` against the revision on disk. Returns the revision the
/// file now holds. `extra` carries fields a prior read preserved.
pub fn write<T: Serialize>(
    path: &Path,
    version: u64,
    body: &T,
    extra: &Map<String, Value>,
    expect: Expect,
) -> Result<u64> {
    let mut guard = lock(path)?;
    guard.with(|| {
        let current = read_value(path)?;
        let current_revision = match &current {
            None => None,
            Some(Value::Object(map)) => map.get(REVISION_KEY).and_then(|v| v.as_u64()),
            Some(_) => {
                return Err(Error::RecordShape {
                    path: path.to_path_buf(),
                    reason: "the record is not a JSON object".to_owned(),
                });
            }
        };
        match (expect, current_revision) {
            (Expect::Any, _) => {}
            (Expect::Absent, None) => {}
            (Expect::Absent, Some(found)) => {
                return Err(Error::RevisionMismatch {
                    path: path.to_path_buf(),
                    expected: 0,
                    found,
                });
            }
            (Expect::Revision(expected), Some(found)) if expected == found => {}
            (Expect::Revision(expected), found) => {
                return Err(Error::RevisionMismatch {
                    path: path.to_path_buf(),
                    expected,
                    found: found.unwrap_or(0),
                });
            }
        }
        let next = current_revision.map(|r| r + 1).unwrap_or(1);
        let mut map = match serde_json::to_value(body).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })? {
            Value::Object(map) => map,
            _ => {
                return Err(Error::RecordShape {
                    path: path.to_path_buf(),
                    reason: "a record body must serialize to a JSON object".to_owned(),
                });
            }
        };
        for (key, value) in extra {
            map.entry(key.clone()).or_insert_with(|| value.clone());
        }
        let mut ordered = Map::new();
        ordered.insert(RECORD_VERSION_KEY.to_owned(), Value::from(version));
        ordered.insert(REVISION_KEY.to_owned(), Value::from(next));
        for (key, value) in map {
            if key != RECORD_VERSION_KEY && key != REVISION_KEY {
                ordered.insert(key, value);
            }
        }
        replace_atomically(path, &Value::Object(ordered))?;
        Ok(next)
    })
}

/// Write `value` to a fresh temporary file beside `path`, created
/// exclusively, then rename it over `path`.
pub fn replace_atomically(path: &Path, value: &Value) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|e| Error::io("create-dir", parent, e))?;
    let base = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("record");
    let mut attempt = 0u32;
    let (temp_path, mut file) = loop {
        let candidate = parent.join(format!(".{base}.{}.{attempt}.tmp", std::process::id()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => break (candidate, file),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempt < 64 => attempt += 1,
            Err(e) => return Err(Error::io("create-temp", &candidate, e)),
        }
    };
    let text = serde_json::to_string_pretty(value).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    let written = file
        .write_all(text.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.sync_all());
    if let Err(e) = written {
        let _ = fs::remove_file(&temp_path);
        return Err(Error::io("write-temp", &temp_path, e));
    }
    drop(file);
    if let Err(e) = fs::rename(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(Error::io("rename", path, e));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::sync::Mutex;

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    struct Body {
        name: String,
        count: u32,
    }

    const V: &[u64] = &[1];

    #[test]
    fn a_first_write_needs_an_absent_file_and_starts_at_revision_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        let body = Body {
            name: "a".into(),
            count: 1,
        };
        let revision = write(&path, 1, &body, &Map::new(), Expect::Absent).unwrap();
        assert_eq!(revision, 1);
        let loaded = read::<Body>(&path, V).unwrap().unwrap();
        assert_eq!(loaded.body, body);
        assert_eq!(loaded.revision, 1);
        let err = write(&path, 1, &body, &Map::new(), Expect::Absent).unwrap_err();
        assert!(matches!(err, Error::RevisionMismatch { found: 1, .. }));
    }

    #[test]
    fn a_stale_revision_is_refused_and_leaves_the_file_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        let body = Body {
            name: "a".into(),
            count: 1,
        };
        write(&path, 1, &body, &Map::new(), Expect::Absent).unwrap();
        let newer = Body {
            name: "b".into(),
            count: 2,
        };
        write(&path, 1, &newer, &Map::new(), Expect::Revision(1)).unwrap();
        let err = write(&path, 1, &body, &Map::new(), Expect::Revision(1)).unwrap_err();
        assert!(matches!(
            err,
            Error::RevisionMismatch {
                expected: 1,
                found: 2,
                ..
            }
        ));
        assert_eq!(read::<Body>(&path, V).unwrap().unwrap().body, newer);
    }

    /// Unknown fields keep their values and their relative order through a
    /// read and a write; the file interleaves them with the typed fields so
    /// a swap on removal would reorder them.
    #[test]
    fn unknown_fields_survive_a_read_and_a_rewrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        fs::write(
            &path,
            r#"{"record_version":1,"revision":4,"first_extra":1,"name":"x","second_extra":"s","count":2,"later_field":{"k":true}}"#,
        )
        .unwrap();
        let unknown = ["first_extra", "second_extra", "later_field"];
        let loaded = read::<Body>(&path, V).unwrap().unwrap();
        assert_eq!(loaded.revision, 4);
        assert_eq!(
            loaded.extra.get("later_field").unwrap()["k"],
            Value::Bool(true)
        );
        assert_eq!(loaded.extra.keys().collect::<Vec<_>>(), unknown);
        let revision = write(&path, 1, &loaded.body, &loaded.extra, Expect::Revision(4)).unwrap();
        assert_eq!(revision, 5);
        let again: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(again["later_field"]["k"], Value::Bool(true));
        assert_eq!(again["first_extra"], Value::from(1));
        assert_eq!(again["second_extra"], Value::from("s"));
        assert_eq!(again["revision"], Value::from(5));
        let kept: Vec<&str> = again
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .filter(|k| unknown.contains(k))
            .collect();
        assert_eq!(kept, unknown);
    }

    #[test]
    fn a_newer_record_version_refuses_without_a_guess() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        fs::write(
            &path,
            r#"{"record_version":9,"revision":1,"name":"x","count":2}"#,
        )
        .unwrap();
        let err = read::<Body>(&path, V).unwrap_err();
        assert!(matches!(err, Error::RecordVersion { found: 9, .. }));
    }

    #[test]
    fn a_missing_file_reads_as_none_not_as_an_empty_record() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            read::<Body>(&dir.path().join("none.json"), V)
                .unwrap()
                .is_none()
        );
    }

    /// A clock that moves only when the wait sleeps on it, and the record of
    /// every sleep; no real time passes in a timeout row.
    pub(crate) struct FakeTimer {
        now: Mutex<Instant>,
        slept: Mutex<Vec<Duration>>,
    }

    impl FakeTimer {
        /// A leaked fake: a `Wait` holds its timer for `'static`, and a test
        /// process ends with its handful of fakes.
        pub(crate) fn leaked() -> &'static FakeTimer {
            Box::leak(Box::new(FakeTimer {
                now: Mutex::new(Instant::now()),
                slept: Mutex::new(Vec::new()),
            }))
        }

        pub(crate) fn slept(&self) -> Vec<Duration> {
            self.slept.lock().unwrap().clone()
        }
    }

    impl Timer for FakeTimer {
        fn now(&self) -> Instant {
            *self.now.lock().unwrap()
        }

        fn sleep(&self, duration: Duration) {
            *self.now.lock().unwrap() += duration;
            self.slept.lock().unwrap().push(duration);
        }
    }

    /// 250 ms in 100 ms polls: two whole polls and one clamped to the rest.
    fn short(timer: &'static FakeTimer) -> Wait {
        Wait {
            limit: Duration::from_millis(250),
            poll: Duration::from_millis(100),
            timer,
        }
    }

    const CLAMPED: [Duration; 3] = [
        Duration::from_millis(100),
        Duration::from_millis(100),
        Duration::from_millis(50),
    ];

    /// The holder keeps the flock past the waiter's limit, and the waiter
    /// refuses once its clock reaches the deadline: the sleeps sum to the
    /// limit exactly, the last one clamped, and none is real.
    #[test]
    fn a_bounded_wait_refuses_lock_timeout_while_another_holder_keeps_the_flock() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        let lock_file = lock_path(&path);
        let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder_path = path.clone();
        let holder = std::thread::spawn(move || {
            let mut guard = lock(&holder_path).unwrap();
            guard
                .with(|| {
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .unwrap();
        });
        held_rx.recv().unwrap();
        let timer = FakeTimer::leaked();
        let wait = short(timer);
        let started = Instant::now();
        let mut waiter = lock(&path).unwrap();
        let err = waiter.with_wait(&wait.start(), || Ok(())).unwrap_err();
        assert!(started.elapsed() < wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        let Error::Refused { fields, .. } = &err else {
            panic!("{err}")
        };
        assert_eq!(
            fields[0],
            ("path".to_owned(), lock_file.display().to_string())
        );
        assert_eq!(fields[1], ("wait_s".to_owned(), "0".to_owned()));
        assert_eq!(timer.slept(), CLAMPED);
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        // Once released, the same bounded wait runs the closure and sleeps
        // no more.
        assert_eq!(waiter.with_wait(&wait.start(), || Ok(7)).unwrap(), 7);
        assert_eq!(timer.slept().len(), CLAMPED.len());
    }

    #[test]
    fn the_mkdir_mutex_excludes_a_standing_directory_and_is_removed_on_drop() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        let mutex = mutex_path(&path);
        assert_eq!(mutex, dir.path().join("r.json.lock.d"));
        let timer = FakeTimer::leaked();
        let wait = short(timer);
        // A legacy writer holds the mutex: its directory stands.
        fs::create_dir(&mutex).unwrap();
        let err = mutex_lock(&path, &wait.start()).unwrap_err();
        assert_eq!(err.key(), "lock-timeout");
        let Error::Refused { fields, .. } = &err else {
            panic!("{err}")
        };
        assert_eq!(fields[0], ("path".to_owned(), mutex.display().to_string()));
        assert_eq!(timer.slept(), CLAMPED);
        assert!(mutex.is_dir(), "a refused wait removes nothing");
        fs::remove_dir(&mutex).unwrap();
        let held = mutex_lock(&path, &wait.start()).unwrap();
        assert!(mutex.is_dir());
        drop(held);
        assert!(!mutex.exists());
    }

    /// Two acquisitions under one started wait share its deadline: the
    /// second gets only what the first left, so together they never exceed
    /// the limit.
    #[test]
    fn acquisitions_under_one_deadline_share_the_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("r.json");
        let mutex = mutex_path(&path);
        let timer = FakeTimer::leaked();
        let wait = short(timer);
        let deadline = wait.start();
        // The first acquisition spends 150 ms of the 250 ms limit.
        timer.sleep(Duration::from_millis(150));
        fs::create_dir(&mutex).unwrap();
        let err = mutex_lock(&path, &deadline).unwrap_err();
        assert_eq!(err.key(), "lock-timeout");
        assert_eq!(
            timer.slept(),
            [Duration::from_millis(150), Duration::from_millis(100)]
        );
        // A deadline already passed refuses before any sleep.
        let err = mutex_lock(&path, &deadline).unwrap_err();
        assert_eq!(err.key(), "lock-timeout");
        assert_eq!(timer.slept().len(), 2);
    }

    #[test]
    fn flock_is_found_on_a_path_only_where_an_executable_of_that_name_lies() {
        let dir = tempfile::tempdir().unwrap();
        let with = dir.path().join("with");
        let without = dir.path().join("without");
        fs::create_dir_all(&with).unwrap();
        fs::create_dir_all(&without).unwrap();
        fs::write(with.join("flock"), "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(with.join("flock"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        fs::write(without.join("flock.txt"), "").unwrap();
        let joined = std::env::join_paths([&without, &with]).unwrap();
        assert!(flock_on_path(Some(&joined)));
        let only_without = std::env::join_paths([&without]).unwrap();
        assert!(!flock_on_path(Some(&only_without)));
        assert!(!flock_on_path(None));
    }
}
