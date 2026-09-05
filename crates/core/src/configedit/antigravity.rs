//! Antigravity's `hooks.json`: one named hook per top-level key, each an
//! object holding an optional `enabled` switch and one list per event.
//! `PreToolUse` and `PostToolUse` nest handlers under a matcher group the
//! way the shared nested shape does; the other events hold handlers
//! directly (the CLI's embedded hooks guide, <https://antigravity.google/docs/hooks>).
//! The name a registration goes under is the hook's own, so the switch
//! the loader offers switches exactly that hook.

use serde_json::{Map, Value};

use super::nested::{handler, remove_in, upsert_in};
use super::{ensure_object, names};

/// The events the loader reads as matcher groups; every other event is a
/// flat list of handlers and a `matcher` there is ignored.
fn grouped(event: &str) -> bool {
    matches!(event, "PreToolUse" | "PostToolUse")
}

/// The switch key, the one key under a name that is not an event.
const ENABLED: &str = "enabled";

pub(super) fn upsert_antigravity_hook(
    root: &mut Map<String, Value>,
    name: &str,
    event: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u32>,
) -> Result<(), String> {
    let hook = ensure_object(root, name)?;
    if grouped(event) {
        return upsert_in(hook, event, matcher, command, timeout);
    }
    let handlers = hook
        .entry(event)
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or("hook event is not an array")?;
    let ours = |h: &Value| h.get("command").and_then(Value::as_str) == Some(command);
    // Refreshed where it already stands, and once: a second copy of the
    // same command under one event would run it twice.
    let first = handlers.iter().position(ours);
    let mut kept = false;
    handlers.retain(|h| !ours(h) || !std::mem::replace(&mut kept, true));
    match first {
        Some(index) => handlers[index] = handler(command, timeout),
        None => handlers.push(handler(command, timeout)),
    }
    Ok(())
}

/// Takes our handler back out from under `name`, or from under every name
/// when none is given, and from every event when none is named. A name
/// left holding no event comes out too: an object carrying only a switch
/// is a hook the person never wrote.
pub(super) fn remove_antigravity_hook(
    root: &mut Map<String, Value>,
    name: Option<&str>,
    event: Option<&str>,
    matcher: Option<&str>,
    command: &str,
) {
    let held: Vec<String> = match name {
        Some(name) => vec![name.to_owned()],
        None => root.keys().cloned().collect(),
    };
    for name in held {
        let Some(hook) = root.get_mut(&name).and_then(Value::as_object_mut) else {
            continue;
        };
        let events: Vec<String> = match event {
            Some(event) => vec![event.to_owned()],
            None => hook.keys().filter(|key| *key != ENABLED).cloned().collect(),
        };
        for event in events {
            if grouped(&event) {
                remove_in(hook, &event, matcher, command);
                continue;
            }
            if let Some(handlers) = hook.get_mut(&event).and_then(Value::as_array_mut) {
                handlers.retain(|h| {
                    !names(h, matcher) || h.get("command").and_then(Value::as_str) != Some(command)
                });
                if handlers.is_empty() {
                    hook.shift_remove(&event);
                }
            }
        }
        if hook.keys().all(|key| key == ENABLED) {
            root.shift_remove(&name);
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::configedit::ConfigEdit;

    const COMMAND: &str = "bash \"$(git rev-parse --show-toplevel)/.agents/hooks/audit.sh\"";

    fn upsert(event: &str, matcher: Option<&str>) -> ConfigEdit {
        ConfigEdit::UpsertAntigravityHook {
            name: "audit".to_owned(),
            event: event.to_owned(),
            matcher: matcher.map(str::to_owned),
            command: COMMAND.to_owned(),
            timeout: Some(10),
        }
    }

    /// Applying twice changes nothing the second time — that equality is how
    /// the plan tells a registered hook from one still to register.
    #[test]
    fn a_tool_event_lands_grouped_under_the_hooks_name_and_re_applying_is_a_no_op() {
        let once = upsert("PreToolUse", Some("run_command")).apply("").unwrap();
        let value: serde_json::Value = serde_json::from_str(&once).unwrap();
        let group = &value["audit"]["PreToolUse"][0];
        assert_eq!(group["matcher"], "run_command");
        assert_eq!(group["hooks"][0]["type"], "command");
        assert_eq!(group["hooks"][0]["command"], COMMAND);
        assert_eq!(group["hooks"][0]["timeout"], 10);
        assert_eq!(
            upsert("PreToolUse", Some("run_command"))
                .apply(&once)
                .unwrap(),
            once
        );
    }

    /// The loader reads `Stop` as a list of handlers with no group around
    /// them; a group there would be a handler with no command.
    #[test]
    fn a_stop_event_lands_flat_and_a_second_copy_is_folded_into_one() {
        let once = upsert("Stop", None).apply("").unwrap();
        let value: serde_json::Value = serde_json::from_str(&once).unwrap();
        assert_eq!(value["audit"]["Stop"][0]["command"], COMMAND);
        assert!(value["audit"]["Stop"][0].get("hooks").is_none());
        let doubled = format!(
            r#"{{"audit": {{"Stop": [{{"command": {COMMAND:?}}}, {{"command": {COMMAND:?}}}]}}}}"#
        );
        let folded = upsert("Stop", None).apply(&doubled).unwrap();
        assert_eq!(folded, once);
    }

    /// Someone else's named hook, and their switch on ours, are not ours to
    /// touch; the last handler out takes the name with it.
    #[test]
    fn removing_ours_leaves_every_other_name_and_prunes_the_empty_one() {
        let existing = r#"{"lint": {"PostToolUse": [{"matcher": "run_command", "hooks": [{"command": "./lint.sh"}]}]},
            "audit": {"enabled": false}}"#;
        let registered = upsert("PreToolUse", Some("run_command"))
            .apply(existing)
            .unwrap();
        let value: serde_json::Value = serde_json::from_str(&registered).unwrap();
        assert_eq!(value["audit"]["enabled"], false);
        let removed = ConfigEdit::RemoveAntigravityHook {
            name: Some("audit".to_owned()),
            event: None,
            matcher: None,
            command: COMMAND.to_owned(),
        }
        .apply(&registered)
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&removed).unwrap();
        assert!(value.get("audit").is_none(), "{removed}");
        assert_eq!(
            value["lint"]["PostToolUse"][0]["hooks"][0]["command"],
            "./lint.sh"
        );
    }

    /// Without a name the command comes out from under whichever name
    /// registered it — what adopting a foreign registration needs.
    #[test]
    fn an_unnamed_removal_finds_the_command_under_any_name() {
        let theirs = format!(
            r#"{{"theirs": {{"PreToolUse": [{{"matcher": "run_command", "hooks": [{{"command": {COMMAND:?}}}]}}]}}}}"#
        );
        let removed = ConfigEdit::RemoveAntigravityHook {
            name: None,
            event: Some("PreToolUse".to_owned()),
            matcher: Some("run_command".to_owned()),
            command: COMMAND.to_owned(),
        }
        .apply(&theirs)
        .unwrap();
        assert_eq!(removed.trim(), "{}");
    }
}
