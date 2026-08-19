//! Verify the live install matches its source on disk.
//!
//! Two checks per item:
//!
//! 1. **Source vs lock hash.** Compares the current source hash against the
//!    hash recorded in the lock at install time. A mismatch means the
//!    source dir has been edited since the last `add`/`refresh` — the lock
//!    is stale.
//!
//! 2. **Install vs source bytes** (Pi packages only). Walks both the source
//!    package dir and the installed package dir, hashing identical
//!    relative-path/content pairs. A mismatch means refresh didn't fully
//!    copy, or something modified the install. Skills, agents, and hooks
//!    have per-harness translation, so they aren't directly byte-comparable
//!    — for those, [`install_gap`] confirms instead that every artifact
//!    the harness needs to RUN the item is on disk.
//!
//! This command is the answer to "did my last refresh actually take?".
//!
//! Exit code is non-zero if any item fails verification, so this composes
//! with shell pipelines (`vstack verify -g && pi`).

use crate::config::{self, ItemKind, LockEntry};
use crate::scope::ScopeFilter;
use anyhow::Result;
use bytes::verify_pi_bytes;
use hooks::verify_hook_install;
use std::collections::HashSet;

mod bytes;
mod hooks;

/// Per-item verification result.
struct VerifyRow {
    kind: &'static str,
    name: String,
    /// Matches lock hash?
    source_ok: bool,
    /// Install matches source on disk? `None` for items we don't byte-compare.
    install_ok: Option<bool>,
    /// Human-readable note (e.g. "install path missing").
    note: Option<String>,
}

pub fn run(scope: ScopeFilter, names: &[String]) -> Result<()> {
    let mut total_failed = 0usize;
    let mut total_checked = 0usize;
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        if !lock_path.exists() {
            continue;
        }
        let lock = config::LockFile::load(&lock_path)?;
        if lock.entries.is_empty() {
            continue;
        }
        let scope_label = if global { "GLOBAL" } else { "PROJECT" };
        eprintln!("\n─ verify ({scope_label}) ─");

        let disk_skills = installed_skill_names(global);
        let mut rows: Vec<VerifyRow> = Vec::new();
        for (entry_name, entry) in &lock.entries {
            if !names.is_empty() && !names.iter().any(|n| n == entry_name) {
                continue;
            }
            rows.push(verify_entry(entry, global, &disk_skills));
        }
        rows.sort_by(|a, b| a.name.cmp(&b.name));

        let kind_w = rows.iter().map(|r| r.kind.len()).max().unwrap_or(0);
        let name_w = rows.iter().map(|r| r.name.len()).max().unwrap_or(0);
        for row in &rows {
            total_checked += 1;
            let source_mark = if row.source_ok { "✓" } else { "!" };
            let install_mark = match row.install_ok {
                Some(true) => "✓",
                Some(false) => "!",
                None => "·",
            };
            let ok = row.source_ok && row.install_ok.unwrap_or(true) && row.note.is_none();
            if !ok {
                total_failed += 1;
            }
            let note = row
                .note
                .as_deref()
                .map(|s| format!("  ({s})"))
                .unwrap_or_default();
            eprintln!(
                "  src:{} install:{}  {:kw$}  {:nw$}{}",
                source_mark,
                install_mark,
                row.kind,
                row.name,
                note,
                kw = kind_w,
                nw = name_w,
            );
        }
    }

    if total_checked == 0 {
        eprintln!("Nothing installed in selected scope(s).");
        return Ok(());
    }

    eprintln!(
        "\n{} checked, {} OK, {} failed",
        total_checked,
        total_checked - total_failed,
        total_failed
    );
    if total_failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}

