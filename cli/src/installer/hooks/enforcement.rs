//! Per-install resolution of the hook execution contract: what an installed
//! hook actually enforces on each harness it is locked at.
//!
//! The matrix in [`super::contract`] is the only source of levels; this module
//! applies the facts of one install on top of it — the hook's `harnesses:`
//! allowlist, whether the Pi package that carries Pi behavior is present,
//! whether every artifact the mechanism installs is there, and whether the
//! harness is configured to run any of it.
//!
//! Every one of those facts is read through the reader `verify` reports it
//! from, so the level `list` prints and the drift line `check` prints cannot
//! disagree about one install.

use super::contract::{self, Cell, Mechanism, PI_HOOKS_PACKAGE};
use crate::config::{ItemKind, LockEntry};
use crate::harness::Harness;

/// What one installed hook enforces on one harness.
pub struct Resolved {
    pub cell: Cell,
    /// Why the contract cell was downgraded, when it was.
    pub note: Option<String>,
}

impl Resolved {
    /// `enforced` / `advisory` / `unsupported`, plus the reason for a
    /// downgrade.
    pub fn label(&self) -> String {
        match &self.note {
            Some(note) => format!("{} ({note})", self.cell.level()),
            None => self.cell.level().to_string(),
        }
    }

    /// The downgrade every gap lands on: a level is a claim about what runs,
    /// and nothing runs.
    fn unsupported(note: String) -> Self {
        Self {
            cell: Cell::Unsupported,
            note: Some(note),
        }
    }
}

/// Why a harness is not running an installed hook, in the same three-way
/// vocabulary `verify` reports in — something a reinstall re-creates, something
/// only repairing a named file answers, something only a setting changes — so a
/// level and a drift line name one fault in one wording.
enum Backing {
    /// Every artifact is in place and the harness will act on it.
    Live,
    /// Something a reinstall re-creates is not there.
    Missing(String),
    /// Something that would have decided it could not be read.
    Unverifiable(String),
    /// Every artifact is in place and the harness is configured not to run it.
    Disabled(String),
}

impl Backing {
    /// The note to downgrade with, or `None` when nothing stands in the way.
    fn note(self) -> Option<String> {
        match self {
            Self::Live => None,
            Self::Missing(note) | Self::Unverifiable(note) | Self::Disabled(note) => Some(note),
        }
    }
}

/// Whether the Pi carrier package is there to run Pi's hook behavior.
///
/// Four states, not a bool, because they carry four remedies: a `settings.json`
/// nothing could parse says nothing about whether the package is registered,
/// and reporting that as "not installed" sends the reader to reinstall a
/// package whose only fault is a file they must repair; a package present but
/// unregistered is fixed by the registration, not by another copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PiCarrier {
    /// Deployed in a scope Pi loads, and registered there.
    Ready,
    /// Deployed in a scope Pi loads, and registered in none of them.
    Unregistered,
    /// Deployed in no scope Pi loads. `blocked` carries the parse failure in
    /// the settings file the install would have to WRITE, when there is one:
    /// the deployment is the fault, and repairing that file is what has to
    /// happen before the remedy for it can run at all.
    Absent { blocked: Option<String> },
    /// Pi's settings could not be read, so registration is unknown. Names the
    /// cause.
    Unknown(String),
}

/// The one probe for the carrier, for every caller that reports on a Pi hook.
///
/// Pi loads packages from BOTH scopes, so a globally deployed carrier backs a
/// project-locked hook. Registration is asked through
/// [`crate::pi_extension::package_registration`] — the reader Pi package
/// entries are already verified with — so an unreadable settings file is
/// unknown, never absent.
pub fn pi_carrier_state(global: bool) -> PiCarrier {
    let scopes: &[bool] = if global { &[true] } else { &[false, true] };
    let mut deployed_anywhere = false;
    let mut unreadable: Option<String> = None;
    for &scope in scopes {
        if !crate::config::pi_packages_dir(scope)
            .join(PI_HOOKS_PACKAGE)
            .exists()
        {
            continue;
        }
        deployed_anywhere = true;
        match crate::pi_extension::package_registration(PI_HOOKS_PACKAGE, scope) {
            crate::pi_extension::PackageRegistration::Registered => return PiCarrier::Ready,
            crate::pi_extension::PackageRegistration::Absent => {}
            crate::pi_extension::PackageRegistration::Unreadable { reason } => {
                unreadable.get_or_insert(reason);
            }
        }
    }
    match (unreadable, deployed_anywhere) {
        (Some(reason), _) => PiCarrier::Unknown(reason),
        (None, true) => PiCarrier::Unregistered,
        // Nothing deployed, so no scope's settings were read above — and the
        // install that would deploy it registers the package in THIS scope's
        // settings and refuses a file it cannot parse. Asked here so the
        // report can name that repair rather than a command it would block.
        (None, false) => PiCarrier::Absent {
            blocked: match crate::pi_extension::package_registration(PI_HOOKS_PACKAGE, global) {
                crate::pi_extension::PackageRegistration::Unreadable { reason } => Some(reason),
                crate::pi_extension::PackageRegistration::Registered
                | crate::pi_extension::PackageRegistration::Absent => None,
            },
        },
    }
}

