//! The shape OpenCode keys an MCP server by. OpenCode takes `command` as one
//! array holding the executable and its arguments, `environment` where the
//! catalog says `env`, a `type` that names `local` or `remote`, and an
//! `enabled` switch on the entry (opencode.ai/config.json, `McpLocalConfig`
//! and `McpRemoteConfig`). An entry written in Claude's shape would fail its
//! schema and load nothing. Config files merge field by field across
//! layers, so `enabled` is always written: an entry with no key would inherit
//! a `false` from another layer (opencode.ai/docs/mcp-servers).

use serde_json::{Map, Value, json};

/// The server entry as OpenCode reads it, switched as `enabled` says.
pub(super) fn server(value: &Value, enabled: bool) -> Value {
    let Some(source) = value.as_object() else {
        return value.clone();
    };
    let mut entry = Map::new();
    if let Some(command) = source.get("command").and_then(Value::as_str) {
        let mut argv = vec![json!(command)];
        if let Some(args) = source.get("args").and_then(Value::as_array) {
            argv.extend(args.iter().cloned());
        }
        entry.insert("type".into(), json!("local"));
        entry.insert("command".into(), Value::Array(argv));
        if let Some(env) = source.get("env").and_then(Value::as_object) {
            entry.insert("environment".into(), Value::Object(environment(env)));
        }
    } else if let Some(url) = source.get("url") {
        entry.insert("type".into(), json!("remote"));
        entry.insert("url".into(), url.clone());
        if let Some(headers) = source.get("headers") {
            entry.insert("headers".into(), headers.clone());
        }
    }
    entry.insert("enabled".into(), Value::Bool(enabled));
    Value::Object(entry)
}

/// The catalog's `$NAME` or `${NAME}` reference spelled the one way OpenCode
/// substitutes it, `{env:NAME}` (opencode.ai/docs/config § variables); a
/// value already in OpenCode's braces passes through.
fn environment(env: &Map<String, Value>) -> Map<String, Value> {
    env.iter()
        .map(|(key, value)| {
            let spelled = match value.as_str() {
                Some(text) if text.starts_with('{') => value.clone(),
                Some(text) => match text
                    .strip_prefix("${")
                    .and_then(|rest| rest.strip_suffix('}'))
                    .or_else(|| text.strip_prefix('$'))
                {
                    Some(name) => Value::String(format!("{{env:{name}}}")),
                    None => value.clone(),
                },
                None => value.clone(),
            };
            (key.clone(), spelled)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_server_becomes_one_local_argv_and_a_url_server_remote() {
        let declared = json!({"command": "gh-mcp", "args": ["--stdio"], "env": {"GITHUB_TOKEN": "$GH_TOKEN", "BRACED": "${BRACED_TOKEN}", "PORT": "{env:PORT}"}});
        assert_eq!(
            server(&declared, true),
            json!({"type": "local", "command": ["gh-mcp", "--stdio"], "environment": {"GITHUB_TOKEN": "{env:GH_TOKEN}", "BRACED": "{env:BRACED_TOKEN}", "PORT": "{env:PORT}"}, "enabled": true})
        );
        let http = json!({"type": "http", "url": "https://mcp.example"});
        assert_eq!(
            server(&http, false),
            json!({"type": "remote", "url": "https://mcp.example", "enabled": false})
        );
    }
}
