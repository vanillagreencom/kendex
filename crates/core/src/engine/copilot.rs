//! What the shared declaration paths have to ask Copilot before they write.
//! Copilot reads more configuration than it owns — a switch in Claude Code's
//! settings turns its hooks off, a personal file can hold a skill down that
//! no repository can lift, and a repository can narrow the models it will
//! run (matrix §R6, §R7, §4). Everything here is a read of a file on disk,
//! so the wording says how things are configured and never claims what a run
//! will do.

use serde_json::Value;

use super::ItemWarning;
use super::desired::{DesiredState, ItemCtx};
use crate::env::Env;
use crate::harness::copilot::settings;
use crate::hook::HookSpec;
use crate::model::{HarnessId, ItemKind, Scope};

fn warning(
    ctx: &ItemCtx,
    kind: ItemKind,
    message: String,
    remediation: Option<String>,
) -> ItemWarning {
    ItemWarning {
        kind,
        name: ctx.name.to_owned(),
        harness: Some(HarnessId::Copilot),
        message,
        remediation,
    }
}

/// The hook as Copilot would register it, or `None` with the note saying why
/// nothing is registered: an event Copilot has no counterpart for. A hook
/// switched off machine-wide still installs — it is written where Copilot
/// looks, and the warning says it will sit there doing nothing.
pub(super) fn hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    hook: &HookSpec,
    state: &mut DesiredState,
) -> Option<HookSpec> {
    let named = |message: String, remediation: Option<String>| ItemWarning {
        kind: ItemKind::Hook,
        name: name.to_owned(),
        harness: Some(HarnessId::Copilot),
        message,
        remediation,
    };
    let Some(registered) = crate::harness::copilot::hook_for(hook) else {
        state.notes.push(super::targets::unsupported_hook_event(
            name,
            &hook.event,
            HarnessId::Copilot,
        ));
        return None;
    };
    if registered.matcher_as_authored {
        state.warnings.push(named(
            format!(
                "Copilot matches `{}` against its own tool names, and this matcher carries syntax kendex cannot restate in them — it installs as written and may never match",
                hook.matcher.as_deref().unwrap_or_default()
            ),
            Some(
                "write the matcher as plain tool names separated by `|`, or check it against Copilot's names (`bash`, `read`, `write`)"
                    .to_owned(),
            ),
        ));
    }
    if let Some(path) = settings::hooks_switched_off_by(env, scope) {
        state.warnings.push(named(
            format!(
                "kendex-hooks-disabled: harness=copilot hook={name} setting=disableAllHooks\n`disableAllHooks` is on in {}, which switches off every Copilot hook — as configured, this one installs but stays inert",
                path.display()
            ),
            Some(
                "set `disableAllHooks` to false there, or drop Copilot from this hook's harnesses"
                    .to_owned(),
            ),
        ));
    }
    Some(registered.hook)
}

/// A skill or server this project declares on that Copilot's own settings
/// hold down. A repository file may add a name to `disabledSkills` or
/// `disabledMcpServers` but can never take one off, so kendex does not write
/// a project-scope switch that Copilot would ignore — it says so instead
/// (matrix §R7).
pub(super) fn switched_off_elsewhere(ctx: &ItemCtx, kind: ItemKind, state: &mut DesiredState) {
    if !ctx.decl.enabled {
        return;
    }
    let Some(path) = settings::disabled_above(ctx.env, ctx.scope, kind, ctx.name) else {
        return;
    };
    let key = match kind {
        ItemKind::McpServer => "disabledMcpServers",
        _ => "disabledSkills",
    };
    state.warnings.push(warning(
        ctx,
        kind,
        format!(
            "kendex-item-disabled: harness=copilot item={0} setting={key}\nYour personal Copilot settings list {0} in `{key}`, and a repository can only add names to that list — as configured, this project cannot switch it back on",
            ctx.name
        ),
        Some(format!(
            "take {} out of `{key}` in {}",
            ctx.name,
            path.display()
        )),
    ));
}

/// What a repository allows an agent to run on. The allowlist is a real file
/// Copilot reads, so a model outside it is an installation that will not run
/// as written (matrix §4).
pub(super) fn agent_notices(ctx: &ItemCtx, state: &mut DesiredState, model: Option<&str>) {
    // `auto` is Copilot's own routing mode rather than a model id, so an
    // allowlist of ids has nothing to say about it.
    let Some(model) = model.filter(|model| *model != "auto") else {
        return;
    };
    let Some(patterns) = settings::allowed_models(ctx.scope) else {
        return;
    };
    if settings::model_allowed(&patterns, model) {
        return;
    }
    state.warnings.push(warning(
        ctx,
        ItemKind::Agent,
        format!(
            "kendex-model-disallowed: harness=copilot agent={} requested={model} allowed={}\nThis repository's `.github/allowed_models.txt` allows {} and not {model} — as configured, Copilot will not run this agent on the model it names",
            ctx.name,
            patterns.join(","),
            patterns.join(", ")
        ),
        Some("pick a model the repository allows, or add this one to that file".to_owned()),
    ));
}

/// The server entry as Copilot keys it: a command server is `local` and a
/// url server carries the transport it speaks, both named by `type`
/// (docs.github.com — MCP servers for the CLI; matrix §2).
pub(super) fn server(value: &Value) -> Value {
    let mut entry = value.clone();
    let Some(object) = entry.as_object_mut() else {
        return entry;
    };
    if object.contains_key("command") {
        object.insert("type".to_owned(), Value::String("local".to_owned()));
    }
    entry
}

/// Why a plugin toggle cannot be written for this scope, or `None` when it
/// can. A machine that never ran the newer CLI keeps its settings somewhere
/// else entirely, and writing the current file would leave the user with a
/// toggle nothing reads (matrix §R9).
pub(super) fn plugin_refusal(env: &crate::env::Env, scope: &Scope) -> Option<String> {
    settings::unmanageable(env, scope)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_command_server_is_typed_local_and_a_url_server_keeps_its_transport() {
        for (input, expected) in [
            (
                json!({"command": "gh-mcp", "args": ["--stdio"]}),
                json!({"type": "local", "command": "gh-mcp", "args": ["--stdio"]}),
            ),
            (
                json!({"type": "http", "url": "https://mcp.example"}),
                json!({"type": "http", "url": "https://mcp.example"}),
            ),
            (
                json!({"type": "sse", "url": "https://mcp.example"}),
                json!({"type": "sse", "url": "https://mcp.example"}),
            ),
        ] {
            assert_eq!(server(&input), expected, "{input}");
        }
    }
}
