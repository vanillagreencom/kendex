//! One declared MCP server as each tool records it: the registry file it
//! belongs in, the shape that tool keys an entry by, and the `mcp/<name>.toml`
//! the catalog ships it as.

use serde_json::{Map, Value, json};

use super::desired::{Artifact, DesiredState, ItemCtx};
use super::desired_kinds::{declared, registration_edits};
use super::targets::{mcp_registry, mcp_remove, mcp_upsert};
use crate::configedit::ConfigEdit;
use crate::error::Result;
use crate::model::{HarnessId, ItemKind};

pub(super) fn desired_mcp(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let text = ctx.sealed.read_to_string(ctx.item_path)?;
    let value = match mcp_value(&text) {
        Ok(value) => value,
        Err(problem) => {
            state.unreadable(
                ItemKind::McpServer,
                ctx.name,
                format!("mcp {}: {problem}", ctx.name),
            );
            return Ok(());
        }
    };
    for harness in ctx.harnesses.clone() {
        // Gemini splits the declaration from the record of whether it is on,
        // and the two live in different files at different scopes.
        let edits = if harness == HarnessId::Gemini {
            match super::gemini::mcp_edits(ctx, state, &value) {
                Some(edits) => edits,
                None => continue,
            }
        } else {
            let Some(registry) = mcp_registry(ctx.env, ctx.scope, harness) else {
                continue;
            };
            if harness == HarnessId::Copilot {
                super::copilot::switched_off_elsewhere(ctx, ItemKind::McpServer, state);
            }
            if let Some(reason) = refusal(harness, &value) {
                state.refused.push(super::desired::Refused {
                    kind: ItemKind::McpServer,
                    name: ctx.name.to_owned(),
                    harness,
                    reason,
                });
                continue;
            }
            // Each harness keys the entry its own way, so a server written in
            // another tool's shape would not load: Copilot names the
            // transport on the entry, OpenCode takes one argv, its own key
            // names and the switch on the entry itself, so its declaration
            // stays in the file either way; everywhere else the entry comes
            // out when switched off.
            let edit = match (ctx.decl.enabled, harness) {
                // Codex keeps a server as its own TOML table and switches it
                // off on the table itself, so the edit carries the switch.
                (_, HarnessId::Codex) => ConfigEdit::UpsertCodexMcpServer {
                    name: ctx.name.to_owned(),
                    value: value.clone(),
                    enabled: ctx.decl.enabled,
                },
                (_, HarnessId::Opencode) => mcp_upsert(
                    harness,
                    ctx.name,
                    super::opencode::server(&value, ctx.decl.enabled),
                ),
                (true, HarnessId::Copilot) => {
                    mcp_upsert(harness, ctx.name, super::copilot::server(&value))
                }
                (true, HarnessId::Cursor) => mcp_upsert(harness, ctx.name, cursor_server(&value)),
                // Antigravity names a remote endpoint `serverUrl` and switches
                // a server off with `disabled: true` on the entry, so its
                // declaration stays in the file either way.
                (true, HarnessId::Antigravity) => {
                    mcp_upsert(harness, ctx.name, super::antigravity::server(&value))
                }
                (false, HarnessId::Antigravity) => {
                    let mut off = super::antigravity::server(&value);
                    if let Some(object) = off.as_object_mut() {
                        object.insert("disabled".into(), Value::Bool(true));
                    }
                    mcp_upsert(harness, ctx.name, off)
                }
                (true, _) => mcp_upsert(harness, ctx.name, value.clone()),
                (false, _) => mcp_remove(harness, ctx.name),
            };
            // A switched-off OpenCode, Antigravity or Codex entry is still a write,
            // so it is planned whether or not the file exists yet.
            let writes = ctx.decl.enabled
                || matches!(
                    harness,
                    HarnessId::Opencode | HarnessId::Antigravity | HarnessId::Codex
                );
            registration_edits(&registry, edit, writes)
        };
        let artifact = Artifact::Registration {
            script: None,
            edits,
        };
        state
            .items
            .push(declared(ctx, ItemKind::McpServer, harness, artifact)?);
    }
    Ok(())
}

/// Why this harness cannot take the server as declared, or `None`: a
/// transport its client does not speak, or an `env` table it has no
/// spelling for. Antigravity's documentation says nothing about substituting
/// a reference in an `env` value, and kendex writes only references, so a
/// server carrying one is refused rather than handed a literal `$NAME`;
/// Codex passes a variable through by its own name only, so a reference
/// under another key is refused with the fix.
fn refusal(harness: HarnessId, value: &Value) -> Option<String> {
    if let Some(reason) = transport_refusal(harness, value) {
        return Some(reason);
    }
    let env = value.get("env");
    match harness {
        HarnessId::Antigravity
            if env
                .and_then(Value::as_object)
                .is_some_and(|env| !env.is_empty()) =>
        {
            Some("Antigravity documents no substitution for an environment value, so a $NAME reference would reach the server as text — declare the server without env, or drop Antigravity from its harnesses".to_owned())
        }
        HarnessId::Codex => env.and_then(|env| crate::configedit::codex_env_vars(env).err()),
        _ => None,
    }
}

