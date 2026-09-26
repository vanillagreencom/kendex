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
        recorded_fork: ctx.manifest.recorded_fork(kind, ctx.name),
        hash: installation_hash(
            ctx.sealed,
            ctx.item_path,
            ctx.manifest,
            kind,
            ctx.name,
            harness,
        )?,
        rendered_hash: artifact.rendered_hash(),
        source: Some(ctx.source(&artifact)?),
        upstream_skills: None,
        emitted: None,
        reasons: ctx.reasons_for(harness),
        artifact,
    })
}

/// Why a hook will not run on a tool at this scope, or `None` where the plan
/// writes it armed. One answer for the planner that writes hooks
/// ([`desired_hook`]) and for the dependency walk that withholds a hook
/// whose required companion will not run beside it (`deps`), so the two
/// cannot disagree about what lands. Every reason planning writes nothing
/// that runs for a hook on a tool, in the order they are asked:
///
/// - kept removed: `[suppressed]` names it and no declaration does
///   (`Manifest::is_held_back`), so nothing derives it;
/// - switched off: its declaration says `enabled = false`, so it is parked
///   as `.disabled` and arms nothing; a derived hook takes the switch of
///   the requirers that bring it in (`Expansion::add`);
/// - unreadable header: `parse_hook` refuses the script
///   (`DesiredState::unreadable`);
/// - declared for other tools: the manifest's `harnesses` on its
///   declaration leave the tool out (`expansion::target_harnesses`);
/// - withheld: a hook it runs with will not run there — one it requires,
///   every requirer a derived companion exists for, or a companion whose
///   catalog does not answer (`DesiredState::withheld`, spread by
///   `deps::withhold_requirers`);
/// - its own harnesses line leaves the tool out (`HookSpec::applies_to`);
/// - undeliverable: `hook::delivery` answers `NotInstallable`, which is an
///   event the tool never fires (`codex_event`, `pi_listener`, the Gemini,
///   Copilot and Antigravity event maps), a tool that holds no hooks at
///   this scope or takes none, a by-name-only tool the header does not
///   name, or nowhere to register;
/// - wanted at two revisions: the expansion recorded a revision
///   disagreement (`Expansion::report_rev_disagreements`) and
///   `holds::hold_rev_conflict` writes nothing for it.
///
/// The two the manifest answers — kept removed, declared for other tools —
/// hold wherever the item is asked about, including the tools a set
/// carries it to past its own declaration: the person's list is the
/// answer for the planner as for the walk. Not offered by the catalog is
/// decided before the question is asked, by `find_item` for the planner
/// and `deps::resolve` and `deps::companion` for the walk, and a source
/// that is pending, disabled or unreadable, or whose own manifest hides
/// its content and the companion is not found, stops the requirer with
/// the companion where both come from it, and withholds the requirer
/// (`Withholding::Unanswered`) where the companion alone does. The question is asked about the declaration
/// the plan writes, the header being that declaration's catalog's, so
/// where a manifest names the companion from another catalog than the
/// requirer's, the walk reads the copy the planner will write and never
/// the requirer's own. Outside this answer, and so outside the walk's
/// view, are what is decided over the whole expansion or on disk after it:
/// a name collision on a tool (`catalog::Collisions`), a rendering refusal
/// (`DesiredState::refused`), a Gemini, Copilot or Antigravity
/// configuration that refuses hooks while the hook is restated
/// ([`restated_hook_artifact`]), and content in the way at the position
/// (`plan_item`). A local edit holds the copy on disk, which still runs.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum NotWritten {
    KeptRemoved,
    SwitchedOff,
    UnreadableHeader(String),
    OtherTools,
    Withheld,
    OwnHarnessesLine,
    Undeliverable(String),
    RevConflict,
}

