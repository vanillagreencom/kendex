use std::collections::BTreeSet;
use std::path::PathBuf;

use super::desired::{Artifact, Desired, DesiredState, ItemCtx};
use super::targets::{
    HookFormat, HookTarget, advisory_notice, disabled_name, hook_target, plugin_settings,
};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::error::Result;
use crate::hash::{hash_bytes, installation_hash};
use crate::hook::{HookBody, HookSpec, codex_event, parse_hook};
use crate::lock::{Reason, entry_key};
use crate::manifest::{Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};

/// Hooks, commands, and MCP servers all declare the same way; only the
/// artifact differs.
pub(super) fn declared(
    ctx: &ItemCtx,
    kind: ItemKind,
    harness: HarnessId,
    artifact: Artifact,
) -> Result<Desired> {
    Ok(Desired {
        key: entry_key(kind, ctx.name, harness),
        kind,
        name: ctx.name.to_owned(),
        harness,
        enabled: ctx.decl.enabled,
        method: Method::Copy,
        source_name: ctx.decl.source.clone(),
        provenance: ctx.provenance.to_owned(),
        source_commit: ctx.source_commit.map(str::to_owned),
        recorded_fork: ctx.recorded_fork(kind),
        hash: installation_hash(
            ctx.sealed,
            ctx.item_path,
            ctx.manifest,
            kind,
            ctx.name,
            harness,
        )?,
        upstream_skills: None,
        emitted: None,
        reasons: ctx.reasons_for(harness),
        author_review: ctx.author_review.clone(),
        // Hooks, commands and MCP servers render from the publisher's bytes
        // and nothing else; there is nothing to subtract.
        authored: None,
        artifact,
    })
}

pub(super) fn desired_hook(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let text = ctx.sealed.read_to_string(ctx.item_path)?;
    let hook = match parse_hook(&text) {
        Ok(hook) => HookSpec::from(hook),
        Err(problem) => {
            state.unreadable(
                ItemKind::Hook,
                ctx.name,
                format!("hook {}: unreadable — {problem}", ctx.name),
            );
            return Ok(());
        }
    };
    for harness in ctx.harnesses.clone() {
        if !hook.applies_to(harness) {
            state.notes.push(format!(
                "hook {}: not declared for {}",
                ctx.name,
                harness.name()
            ));
            continue;
        }
        let Some(artifact) = restated_hook_artifact(
            ctx.env,
            ctx.scope,
            ctx.name,
            &hook,
            ctx.decl.enabled,
            harness,
            state,
        ) else {
            continue;
        };
        state
            .items
            .push(declared(ctx, ItemKind::Hook, harness, artifact)?);
    }
    Ok(())
}

/// The hook restated in one harness's own words, then placed: event renamed
/// where the harness names it differently, skipped with a note where the
/// harness never fires it, and turned into the target's artifact. One path
/// for both authors — the catalog loop above and the custom-hook loop
/// (`desired_custom_hooks`) differ only in where the spec came from.
pub(super) fn restated_hook_artifact(
    env: &Env,
    scope: &Scope,
    name: &str,
    hook: &HookSpec,
    enabled: bool,
    harness: HarnessId,
    state: &mut DesiredState,
) -> Option<Artifact> {
    if harness == HarnessId::Codex && codex_event(&hook.event).is_none() {
        state.notes.push(format!(
            "hook {name}: event {} unsupported on codex — advisory prose lands with the customization editor",
            hook.event
        ));
        return None;
    }
    // Pi fires a fixed set of listeners through the pi-hooks carrier;
    // an event outside that set cannot run there and installs nothing —
    // honesty over prose (a stale advisory drift claim is worse than
    // none). A mappable event is restated in the listener's name, and
    // a scope with no carrier registered anywhere Pi loads gets the
    // downgrade said per item, because the rendered registry is prose
    // until something executes it.
    let hook = match harness {
        HarnessId::Pi => {
            let Some(listener) = crate::harness::pi_listener(&hook.event) else {
                state.notes.push(format!(
                    "hook {name}: event {} unsupported on pi — pi fires no such listener",
                    hook.event
                ));
                return None;
            };
            HookSpec {
                event: listener.to_owned(),
                ..hook.clone()
            }
        }
        _ => hook.clone(),
    };
    // Gemini and Copilot each name the lifecycle events their own way,
    // so the hook is restated in the reader's words — and whatever their
    // configuration already says about hooks is said now, before
    // anything is registered.
    let hook = match harness {
        HarnessId::Gemini => super::gemini::hook(env, scope, name, &hook, state)?,
        HarnessId::Copilot => super::copilot::hook(env, scope, name, &hook, state)?,
        _ => hook,
    };
    let target = hook_target(env, scope, harness, name)?;
    state
        .warnings
        .extend(advisory_notice(env, scope, harness, name));
    Some(hook_artifact(&target, &hook, name, enabled))
}

