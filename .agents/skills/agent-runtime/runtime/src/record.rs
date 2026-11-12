//! Versioned JSON records with one OS-backed writer lock per file, atomic
//! replacement and an explicit revision check.
//!
//! A record is one JSON object carrying `record_version` and `revision`.
//! Every write takes the file's lock, reads the current revision, refuses
//! a stale expectation, writes a temporary file beside the target that this
//! process created exclusively, and renames it over the target. Unknown
//! fields survive a read and a write: a newer writer's fields are not this
//! build's to drop.
//!
//! A document is the other form: one JSON object in its own key order with
//! no meta keys, which shell writers patch beside this runtime. It is held
//! as the file holds it, a writer patches named keys, so every key it does
//! not touch keeps its value and its position, and its one write check is
//! the content comparison under the lock. A file stamped with the
//! versioned form's meta keys is no document and is refused by name.

use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::clock::{Clock, SystemClock};
use crate::error::{Error, Result, ShapeReason};

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

/// The lock file beside a record: `<file>.lock`, the path the shell
/// writers take their `flock(1)` on.
pub fn lock_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".lock");
    path.with_file_name(name)
}

/// The directory the shell writers take as a `mkdir` mutex where
/// `flock(1)` is absent: `<file>.lock.d` (mailbox's `lib/file-lock.sh`).
pub fn mutex_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".lock.d");
    path.with_file_name(name)
}

/// How long a lock acquisition may wait before it refuses `lock-timeout`,
/// how often it retries, and the timer it waits on. The shell writers wait
/// 10 s and poll every 100 ms; a test passes a shorter limit and a fake
/// timer.
#[derive(Clone, Copy)]
pub struct Wait {
    pub limit: Duration,
    pub poll: Duration,
    pub timer: &'static dyn Clock,
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
    /// The default bound, the one the shell writers wait on:
    /// `orch_take_lock ... 10`.
    pub const DEFAULT: Wait = Wait {
        limit: Duration::from_secs(10),
        poll: Duration::from_millis(100),
        timer: &SystemClock,
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
/// mechanism the shell writers of a host resolve (`file-lock.sh`).
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

/// The shell writers' `mkdir` mutex `<file>.lock.d`, held while the value lives and
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

/// Take the `mkdir` mutex beside `path`, waiting up to `deadline`.
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
/// unversioned workflow state) starts here and then hands a versioned value to
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
            field: String::new(),
            reason: ShapeReason::NotObject,
            cause: "the record is not a JSON object".to_owned(),
        });
    };
    // `shift_remove`, not `remove`: under `preserve_order` a plain remove
    // swaps the last entry into the hole and the fields change places.
    let version = map
        .shift_remove(RECORD_VERSION_KEY)
        .and_then(|v| v.as_u64())
        .ok_or_else(|| Error::RecordShape {
            path: path.to_path_buf(),
            field: RECORD_VERSION_KEY.to_owned(),
            reason: ShapeReason::TypeMismatch,
            cause: "not a number".to_owned(),
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
            field: REVISION_KEY.to_owned(),
            reason: ShapeReason::TypeMismatch,
            cause: "not a number".to_owned(),
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
                    field: String::new(),
                    reason: ShapeReason::NotObject,
                    cause: "the record is not a JSON object".to_owned(),
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
                    field: String::new(),
                    reason: ShapeReason::NotObject,
                    cause: "a record body must serialize to a JSON object".to_owned(),
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

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

/// The fleet record's fixed file name: `workflow-state` writes the key
/// `oversee` into `workflow-state-<KEY>.json`.
pub const FLEET_FILE_NAME: &str = "workflow-state-oversee.json";

/// A document as the file holds it: one JSON object in its own key order.
pub type Document = Map<String, Value>;

/// The fleet record under `dir`.
pub fn fleet_path(dir: &Path) -> PathBuf {
    dir.join(FLEET_FILE_NAME)
}

/// The receipt the pane an effect opened writes for its intent, beside
/// the records under `dir`: `intents/<intent id>.pane`. An
/// intent id is `<op>:<target>:<stamp>` and carries no path separator.
pub fn receipt_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.pane"))
}

/// The request a transfer's detached job runs, written by the
/// caller beside the receipt before the job starts: `intents/<intent
/// id>.request`.
pub fn job_request_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.request"))
}

/// The job-unit record of that job, `intents/<intent id>.job`, which names
/// how the job runs (its unit, or its process group).
pub fn job_record_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.job"))
}

