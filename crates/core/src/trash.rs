//! Where a removal's bytes go, and what bounds how long they stay.
//!
//! Removal never deletes: the apply engine's `Trash` op, the project
//! restore and a Pi package's replacement or removal all land through
//! [`move_to_trash`], under a name that carries the moment it was moved
//! and the name it had. The other half of that promise is the bound:
//! nothing reads the trash back, so an install that replaces packages
//! fills its disk unless something takes entries out again.
//!
//! [`retain`] is that pass. It keeps every entry younger than
//! [`KEEP_DAYS_VAR`] days whose bytes, newest first, fit under
//! [`KEEP_MB_VAR`], and every entry this invocation wrote
//! (`Env::hold_trashed`), and removes the rest. It runs at the end of
//! the verbs `docs/architecture/trash.md` names, after the command's own
//! writes, never in the middle of one. A bound it cannot read stops the
//! pass with everything intact; an entry it cannot measure or remove
//! stops it where it is, with what went before already gone.
//!
//! Nothing writes into an entry after it lands, so its bytes are
//! measured once: the pass records them in [`SIZES_FILE`] beside the
//! entries and reads them back on every later pass, until the entry
//! goes and its record with it.
//!
//! [`empty`] is the person's own request, through `kendex trash empty`:
//! every entry, or every entry past an age, this invocation's excepted.
//!
//! A name that does not open with kendex's stamp is not kendex's entry:
//! it is neither listed nor removed.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};

/// The variable naming how many days an entry stays. Unset or empty, the
/// count is [`DEFAULT_KEEP_DAYS`]; zero keeps only what this invocation
/// wrote and what was moved in this same second.
pub const KEEP_DAYS_VAR: &str = "KENDEX_TRASH_KEEP_DAYS";

/// Days an entry stays when [`KEEP_DAYS_VAR`] names no count.
pub const DEFAULT_KEEP_DAYS: u64 = 30;

/// The variable naming how many MB the trash may hold, counted newest
/// first: the entry that takes the total past it goes, and every older
/// one with it. Unset or empty, the count is [`DEFAULT_KEEP_MB`]; zero
/// keeps only what this invocation wrote.
pub const KEEP_MB_VAR: &str = "KENDEX_TRASH_KEEP_MB";

/// MB the trash may hold when [`KEEP_MB_VAR`] names no count.
pub const DEFAULT_KEEP_MB: u64 = 512;

/// The file inside the trash recording each entry's bytes by name, as
/// the retention pass measured them. Its name opens with no stamp, so it
/// is not an entry: `kendex trash` neither lists nor removes it.
pub const SIZES_FILE: &str = "sizes.json";

/// One entry as the trash holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Its name inside the trash: the stamp, a counter where one name was
    /// taken twice in a second, and the name it had where it was removed.
    pub name: String,
    pub path: PathBuf,
    /// When it was moved here, in seconds since the Unix epoch, read off
    /// the stamp in its name.
    pub trashed_at: u64,
}

/// A pass that did not finish: what went before it stopped, and why.
/// What is left stays until the next pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stopped {
    pub removed: usize,
    pub reason: String,
}

/// One entry with what a listing says about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listed {
    pub name: String,
    /// Seconds since it was moved here.
    pub age_secs: u64,
    /// The bytes it holds ([`bytes_under`]).
    pub bytes: u64,
}

/// Move one artifact into this machine's trash directory, under a name
/// nothing there already holds, and record it as this invocation's so
/// the retention pass that closes the command leaves it standing.
pub fn move_to_trash(env: &Env, path: &Path) -> Result<()> {
    let trash = env.trash_dir();
    fs::create_dir_all(&trash).map_err(|e| CoreError::io(&trash, e))?;
    let base = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "item".to_owned());
    let dest = unique_in(&trash, &base);
    // Held before the move: a move that fails halfway across a
    // filesystem boundary leaves the copy here, and that copy is still
    // this run's.
    env.hold_trashed(&dest);
    crate::fs::move_any(path, &dest)
}

