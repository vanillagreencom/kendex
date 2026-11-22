//! The checkout's scratch for the watch's retention duty: each direct entry
//! of the main checkout's `tmp/` that nothing uses. The progress report
//! folder is not scratch: a setting places it anywhere, a folder of the
//! owner's own among them, so only its stamped reports leave it, by the
//! duty's own rule.
//!
//! An entry is used while a citing text names it, a running process's
//! command line names it, its name carries the key of an item with a lane
//! record or a standing item record, or it was written within the
//! retention. The citing texts are the fleet record, the item records, the
//! handoffs, the settings files and the private env file the settings read,
//! and every scratch file the duty judges and keeps, read as it joins, so a
//! brief keeps the files it names.
//!
//! Never judged: the state store's own entries (the records and their
//! locks, the watch's files beside its log), every lock file, a folder other
//! than a reader or waiter folder `waiter.*`, a dotfile, a name with a
//! character outside `[A-Za-z0-9._-]`, which no text is read for, the
//! progress reports and their delivery attempts, which the duty judges by
//! their own rule, and the live follow's reader folder: the newest one whose
//! `watch.log` is the watch's log. A folder's own write time says nothing of
//! what it holds, and the other folders under `tmp/` are stores with an
//! owner of their own: the item records, the intents, the handoffs, the
//! mailboxes, an item's run folder.

use std::collections::{BTreeSet, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};

use agent_runtime::record::Document;
use serde_json::Value;

use crate::archive::{name_of, read_dir};
use crate::error::Result;
use crate::state;
use crate::watch::Paths;

/// The bytes of a scratch file read for the names it cites: a citing text,
/// a brief, a plan or a handoff, is well under it, and a larger file is a
/// log or evidence, never a citer.
const CITER_BYTES: u64 = 256 * 1024;

/// The prefix of the folders a reader or a waiter is made in.
const WAITER: &str = "waiter.";

/// Every name a text spells: each run of `[A-Za-z0-9._-]` and each of its
/// prefixes up to a `.`, so `tmp/brief.md.` at a sentence's end names
/// `brief.md`. A run after a `\` is read with and without its first
/// letter: a JSON or TOML string escapes a line break as `\n`, so a name
/// opening a line of one is spelled after that letter. A longer name keeps
/// a shorter one only where it extends it at a `.`, and a run read twice
/// keeps one more, never less.
#[derive(Debug, Default)]
struct Names(HashSet<String>);

fn name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')
}

impl Names {
    fn read(&mut self, text: &str) {
        let mut start = None;
        for (at, c) in text.char_indices().chain([(text.len(), ' ')]) {
            match (name_char(c), start) {
                (true, None) => start = Some(at),
                (false, Some(from)) => {
                    let run = &text[from..at];
                    self.run(run);
                    // A run is ASCII, so its first letter is one byte.
                    if text[..from].ends_with('\\') {
                        self.run(&run[1..]);
                    }
                    start = None;
                }
                (true, Some(_)) | (false, None) => {}
            }
        }
    }

    fn run(&mut self, run: &str) {
        if run.is_empty() {
            return;
        }
        for (at, _) in run.match_indices('.').filter(|(at, _)| *at > 0) {
            self.0.insert(run[..at].to_owned());
        }
        self.0.insert(run.to_owned());
    }

    /// Each string a record holds, read as the text it is.
    fn read_value(&mut self, value: &Value) {
        match value {
            Value::String(text) => self.read(text),
            Value::Array(values) => values.iter().for_each(|v| self.read_value(v)),
            Value::Object(fields) => fields.values().for_each(|v| self.read_value(v)),
            Value::Null | Value::Bool(_) | Value::Number(_) => {}
        }
    }
}