/// Resolve one hook against one harness: the contract cell, downgraded by the
/// facts of this install.
///
/// A level is a claim about this scope right now, so it is never stronger than
/// what backs it: a hook the allowlist excludes, a Pi carrier package that is
/// not installed, an artifact that has been deleted, and a harness switched off
/// all report `unsupported` with the reason.
pub fn resolve(
    hook: &crate::hook::Hook,
    harness: Harness,
    global: bool,
    pi_hooks: &PiCarrier,
) -> Option<Resolved> {
    let cell = contract::cell(&hook.event, harness)?;
    if !hook.applies_to(harness.id()) {
        return Some(Resolved::unsupported("excluded by harnesses:".to_string()));
    }
    if let Some(Mechanism::PiHooksExtension) = cell.mechanism() {
        let downgrade = match pi_hooks {
            PiCarrier::Ready => None,
            PiCarrier::Unregistered => Some("pi-hooks not registered in Pi settings"),
            PiCarrier::Absent { .. } => Some("pi-hooks not installed"),
            PiCarrier::Unknown(_) => Some("pi-hooks registration unreadable"),
        };
        if let Some(note) = downgrade {
            return Some(Resolved::unsupported(note.to_string()));
        }
    }
    if let Some(mechanism) = cell.mechanism() {
        if let Some(note) = artifact_backing(mechanism, hook, global).note() {
            return Some(Resolved::unsupported(note));
        }
        // Whether the harness will ACT on an install that is whole — the
        // question this reader used to skip, so `list` called a hook enforced
        // while `check` and `verify` called the same install disabled. Asked
        // through [`super::hook_switch`], the one entry point they read it
        // from, and asked OUTSIDE the per-mechanism match, so a mechanism
        // added to that match inherits it instead of having to remember it.
        if let Some(note) = switch_backing(harness, global, &hook.name).note() {
            return Some(Resolved::unsupported(note));
        }
    }
    Some(Resolved { cell, note: None })
}

/// What stands between a mechanism's artifacts and the harness invoking them —
/// the script AND the registration, in the slot the hook declares, because a
/// script nothing invokes (or that fires at another time) enforces nothing.
/// `PiHooksExtension` has no per-hook artifact; its carrier package is checked
/// by the caller.
///
/// Asked through the same readers `verify` reports from, so a level and a
/// drift line can never disagree about what is installed. A level is a claim,
/// and a registration nothing could read backs none — an unreadable config
/// resolves to `unsupported` here while `verify` names the file to repair.
fn artifact_backing(mechanism: Mechanism, hook: &crate::hook::Hook, global: bool) -> Backing {
    let name = hook.name.as_str();
    match mechanism {
        Mechanism::ClaudeSettingsHook => {
            if !Harness::ClaudeCode
                .hooks_dir(global)
                .is_some_and(|dir| dir.join(format!("{name}.sh")).is_file())
            {
                return Backing::Missing("script missing".to_string());
            }
            registration_backing(
                super::claude_hook_registration(
                    global,
                    name,
                    Some(super::RegistrationSlot {
                        event: &hook.event,
                        matcher: hook.matcher.as_deref(),
                    }),
                ),
                "script present but not registered",
            )
        }
        Mechanism::CodexHooksJson => {
            let Some(codex_event) = super::codex_event_for(&hook.event) else {
                return Backing::Missing("no native codex event".to_string());
            };
            if !super::codex_root(global)
                .join("hooks")
                .join(format!("{name}.sh"))
                .is_file()
            {
                return Backing::Missing("script missing".to_string());
            }
            // Registration and `[features] hooks` arrive classified together:
            // codex's switch is inseparable from the config it shares.
            let gaps = super::codex_native_hook_gaps(
                global,
                name,
                super::RegistrationSlot {
                    event: codex_event,
                    matcher: hook.matcher.as_deref(),
                },
            );
            let note = gaps
                .iter()
                .map(|gap| gap.describe())
                .collect::<Vec<_>>()
                .join("; ");
            if gaps.iter().any(|gap| gap.is_unreadable()) {
                Backing::Unverifiable(note)
            } else if gaps.iter().any(|gap| !gap.is_disabled()) {
                Backing::Missing(note)
            } else if !gaps.is_empty() {
                Backing::Disabled(note)
            } else {
                Backing::Live
            }
        }
        Mechanism::CursorRule => {
            if super::cursor_hook_rule_path(global, name).is_file() {
                Backing::Live
            } else {
                Backing::Missing("rule missing".to_string())
            }
        }
        Mechanism::OpenCodeInstruction => {
            if !super::opencode_hook_instruction_path(global, name).is_file() {
                return Backing::Missing("instruction missing".to_string());
            }
            registration_backing(
                super::opencode_hook_registration(global, name),
                "instruction present but not referenced",
            )
        }
        Mechanism::CodexInstructions => {
            match super::codex_hook_prose(&super::codex_root(global), hook) {
                super::CodexProse::Carried => Backing::Live,
                // Nothing carries the prose because there is nothing to carry
                // it: reconciliation writes the block into the first codex
                // agent installed. Still nothing enforcing, and naming that
                // beats prescribing a reinstall that writes no file.
                super::CodexProse::NoAgents => {
                    Backing::Missing("no codex agent carries it".to_string())
                }
                super::CodexProse::Absent => Backing::Missing("prose missing".to_string()),
                super::CodexProse::Unreadable(reason) => {
                    Backing::Unverifiable(format!("prose unverifiable — {reason}"))
                }
            }
        }
        Mechanism::PiHooksExtension => Backing::Live,
    }
}

