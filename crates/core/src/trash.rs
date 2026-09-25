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
//! `apply`, `refresh` and `remove`, after the command's own writes, never
//! in the middle of one. A bound it cannot read stops the pass with
//! everything intact, and so does an entry it cannot measure or remove.
//!
//! [`empty`] is the person's own request, through `kendex trash empty`:
//! every entry, or every entry past an age, this invocation's excepted.
//!
//! A name that does not open with kendex's stamp is not kendex's entry:
//! it is neither listed nor removed.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};

pub use crate::remote::store::Retention;

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
    let stamp = clock::timestamp().replace(':', "-");
    let mut candidate = dir.join(format!("{stamp}-{base}"));
    let mut counter = 1;
    while candidate.exists() || candidate.is_symlink() {
        candidate = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    candidate
}

/// The moment a name's stamp records, or `None` where the name does not
/// open with one. The stamp is [`clock::timestamp`] with its colons
/// replaced, `YYYY-MM-DDTHH-MM-SSZ`, followed by the hyphen that joins it
/// to the rest of the name.
fn trashed_at(name: &str) -> Option<u64> {
    let bytes = name.as_bytes();
    if bytes.len() < 21 || bytes[20] != b'-' {
        return None;
    }
    let stamp = &bytes[..20];
    if stamp[10] != b'T' || stamp[19] != b'Z' {
        return None;
    }
    if [4, 7, 13, 16].iter().any(|&at| stamp[at] != b'-') {
        return None;
    }
    let field = |from: usize, to: usize| -> Option<u32> {
        let digits = &stamp[from..to];
        if !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        std::str::from_utf8(digits).ok()?.parse().ok()
    };
    clock::unix_from_civil(
        i64::from(field(0, 4)?),
        field(5, 7)?,
        field(8, 10)?,
        field(11, 13)?,
        field(14, 16)?,
        field(17, 19)?,
    )
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

/// A variable exported empty is how a shell profile or a job neutralises
/// one, so it reads as unset; anything else that is not a count stops the
/// pass with everything intact.
fn count(env: &Env, var: &str, default: u64) -> std::result::Result<u64, String> {
    match env.var(var).map(str::trim) {
        None | Some("") => Ok(default),
        Some(text) => text
            .parse()
            .map_err(|_| format!("{var}={text:?} is not a count")),
    }
}

fn bounds(env: &Env) -> std::result::Result<Bounds, String> {
    let days = count(env, KEEP_DAYS_VAR, DEFAULT_KEEP_DAYS)?;
    let mb = count(env, KEEP_MB_VAR, DEFAULT_KEEP_MB)?;
    Ok(Bounds {
        max_age_secs: days.saturating_mul(86_400),
        max_bytes: mb.saturating_mul(1024 * 1024),
    })
}

/// Remove what the bounds do not keep. The keep set is every entry this
/// invocation wrote, plus, newest first, every entry within the age
/// bound while the running total of bytes stays within the size bound.
/// The entry that takes the total past the bound goes, and everything
/// older than it goes unmeasured: once the newer entries fill the bound
/// there is nothing an older one's size could change.
///
/// One directory listing and one measurement of the kept entries per
/// pass, and no measurement at all of what the age bound or the
/// crossing already decided. A trash the pass cannot read, measure or
/// remove from stops it where it is, with the count of what went before.
pub fn retain(env: &Env) -> Retention {
    let judged = bounds(env).and_then(|bounds| entries(env).map(|entries| (bounds, entries)));
    let (bounds, entries) = match judged {
        Ok(judged) => judged,
        Err(reason) => return Retention::Stopped { removed: 0, reason },
    };
    let held = env.held().trashed;
    let now = clock::unix_now();
    let mut total = 0u64;
    let mut over = false;
    let mut removed = 0;
    for entry in &entries {
        let measured = |total: &mut u64| -> std::result::Result<(), String> {
            *total = total.saturating_add(bytes_under(&entry.path)?);
            Ok(())
        };
        if held.contains(&entry.path) {
            if let Err(reason) = measured(&mut total) {
                return Retention::Stopped { removed, reason };
            }
            continue;
        }
        let aged = now.saturating_sub(entry.trashed_at) > bounds.max_age_secs;
        if !over && !aged {
            if let Err(reason) = measured(&mut total) {
                return Retention::Stopped { removed, reason };
            }
            if total <= bounds.max_bytes {
                continue;
            }
            over = true;
        }
        if let Err(reason) = remove(&entry.path) {
            return Retention::Stopped { removed, reason };
        }
        removed += 1;
    }
    Retention::Pruned { removed }
}

/// Remove every entry, or with `older_than` every entry at least that
/// old, this invocation's own excepted. Oldest first, so a removal that
/// stops leaves the newest entries, the ones a person is most likely to
/// want back.
pub fn empty(env: &Env, older_than: Option<Duration>) -> Retention {
    let entries = match entries(env) {
        Ok(entries) => entries,
        Err(reason) => return Retention::Stopped { removed: 0, reason },
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
            return Retention::Stopped { removed, reason };
        }
        removed += 1;
    }
    Retention::Pruned { removed }
}

fn remove(path: &Path) -> std::result::Result<(), String> {
    crate::fs::remove_any(path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests;