/// What the duty judges the scratch by.
pub(super) struct Inputs<'a> {
    pub paths: &'a Paths,
    /// The main checkout, whose `tmp/` is judged and whose settings files
    /// cite.
    pub checkout: &'a Path,
    /// The private env file the settings read, `None` under
    /// `--no-private-env`.
    pub private_env: Option<&'a Path>,
    pub record: &'a Document,
    /// The items with a lane record or a standing item record.
    pub items: &'a BTreeSet<String>,
    pub cutoff: u64,
}

/// The unused entries, or why none was judged: a process table that cannot
/// be read leaves every entry, since a process holding one is unknown.
#[derive(Debug, Default)]
pub(super) struct Judged {
    pub paths: Vec<PathBuf>,
    pub unread: Option<String>,
}

#[derive(Debug)]
struct Candidate {
    path: PathBuf,
    name: String,
    folder: bool,
    written: u64,
}

impl Candidate {
    fn used(&self, names: &Names, items: &BTreeSet<String>, cutoff: u64) -> bool {
        self.written >= cutoff
            || names.0.contains(&self.name)
            || items
                .iter()
                .any(|item| crate::archive::names_item(&self.name, item))
    }
}

/// Whether `name` is one the duty never judges.
fn kept_by_name(name: &str, paths: &Paths) -> bool {
    name.starts_with('.')
        || !name.chars().all(name_char)
        || name.starts_with(&name_of(&paths.state))
        || name.starts_with("workflow-state-")
        || name.starts_with(&paths.runner_prefix())
        || name.ends_with(".lock")
        || super::retention::is_progress_report(name)
        || super::retention::is_report_attempt(name)
}

/// The epoch second of an entry's newest write: a file's own, or a
/// folder's and each regular file directly in it. A link in a folder is no
/// write of its own: making it wrote the folder.
fn newest_write(path: &Path, meta: &std::fs::Metadata) -> Result<u64> {
    let mut newest = super::retention::epoch_of(
        meta.modified()
            .map_err(|e| agent_runtime::Error::io("modified", path, e))?,
    );
    if meta.is_dir() {
        for child in read_dir(path)? {
            match std::fs::symlink_metadata(&child) {
                Ok(m) if m.is_file() => {
                    let at = m
                        .modified()
                        .map_err(|e| agent_runtime::Error::io("modified", &child, e))?;
                    newest = newest.max(super::retention::epoch_of(at));
                }
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(agent_runtime::Error::io("modified", &child, e).into()),
            }
        }
    }
    Ok(newest)
}

/// The head of a file that stands, [`CITER_BYTES`] at most; `None` where it
/// went since it was listed.
fn head(path: &Path) -> Result<Option<String>> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(agent_runtime::Error::io("read", path, e).into()),
    };
    let mut bytes = Vec::new();
    file.take(CITER_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|e| agent_runtime::Error::io("read", path, e))?;
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

/// The fleet record's pointers to the overseer handoff a controller's
/// launch named (`--handoff`), which its successor and a recovery keep.
const HANDOFF_POINTERS: [&str; 3] = [
    "/controller/handoff",
    "/controller/pending/handoff",
    "/pending/handoff",
];

/// The texts that cite before any scratch does: the fleet record, each
/// item record, each handoff, each settings file and the private env file.
/// A handoff is each file under `handoffs/` of the state directory and of
/// the main checkout's `tmp/`, where the overseer's `handoff --fleet`
/// writes by default whatever the state directory, and the file the record
/// names, a relative one under the main checkout, the overseer's cwd.
fn seeds(input: &Inputs) -> Result<Names> {
    let record = Value::Object(input.record.clone());
    let mut names = Names::default();
    names.read_value(&record);
    let mut files: Vec<PathBuf> = input
        .items
        .iter()
        .map(|item| state::item_path(&input.paths.dir, item))
        .collect();
    let mut handoffs = BTreeSet::new();
    for dir in [
        input.paths.dir.join("handoffs"),
        input.checkout.join("tmp").join("handoffs"),
    ] {
        if handoffs.insert(crate::archive::resolve(&dir)) {
            files.extend(read_dir(&dir)?);
        }
    }
    files.extend(
        HANDOFF_POINTERS
            .iter()
            .filter_map(|pointer| record.pointer(pointer).and_then(Value::as_str))
            .map(|named| input.checkout.join(named)),
    );
    files.extend(
        agent_runtime::settings::SETTINGS_FILES
            .iter()
            .map(|file| input.checkout.join(file)),
    );
    files.extend(input.private_env.map(Path::to_path_buf));
    for file in files {
        // A link is read through: a worktree's `.env.local` links to its
        // main checkout's, and a citer read keeps more, never less.
        if std::fs::metadata(&file).is_ok_and(|m| m.is_file())
            && let Some(text) = head(&file)?
        {
            names.read(&text);
        }
    }
    Ok(names)
}

