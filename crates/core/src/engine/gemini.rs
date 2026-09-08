//! What the shared declaration paths have to ask Gemini before they write.
//! Two facts drive everything here: Gemini's settings file gained a nested
//! schema that older CLIs do not read, and a system settings layer sits
//! above both the user's and the project's (matrix §R2, §R9).

use std::path::PathBuf;

use serde_json::Value;

use super::ItemWarning;
use super::desired::{DesiredState, ItemCtx};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::harness::gemini::settings::{
    Settings, mcp_enablement_file, mcp_gated_out, mcp_switched_off, read, settings_file,
    system_defines, system_settings_file,
};
use crate::hook::HookSpec;
use crate::model::{HarnessId, ItemKind, Scope};

fn settings(ctx: &ItemCtx) -> Settings {
    read(&settings_file(ctx.env, ctx.scope))
}

/// The system settings layer outranks both the user's file and the
/// project's, so a key it sets can leave what kendex writes inert. Only what
/// is on disk is observable, so the wording says how things are configured
/// and never claims what a run will do (matrix §R2).
fn overridden(ctx: &ItemCtx, kind: ItemKind, key: &str) -> Option<ItemWarning> {
    overridden_named(ctx.env, ctx.name, kind, key)
}

fn overridden_named(env: &Env, name: &str, kind: ItemKind, key: &str) -> Option<ItemWarning> {
    system_defines(env, key).then(|| ItemWarning {
        kind,
        name: name.to_owned(),
        harness: Some(HarnessId::Gemini),
        message: format!(
            "kendex-settings-overridden: harness=gemini item={name} key={key}\nThis machine's system-wide Gemini settings also set `{key}`, which outranks both your settings and this project — as configured, what kendex writes here can be overridden"
        ),
        remediation: Some(format!(
            "ask whoever manages {} to make room for it, or install this at a scope that file leaves alone",
            system_settings_file(env).display()
        )),
    })
}

/// What the machine's own configuration says about an agent kendex is about
/// to write. An installation that cannot run must not read as one that can.
pub(super) fn agent_notices(ctx: &ItemCtx, state: &mut DesiredState) {
    // Gemini's own default for this flag is on, so only an explicit `false`
    // means the feature is off — absence is not the feature being missing
    // (configuration reference; matrix §1, §R3).
    if settings(ctx).agents_enabled == Some(false) {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness: Some(HarnessId::Gemini),
            message: format!(
                "kendex-agents-disabled: harness=gemini agent={} setting=experimental.enableAgents\nGemini's subagents are switched off in its settings, so this agent installs but stays inert",
                ctx.name,
            ),
            remediation: Some(
                "turn `experimental.enableAgents` on in Gemini's settings, or drop Gemini from this agent's harnesses"
                    .to_owned(),
            ),
        });
    }
    state
        .warnings
        .extend(overridden(ctx, ItemKind::Agent, "agents"));
}

/// The hook as Gemini would register it, or `None` with the note saying why
/// nothing is registered: an event Gemini has no counterpart for, or a
/// settings file the installed CLI would not read back.
pub(super) fn hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    hook: &HookSpec,
    state: &mut DesiredState,
) -> Option<HookSpec> {
    if let Some(reason) = read(&settings_file(env, scope)).unmanageable() {
        state.notes.push(format!(
            "kendex-settings-unmanageable: harness=gemini kind=hook item={name}\n{reason} — nothing was registered for Gemini"
        ));
        return None;
    }
    let Some(registered) = crate::harness::gemini::hook_for(hook) else {
        state.notes.push(super::targets::unsupported_hook_event(
            name,
            &hook.event,
            HarnessId::Gemini,
        ));
        return None;
    };
    if registered.matcher_as_authored {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Hook,
            name: name.to_owned(),
            harness: Some(HarnessId::Gemini),
            message: format!(
                "Gemini matches `{}` against its own tool names, and this matcher carries syntax kendex cannot restate in them — it installs as written and may never match",
                hook.matcher.as_deref().unwrap_or_default()
            ),
            remediation: Some(
                "write the matcher as plain tool names separated by `|`, or check it against Gemini's names (`run_shell_command`, `read_file`, `write_file`)"
                    .to_owned(),
            ),
        });
    }
    state
        .warnings
        .extend(overridden_named(env, name, ItemKind::Hook, "hooks"));
    Some(registered.hook)
}

/// A server this project declares that the machine-wide record has switched
/// off. The record is one file for every scope, so a project cannot turn it
/// back on — it says so instead of writing there (matrix §1).
fn switched_off_machine_wide(ctx: &ItemCtx) -> Option<ItemWarning> {
    (ctx.decl.enabled && mcp_switched_off(ctx.env, ctx.name)).then(|| ItemWarning {
        kind: ItemKind::McpServer,
        name: ctx.name.to_owned(),
        harness: Some(HarnessId::Gemini),
        message: format!(
            "kendex-mcp-disabled: harness=gemini server={0}\nGemini records whether a server is on in one file for the whole machine, and {0} is switched off there — as configured, it is declared for this project but stays inert",
            ctx.name
        ),
        remediation: Some(format!(
            "switch it back on for the whole machine, in {}",
            mcp_enablement_file(ctx.env).display()
        )),
    })
}