fn verify_entry(entry: &LockEntry, global: bool, disk_skills: &HashSet<String>) -> VerifyRow {
    let kind = entry.kind.label_short();
    let name = entry.name.clone();

    // Source hash check (covers all kinds). Resolved once here: the row needs
    // the root to hash against AND, when there is none, the cause to report.
    use crate::refresh_sources::SourceResolution;
    let resolution = crate::refresh_sources::source_path_resolution(&entry.source);
    // Exhaustive: a new resolution state must decide here whether it has a
    // root to hash, rather than be hashed as empty because a wildcard said so.
    // `Busy` hashes nothing on purpose: a tree another process is
    // `reset --hard`-ing hashes to a value that matches nothing, and reporting
    // that as a source mismatch would be a false verdict on an install that is
    // very probably fine. The row still fails — an assertion that could not
    // read its evidence has not passed — but the note says so and names a
    // remedy that is simply "re-run", not a repair.
    let current = match &resolution {
        SourceResolution::Resolved(root) => config::compute_source_hash_in(entry, root),
        SourceResolution::Absent | SourceResolution::Refused(_) | SourceResolution::Busy => {
            String::new()
        }
    };
    let source_ok = if entry.source_hash.is_empty() {
        // Legacy lock without recorded hash — best effort: just confirm
        // we could resolve a source at all.
        !current.is_empty()
    } else {
        current == entry.source_hash
    };

    // Per-kind install check: presence first (shared with `check`), then the
    // byte comparison only Pi packages support.
    // Either gap fails the row: `verify` asserts the install is correct, and
    // an install it cannot read the evidence for is not one it can pass. The
    // note is what tells the two apart.
    let (install_ok, note) = match install_gap(entry, global, disk_skills) {
        Some(gap) => (Some(false), Some(gap.note().to_string())),
        None => match entry.kind {
            ItemKind::PiExtension => verify_pi_bytes(&entry.name, global),
            ItemKind::Extra => (None, None),
            _ => (Some(true), None),
        },
    };

    // A source that did not resolve has no hash to compare; saying only `src:!`
    // leaves the user to guess between changed content, a cache that is not on
    // this machine, and a source vstack refused — each fixed by a different
    // command, and only one of them by `vstack add`.
    // The ABSENT case carries the command that repairs it, the same one
    // `check` prints; every other unresolved state already names its own next
    // step inside its reason.
    let cause = match &resolution {
        SourceResolution::Absent => Some(crate::refresh_sources::absent_source_note(
            &entry.source,
            entry.source_repo.as_deref(),
            global,
        )),
        resolution => resolution.unresolved_note(&entry.source),
    };
    let note = match (cause, note) {
        (Some(cause), Some(note)) => Some(format!("{cause}; {note}")),
        (Some(cause), None) => Some(cause),
        (None, note) => note,
    };

    VerifyRow {
        kind,
        name,
        source_ok,
        install_ok,
        note,
    }
}

/// What stands between a lock entry and a complete install. The variants carry
/// different remedies, and conflating them is how a user gets told to reinstall
/// something that is fine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum InstallGap {
    /// A recorded artifact is not on disk. `vstack add` re-creates it.
    Missing(String),
    /// The install could not be DETERMINED: the evidence a presence check
    /// reads is itself unreadable. The note names the file to fix; reinstalling
    /// would not touch the real fault.
    Unverifiable(String),
    /// Every artifact is on disk and readable, and the harness is configured
    /// NOT to run it. `vstack add` would rewrite files that are already
    /// correct and change nothing observable, so the note names the switch and
    /// the file holding it instead.
    Disabled(String),
}

impl InstallGap {
    /// The human note, whichever gap it is.
    pub(crate) fn note(&self) -> &str {
        match self {
            Self::Missing(note) | Self::Unverifiable(note) | Self::Disabled(note) => note,
        }
    }
}

