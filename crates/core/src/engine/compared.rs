//! What sits at a declaration's position, measured against the bytes that
//! declaration would write.
//!
//! A conflict says files kendex did not write are in the way. That sentence
//! covers two very different decisions: content identical to the catalog,
//! where either exit lands the same bytes, and content somebody worked on,
//! where one exit loses it. The plan holds both sides at the moment it
//! refuses, and it is the only place that does — so it measures there and
//! hands the answer to every surface on the row.
//!
//! The position belongs to somebody else, which sets the reading policy:
//! never through a link, never past the bounds below, and anything that
//! cannot be read in full — one unreadable entry included — is no answer at
//! all rather than a partial one that could pass as equal.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

/// How the content in the way compares with the install it blocks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Comparison {
    /// Paths relative to the item's position whose bytes on disk are not
    /// the bytes that would install — a file only one side has included.
    /// At most `SHOWN_DIFFERING` of them: this rides in a drift row into
    /// `--json` and across IPC, and a wide walk must not inflate either.
    ///
    /// Stored as they are, never as their rendering, the way
    /// `DriftRow::detail` is: these are identities — two entries are the
    /// same file when their paths match — and escaping first would let two
    /// different names compare, and count, as one. Surfaces escape at the
    /// moment they print (`names::shown`).
    pub differing: Vec<String>,
    /// How many differ in all. Zero means the two are byte-identical.
    pub differing_total: u32,
}

/// Enough for a surface to show what changed without carrying a directory
/// listing through every report.
pub const SHOWN_DIFFERING: usize = 32;

impl Comparison {
    pub fn identical(&self) -> bool {
        self.differing_total == 0
    }
}

/// One file against the bytes that would replace it. `None` where the
/// content cannot be read as one file's bytes — a link, an unreadable
/// path, a shape that is not a file, or one larger than `MAX_BYTES` —
/// since an unread side must never compare as equal.
pub(super) fn of_file(path: &Path, bytes: &[u8]) -> Option<Comparison> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let disk = read_bounded(path)?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    let differs = disk != bytes;
    Some(Comparison {
        differing: match differs {
            true => vec![name],
            false => Vec::new(),
        },
        differing_total: u32::from(differs),
    })
}

/// A tree against the files that would replace it, matched by relative
/// path. `None` where the tree cannot be walked in full — a link anywhere
/// inside it, an entry that would not read, or more entries or bytes than
/// the bounds below allow.
pub(super) fn of_tree(root: &Path, files: &[(PathBuf, Vec<u8>)]) -> Option<Comparison> {
    let mut disk = Walked::default();
    if !collect(root, Path::new(""), 0, &mut disk) {
        return None;
    }
    let wanted: BTreeMap<&PathBuf, String> = files
        .iter()
        .map(|(rel, bytes)| (rel, crate::hash::hash_bytes(bytes)))
        .collect();
    // Sorted and deduplicated as paths, before anything renders them: two
    // names that escape alike are still two files, and merging them here
    // would drop one from the count the surfaces print.
    let mut differing: Vec<&PathBuf> = Vec::new();
    for (rel, hash) in &disk.files {
        if wanted.get(rel).is_none_or(|wanted| wanted != hash) {
            differing.push(rel);
        }
    }
    for rel in wanted.keys() {
        if !disk.files.contains_key(*rel) {
            differing.push(rel);
        }
    }
    differing.sort_unstable();
    differing.dedup();
    // Saturating rather than fallible: the count is a report of how much
    // differs, and a walk this wide is already past every bound above.
    let differing_total = u32::try_from(differing.len()).unwrap_or(u32::MAX);
    let differing: Vec<String> = differing
        .into_iter()
        .take(SHOWN_DIFFERING)
        .map(|rel| crate::paths::slashed(rel))
        .collect();
    Some(Comparison {
        differing,
        differing_total,
    })
}

/// A tree read for comparison: one hash per file rather than the bytes, so
/// a directory somebody parked in the way is never held in memory whole.
#[derive(Default)]
struct Walked {
    files: BTreeMap<PathBuf, String>,
    /// Every entry visited, directories included — what the fanout bound
    /// counts, so a tree wide in folders is bounded like one wide in files.
    visited: usize,
    /// Everything read so far. The per-file and per-tree bounds multiply
    /// without this: five hundred files at eight megabytes each is four
    /// gigabytes of reading for one position, on a path that runs at every
    /// plain refresh.
    read: u64,
}

/// What the comparison will read before it gives up. A rendered item is far
/// under both; a position somebody else owns is not ours to read without
/// limit. Depth is `hash`'s own cap, so the two walks stop together.
const MAX_ENTRIES: usize = 512;
const MAX_BYTES: u64 = 8 << 20;
const MAX_TOTAL_BYTES: u64 = 64 << 20;

/// Every file under a tree by relative path. Any entry that cannot be read
/// as a plain file drops the whole answer — a tree read in part must never
/// compare as equal, so a directory entry that will not even enumerate
/// refuses here rather than quietly leaving itself out. Links are refused
/// rather than followed: the position belongs to somebody else, and a link
/// there would aim the read at a file nothing about this item chose.
fn collect(path: &Path, rel: &Path, depth: usize, found: &mut Walked) -> bool {
    found.visited += 1;
    if depth > crate::hash::MAX_DEPTH || found.visited > MAX_ENTRIES {
        return false;
    }
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return false;
    };
    if meta.is_file() {
        let Some(bytes) = read_bounded(path) else {
            return false;
        };
        found.read += u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if found.read > MAX_TOTAL_BYTES {
            return false;
        }
        found
            .files
            .insert(rel.to_path_buf(), crate::hash::hash_bytes(&bytes));
        return true;
    }
    if !meta.is_dir() {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        return false;
    };
    for entry in entries {
        // An entry the directory will not hand over is the same refusal as
        // one that will not read: dropped from the walk, it would leave a
        // partial tree comparing as whole.
        let Ok(entry) = entry else {
            return false;
        };
        let name = entry.file_name();
        if !collect(&entry.path(), &rel.join(&name), depth + 1, found) {
            return false;
        }
    }
    true
}

/// A file's bytes, or `None` past `MAX_BYTES`. Bounded by the read itself
/// rather than by a size checked beforehand: a file that grows between the
/// two would be read whole. Opened without following a link for the same
/// reason — the type check and the open are two separate resolutions of
/// one name, and an entry swapped in between would otherwise be read
/// through. A handle's own metadata is no substitute: it reports whatever
/// the name resolved to.
fn read_bounded(path: &Path) -> Option<Vec<u8>> {
    let file = crate::fs::open_read_no_follow(path).ok()?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
    match u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_BYTES {
        true => None,
        false => Some(bytes),
    }
}

#[cfg(test)]
mod tests;
