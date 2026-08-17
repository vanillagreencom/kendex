//! What one installed hook needs to RUN, per harness it was locked at.
//!
//! Every harness answers the same three questions — is the artifact there,
//! does the config point the harness at it, and will the harness act on it —
//! and the answers are classified by the remedy they carry, never by which
//! harness produced them.

use super::InstallGap;
use crate::config::{self, ItemKind, LockEntry};

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
        PiCarrier::Absent { blocked } => {
            let scope_flag = if global { " --global" } else { "" };
            let install = format!(
                "run `vstack add{scope_flag} --pi-extension {}`",
                crate::display::command_arg(PI_HOOKS_PACKAGE)
            );
            match blocked {
                // Short enough to survive the phantom section's label width: a
                // remedy elided mid-command cannot be pasted.
                None => missing.push(format!(
                    "{harness}: {PI_HOOKS_PACKAGE} not installed — {install}"
                )),
                // That install has to WRITE the settings it cannot read, so
                // the file is the fault to clear first. This line lands in the
                // unverifiable section, whose details are given a remedy's
                // width, so the command survives beside the parse failure.
                Some(reason) => unverifiable.push(format!(
                    "{harness}: {PI_HOOKS_PACKAGE} not installed, and Pi settings cannot be read — {}; repair that file, then {install}",
                    crate::display::display_reason(&reason)
                )),
            }
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
pub(super) fn verify_hook_install(entry: &LockEntry, global: bool) -> Option<InstallGap> {
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
                //
                // Both questions are asked whatever the other answers. A
                // missing script used to short-circuit the settings read, and
                // `settings.json` is exactly what the prescribed `vstack add`
                // refuses to touch when it cannot parse it: the report named
                // the one remedy that cannot run and hid the repair it waits
                // on.
                let script_present = harness
                    .hooks_dir(global)
                    .is_some_and(|dir| dir.join(format!("{name}.sh")).exists());
                if !script_present {
                    missing.push(format!("{h}: script missing"));
                }
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
                    // Beside a missing script this says nothing new: the one
                    // `vstack add` that re-creates the script writes the
                    // registration with it.
                    crate::installer::HookRegistration::Absent => {
                        if script_present {
                            missing.push(format!("{h}: script present but not registered"));
                        }
                    }
                    crate::installer::HookRegistration::Unreadable(reason) => {
                        unverifiable.push(format!("{h}: registration unverifiable — {reason}"));
                    }
                }
                // A registration claude will not act on. This is the twin
                // of Codex's `[features] hooks`: the registration is
                // perfect and the harness runs none of it — including
                // `session-drift-check`, which is then the one hook that
                // cannot report the state it exists to report. Read beside a
                // missing script too: no reinstall flips it, so omitting it
                // sends the user back for a second round.
                record_switch(
                    h,
                    crate::installer::hook_switch(harness, global, name),
                    &mut disabled,
                    &mut unverifiable,
                );
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
                //
                // The config is read whatever the file says, for the reason
                // claude's is: `opencode.json` is what the prescribed
                // `vstack add` refuses when it cannot parse it, so a missing
                // instruction must not hide it.
                let instruction_present =
                    crate::installer::opencode_hook_instruction_path(global, name).exists();
                if !instruction_present {
                    missing.push(format!("{h}: instruction missing"));
                }
                match crate::installer::opencode_hook_registration(global, name) {
                    crate::installer::HookRegistration::Registered => {}
                    // One `vstack add` writes the file and the entry together.
                    crate::installer::HookRegistration::Absent => {
                        if instruction_present {
                            missing.push(format!("{h}: instruction present but not referenced"));
                        }
                    }
                    crate::installer::HookRegistration::Unreadable(reason) => {
                        unverifiable.push(format!("{h}: registration unverifiable — {reason}"));
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
                        }
                        let slot = crate::installer::RegistrationSlot {
                            event: codex_event,
                            matcher: hook.matcher.as_deref(),
                        };
                        for gap in crate::installer::codex_native_hook_gaps(global, name, slot) {
                            // Beside a missing script, only a file the
                            // reinstall cannot PARSE is worth a line: one
                            // `vstack add` rewrites `hooks.json` and turns
                            // `[features] hooks` back on, and it refuses both
                            // files when they do not parse — the fault that
                            // has to be cleared before the script can return.
                            if !has_script && !gap.is_unreadable() {
                                continue;
                            }
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
