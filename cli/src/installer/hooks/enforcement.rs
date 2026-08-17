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
    pi_hooks_installed: bool,
) -> Option<Resolved> {
    let cell = contract::cell(&hook.event, harness)?;
    if !hook.applies_to(harness.id()) {
        return Some(Resolved {
            cell: Cell::Unsupported,
            note: Some("excluded by harnesses:"),
        });
    }
    if let Some(Mechanism::PiHooksExtension) = cell.mechanism()
        && !pi_hooks_installed
    {
        return Some(Resolved {
            cell: Cell::Unsupported,
            note: Some("pi-hooks not installed"),
        });
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
    let pi_hooks_installed =
        crate::pi_extension::is_pi_extension_operational(PI_HOOKS_PACKAGE, global);
    let mut parts: Vec<String> = Vec::new();
    for harness_id in &entry.harnesses {
        let Some(harness) = Harness::from_id(harness_id) else {
            continue;
        };
        let label = match resolve(&hook, harness, global, pi_hooks_installed) {
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