/// Is every artifact this lock entry claims to have installed still on disk?
/// `None` when nothing is missing, otherwise the gap naming what is — or
/// naming what made the answer unknowable.
///
/// `check` shares this so its phantom report covers every kind rather than
/// skills alone — a deleted agent file or Pi package is exactly the incomplete
/// install a session-start check exists to surface.
///
/// The name is validated HERE, before any join, so no caller can break the
/// contract by forgetting to; an unsafe name is reported as its own note and
/// never touches the filesystem.
///
/// `disk_skills` is the skill inventory from
/// [`config::scan_installed_skills_on_disk`], which also consults
/// checkout-anchored roots. A skill reachable only through such a root (a
/// worktree sharing the main checkout's `.agents`, VST-195) is installed, and
/// passing that evidence in is what keeps it from reading as a phantom in
/// every worktree session.
pub(crate) fn install_gap(
    entry: &LockEntry,
    global: bool,
    disk_skills: &HashSet<String>,
) -> Option<InstallGap> {
    if !crate::path_safety::is_safe_item_name(entry.kind, &entry.name) {
        return Some(InstallGap::Missing(
            "unsafe name — not resolved on disk".into(),
        ));
    }
    let missing = |(ok, note): (Option<bool>, Option<String>)| match ok {
        Some(false) => Some(InstallGap::Missing(
            note.unwrap_or_else(|| "install path missing".into()),
        )),
        _ => None,
    };
    match entry.kind {
        // A Pi package is installed only when Pi will LOAD it: the copied
        // directory AND the `packages` entry in the scope's Pi settings that
        // points at it. A copy nothing registers never loads.
        // The settings are read whatever the directory says: `vstack add`
        // registers every package it copies and refuses a settings file it
        // cannot parse, so a missing copy that short-circuited the read
        // prescribed the one command that cannot run and hid the repair it
        // waits on.
        ItemKind::PiExtension => {
            let deployed = config::pi_packages_dir(global).join(&entry.name).is_dir();
            // Second, because the file that blocks its remedy is first: a note
            // opening with the missing copy sends the reader to the one command
            // this settings file refuses, and puts the repair at the far end of
            // a line the reason width can elide.
            let absent_copy = if deployed {
                ""
            } else {
                "; install path missing too"
            };
            match crate::pi_extension::package_registration(&entry.name, global) {
                // The package may well be registered; nothing here can say.
                // Reporting it missing would send the user to reinstall a
                // package whose only fault is a settings file they must fix.
                crate::pi_extension::PackageRegistration::Unreadable { reason } => {
                    Some(InstallGap::Unverifiable(format!(
                        "registration unknown — Pi settings unreadable: {reason}{absent_copy}"
                    )))
                }
                // One `vstack add` copies the package and registers it, so
                // whichever of the two the readable settings say is subsumed.
                _ if !deployed => Some(InstallGap::Missing("install path missing".to_string())),
                crate::pi_extension::PackageRegistration::Registered => None,
                crate::pi_extension::PackageRegistration::Absent => Some(InstallGap::Missing(
                    "package present but not registered".to_string(),
                )),
            }
        }
        ItemKind::Skill => {
            if disk_skills.contains(&entry.name) {
                return None;
            }
            let gap = missing(verify_skill_install(&entry.name, &entry.harnesses, global))?;
            if global {
                return Some(gap);
            }
            // The canonical a project skill installs to lives under `.agents`,
            // and the `vstack add` this gap prescribes REFUSES a `.agents` that
            // is not this checkout's own directory — so a path fault there is
            // named first, before the reinstall it blocks. Ok when `.agents` is
            // simply absent, which is the ordinary missing-install case.
            match crate::path_safety::ensure_agents_dir_within_project(&config::project_root()) {
                Ok(()) => Some(gap),
                Err(err) => Some(InstallGap::Unverifiable(format!("{err:#}; {}", gap.note()))),
            }
        }
        ItemKind::Agent => missing(verify_agent_install(&entry.name, &entry.harnesses, global)),
        ItemKind::Hook => verify_hook_install(entry, global),
        // Extras have no single recorded install path to check.
        ItemKind::Extra => None,
    }
}

/// Skill names the disk scan can see, including through anchored roots.
pub(crate) fn installed_skill_names(global: bool) -> HashSet<String> {
    config::scan_installed_skills_on_disk(global)
        .into_iter()
        .map(|item| item.name)
        .collect()
}

fn verify_skill_install(
    name: &str,
    _harnesses: &[String],
    global: bool,
) -> (Option<bool>, Option<String>) {
    let canonical = if global {
        config::global_state_dir().join("skills").join(name)
    } else {
        config::project_root()
            .join(".agents")
            .join("skills")
            .join(name)
    };
    if canonical.exists() {
        (Some(true), None)
    } else {
        (Some(false), Some("install path missing".into()))
    }
}

fn verify_agent_install(
    name: &str,
    harnesses: &[String],
    global: bool,
) -> (Option<bool>, Option<String>) {
    let mut missing = Vec::new();
    for h in harnesses {
        let Some(harness) = crate::harness::Harness::from_id(h) else {
            continue;
        };
        let path = harness
            .agents_dir(global)
            .join(harness.agent_filename(name));
        if !path.exists() {
            missing.push(h.clone());
        }
    }
    if missing.is_empty() {
        (Some(true), None)
    } else {
        (
            Some(false),
            Some(format!("missing in: {}", missing.join(", "))),
        )
    }
}

#[cfg(test)]
mod scope_tests;
