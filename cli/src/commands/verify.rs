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
use std::collections::HashSet;

mod bytes;

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

/// Where a harness's switch lands, in the one wording every harness shares —
/// what is off, and the file that turns it back on. Codex's answer comes
/// classified with its other native gaps; claude's and cursor's arrive here.
fn record_switch(
    harness: &str,
    switch: crate::installer::HookSwitch,
    disabled: &mut Vec<String>,
    unverifiable: &mut Vec<String>,
) {
    match switch {
        crate::installer::HookSwitch::On => {}
        crate::installer::HookSwitch::Off(note) => {
            disabled.push(format!("{harness}: switched off — {note}"));
        }
        crate::installer::HookSwitch::Unreadable(reason) => {
            unverifiable.push(format!("{harness}: switch unverifiable — {reason}"));
        }
    }
}

/// The carrier package a Pi-locked hook runs from: deployed in a scope Pi
/// loads, and registered there.
///
/// Only demanded when the contract routes this hook's event to Pi's extension
/// and the hook's own `harnesses:` allowlist admits Pi — the same two questions
/// [`crate::installer::enforcement::resolve`] asks, so a level and a drift line
/// cannot disagree. A hook with no readable source definition demands nothing:
/// its event is unknown, and the unresolvable source is reported in its own
/// right.
///
/// Asked through [`crate::installer::enforcement::pi_carrier_state`] — the one
/// probe the enforcement level is derived from — so a `verify` row and a `list`
/// level cannot disagree about the carrier, and an unreadable `settings.json`
/// is unverifiable naming the file rather than a missing package.
fn record_pi_carrier(
    harness: &str,
    source_hook: Option<&crate::hook::Hook>,
    global: bool,
    missing: &mut Vec<String>,
    unverifiable: &mut Vec<String>,
) {
    use crate::installer::contract::{self, Cell, Mechanism, PI_HOOKS_PACKAGE};
    use crate::installer::enforcement::PiCarrier;
    let Some(hook) = source_hook else { return };
    if !hook.applies_to(crate::harness::Harness::Pi.id()) {
        return;
    }
    let carried = contract::cell(&hook.event, crate::harness::Harness::Pi)
        .and_then(Cell::mechanism)
        .is_some_and(|mechanism| mechanism == Mechanism::PiHooksExtension);
    if !carried {
        return;
    }
    match crate::installer::enforcement::pi_carrier_state(global) {
        PiCarrier::Ready => {}
        PiCarrier::Unregistered => missing.push(format!(
            "{harness}: {PI_HOOKS_PACKAGE} present but not registered in Pi settings — Pi loads no hook until it is"
        )),
        PiCarrier::Absent => {
            // Short enough to survive the phantom section's label width: a
            // remedy elided mid-command cannot be pasted.
            let scope_flag = if global { " --global" } else { "" };
            missing.push(format!(
                "{harness}: {PI_HOOKS_PACKAGE} not installed — run `vstack add{scope_flag} --pi-extension {}`",
                crate::display::command_arg(PI_HOOKS_PACKAGE)
            ));
        }
        PiCarrier::Unknown(reason) => unverifiable.push(format!(
            "{harness}: {PI_HOOKS_PACKAGE} registration unverifiable — {}",
            crate::display::display_reason(&reason)
        )),
    }
}

