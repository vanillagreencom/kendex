//! What the shared declaration paths have to ask Antigravity before they
//! write a hook: whether it fires the event at all, and whether the matcher
//! can be said in its tool names.

use super::ItemWarning;
use super::desired::DesiredState;
use crate::hook::HookSpec;
use crate::model::{HarnessId, ItemKind};

/// The hook as Antigravity would register it, or `None` with the note
/// saying why nothing is registered: an event it has no counterpart for.
pub(super) fn hook(name: &str, hook: &HookSpec, state: &mut DesiredState) -> Option<HookSpec> {
    if hook.harnesses.is_none() {
        state.notes.push(format!(
            "hook {name}: skips antigravity — {}",
            crate::hook::by_name_only(HarnessId::Antigravity)
        ));
        return None;
    }
    let Some(registered) = crate::harness::antigravity::hook_for(hook) else {
        state.notes.push(format!(
            "hook {name}: event {} has no Antigravity counterpart, and hanging it on a near-miss would run it at the wrong moment",
            hook.event
        ));
        return None;
    };
    if registered.matcher_as_authored {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Hook,
            name: name.to_owned(),
            harness: Some(HarnessId::Antigravity),
            message: format!(
                "Antigravity matches `{}` against its own tool names, and this matcher carries syntax kendex cannot restate in them — it installs as written and may never match",
                hook.matcher.as_deref().unwrap_or_default()
            ),
            remediation: Some(
                "write the matcher as plain tool names separated by `|`, or check it against Antigravity's names (`run_command`, `view_file`, `write_to_file`)"
                    .to_owned(),
            ),
        });
    }
    Some(registered.hook)
}

/// The server entry as Antigravity keys it: a remote endpoint is `serverUrl`
/// whatever transport it speaks, with no `type` beside it, since its docs
/// say "Legacy fields like `url` or `httpUrl` are not supported"
/// (antigravity.google/docs/mcp). A command server is read as written.
pub(super) fn server(value: &serde_json::Value) -> serde_json::Value {
    let Some(url) = value.get("url").and_then(serde_json::Value::as_str) else {
        return value.clone();
    };
    let mut entry = value.clone();
    let Some(object) = entry.as_object_mut() else {
        return entry;
    };
    object.remove("type");
    object.remove("url");
    object.insert(
        "serverUrl".to_owned(),
        serde_json::Value::String(url.to_owned()),
    );
    entry
}

#[cfg(test)]
mod server_tests {
    use serde_json::json;

    #[test]
    fn a_remote_server_is_keyed_server_url_and_a_command_server_kept() {
        assert_eq!(
            super::server(&json!({"type": "http", "url": "https://mcp.example"})),
            json!({"serverUrl": "https://mcp.example"})
        );
        assert_eq!(
            super::server(&json!({"type": "sse", "url": "https://mcp.example/sse"})),
            json!({"serverUrl": "https://mcp.example/sse"})
        );
        let stdio = json!({"command": "gh-mcp", "args": ["--stdio"]});
        assert_eq!(super::server(&stdio), stdio);
        // The endpoint stays visible to the safety rules under its new key.
        let scored = crate::quality::McpEntry::from_json(&super::server(
            &json!({"type": "http", "url": "https://u:secret@mcp.example"}),
        ));
        assert_eq!(scored.url.as_deref(), Some("https://u:secret@mcp.example"));
    }
}
