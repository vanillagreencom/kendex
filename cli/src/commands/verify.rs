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
use std::collections::HashSet;
use std::path::{Path, PathBuf};

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
    let current = match &resolution {
        SourceResolution::Resolved(root) => config::compute_source_hash_in(entry, root),
        SourceResolution::Absent | SourceResolution::Refused(_) => String::new(),
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
    let note = match (resolution.unresolved_note(&entry.source), note) {
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

/// What stands between a lock entry and a complete install. The two variants
/// carry different remedies, and conflating them is how a user gets told to
/// reinstall something that is fine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum InstallGap {
    /// A recorded artifact is not on disk. `vstack add` re-creates it.
    Missing(String),
    /// The install could not be DETERMINED: the evidence a presence check
    /// reads is itself unreadable. The note names the file to fix; reinstalling
    /// would not touch the real fault.
    Unverifiable(String),
}

impl InstallGap {
    /// The human note, whichever gap it is.
    pub(crate) fn note(&self) -> &str {
        match self {
            Self::Missing(note) | Self::Unverifiable(note) => note,
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
        ItemKind::PiExtension => {
            if !config::pi_packages_dir(global).join(&entry.name).is_dir() {
                return Some(InstallGap::Missing("install path missing".to_string()));
            }
            match crate::pi_extension::package_registration(&entry.name, global) {
                crate::pi_extension::PackageRegistration::Registered => None,
                crate::pi_extension::PackageRegistration::Absent => Some(InstallGap::Missing(
                    "package present but not registered".to_string(),
                )),
                // The package may well be registered; nothing here can say.
                // Reporting it missing would send the user to reinstall a
                // package whose only fault is a settings file they must fix.
                crate::pi_extension::PackageRegistration::Unreadable { reason } => {
                    Some(InstallGap::Unverifiable(format!(
                        "registration unknown — Pi settings unreadable: {reason}"
                    )))
                }
            }
        }
        ItemKind::Skill => {
            if disk_skills.contains(&entry.name) {
                return None;
            }
            missing(verify_skill_install(&entry.name, &entry.harnesses, global))
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

/// Byte comparison of an installed Pi package against its source. Presence is
/// [`missing_install`]'s job; this runs only once the install dir exists.
fn verify_pi_bytes(name: &str, global: bool) -> (Option<bool>, Option<String>) {
    let install_dir = config::pi_packages_dir(global).join(name);
    // Locate source dir for this package by reading the source-index sidecar.
    let source_dir = match locate_pi_source(name, global) {
        Some(p) => p,
        None => return (None, Some("source path unresolvable".into())),
    };
    let src_hash = hash_dir_walk(&source_dir);
    let install_hash = hash_dir_walk(&install_dir);
    let ok = src_hash == install_hash;
    let note = if ok {
        None
    } else {
        Some(format!(
            "install drift: src {} vs install {}",
            short_hash(src_hash),
            short_hash(install_hash)
        ))
    };
    (Some(ok), note)
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

/// Every artifact a hook needs to RUN, per harness it was installed for.
///
/// Two lists, because they carry different remedies: something a reinstall
/// re-creates, and something only repairing a named file can answer. A
/// registration file that exists and cannot be parsed belongs to the second —
/// reported as missing, it prescribed `vstack add` on a file the installer
/// refuses to touch.
fn verify_hook_install(entry: &LockEntry, global: bool) -> Option<InstallGap> {
    let name = &entry.name;
    let mut missing = Vec::new();
    let mut unverifiable = Vec::new();
    // The hook's own source definition: what decided the event and the prose
    // at install time, and the only thing that can say what to demand now.
    let source_hook = hook_source(entry);
    for h in &entry.harnesses {
        let Some(harness) = crate::harness::Harness::from_id(h) else {
            continue;
        };
        match harness {
            crate::harness::Harness::ClaudeCode => {
                // A hook is installed only when claude will RUN it: the
                // script AND a settings registration under the hook's own
                // event. A script whose registration is gone never fires —
                // `session-drift-check` included, which cannot then diagnose
                // its own absence.
                let path = harness
                    .hooks_dir(global)
                    .map(|d| d.join(format!("{name}.sh")));
                if path.is_none_or(|p| !p.exists()) {
                    missing.push(format!("{h}: script missing"));
                } else {
                    match crate::installer::claude_hook_registration(
                        global,
                        name,
                        source_hook.as_ref().map(|hook| hook.event.as_str()),
                    ) {
                        crate::installer::HookRegistration::Registered => {}
                        crate::installer::HookRegistration::Absent => {
                            missing.push(format!("{h}: script present but not registered"));
                        }
                        crate::installer::HookRegistration::Unreadable(reason) => {
                            unverifiable.push(format!("{h}: registration unverifiable — {reason}"));
                        }
                    }
                }
            }
            crate::harness::Harness::Cursor => {
                let path = crate::installer::cursor_hook_rule_path(global, name);
                if !path.exists() {
                    missing.push(format!("{h}: rule missing"));
                }
            }
            crate::harness::Harness::OpenCode => {
                let path = crate::installer::opencode_hook_instruction_path(global, name);
                if !path.exists() {
                    missing.push(format!("{h}: instruction missing"));
                }
            }
            crate::harness::Harness::Codex => {
                // Native install: script under <root>/.codex/hooks/.
                // Prose-fallback: `## Safety: <name>` block in some agent toml.
                //
                // A scope with no Codex agents at all has NO artifact to
                // miss: an event with no Codex equivalent installs as prose
                // inside agent TOMLs, so until one exists there is nothing to
                // write. The lock still records codex — that is what makes
                // reconciliation add the block to the first agent installed
                // later — and demanding a file here would report permanent
                // drift no `add` or `refresh` could ever clear.
                let root = crate::installer::codex_root(global);
                let script = root.join("hooks").join(format!("{name}.sh"));
                let has_script = script.exists();
                match source_hook
                    .as_ref()
                    .map(|hook| (hook, crate::installer::codex_event_for(&hook.event)))
                {
                    // A native hook is installed only when codex will
                    // RUN it: the script, its `hooks.json` registration,
                    // and the `hooks` feature. Any one of the three
                    // missing is a hook that silently never fires.
                    Some((_, Some(codex_event))) => {
                        if !has_script {
                            missing.push(format!("{h}: script missing"));
                        } else {
                            for gap in
                                crate::installer::codex_native_hook_gaps(global, name, codex_event)
                            {
                                let note = format!("{h}: {}", gap.describe());
                                if gap.is_unreadable() {
                                    unverifiable.push(note);
                                } else {
                                    missing.push(note);
                                }
                            }
                        }
                    }
                    // Prose fallback: the block counts only when it still
                    // carries the hook's action line, asked through the one
                    // predicate the install writes against — a heading whose
                    // body was deleted is a hook codex no longer carries.
                    // A scope with no codex agents has nothing to miss.
                    Some((hook, None)) => {
                        let has_prose = !has_script
                            && crate::installer::codex_agent_carries_hook_prose(&root, hook);
                        if !has_script && !has_prose && codex_scope_has_agents(&root) {
                            missing.push(format!("{h}: no script and no prose"));
                        }
                    }
                    // No source to read: nothing here can say whether this
                    // hook installs natively or as prose, so neither artifact
                    // can be demanded. The unresolvable source is reported in
                    // its own right.
                    None => {}
                }
            }
            crate::harness::Harness::Pi => {
                // Pi has no script-based per-hook install path — the safety
                // hooks ship as the @vanillagreen/pi-hooks extension instead,
                // which is verified separately as a Pi package. Nothing to
                // check here.
            }
        }
    }
    // Unverifiable wins the classification when both are present: the file it
    // names has to be repaired before any reinstall can even run, and the
    // note carries what is missing alongside it.
    let notes: Vec<String> = unverifiable.iter().chain(missing.iter()).cloned().collect();
    if notes.is_empty() {
        None
    } else if unverifiable.is_empty() {
        Some(InstallGap::Missing(notes.join("; ")))
    } else {
        Some(InstallGap::Unverifiable(notes.join("; ")))
    }
}

/// The hook definition in its resolved source — what decided the event, the
/// Codex native-vs-prose split, and the prose text itself at install time. The
/// INSTALLED artifacts cannot answer any of that: a deleted registration takes
/// its own evidence with it.
///
/// `None` when the source cannot be resolved or read; the source problem is
/// reported in its own right, and each caller decides what an unanswerable
/// question means for presence.
fn hook_source(entry: &LockEntry) -> Option<crate::hook::Hook> {
    let root = config::resolve_source_path(&entry.source)?;
    let path = crate::catalog::find_item_path(&root, ItemKind::Hook, &entry.name)?;
    crate::hook::Hook::from_file(&path).ok()
}

/// Does this scope have any Codex agent for a prose fallback to live in?
fn codex_scope_has_agents(codex_root: &Path) -> bool {
    std::fs::read_dir(codex_root.join("agents")).is_ok_and(|entries| {
        entries.flatten().any(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "toml")
        })
    })
}

/// Walk a directory and compute an order-stable hash of (relative path, content).
/// Mirrors `config::hash_dir_bytes` so the two are directly comparable.
fn hash_dir_walk(dir: &Path) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x00000100000001B3;
    let mut state = FNV_OFFSET;
    let mut walker = walkdir::WalkDir::new(dir)
        .min_depth(1)
        .sort_by_file_name()
        .into_iter();
    while let Some(entry) = walker.next() {
        let Ok(entry) = entry else { continue };
        if entry.file_type().is_dir()
            && should_skip_hash_dir(entry.file_name().to_string_lossy().as_ref())
        {
            walker.skip_current_dir();
            continue;
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry.path().strip_prefix(dir).unwrap_or(entry.path());
        for &b in rel.to_string_lossy().as_bytes() {
            state ^= b as u64;
            state = state.wrapping_mul(FNV_PRIME);
        }
        if let Ok(content) = std::fs::read(entry.path()) {
            for &b in &content {
                state ^= b as u64;
                state = state.wrapping_mul(FNV_PRIME);
            }
        }
    }
    state
}

fn should_skip_hash_dir(name: &str) -> bool {
    // Keep in sync with config::should_skip_hash_dir. `.test-output` is a
    // pi-claude-bridge integration-test artifact dir; running its tests
    // creates symlinks/logs that are gitignored and never part of the
    // distributed package, so they must not influence install drift.
    matches!(
        name,
        "node_modules"
            | ".git"
            | ".turbo"
            | ".next"
            | ".cache"
            | "build"
            | "out"
            | "coverage"
            | ".pi"
            | ".test-output"
    )
}

fn short_hash(h: u64) -> String {
    format!("{h:016x}").chars().take(8).collect()
}

/// Walk the per-scope `.vstack-source.json` to find the source path for a
/// Pi package. Falls back to None if not recorded.
fn locate_pi_source(name: &str, global: bool) -> Option<PathBuf> {
    let index_path = if global {
        crate::config::pi_global_dir().join(".vstack-source.json")
    } else {
        crate::config::pi_project_dir().join(".vstack-source.json")
    };
    let raw = std::fs::read_to_string(&index_path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let entry = json.get(name)?;
    let source_path = entry.get("sourcePath").and_then(|v| v.as_str())?;
    let p = PathBuf::from(source_path);
    if p.is_dir() { Some(p) } else { None }
}