/// Every artifact a hook needs to RUN, per harness it was installed for.
///
/// Three lists, because they carry three remedies: something a reinstall
/// re-creates, something only repairing a named file can answer, and something
/// only a settings change can. A registration file that exists and cannot be
/// parsed belongs to the second — reported as missing, it prescribed `vstack
/// add` on a file the installer refuses to touch. A harness switched off
/// belongs to the third: every artifact is there and correct, and a reinstall
/// changes nothing the harness will act on.
fn verify_hook_install(entry: &LockEntry, global: bool) -> Option<InstallGap> {
    let name = &entry.name;
    let mut missing = Vec::new();
    let mut unverifiable = Vec::new();
    let mut disabled = Vec::new();
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
                        source_hook
                            .as_ref()
                            .map(|hook| crate::installer::RegistrationSlot {
                                event: hook.event.as_str(),
                                matcher: hook.matcher.as_deref(),
                            }),
                    ) {
                        crate::installer::HookRegistration::Registered => {}
                        crate::installer::HookRegistration::Absent => {
                            missing.push(format!("{h}: script present but not registered"));
                        }
                        crate::installer::HookRegistration::Unreadable(reason) => {
                            unverifiable.push(format!("{h}: registration unverifiable — {reason}"));
                        }
                    }
                    // A registration claude will not act on. This is the twin
                    // of Codex's `[features] hooks`: the registration is
                    // perfect and the harness runs none of it — including
                    // `session-drift-check`, which is then the one hook that
                    // cannot report the state it exists to report.
                    record_switch(
                        h,
                        crate::installer::hook_switch(harness, global, name),
                        &mut disabled,
                        &mut unverifiable,
                    );
                }
            }
            crate::harness::Harness::Cursor => {
                // A rule is installed only when cursor will APPLY it, which
                // its own `alwaysApply` decides. The file existing was the
                // whole test, so a rule edited down to description-matching —
                // attached when the model judges it relevant, and for a safety
                // rule that is not the same as attached — read as installed.
                let path = crate::installer::cursor_hook_rule_path(global, name);
                if !path.exists() {
                    missing.push(format!("{h}: rule missing"));
                } else {
                    record_switch(
                        h,
                        crate::installer::hook_switch(harness, global, name),
                        &mut disabled,
                        &mut unverifiable,
                    );
                }
            }
            crate::harness::Harness::OpenCode => {
                // A hook is installed only when opencode will LOAD it: the
                // instruction file AND the `opencode.json` entry naming it.
                // A file nothing references is prose no agent ever sees.
                //
                // There is no third condition to check: opencode exposes no
                // switch that suppresses instructions it is configured to
                // load, so the entry's absence is the only off state, and it
                // is already the missing case below. The config vstack reads
                // is the one opencode resolves — `$OPENCODE_CONFIG` and the
                // `.jsonc` spelling included.
                let path = crate::installer::opencode_hook_instruction_path(global, name);
                if !path.exists() {
                    missing.push(format!("{h}: instruction missing"));
                } else {
                    match crate::installer::opencode_hook_registration(global, name) {
                        crate::installer::HookRegistration::Registered => {}
                        crate::installer::HookRegistration::Absent => {
                            missing.push(format!("{h}: instruction present but not referenced"));
                        }
                        crate::installer::HookRegistration::Unreadable(reason) => {
                            unverifiable.push(format!("{h}: registration unverifiable — {reason}"));
                        }
                    }
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
                    Some((hook, Some(codex_event))) => {
                        if !has_script {
                            missing.push(format!("{h}: script missing"));
                        } else {
                            let slot = crate::installer::RegistrationSlot {
                                event: codex_event,
                                matcher: hook.matcher.as_deref(),
                            };
                            for gap in crate::installer::codex_native_hook_gaps(global, name, slot)
                            {
                                let note = format!("{h}: {}", gap.describe());
                                if gap.is_unreadable() {
                                    unverifiable.push(note);
                                } else if gap.is_disabled() {
                                    disabled.push(note);
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
                    // A scope with no codex agents has nothing to miss, and an
                    // agent file nothing could read answers for nothing.
                    Some((hook, None)) if !has_script => {
                        match crate::installer::codex_hook_prose(&root, hook) {
                            crate::installer::CodexProse::Carried
                            | crate::installer::CodexProse::NoAgents => {}
                            crate::installer::CodexProse::Absent => {
                                missing.push(format!("{h}: no script and no prose"));
                            }
                            crate::installer::CodexProse::Unreadable(reason) => {
                                unverifiable.push(format!("{h}: prose unverifiable — {reason}"));
                            }
                        }
                    }
                    // A script left by an earlier native mapping still runs.
                    Some((_, None)) => {}
                    // No source to read: nothing here can say whether this
                    // hook installs natively or as prose, so neither artifact
                    // can be demanded. The unresolvable source is reported in
                    // its own right.
                    None => {}
                }
            }
            crate::harness::Harness::Pi => {
                // Pi has no per-hook artifact: the @vanillagreen/pi-hooks
                // package IS what makes a Pi hook run, so its absence is the
                // Pi twin of a missing Codex registration — an entry the lock
                // says is enforced for Pi, with nothing on disk that could
                // ever enforce it. Skipping Pi here let a filtered install
                // (`--hook X --harness pi`, which selects no Pi extension)
                // lock a hook that cannot run and still report clean.
                record_pi_carrier(
                    h,
                    source_hook.as_ref(),
                    global,
                    &mut missing,
                    &mut unverifiable,
                );
                // Pi's switches are deliberately not reported. The extension
                // reads `enabled` and a per-hook key out of the
                // `vstack.extensionManager` namespace in Pi's settings, and
                // that namespace is VSTACK'S OWN toggle UI: its state is the
                // user's answer, given in a surface that already shows it, and
                // the only remedy a report could print is the toggle they just
                // used. That is the line the other harnesses fall the other
                // side of — `disableAllHooks`, `[features] hooks` and
                // `alwaysApply` are the HARNESS's configuration silently
                // deciding the fate of an artifact vstack installed, with
                // nothing in view to say so. The package's own presence is
                // still checked, as its own lock entry.
            }
        }
    }
    // One classification, and every note rides along whichever it is, so
    // nothing found is dropped. The order is the order the remedies have to
    // happen in: a file that cannot be parsed blocks every command that would
    // touch it, then an artifact that is not there at all, then the switch —
    // which is the only thing left to say once the install itself is whole.
    let notes: Vec<String> = unverifiable
        .iter()
        .chain(missing.iter())
        .chain(disabled.iter())
        .cloned()
        .collect();
    if notes.is_empty() {
        None
    } else if !unverifiable.is_empty() {
        Some(InstallGap::Unverifiable(notes.join("; ")))
    } else if !missing.is_empty() {
        Some(InstallGap::Missing(notes.join("; ")))
    } else {
        Some(InstallGap::Disabled(notes.join("; ")))
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