/// A disabled hook keeps its file under the `.disabled` name and reverses its
/// registration — the constraint stops applying without losing anything. A
/// command-bodied hook has no file of its own: the person's command is
/// registered verbatim, and disabling is the reversed registration alone.
fn hook_artifact(target: &HookTarget, hook: &HookSpec, name: &str, enabled: bool) -> Artifact {
    let placed = |path: &PathBuf| {
        if enabled {
            path.clone()
        } else {
            disabled_name(path)
        }
    };
    match target {
        HookTarget::Script {
            path,
            command,
            registry,
            format,
            feature,
        } => {
            let (registered_command, script) = match &hook.body {
                HookBody::Script(text) => (
                    command.clone(),
                    Some((placed(path), text.clone().into_bytes())),
                ),
                HookBody::Command(command) => (command.clone(), None),
            };
            let registration = match (enabled, format) {
                (true, HookFormat::Nested) => ConfigEdit::UpsertHook {
                    event: hook.event.clone(),
                    matcher: hook.matcher.clone(),
                    command: registered_command,
                    timeout: hook.timeout,
                },
                (true, HookFormat::Copilot) => ConfigEdit::UpsertCopilotHook {
                    event: hook.event.clone(),
                    matcher: hook.matcher.clone(),
                    command: registered_command,
                    timeout: hook.timeout,
                },
                // Switched off, its own entry comes out and nobody
                // else's: the matcher it would have gone in under is the
                // matcher it is taken from, spelled the way a registry
                // spells it, since that is what it will be looked for by.
                (false, HookFormat::Nested) => ConfigEdit::RemoveHook {
                    event: Some(hook.event.clone()),
                    matcher: Some(crate::configedit::spelled(hook.matcher.as_deref()).to_owned()),
                    command: registered_command,
                },
                (false, HookFormat::Copilot) => ConfigEdit::RemoveCopilotHook {
                    event: Some(hook.event.clone()),
                    matcher: Some(crate::configedit::spelled(hook.matcher.as_deref()).to_owned()),
                    command: registered_command,
                },
            };
            let mut edits = registration_edits(registry, registration, enabled);
            if let Some(feature) = feature
                && enabled
            {
                edits.push((feature.clone(), ConfigEdit::CodexEnableHooksFeature));
            }
            Artifact::Registration { script, edits }
        }
        HookTarget::Instruction {
            path,
            config,
            reference,
        } => {
            let edit = if enabled {
                ConfigEdit::OpencodeAddInstruction {
                    reference: reference.clone(),
                    bash_permission: hook.event == "PreToolUse"
                        && hook.matcher.as_deref() == Some("Bash"),
                }
            } else {
                ConfigEdit::OpencodeRemoveInstruction {
                    reference: reference.clone(),
                }
            };
            let body = format!("# Safety: {name}\n\n{}", hook.safety_prose());
            Artifact::Registration {
                script: Some((placed(path), body.into_bytes())),
                edits: registration_edits(config, edit, enabled),
            }
        }
        HookTarget::Rule { path } => {
            let body = format!(
                "---\ndescription: \"{name} — {}\"\nalwaysApply: true\n---\n\n{}",
                hook.description,
                hook.safety_prose()
            );
            Artifact::Registration {
                script: Some((placed(path), body.into_bytes())),
                edits: Vec::new(),
            }
        }
    }
}

/// Registering is always worth an edit; deregistering is only worth one when
/// the config file exists — bringing one into being to record an absence is a
/// change nobody asked for.
pub(super) fn registration_edits(
    path: &std::path::Path,
    edit: ConfigEdit,
    enabled: bool,
) -> Vec<(PathBuf, ConfigEdit)> {
    if enabled || path.exists() {
        vec![(path.to_path_buf(), edit)]
    } else {
        Vec::new()
    }
}

/// Plugins carry no source content — the declaration is the whole item, and
/// applying it is one toggle in the settings file of the tool it names. Each
/// declaration names that tool: more than one harness reads an
/// `enabledPlugins` map, and a plugin installed for one of them is not a
/// plugin the others have.
pub(super) fn desired_plugins(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &mut DesiredState,
) {
    for (key, decl) in &manifest.plugins {
        let harness = decl.harness;
        let toggle = crate::harness::capabilities(harness, ItemKind::Plugin).toggle;
        let supported = match scope {
            Scope::Global => toggle.global,
            Scope::Project { .. } => toggle.project,
        };
        let Some(settings) = plugin_settings(env, scope, harness).filter(|_| supported) else {
            state.notes.push(format!(
                "plugin {key}: {} has no plugin switch at this scope",
                harness.display_name()
            ));
            continue;
        };
        if harness == HarnessId::Copilot
            && let Some(reason) = super::copilot::plugin_refusal(env, scope)
        {
            state
                .notes
                .push(format!("plugin {key}: {reason} — nothing was switched"));
            continue;
        }
        state.items.push(Desired {
            key: entry_key(ItemKind::Plugin, key, harness),
            kind: ItemKind::Plugin,
            name: key.clone(),
            harness,
            enabled: decl.enabled,
            method: Method::Copy,
            source_name: "plugin".to_owned(),
            provenance: "marketplace".to_owned(),
            source_commit: None,
            recorded_fork: false,
            hash: hash_bytes(format!("plugin:{key}:{}", decl.enabled).as_bytes()),
            upstream_skills: None,
            emitted: None,
            reasons: BTreeSet::from([Reason::Requested]),
            // A plugin is a switch in a settings file, not catalog content
            // an author could have reviewed.
            author_review: None,
            authored: None,
            artifact: Artifact::Registration {
                script: None,
                edits: vec![(
                    settings,
                    ConfigEdit::SetPluginEnabled {
                        key: key.clone(),
                        enabled: Some(decl.enabled),
                    },
                )],
            },
        });
    }
}