/// [`NotWritten`] for one hook on one tool. `header` is the hook's own
/// header as the catalog of the declaration the plan writes holds it:
/// `Ok(None)` for a kind with no header, or why it will not read.
#[allow(clippy::too_many_arguments)]
pub(super) fn not_written(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &DesiredState,
    kind: ItemKind,
    name: &str,
    header: std::result::Result<Option<&HookSpec>, &str>,
    harness: HarnessId,
) -> Option<NotWritten> {
    if let Some(refused) = manifest_refusal(manifest, kind, name) {
        return Some(refused);
    }
    let declared = manifest.declared(kind).get(name);
    let header = match header {
        Ok(header) => header,
        Err(problem) => return Some(NotWritten::UnreadableHeader(problem.to_owned())),
    };
    if declared
        .and_then(|decl| decl.harnesses.as_ref())
        .is_some_and(|list| !list.contains(&harness))
    {
        return Some(NotWritten::OtherTools);
    }
    if state
        .withheld
        .contains_key(&(kind, name.to_owned(), harness))
    {
        return Some(NotWritten::Withheld);
    }
    if let Some(own) = header {
        if !own.applies_to(harness) {
            return Some(NotWritten::OwnHarnessesLine);
        }
        if let crate::hook::Delivery::NotInstallable(reason) =
            crate::hook::delivery(env, scope, harness, own)
        {
            return Some(NotWritten::Undeliverable(reason));
        }
    }
    if state.rev_conflicts.contains(&(kind, name.to_owned())) {
        return Some(NotWritten::RevConflict);
    }
    None
}

/// The two answers of [`not_written`] the manifest gives alone, before any
/// tool or catalog is consulted: kept removed, and switched off. Asked on
/// their own for a companion whose catalog says nothing of it
/// (`deps::silent`), where they are all that can be known.
pub(super) fn manifest_refusal(
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
) -> Option<NotWritten> {
    if manifest.is_held_back(kind, name) {
        return Some(NotWritten::KeptRemoved);
    }
    let switched_off = manifest
        .declared(kind)
        .get(name)
        .is_some_and(|decl| !decl.enabled);
    switched_off.then_some(NotWritten::SwitchedOff)
}