/// Why this harness cannot take the server as declared: a transport its
/// client does not speak, read off the capability table so the list lives
/// in one place (`format_caps`, `crates/core/src/harness/caps.rs`).
fn transport_refusal(harness: HarnessId, value: &Value) -> Option<String> {
    use crate::harness::McpTransport;
    let transport = match value.get("type").and_then(Value::as_str) {
        Some("http") => McpTransport::Http,
        Some("sse") => McpTransport::Sse,
        _ => McpTransport::Stdio,
    };
    let spoken = crate::harness::format_caps(harness).mcp_transports;
    if spoken.contains(&transport) {
        return None;
    }
    let names = |t: &McpTransport| match t {
        McpTransport::Stdio => "stdio",
        McpTransport::Http => "streamable HTTP",
        McpTransport::Sse => "SSE",
    };
    Some(format!(
        "{} speaks {} and not {}, so this server would never connect — declare it over a transport it speaks, or drop {} from its harnesses",
        harness.display_name(),
        spoken.iter().map(names).collect::<Vec<_>>().join(" and "),
        names(&transport),
        harness.display_name(),
    ))
}

/// The entry as Cursor reads it: transport is inferred from `command` or
/// `url`, and the `type` key the docs list is never read, while its schema
/// marks the entry with an unknown key (research on 3.18.9, `KKs`,
/// `parseMcpServersFromFile`), so the key comes off. An environment value
/// reaches the process through Cursor's variable resolver, which reads
/// `${env:NAME}` and nothing else (cursor.com/docs/mcp § interpolation), so
/// the catalog's `$NAME` and `${NAME}` references are spelled that way; a
/// value naming a resolver, `${env:…}` or `${workspaceFolder}`, passes
/// through.
fn cursor_server(value: &Value) -> Value {
    let mut entry = value.clone();
    let Some(object) = entry.as_object_mut() else {
        return entry;
    };
    object.remove("type");
    if let Some(env) = object.get_mut("env").and_then(Value::as_object_mut) {
        for reference in env.values_mut() {
            let name = reference.as_str().and_then(|text| {
                match text
                    .strip_prefix("${")
                    .and_then(|rest| rest.strip_suffix('}'))
                {
                    // A colon names one of Cursor's resolvers; a bare name
                    // inside the braces names nothing it can resolve.
                    Some(inner) if !inner.contains(':') && !inner.is_empty() => Some(inner),
                    Some(_) => None,
                    None => text.strip_prefix('$'),
                }
            });
            if let Some(name) = name {
                *reference = Value::String(format!("${{env:{name}}}"));
            }
        }
    }
    entry
}

/// `mcp/<name>.toml` → the JSON value claude stores under `mcpServers`.
/// Env values are `$`-references by contract: a literal is a secret in a
/// tracked file, so it is rejected rather than installed.
fn mcp_value(text: &str) -> std::result::Result<Value, String> {
    let table: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
    let string = |key: &str| {
        table
            .get(key)
            .and_then(toml::Value::as_str)
            .map(str::to_owned)
    };
    let mut vars = Map::new();
    if let Some(env) = table.get("env").and_then(toml::Value::as_table) {
        for (key, value) in env {
            let reference = value.as_str().unwrap_or_default();
            if !reference.starts_with('$') {
                return Err(format!(
                    "env value for {key} must be a $REFERENCE, never a secret"
                ));
            }
            vars.insert(key.clone(), json!(reference));
        }
    }
    let transport = string("transport").unwrap_or_else(|| "stdio".to_owned());
    let mut server = Map::new();
    match transport.as_str() {
        "stdio" => {
            let command = string("command").ok_or("stdio transport needs a command")?;
            server.insert("command".into(), json!(command));
            if let Some(args) = table.get("args").and_then(toml::Value::as_array) {
                let args: Vec<Value> = args
                    .iter()
                    .filter_map(|a| a.as_str())
                    .map(|a| json!(a))
                    .collect();
                server.insert("args".into(), Value::Array(args));
            }
            if !vars.is_empty() {
                server.insert("env".into(), Value::Object(vars));
            }
        }
        "http" | "sse" => {
            let url = string("url").ok_or(format!("{transport} transport needs a url"))?;
            server.insert("type".into(), json!(transport));
            server.insert("url".into(), json!(url));
        }
        other => return Err(format!("unknown transport '{other}'")),
    }
    Ok(Value::Object(server))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcp_transports_render_and_literal_env_values_are_refused() {
        let stdio = mcp_value(
            "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n[env]\nGITHUB_TOKEN = \"$GH_TOKEN\"\n",
        )
        .unwrap();
        assert_eq!(stdio["command"], "gh-mcp");
        assert_eq!(stdio["args"][0], "--stdio");
        assert_eq!(stdio["env"]["GITHUB_TOKEN"], "$GH_TOKEN");

        let http = mcp_value("transport = \"http\"\nurl = \"https://mcp.example\"\n").unwrap();
        assert_eq!(http["type"], "http");
        assert_eq!(http["url"], "https://mcp.example");

        let secret = mcp_value("command = \"x\"\n[env]\nTOKEN = \"ghp_literal\"\n").unwrap_err();
        assert_eq!(
            secret,
            "env value for TOKEN must be a $REFERENCE, never a secret"
        );
        assert!(mcp_value("transport = \"stdio\"\n").is_err());
        assert!(mcp_value("transport = \"carrier-pigeon\"\n").is_err());

        let cursor = cursor_server(&json!({"type": "sse", "url": "https://mcp.example"}));
        assert_eq!(cursor, json!({"url": "https://mcp.example"}));
        let cursor = cursor_server(
            &json!({"command": "gh", "env": {"A": "$A_TOKEN", "B": "${B_TOKEN}", "C": "${env:C_TOKEN}"}}),
        );
        assert_eq!(
            cursor,
            json!({"command": "gh", "env": {"A": "${env:A_TOKEN}", "B": "${env:B_TOKEN}", "C": "${env:C_TOKEN}"}})
        );
        assert!(mcp_value("transport = \"carrier-pigeon\"\n").is_err());
    }
}