/// How a write takes the file's lock. `wait` bounds the acquisition, the
/// flock and the mutex together; with `mkdir_mutex` the file is also
/// written under the `mkdir` mutex the shell writers take where the
/// host has no `flock(1)`, so those writers are excluded.
#[derive(Debug, Clone, Copy)]
pub struct Locking {
    pub wait: Wait,
    pub mkdir_mutex: bool,
}

impl Locking {
    /// A host with `flock(1)`: the flock alone, with the shell writers' wait. A
    /// program resolves a host's policy itself, from its own `PATH`.
    pub const FLOCK: Locking = Locking {
        wait: Wait::DEFAULT,
        mkdir_mutex: false,
    };
}

fn shape(path: &Path, field: &str, reason: ShapeReason, cause: impl Into<String>) -> Error {
    Error::RecordShape {
        path: path.to_path_buf(),
        field: field.to_owned(),
        reason,
        cause: cause.into(),
    }
}

/// Read the top-level `key` as `T`. An absent key or a `null` reads as
/// `None`, the way the shell writers' `.key // default` reads do; another value that
/// is not a `T` refuses `record-shape` naming the key.
pub fn field<T: DeserializeOwned>(path: &Path, doc: &Document, key: &str) -> Result<Option<T>> {
    match doc.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|e| shape(path, key, ShapeReason::TypeMismatch, e.to_string())),
    }
}

/// Null `key` where `doc` holds it; an absent optional field gains no null.
pub fn null_held(doc: &mut Document, key: &str) {
    if doc.contains_key(key) {
        set(doc, key, Value::Null);
    }
}

/// Set `key` to `value`: in place when the key exists, appended otherwise.
pub fn set(doc: &mut Document, key: &str, value: impl Into<Value>) {
    doc.insert(key.to_owned(), value.into());
}

/// Remove `key`, keeping every other key in place. Returns whether it stood.
pub fn delete(doc: &mut Document, key: &str) -> bool {
    doc.shift_remove(key).is_some()
}

/// The array under `key`, created empty when the key is absent or `null`
/// (the shell writers' `.key // []`). Another value refuses `record-shape`.
pub fn array_mut<'a>(path: &Path, doc: &'a mut Document, key: &str) -> Result<&'a mut Vec<Value>> {
    if matches!(doc.get(key), None | Some(Value::Null)) {
        doc.insert(key.to_owned(), Value::Array(Vec::new()));
    }
    match doc.get_mut(key) {
        Some(Value::Array(items)) => Ok(items),
        Some(other) => Err(shape(
            path,
            key,
            ShapeReason::NotArray,
            format!("found {}", json_type(other)),
        )),
        None => unreachable!("inserted above"),
    }
}

/// The object under `key`; an absent key refuses `record-shape` too, since
/// the callers patch an object the file already holds.
pub fn object_mut<'a>(path: &Path, doc: &'a mut Document, key: &str) -> Result<&'a mut Document> {
    match doc.get_mut(key) {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(shape(
            path,
            key,
            ShapeReason::NotObject,
            format!("found {}", json_type(other)),
        )),
        None => Err(shape(path, key, ShapeReason::NotObject, "absent")),
    }
}

/// Element `index` of the array under `key` as an object.
pub fn element_mut<'a>(
    path: &Path,
    items: &'a mut [Value],
    index: usize,
    key: &str,
) -> Result<&'a mut Document> {
    let field = format!("{key}/{index}");
    match items.get_mut(index) {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(shape(
            path,
            &field,
            ShapeReason::NotObject,
            format!("found {}", json_type(other)),
        )),
        None => Err(shape(path, &field, ShapeReason::NotObject, "absent")),
    }
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// POSIX `cksum`: CRC-32 over the bytes then over the byte count, least
/// significant byte first until none is left, complemented (POSIX.1-2017,
/// `cksum`). The one checksum every record name and digest takes:
/// the account wall record's, the usage cache's and a private home's.
pub fn cksum(bytes: &[u8]) -> u32 {
    fn feed(mut crc: u32, byte: u8) -> u32 {
        crc ^= u32::from(byte) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04C1_1DB7
            } else {
                crc << 1
            };
        }
        crc
    }
    let mut crc = bytes.iter().fold(0u32, |crc, b| feed(crc, *b));
    let mut len = bytes.len();
    while len > 0 {
        crc = feed(crc, (len & 0xff) as u8);
        len >>= 8;
    }
    !crc
}