pub(super) fn desired_hook(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let text = ctx.sealed.read_to_string(ctx.item_path)?;
    let hook = match parse_hook(&text) {
        Ok(hook) => HookSpec::from(hook),
        Err(problem) => {
            state.unreadable(
                ItemKind::Hook,
                ctx.name,
                format!(
                    "kendex-hook-unreadable: hook={record_arg0}\nThe hook could not be read: {problem}",
                    record_arg0 = crate::names::shown(ctx.name ),
                ),
            );
            return Ok(());
        }
    };
    for harness in ctx.harnesses.clone() {
        match not_written(
            ctx.env,
            ctx.scope,
            ctx.manifest,
            state,
            ItemKind::Hook,
            ctx.name,
            Ok(Some(&hook)),
            harness,
        ) {
            // Written: parked under `.disabled` when off, and held by
            // `holds::hold_rev_conflict` when wanted at two revisions,
            // which writes nothing and says so in the plan.
            None | Some(NotWritten::SwitchedOff | NotWritten::RevConflict) => {}
            // The declaration is the person's own list, and a set that
            // carries the hook to more tools than it names does not widen
            // it; a name kept removed is theirs the same way. Neither
            // reaches here through a declaration of its own, so the plan
            // writes nothing rather than installing past what they wrote.
            Some(NotWritten::KeptRemoved | NotWritten::OtherTools) => continue,
            // The finding on the hook already says why.
            Some(NotWritten::Withheld) => continue,
            Some(NotWritten::OwnHarnessesLine) => {
                // The hook's own header deciding where it runs is expected
                // state, and every consumer rendering for that tool would
                // otherwise read the same note on every run. It becomes a
                // finding only where the person's own declaration of the
                // hook names the tool: then two lines disagree, and the
                // note names both. The hook script's frontmatter is what
                // decides the skip, so a remedy only naming the manifest
                // would change nothing.
                let named = ctx
                    .manifest
                    .declared(ItemKind::Hook)
                    .get(ctx.name)
                    .and_then(|decl| decl.harnesses.as_ref())
                    .is_some_and(|listed| listed.contains(&harness));
                match named {
                    true => state.notes.push(format!(
                        "kendex-hook-excluded: hook={record_arg0} harness={record_arg1} source=catalog field=harnesses\nkendex.toml lists {arg2} in this hook's harnesses, and the hook's own harnesses line in the catalog leaves it out; add {arg2} to the catalog line, or take it off the hook's harnesses in kendex.toml",
                        arg2 = harness.name(),
                        record_arg0 = crate::names::shown(ctx.name),
                        record_arg1 = crate::names::shown(harness.name()),
                    )),
                    false => state.excluded_hooks.push(super::ExcludedHook {
                        name: ctx.name.to_owned(),
                        harness,
                    }),
                }
                continue;
            }
            Some(NotWritten::Undeliverable(reason)) => {
                // Restating the hook says the same in the tool's own words,
                // and writes nothing. Were it to hand an artifact back, the
                // delivery decision and the restating would disagree; the
                // decision wins, so nothing is armed that the walk believes
                // absent, and the plan says so.
                let restated = restated_hook_artifact(
                    ctx.env,
                    ctx.scope,
                    ctx.name,
                    &hook,
                    ctx.decl.enabled,
                    harness,
                    ctx.manifest.hook_env(ctx.name),
                    state,
                );
                if restated.is_some() {
                    state.mark_incomplete();
                    state.notes.push(format!(
                        "kendex-hook-undeliverable: hook={record_arg0} harness={record_arg1}\n{reason}",
                        record_arg0 = crate::names::shown(ctx.name),
                        record_arg1 = crate::names::shown(harness.name()),
                    ));
                }
                continue;
            }
            Some(NotWritten::UnreadableHeader(problem)) => unreachable!(
                "{} was asked about on {harness:?} with the header in hand and answered {problem}",
                ctx.name
            ),
        }
        let Some(artifact) = restated_hook_artifact(
            ctx.env,
            ctx.scope,
            ctx.name,
            &hook,
            ctx.decl.enabled,
            harness,
            ctx.manifest.hook_env(ctx.name),
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
#[allow(clippy::too_many_arguments)]
pub(crate) fn restated_hook_artifact(
    env: &Env,
    scope: &Scope,
    name: &str,
    hook: &HookSpec,
    enabled: bool,
    harness: HarnessId,
    vars: Option<&std::collections::BTreeMap<String, String>>,
    state: &mut DesiredState,
) -> Option<Artifact> {
    let event = match harness {
        HarnessId::Codex => codex_event(&hook.event).map(|_| hook.event.as_str()),
        HarnessId::Pi => crate::harness::pi_listener(&hook.event),
        _ => Some(hook.event.as_str()),
    };
    let Some(event) = event else {
        state.notes.push(super::targets::unsupported_hook_event(
            name,
            &hook.event,
            harness,
        ));
        return None;
    };
    let hook = HookSpec {
        event: event.to_owned(),
        ..hook.clone()
    };
    // Gemini and Copilot each name the lifecycle events their own way,
    // so the hook is restated in the reader's words — and whatever their
    // configuration already says about hooks is said now, before
    // anything is registered.
    let hook = match harness {
        HarnessId::Gemini => super::gemini::hook(env, scope, name, &hook, state)?,
        HarnessId::Copilot => super::copilot::hook(env, scope, name, &hook, state)?,
        HarnessId::Antigravity => super::antigravity::hook(name, &hook, state)?,
        _ => hook,
    };
    let target = hook_target(env, scope, harness, name, vars)?;
    state
        .warnings
        .extend(advisory_notice(env, scope, harness, name));
    Some(hook_artifact(&target, &hook, name, enabled))
}

/// The registry edit one hook's switch state asks for, in the shape its
/// registry speaks. Switched off, its own entry comes out and nobody
/// else's: the matcher it would have gone in under is the matcher it is
/// taken from, spelled the way a registry spells it, since that is what
/// it will be looked for by.
fn registration_edit(
    format: HookFormat,
    hook: &HookSpec,
    name: &str,
    enabled: bool,
    registered_command: String,
) -> ConfigEdit {
    match (enabled, format) {
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
        (true, HookFormat::Antigravity) => ConfigEdit::UpsertAntigravityHook {
            name: name.to_owned(),
            event: hook.event.clone(),
            matcher: hook.matcher.clone(),
            command: registered_command,
            timeout: hook.timeout,
        },
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
        (false, HookFormat::Antigravity) => ConfigEdit::RemoveAntigravityHook {
            name: Some(name.to_owned()),
            event: Some(hook.event.clone()),
            matcher: Some(crate::configedit::spelled(hook.matcher.as_deref()).to_owned()),
            command: registered_command,
        },
    }
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
            let registration = registration_edit(*format, hook, name, enabled, registered_command);
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
            state.mark_incomplete();
            state.notes.push(format!(
                "plugin {key}: {} has no plugin switch at this scope",
                harness.display_name()
            ));
            continue;
        };
        if harness == HarnessId::Copilot
            && let Some(reason) = super::copilot::plugin_refusal(env, scope)
        {
            state.mark_incomplete();
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
            rendered_hash: None,
            source: None,
            upstream_skills: None,
            emitted: None,
            reasons: BTreeSet::from([Reason::Requested]),
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