/// A registration read, in the vocabulary above: absent is a reinstall,
/// unreadable is a file to repair, and the two must not be told alike.
fn registration_backing(registration: super::HookRegistration, absent: &str) -> Backing {
    match registration {
        super::HookRegistration::Registered => Backing::Live,
        super::HookRegistration::Absent => Backing::Missing(absent.to_string()),
        super::HookRegistration::Unreadable(reason) => {
            Backing::Unverifiable(format!("registration unverifiable — {reason}"))
        }
    }
}

/// The harness's own switch over an install that is whole, in the one wording
/// every command shares — what is off, and the file that turns it back on.
fn switch_backing(harness: Harness, global: bool, name: &str) -> Backing {
    match super::hook_switch(harness, global, name) {
        super::HookSwitch::On => Backing::Live,
        super::HookSwitch::Off(note) => Backing::Disabled(format!("switched off — {note}")),
        super::HookSwitch::Unreadable(reason) => {
            Backing::Unverifiable(format!("switch unverifiable — {reason}"))
        }
    }
}

/// The per-harness enforcement summary for one installed hook, in the order
/// the lock records the harnesses. `None` for entries that are not hooks.
///
/// An event that cannot be recovered is reported as such: a hook whose level
/// is unknown must not read as one that enforces.
pub fn summary(entry: &LockEntry, global: bool) -> Option<String> {
    if entry.kind != ItemKind::Hook {
        return None;
    }
    let Some(hook) = hook_definition(entry, global) else {
        // Without the definition there is no event, and without an event no
        // level can be derived. Saying so beats printing one.
        return Some(format!(
            "{} — enforcement unknown (hook definition unavailable)",
            entry.harnesses.join(", ")
        ));
    };
    let pi_hooks = pi_carrier_state(global);
    let mut parts: Vec<String> = Vec::new();
    for harness_id in &entry.harnesses {
        let Some(harness) = Harness::from_id(harness_id) else {
            continue;
        };
        let label = match resolve(&hook, harness, global, &pi_hooks) {
            Some(resolved) => resolved.label(),
            None => format!("unsupported (event {} not in contract)", hook.event),
        };
        parts.push(format!("{harness_id}: {label}"));
    }
    if parts.is_empty() {
        return None;
    }
    Some(parts.join(", "))
}

/// Recover the hook definition behind a lock entry.
///
/// The recorded source is authoritative — it is what the next refresh will
/// install, and what `check` measures staleness against — so a hook narrowed
/// to fewer harnesses reports as excluded before the stale artifact is
/// replaced. A source that no longer resolves falls back to the copy this
/// scope installed, which is the only definition left.
fn hook_definition(entry: &LockEntry, global: bool) -> Option<crate::hook::Hook> {
    if let Some(root) = crate::config::resolve_source_path(&entry.source)
        && let Ok(hooks) = crate::catalog::discover_hooks(&root)
        && let Some(hook) = hooks.into_iter().find(|hook| hook.name == entry.name)
    {
        return Some(hook);
    }
    let script_candidates = [
        Harness::ClaudeCode
            .hooks_dir(global)
            .map(|dir| dir.join(format!("{}.sh", entry.name))),
        Some(
            super::codex_root(global)
                .join("hooks")
                .join(format!("{}.sh", entry.name)),
        ),
    ];
    script_candidates
        .into_iter()
        .flatten()
        .filter(|path| path.is_file())
        .find_map(|path| crate::hook::Hook::from_file(&path).ok())
}