/// A server Gemini's own settings keep out of the list it loads, whatever
/// this scope declares (matrix §1).
fn gated_out(ctx: &ItemCtx) -> Option<ItemWarning> {
    let path = mcp_gated_out(ctx.env, ctx.scope, ctx.name)?;
    Some(ItemWarning {
        kind: ItemKind::McpServer,
        name: ctx.name.to_owned(),
        harness: Some(HarnessId::Gemini),
        message: format!(
            "kendex-mcp-filtered: harness=gemini server={1}\nGemini's settings in {0} gate which servers load, and {1} is not among them — as configured, it installs but stays inert",
            path.display(),
            ctx.name
        ),
        remediation: Some(format!(
            "take it out of `mcp.excluded`, or add it to `mcp.allowed`, in {}",
            path.display()
        )),
    })
}

/// The server entry as Gemini keys it: a streamable-HTTP endpoint is
/// `httpUrl` and an SSE one is plain `url`, with no `type` beside either
/// (matrix §1). Written in the shape another tool uses, an HTTP server
/// would load as SSE and reach nothing.
fn server(value: &Value) -> Value {
    let Some(url) = value.get("url").and_then(Value::as_str) else {
        return value.clone();
    };
    let key = match value.get("type").and_then(Value::as_str) {
        Some("http") => "httpUrl",
        _ => "url",
    };
    let mut entry = value.clone();
    let Some(object) = entry.as_object_mut() else {
        return entry;
    };
    object.remove("type");
    object.remove("url");
    object.insert(key.to_owned(), Value::String(url.to_owned()));
    entry
}

/// Every edit one declared MCP server takes on Gemini, or `None` when the
/// declaration cannot be honored here. The server itself is declared in the
/// settings file for its scope; whether it is switched on is recorded in one
/// global file, whatever scope declared it (matrix §1).
pub(super) fn mcp_edits(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    value: &Value,
) -> Option<Vec<(PathBuf, ConfigEdit)>> {
    if let Some(reason) = settings(ctx).unmanageable() {
        state.notes.push(format!(
            "kendex-settings-unmanageable: harness=gemini kind=mcp-server item={}\n{reason} — nothing was declared for Gemini",
            ctx.name
        ));
        return None;
    }
    if !ctx.decl.enabled && matches!(ctx.scope, Scope::Project { .. }) {
        state.notes.push(format!(
            "mcp {}: Gemini records whether a server is on in one file for the whole machine, so a project can declare one but not switch it off — remove it here instead",
            ctx.name
        ));
        return None;
    }
    let mut edits = vec![(
        settings_file(ctx.env, ctx.scope),
        ConfigEdit::UpsertMcpServer {
            name: ctx.name.to_owned(),
            value: server(value),
        },
    )];
    // The record of whether a server is on is one file for the whole
    // machine, so only a global-scope declaration writes it. A project holds
    // the project lock and nothing else: editing that file from here would
    // overwrite a choice the user made for every scope at once.
    match ctx.scope {
        // Switching one off keeps the declaration and records the state;
        // turning one back on drops our record so Gemini's own default
        // applies again — and only when there is already a file holding it.
        Scope::Global => {
            let enablement = mcp_enablement_file(ctx.env);
            if !ctx.decl.enabled || enablement.exists() {
                edits.push((
                    enablement,
                    ConfigEdit::SetGeminiMcpEnabled {
                        name: ctx.name.to_owned(),
                        enabled: (!ctx.decl.enabled).then_some(false),
                    },
                ));
            }
        }
        Scope::Project { .. } => state.warnings.extend(switched_off_machine_wide(ctx)),
    }
    state.warnings.extend(gated_out(ctx));
    state
        .warnings
        .extend(overridden(ctx, ItemKind::McpServer, "mcpServers"));
    Some(edits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_streamable_http_server_is_keyed_apart_from_an_sse_one() {
        for (input, expected) in [
            (
                json!({"type": "http", "url": "https://mcp.example"}),
                json!({"httpUrl": "https://mcp.example"}),
            ),
            (
                json!({"type": "sse", "url": "https://mcp.example"}),
                json!({"url": "https://mcp.example"}),
            ),
            (
                json!({"command": "gh-mcp", "args": ["--stdio"]}),
                json!({"command": "gh-mcp", "args": ["--stdio"]}),
            ),
        ] {
            assert_eq!(server(&input), expected, "{input}");
        }
    }
}
