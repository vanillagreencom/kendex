//! Per-install resolution of the hook execution contract: what an installed
//! hook actually enforces on each harness it is locked at.
//!
//! The matrix in [`super::contract`] is the only source of levels; this module
//! applies the facts of one install on top of it — the hook's `harnesses:`
//! allowlist, and whether the Pi package that carries Pi behavior is present.

use super::contract::{self, Cell, Mechanism, PI_HOOKS_PACKAGE};
use crate::config::{ItemKind, LockEntry};
use crate::harness::Harness;

/// What one installed hook enforces on one harness.
pub struct Resolved {
    pub cell: Cell,
    /// Why the contract cell was downgraded, when it was.
    pub note: Option<&'static str>,
}

impl Resolved {
    /// `enforced` / `advisory` / `unsupported`, plus the reason for a
    /// downgrade.
    pub fn label(&self) -> String {
        match self.note {
            Some(note) => format!("{} ({note})", self.cell.level()),
            None => self.cell.level().to_string(),
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
    /// Deployed in no scope Pi loads.
    Absent,
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
        (None, false) => PiCarrier::Absent,
    }
}

/// Resolve one hook against one harness: the contract cell, downgraded by the
/// facts of this install.
///
/// A level is a claim about this scope right now, so it is never stronger than
/// the artifact backing it: a hook the allowlist excludes, a Pi carrier package
/// that is not installed, and an artifact that has been deleted all report
/// `unsupported` with the reason.
pub fn resolve(
    hook: &crate::hook::Hook,
    harness: Harness,
    global: bool,
    pi_hooks: &PiCarrier,
) -> Option<Resolved> {
    let cell = contract::cell(&hook.event, harness)?;
    if !hook.applies_to(harness.id()) {
        return Some(Resolved {
            cell: Cell::Unsupported,
            note: Some("excluded by harnesses:"),
        });
    }
    if let Some(Mechanism::PiHooksExtension) = cell.mechanism() {
        let downgrade = match pi_hooks {
            PiCarrier::Ready => None,
            PiCarrier::Unregistered => Some("pi-hooks not registered in Pi settings"),
            PiCarrier::Absent => Some("pi-hooks not installed"),
            PiCarrier::Unknown(_) => Some("pi-hooks registration unreadable"),
        };
        if let Some(note) = downgrade {
            return Some(Resolved {
                cell: Cell::Unsupported,
                note: Some(note),
            });
        }
    }
    if cell
        .mechanism()
        .is_some_and(|mechanism| !artifact_present(mechanism, hook, global))
    {
        return Some(Resolved {
            cell: Cell::Unsupported,
            note: Some("artifact missing"),
        });
    }
    Some(Resolved { cell, note: None })
}

/// Whether everything a mechanism installs is in place — the script AND the
/// registration, in the slot the hook declares, that makes a harness invoke
/// it, because a script nothing invokes (or that fires at another time)
/// enforces nothing. `PiHooksExtension` has no per-hook artifact; its carrier
/// package is checked by the caller.
///
/// Asked through the same readers `verify` reports from, so a level and a
/// drift line can never disagree about what is installed. A level is a claim,
/// and a registration nothing could read backs none — an unreadable config
/// resolves to `unsupported` here while `verify` names the file to repair.
fn artifact_present(mechanism: Mechanism, hook: &crate::hook::Hook, global: bool) -> bool {
    let name = hook.name.as_str();
    let registered = |registration| matches!(registration, super::HookRegistration::Registered);
    match mechanism {
        Mechanism::ClaudeSettingsHook => {
            Harness::ClaudeCode
                .hooks_dir(global)
                .is_some_and(|dir| dir.join(format!("{name}.sh")).is_file())
                && registered(super::claude_hook_registration(
                    global,
                    name,
                    Some(super::RegistrationSlot {
                        event: &hook.event,
                        matcher: hook.matcher.as_deref(),
                    }),
                ))
        }
        Mechanism::CodexHooksJson => {
            let Some(codex_event) = super::codex_event_for(&hook.event) else {
                return false;
            };
            super::codex_root(global)
                .join("hooks")
                .join(format!("{name}.sh"))
                .is_file()
                && super::codex_native_hook_gaps(
                    global,
                    name,
                    super::RegistrationSlot {
                        event: codex_event,
                        matcher: hook.matcher.as_deref(),
                    },
                )
                .is_empty()
        }
        Mechanism::CursorRule => super::cursor_hook_rule_path(global, name).is_file(),
        Mechanism::OpenCodeInstruction => {
            super::opencode_hook_instruction_path(global, name).is_file()
                && registered(super::opencode_hook_registration(global, name))
        }
        Mechanism::CodexInstructions => matches!(
            super::codex_hook_prose(&super::codex_root(global), hook),
            super::CodexProse::Carried
        ),
        Mechanism::PiHooksExtension => true,
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