/// Read a document: `None` for an absent file; unparsable bytes refuse
/// `json-invalid`, a non-object `record-shape`, and a file stamped with
/// `record_version` or `revision` `record-stamped`. Every field is read
/// when its reader needs it.
pub fn read_document(path: &Path) -> Result<Option<Document>> {
    let Some(value) = read_value(path)? else {
        return Ok(None);
    };
    let Value::Object(doc) = value else {
        return Err(shape(
            path,
            "",
            ShapeReason::NotObject,
            format!("found {}", json_type(&value)),
        ));
    };
    // A file stamped with the versioned form's meta keys is no document:
    // the shell writers patch the file beside this runtime and keep no
    // revision, so the content comparison is the one write check, and a
    // file carrying either key is refused by name rather than read as if
    // unstamped.
    if let Some(key) = [RECORD_VERSION_KEY, REVISION_KEY]
        .into_iter()
        .find(|key| doc.contains_key(*key))
    {
        return Err(Error::refused(
            "record-stamped",
            &[("path", &path.display().to_string()), ("key", key)],
        ));
    }
    Ok(Some(doc))
}

/// Run `f` under the lock beside `path` (`<path>.lock`), bounded by
/// `locking.wait`, and under the shell writers' `mkdir` mutex where the
/// policy says the host's shell writers take one. Both locks are taken under
/// one deadline, so the whole acquisition waits at most the shell writers'
/// 10 s. A lock with no document beside it, such as a launch lock, is taken
/// through the same function, so one lock discipline serves every lock.
pub fn locked<R, E: From<Error>>(
    path: &Path,
    locking: Locking,
    f: impl FnOnce() -> std::result::Result<R, E>,
) -> std::result::Result<R, E> {
    let deadline = locking.wait.start();
    let mut guard = lock(path)?;
    guard.with_wait(&deadline, || {
        let _mutex = if locking.mkdir_mutex {
            Some(mutex_lock(path, &deadline)?)
        } else {
            None
        };
        Ok(f())
    })?
}

/// Write `doc` over the file `read` was read from, refusing
/// `record-changed` when the file's content moved since the read: the check
/// the shell writers' lock cannot give it otherwise. A `doc` whose record
/// bytes equal the read's passes the same check and then writes nothing,
/// so a repeated request that reconciles its standing intent
/// leaves the file as it found it. The comparison is of the serialized
/// bytes with key order kept, never of the values: a key that
/// moved is a changed record.
pub fn store(path: &Path, read: &Document, doc: &Document, locking: Locking) -> Result<()> {
    let unchanged = same_document(path, doc, read)?;
    locked(path, locking, || {
        match read_value(path)? {
            Some(Value::Object(current)) if current == *read => {}
            _ => {
                return Err(Error::refused(
                    "record-changed",
                    &[("path", &path.display().to_string())],
                ));
            }
        }
        if !unchanged {
            replace_atomically(path, &Value::Object(doc.clone()))?;
        }
        Ok(())
    })
}

/// Whether two documents are one record byte for byte, key order included:
/// what the store's no-change check compares, and what a
/// transition compares before it reports a record changed.
pub fn same_document(path: &Path, a: &Document, b: &Document) -> Result<bool> {
    Ok(serialized(path, a)? == serialized(path, b)?)
}

/// The bytes the record writer puts on disk for `doc`, key order included:
/// the form the no-change check compares, since two documents equal as
/// values are different records once a key moved.
fn serialized(path: &Path, doc: &Document) -> Result<Vec<u8>> {
    serde_json::to_vec_pretty(doc).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })
}

/// How many fresh reads a re-applied write takes before a document that keeps
/// moving under it is reported as `record-changed`.
const REREADS: u32 = 8;

