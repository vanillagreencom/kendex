//! Manifest `[[custom-hooks]]` entering the same engine catalog hooks use.
//! Where `delivery()` says a hook is registered, it becomes an ordinary
//! `Artifact::Registration` — locked, scored, drift-checked and removed like
//! any other. Where it says advisory, the agent renderer carries the prose
//! and the downgrade is a warning here; the two never both fire for one
//! harness, or the same rule would exist twice with different strengths.

use std::collections::BTreeSet;

use super::desired::{Desired, DesiredState};
use crate::env::Env;
use crate::hash::hash_bytes;
use crate::hook::{Delivery, HookSpec, custom_hook_names, delivery};
use crate::lock::{Reason, entry_key};
use crate::manifest::{Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};

pub(super) fn desired_custom_hooks(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &mut DesiredState,
) {
    let names = custom_hook_names(manifest);
    for (hook, name) in manifest.custom_hooks.iter().zip(names) {
        let spec = HookSpec::custom(hook, name.clone());
        state.processed.insert((ItemKind::Hook, name.clone()));
        for harness in &manifest.install.harnesses {
            let harness = *harness;
            if !spec.applies_to(harness) {
                continue;
            }
            match delivery(env, scope, harness, &spec) {
                Delivery::Registered => {}
                // Enforced harnesses that fall back to prose say so — the
                // person asked for a guard and is getting a request.
                Delivery::Advisory
                    if crate::harness::hook_enforcement(env, scope, harness)
                        == crate::harness::Enforcement::Enforced =>
                {
                    state.warnings.push(super::ItemWarning {
                        kind: ItemKind::Hook,
                        name: name.clone(),
                        harness: Some(harness),
                        message: advisory_downgrade(harness, &spec),
                        remediation: Some(
                            "set agents = \"all\" to make it run for everything, or keep it as instructions"
                                .to_owned(),
                        ),
                    });
                    continue;
                }
                Delivery::InAgentFile | Delivery::Advisory | Delivery::NotInstallable(_) => {
                    continue;
                }
            }
            let Some(artifact) = super::desired_kinds::restated_hook_artifact(
                env,
                scope,
                &spec.name,
                &spec,
                hook.enabled,
                harness,
                state,
            ) else {
                continue;
            };
            state.items.push(Desired {
                key: entry_key(ItemKind::Hook, &spec.name, harness),
                kind: ItemKind::Hook,
                name: spec.name.clone(),
                harness,
                enabled: hook.enabled,
                method: Method::Copy,
                source_name: "custom".to_owned(),
                provenance: "kendex.toml [[custom-hooks]]".to_owned(),
                source_commit: None,
                recorded_fork: false,
                hash: hash_bytes(
                    format!(
                        "custom-hook:{}:{}:{}:{}:{}:{}",
                        spec.name,
                        spec.event,
                        spec.matcher.as_deref().unwrap_or_default(),
                        hook.command,
                        spec.timeout.map(|t| t.to_string()).unwrap_or_default(),
                        hook.enabled,
                    )
                    .as_bytes(),
                ),
                upstream_skills: None,
                emitted: None,
                reasons: BTreeSet::from([Reason::Requested]),
                // The person wrote this hook themselves; no catalog author
                // stands behind it.
                author_review: None,
                authored: None,
                artifact,
            });
        }
    }
}

/// The registry entry a script-less hook writes. Recorded in the lock so
/// removal can name the registered command after the manifest entry that
/// carried it is gone; hooks with a script re-derive theirs from the target.
pub(super) fn hook_registration(item: &Desired) -> Option<crate::lock::HookRegistration> {
    use crate::configedit::ConfigEdit;
    let super::desired::Artifact::Registration {
        script: None,
        edits,
    } = &item.artifact
    else {
        return None;
    };
    if item.kind != ItemKind::Hook {
        return None;
    }
    let record = |event: &String, matcher: Option<&String>, command: &String| {
        Some(crate::lock::HookRegistration {
            event: event.clone(),
            command: command.clone(),
            // Spelled the way the registry spells it, so the record and a
            // reading of the file are comparable without either guessing.
            matcher: Some(
                matcher
                    .map(String::as_str)
                    .filter(|matcher| !matcher.is_empty())
                    .unwrap_or(crate::scan::hooks::ANY_MATCHER)
                    .to_owned(),
            ),
        })
    };
    edits.iter().find_map(|(_, edit)| match edit {
        ConfigEdit::UpsertHook {
            event,
            matcher,
            command,
            ..
        }
        | ConfigEdit::UpsertCopilotHook {
            event,
            matcher,
            command,
            ..
        } => record(event, matcher.as_ref(), command),
        // A disabled hook renders the reversed registration, which names
        // the event its entry was written under; its matcher is not part
        // of that edit, so it stays unknown rather than assumed.
        ConfigEdit::RemoveHook {
            event: Some(event),
            command,
        }
        | ConfigEdit::RemoveCopilotHook {
            event: Some(event),
            command,
        } => Some(crate::lock::HookRegistration {
            event: event.clone(),
            command: command.clone(),
            matcher: None,
        }),
        _ => None,
    })
}

fn advisory_downgrade(harness: HarnessId, spec: &HookSpec) -> String {
    if crate::hook::delivery::agent_scoping(harness) == crate::hook::AgentScoping::None
        && !spec.every_agent()
    {
        return format!(
            "{} cannot tell agents apart at runtime, so a hook for specific agents is written into them as instructions — nothing enforces it there",
            harness.display_name()
        );
    }
    format!(
        "{} never fires {}, so this hook is written into the agents as instructions — nothing enforces it there",
        harness.display_name(),
        spec.event
    )
}