/// The entries of the main checkout's `tmp/` nothing uses.
pub(super) fn unused(input: &Inputs) -> Result<Judged> {
    let mut candidates = Vec::new();
    let mut readers: Vec<(u64, PathBuf)> = Vec::new();
    for path in read_dir(&input.checkout.join("tmp"))? {
        let name = name_of(&path);
        if kept_by_name(&name, input.paths) {
            continue;
        }
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(agent_runtime::Error::io("read", &path, e).into()),
        };
        let folder = meta.is_dir();
        if folder && !name.starts_with(WAITER) {
            continue;
        }
        let written = newest_write(&path, &meta)?;
        if folder && super::claim::same_file(&path.join("watch.log"), &input.paths.log) {
            readers.push((written, path.clone()));
        }
        candidates.push(Candidate {
            path,
            name,
            folder,
            written,
        });
    }
    if let Some((_, live)) = readers.iter().max() {
        candidates.retain(|c| &c.path != live);
    }
    if candidates.is_empty() {
        return Ok(Judged::default());
    }
    let mut names = seeds(input)?;
    match agent_runtime::process::command_lines() {
        Ok(lines) => {
            for word in lines.iter().flat_map(|(_, words)| words) {
                names.read(word);
            }
        }
        Err(e) => {
            return Ok(Judged {
                paths: Vec::new(),
                unread: Some(format!("scratch=unjudged cause=process-table-{}", e.cause)),
            });
        }
    }
    // A used file's citations keep what it names; read each once, until
    // no file joins.
    let mut read: HashSet<PathBuf> = HashSet::new();
    loop {
        let mut joined = false;
        for c in &candidates {
            if c.folder || read.contains(&c.path) || !c.used(&names, input.items, input.cutoff) {
                continue;
            }
            read.insert(c.path.clone());
            if let Some(text) = head(&c.path)? {
                names.read(&text);
                joined = true;
            }
        }
        if !joined {
            break;
        }
    }
    Ok(Judged {
        paths: candidates
            .into_iter()
            .filter(|c| !c.used(&names, input.items, input.cutoff))
            .map(|c| c.path)
            .collect(),
        unread: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A name is cited where a text spells it whole, at a path's end, before
    /// a `/` or a sentence's `.`, and not inside a longer name.
    #[test]
    fn a_text_cites_a_name_it_spells_whole() {
        for (text, name, cited) in [
            ("bash tmp/nested-slot.sh --x", "nested-slot.sh", true),
            ("see /home/a/tmp/brief.md.", "brief.md", true),
            ("log=tmp/waiter.Ab12/wait.log", "waiter.Ab12", true),
            (
                "\"path\":\"tmp/inventory-1.json\"",
                "inventory-1.json",
                true,
            ),
            ("\"Keep:\\nbrief.md\"", "brief.md", true),
            ("tmp/old-brief.md", "brief.md", false),
            ("tmp/brief.mdx", "brief.md", false),
            ("", "brief.md", false),
        ] {
            let mut names = Names::default();
            names.read(text);
            assert_eq!(names.0.contains(name), cited, "{text:?} {name}");
        }
    }
}