/// Run `attempt` again while its store refuses `record-changed`, up to
/// [`REREADS`] times; `key_of` reads an error's stable key. Each attempt
/// reads the document afresh and re-applies its change, so a write another
/// writer committed between the read and the store is kept, never
/// overwritten.
pub fn reread<R, E>(
    attempt: impl Fn() -> std::result::Result<R, E>,
    key_of: impl Fn(&E) -> &'static str,
) -> std::result::Result<R, E> {
    let mut attempts = 0;
    loop {
        match attempt() {
            Err(e) if attempts < REREADS && key_of(&e) == "record-changed" => attempts += 1,
            settled => return settled,
        }
    }
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
    /// every sleep; no real time passes in a timeout row. `on_first_sleep`
    /// runs once, in the waiter's thread, before the first sleep moves the
    /// clock: a row that needs a lock released after the waiter's first poll
    /// hands the release over here, so the order is the timer's and not the
    /// scheduler's.
    pub(crate) struct FakeTimer {
        now: Mutex<Instant>,
        slept: Mutex<Vec<Duration>>,
        on_first_sleep: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    }

    impl FakeTimer {
        /// A leaked fake: a `Wait` holds its timer for `'static`, and a test
        /// process ends with its handful of fakes.
        pub(crate) fn leaked() -> &'static FakeTimer {
            Box::leak(Box::new(FakeTimer {
                now: Mutex::new(Instant::now()),
                slept: Mutex::new(Vec::new()),
                on_first_sleep: Mutex::new(None),
            }))
        }

        pub(crate) fn releasing_on_first_sleep(
            release: impl FnOnce() + Send + 'static,
        ) -> &'static FakeTimer {
            let timer = FakeTimer::leaked();
            *timer.on_first_sleep.lock().unwrap() = Some(Box::new(release));
            timer
        }

        pub(crate) fn slept(&self) -> Vec<Duration> {
            self.slept.lock().unwrap().clone()
        }
    }

    impl Clock for FakeTimer {
        fn now(&self) -> Instant {
            *self.now.lock().unwrap()
        }

        fn wall(&self) -> std::time::SystemTime {
            unreachable!("a lock wait reads no wall clock")
        }

        fn sleep(&self, duration: Duration) {
            if let Some(release) = self.on_first_sleep.lock().unwrap().take() {
                release();
            }
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
        // A shell writer holds the mutex: its directory stands.
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

    /// A document in the shell writers' shape: pretty-printed, keys in the
    /// writer's order, no meta keys.
    const DOC: &str = "{\n  \"issue_id\": \"KEN-1\",\n  \"cycles\": 0,\n  \"phase\": \"dev\",\n  \"stages\": []\n}\n";

    fn write_doc(dir: &Path, text: &str) -> PathBuf {
        let path = dir.join("doc.json");
        fs::write(&path, text).unwrap();
        path
    }

    fn document(path: &Path) -> Document {
        read_document(path).unwrap().unwrap()
    }

    fn keys(doc: &Document) -> Vec<String> {
        doc.keys().cloned().collect()
    }

    /// A shell writer's edit between the read and the
    /// store refuses `record-changed`, and the edit stands.
    #[test]
    fn a_shell_writers_edit_between_load_and_store_refuses_record_changed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_doc(dir.path(), DOC);
        let read = document(&path);
        let moved = DOC.replacen("\"cycles\": 0", "\"cycles\": 5", 1);
        fs::write(&path, &moved).unwrap();
        let mut doc = read.clone();
        set(&mut doc, "cycles", 1);
        let err = store(&path, &read, &doc, Locking::FLOCK).unwrap_err();
        assert_eq!(err.key(), "record-changed");
        assert_eq!(fs::read_to_string(&path).unwrap(), moved);
    }

    /// A document whose record bytes equal the
    /// read's writes nothing, so a repeated request that changes no
    /// record leaves the file as it found it. A document equal as a value
    /// but with a key moved is a changed record: it is written, as a changed
    /// value is.
    #[test]
    fn an_unchanged_document_writes_nothing_and_a_moved_key_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_doc(dir.path(), DOC);
        let read = document(&path);
        let before = fs::read(&path).unwrap();
        store(&path, &read, &read, Locking::FLOCK).unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        // The same values with `cycles` moved to the end of the document.
        let mut reordered = read.clone();
        let cycles = reordered.shift_remove("cycles").unwrap();
        reordered.insert("cycles".to_owned(), cycles);
        assert_eq!(reordered, read, "equal as values");
        assert_ne!(keys(&reordered), keys(&read), "a key moved");
        store(&path, &read, &reordered, Locking::FLOCK).unwrap();
        assert_ne!(
            fs::read(&path).unwrap(),
            before,
            "an order-only change is written"
        );
        assert_eq!(
            keys(&document(&path)).last().map(String::as_str),
            Some("cycles")
        );
        let read = document(&path);
        let mut doc = read.clone();
        set(&mut doc, "cycles", 7);
        store(&path, &read, &doc, Locking::FLOCK).unwrap();
        assert_eq!(document(&path)["cycles"], Value::from(7));
    }

    /// A file stamped with the versioned form's meta keys is no document:
    /// the reader refuses `record-stamped` naming the key, and the file is
    /// left as it was.
    #[test]
    fn a_stamped_file_refuses_record_stamped_without_touching_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            (
                DOC.replacen("{", "{\"record_version\": 1, \"revision\": 4,", 1),
                "record_version",
            ),
            (
                "{\"revision\": 3, \"issue_id\": \"KEN-1\"}".to_owned(),
                "revision",
            ),
        ];
        for (text, key) in rows {
            let path = write_doc(dir.path(), &text);
            let before = fs::read(&path).unwrap();
            let err = read_document(&path).unwrap_err();
            assert_eq!(err.key(), "record-stamped", "{text}: {err:?}");
            let Error::Refused { fields, .. } = &err else {
                panic!("{text}: {err:?}")
            };
            assert_eq!(fields[1], ("key".to_owned(), key.to_owned()), "{text}");
            assert_eq!(fs::read(&path).unwrap(), before, "{text}");
        }
    }

    /// The policy a program resolves for a host whose `PATH` is
    /// `path_var`: the shell writers' wait, and the mutex wherever
    /// `flock(1)` is not on that path.
    fn for_host(path_var: Option<&OsStr>) -> Locking {
        Locking {
            wait: Wait::DEFAULT,
            mkdir_mutex: !flock_on_path(path_var),
        }
    }

    /// On a host whose `PATH` lacks `flock(1)`
    /// the write takes the shell writers' `mkdir` mutex, so a shell writer holding
    /// it excludes the store, and the store removes its own mutex
    /// afterwards. The wait runs on the fake clock and stops at the limit.
    #[test]
    fn without_flock_on_path_the_write_takes_the_mkdir_mutex() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path_var = std::env::join_paths([&bin]).unwrap();
        let timer = FakeTimer::leaked();
        let locking = Locking {
            wait: short(timer),
            ..for_host(Some(&path_var))
        };
        assert!(locking.mkdir_mutex);
        let path = write_doc(dir.path(), DOC);
        let mutex = mutex_path(&path);
        fs::create_dir(&mutex).unwrap();
        let read = document(&path);
        let started = Instant::now();
        let err = store(&path, &read, &read, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        let Error::Refused { fields, .. } = &err else {
            panic!("{err:?}")
        };
        assert_eq!(fields[0], ("path".to_owned(), mutex.display().to_string()));
        assert_eq!(timer.slept(), CLAMPED);
        fs::remove_dir(&mutex).unwrap();
        store(&path, &read, &read, locking).unwrap();
        assert!(!mutex.exists());
        // With flock on the path the policy takes no mutex.
        fs::write(bin.join("flock"), "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(bin.join("flock"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(!for_host(Some(&path_var)).mkdir_mutex);
    }

    /// The flock wait is bounded and refuses `lock-timeout` at
    /// the limit, on the fake clock.
    #[test]
    fn a_held_flock_bounds_the_store_wait() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_doc(dir.path(), DOC);
        let read = document(&path);
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
        let locking = Locking {
            wait: short(timer),
            mkdir_mutex: false,
        };
        let started = Instant::now();
        let err = store(&path, &read, &read, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        assert_eq!(timer.slept(), CLAMPED);
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        store(&path, &read, &read, locking).unwrap();
        assert_eq!(
            timer.slept().len(),
            CLAMPED.len(),
            "a free lock sleeps nothing"
        );
    }

    /// The flock and the mutex share one deadline: a mutex wait that starts
    /// after the flock took part of the limit gets only what is left, so the
    /// two never add up past the bound. A holder keeps
    /// the flock through the waiter's first poll and lets go from inside
    /// that poll's sleep, so the flock is acquired on the second attempt
    /// with one poll of the limit spent; the mutex the test planted then
    /// holds the rest, and is the lock the refusal names.
    #[test]
    fn the_flock_and_the_mutex_share_one_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path_var = std::env::join_paths([&bin]).unwrap();
        let path = write_doc(dir.path(), DOC);
        let read = document(&path);
        let mutex = mutex_path(&path);
        fs::create_dir(&mutex).unwrap();
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
        // The join acknowledges the release: the holder's guard has dropped
        // the flock before its thread ends, so the waiter's next attempt
        // takes it.
        let timer = FakeTimer::releasing_on_first_sleep(move || {
            release_tx.send(()).unwrap();
            holder.join().unwrap();
        });
        let locking = Locking {
            wait: short(timer),
            ..for_host(Some(&path_var))
        };
        assert!(locking.mkdir_mutex);
        let started = Instant::now();
        let err = store(&path, &read, &read, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        let Error::Refused { fields, .. } = &err else {
            panic!("{err:?}")
        };
        assert_eq!(
            fields[0],
            ("path".to_owned(), mutex.display().to_string()),
            "the mutex, not the flock, is the lock the wait ran out on"
        );
        assert_eq!(
            timer.slept(),
            CLAMPED,
            "one poll on the flock, then the rest of the one limit on the mutex"
        );
        assert_eq!(
            timer.slept().iter().sum::<Duration>(),
            locking.wait.limit,
            "flock and mutex waits sum to one limit"
        );
        assert!(
            mutex.is_dir(),
            "the planted mutex stands; the store removed nothing"
        );
    }
}