/// A free name for `base` inside `dir`: the stamp, then `base`, with a
/// counter between them where that name is taken.
///
/// A link, not what it points at: a relative link lands in the trash
/// pointing nowhere, and `exists` on a broken link says the name is free.
/// The rename onto it then fails, and one apply's rollback takes the whole
/// removal with it.
fn unique_in(dir: &Path, base: &str) -> PathBuf {
    let stamp = stamp();
    let mut candidate = dir.join(format!("{stamp}-{base}"));
    let mut counter = 1;
    while candidate.exists() || candidate.is_symlink() {
        candidate = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    candidate
}

/// The moment an entry is moved, as its name opens: [`clock::timestamp`]
/// with its colons replaced, `YYYY-MM-DDTHH-MM-SSZ`, since a colon is not
/// a file name character everywhere kendex runs.
fn stamp() -> String {
    clock::timestamp().replace(':', "-")
}

/// The moment a name's stamp records, or `None` where the name does not
/// open with one: the [`stamp`] shape, then the hyphen that joins it to
/// the rest of the name. Read by restoring the two colons and asking the
/// clock, so the one inverse of its timestamp is the clock's own.
fn trashed_at(name: &str) -> Option<u64> {
    let (stamp, rest) = name.split_at_checked(20)?;
    if !rest.starts_with('-') || !stamp.is_ascii() {
        return None;
    }
    if &stamp[13..14] != "-" || &stamp[16..17] != "-" {
        return None;
    }
    let iso = format!("{}:{}:{}", &stamp[..13], &stamp[14..16], &stamp[17..]);
    clock::unix_from_iso(&iso)
}

/// Every entry the trash holds, newest first; two moved in one second
/// order by name so the same directory reads the same way on every pass.
/// A trash that is not there holds nothing; one that will not read is
/// the whole answer, so nothing is judged from it.
pub fn entries(env: &Env) -> std::result::Result<Vec<Entry>, String> {
    let trash = env.trash_dir();
    let listing = match fs::read_dir(&trash) {
        Ok(listing) => listing,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("{}: {error}", trash.display())),
    };
    let mut found = Vec::new();
    for entry in listing {
        let entry = entry.map_err(|e| format!("{}: {e}", trash.display()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(trashed_at) = trashed_at(&name) else {
            continue;
        };
        found.push(Entry {
            path: entry.path(),
            name,
            trashed_at,
        });
    }
    found.sort_by(|a, b| {
        b.trashed_at
            .cmp(&a.trashed_at)
            .then_with(|| b.name.cmp(&a.name))
    });
    Ok(found)
}

/// Every entry with its age and size, newest first, for `kendex trash
/// list`. An entry that will not measure stops the listing: a size left
/// out would read as a trash smaller than it is.
pub fn list(env: &Env) -> std::result::Result<Vec<Listed>, String> {
    let now = clock::unix_now();
    entries(env)?
        .into_iter()
        .map(|entry| {
            Ok(Listed {
                age_secs: now.saturating_sub(entry.trashed_at),
                bytes: bytes_under(&entry.path)?,
                name: entry.name,
            })
        })
        .collect()
}

/// The bytes an entry holds: its own length for a file or a link, and
/// the lengths of every file under it for a directory. A link is counted
/// as itself and never read through, so a tree that links outside the
/// trash measures the trash alone. Directories themselves count nothing:
/// this is what the files hold, not what the filesystem spends on them.
pub fn bytes_under(path: &Path) -> std::result::Result<u64, String> {
    let read = |error: std::io::Error, at: &Path| format!("{}: {error}", at.display());
    let meta = fs::symlink_metadata(path).map_err(|e| read(e, path))?;
    if !meta.is_dir() {
        return Ok(meta.len());
    }
    let mut total = 0u64;
    let mut pending = vec![path.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).map_err(|e| read(e, &dir))? {
            let entry = entry.map_err(|e| read(e, &dir))?;
            let kind = entry.file_type().map_err(|e| read(e, &entry.path()))?;
            if kind.is_dir() {
                pending.push(entry.path());
            } else {
                let meta = entry.metadata().map_err(|e| read(e, &entry.path()))?;
                total = total.saturating_add(meta.len());
            }
        }
    }
    Ok(total)
}

/// The two bounds as this invocation reads them.
struct Bounds {
    max_age_secs: u64,
    max_bytes: u64,
}

/// The two bounds as `Env::count_var` reads them: a bound that is not a
/// count stops the pass with everything intact.
fn bounds(env: &Env) -> std::result::Result<Bounds, String> {
    let days = env.count_var(KEEP_DAYS_VAR, DEFAULT_KEEP_DAYS)?;
    let mb = env.count_var(KEEP_MB_VAR, DEFAULT_KEEP_MB)?;
    Ok(Bounds {
        max_age_secs: days.saturating_mul(86_400),
        max_bytes: mb.saturating_mul(1024 * 1024),
    })
}

/// Each entry's bytes by name, as [`SIZES_FILE`] holds them. An entry
/// is measured the first time a pass needs its size and read back from
/// here on every later pass, so a kept entry costs one lookup, not one
/// walk of its files. A name the listing no longer holds is dropped on
/// the next write, and an entry's record goes before its removal is
/// tried, so a removal that stops halfway leaves no number for what is
/// left of it.
struct Sizes {
    path: PathBuf,
    /// As the file held it, so a pass that learned nothing writes nothing:
    /// a no-op apply on a trash within its bounds touches no file.
    read: BTreeMap<String, u64>,
    known: BTreeMap<String, u64>,
}

impl Sizes {
    /// The record as the trash holds it, narrowed to `present`. No file
    /// is an empty record; one that will not read or does not parse is
    /// judged like a trash that will not read, and the pass stops on it.
    fn read(trash: &Path, present: &[Entry]) -> std::result::Result<Self, String> {
        let path = trash.join(SIZES_FILE);
        let read: BTreeMap<String, u64> = match fs::read_to_string(&path) {
            Ok(text) => {
                serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        let listed: BTreeSet<&str> = present.iter().map(|entry| entry.name.as_str()).collect();
        let mut known = read.clone();
        known.retain(|name, _| listed.contains(name.as_str()));
        Ok(Sizes { path, read, known })
    }

    /// The entry's bytes: as recorded, or measured now and recorded.
    fn bytes(&mut self, entry: &Entry) -> std::result::Result<u64, String> {
        if let Some(bytes) = self.known.get(&entry.name) {
            return Ok(*bytes);
        }
        let bytes = bytes_under(&entry.path)?;
        self.known.insert(entry.name.clone(), bytes);
        Ok(bytes)
    }

    fn forget(&mut self, entry: &Entry) {
        self.known.remove(&entry.name);
    }

    /// Write the record back where a pass changed it. A record that will
    /// not write is reported: the pass's decisions stand, and the next
    /// pass measures again what this one could not record.
    fn store(&self) -> std::result::Result<(), String> {
        if self.known == self.read {
            return Ok(());
        }
        let text = serde_json::to_string_pretty(&self.known)
            .map_err(|e| format!("{}: {e}", self.path.display()))?;
        crate::fs::atomic_write_no_follow(&self.path, &text).map_err(|e| e.to_string())
    }
}

/// Remove what the bounds do not keep. The keep set is every entry this
/// invocation wrote, plus, newest first, every entry within the age
/// bound while the running total of bytes stays within the size bound.
/// The entry that takes the total past the bound goes, and everything
/// older than it goes unmeasured: once the newer entries fill the bound
/// there is nothing an older one's size could change.
///
/// One directory listing per pass, one read of the size record, and one
/// measurement of each kept entry the record does not yet hold, which
/// is none on a trash the last pass already judged; no measurement at
/// all of what the age bound or the crossing already decided. A trash
/// the pass cannot read, measure or remove from stops it where it is,
/// with the count of what went before, and so does a record it cannot
/// read or write back; `Ok` carries the count of what went.
pub fn retain(env: &Env) -> std::result::Result<usize, Stopped> {
    let judged = bounds(env).and_then(|bounds| {
        let entries = entries(env)?;
        let sizes = Sizes::read(&env.trash_dir(), &entries)?;
        Ok((bounds, entries, sizes))
    });
    let (bounds, entries, mut sizes) = match judged {
        Ok(judged) => judged,
        Err(reason) => return Err(Stopped { removed: 0, reason }),
    };
    let outcome = judge(env, &bounds, &entries, &mut sizes);
    match (outcome, sizes.store()) {
        (Ok(removed), Ok(())) => Ok(removed),
        (Ok(removed), Err(reason)) => Err(Stopped { removed, reason }),
        (Err(stopped), Ok(())) => Err(stopped),
        (Err(Stopped { removed, reason }), Err(unstored)) => Err(Stopped {
            removed,
            reason: format!("{reason}; {unstored}"),
        }),
    }
}

/// The pass over the listing, newest first, once the bounds, the
/// listing and the record are in hand: [`retain`] without its reading
/// and its writing back.
fn judge(
    env: &Env,
    bounds: &Bounds,
    entries: &[Entry],
    sizes: &mut Sizes,
) -> std::result::Result<usize, Stopped> {
    let held = env.held().trashed;
    let now = clock::unix_now();
    let mut total = 0u64;
    let mut over = false;
    let mut removed = 0;
    for entry in entries {
        if held.contains(&entry.path) {
            match sizes.bytes(entry) {
                Ok(bytes) => total = total.saturating_add(bytes),
                Err(reason) => return Err(Stopped { removed, reason }),
            }
            continue;
        }
        let aged = now.saturating_sub(entry.trashed_at) > bounds.max_age_secs;
        if !over && !aged {
            match sizes.bytes(entry) {
                Ok(bytes) => total = total.saturating_add(bytes),
                Err(reason) => return Err(Stopped { removed, reason }),
            }
            if total <= bounds.max_bytes {
                continue;
            }
            over = true;
        }
        sizes.forget(entry);
        if let Err(reason) = remove(&entry.path) {
            return Err(Stopped { removed, reason });
        }
        removed += 1;
    }
    Ok(removed)
}

/// Remove every entry, or with `older_than` every entry at least that
/// old, this invocation's own excepted. Oldest first, so a removal that
/// stops leaves the newest entries, the ones a person is most likely to
/// want back. `Ok` carries the count of what went.
pub fn empty(env: &Env, older_than: Option<Duration>) -> std::result::Result<usize, Stopped> {
    let entries = match entries(env) {
        Ok(entries) => entries,
        Err(reason) => return Err(Stopped { removed: 0, reason }),
    };
    let held: BTreeSet<PathBuf> = env.held().trashed;
    let now = clock::unix_now();
    let mut removed = 0;
    for entry in entries.iter().rev() {
        if held.contains(&entry.path) {
            continue;
        }
        let age = Duration::from_secs(now.saturating_sub(entry.trashed_at));
        if older_than.is_some_and(|bound| age < bound) {
            continue;
        }
        if let Err(reason) = remove(&entry.path) {
            return Err(Stopped { removed, reason });
        }
        removed += 1;
    }
    Ok(removed)
}

fn remove(path: &Path) -> std::result::Result<(), String> {
    crate::fs::remove_any(path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests;
