use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

mod antigravity;
mod copilot;
mod nested;
mod text;

use antigravity::{remove_antigravity_hook, upsert_antigravity_hook};
use copilot::{remove_copilot_hook, upsert_copilot_hook};
use nested::{remove_hook, upsert_hook};
use text::codex_enable_hooks;
pub use text::{remove_marker_block, upsert_marker_block};

/// A deterministic, idempotent structured edit. Applied to the file's
/// current text at execute time; a file is in sync exactly when
/// `apply(current) == current` — that equality is the drift check for
/// config-entry kinds. Unrelated keys always survive (invariant 2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ConfigEdit {
    /// claude settings.json / codex hooks.json: upsert our handler under
    /// `hooks.<event>` for `matcher`, replacing entries that run `command`.
    UpsertHook {
        event: String,
        matcher: Option<String>,
        command: String,
        timeout: Option<u32>,
    },
    /// Remove our handler (from every event when `event` is None, and
    /// from every matcher within it when `matcher` is None); empty groups
    /// and events are pruned. A matcher names one group: a command the
    /// person also registered under a matcher of their own is theirs, and
    /// removing by the command alone would take it with ours.
    RemoveHook {
        event: Option<String>,
        #[serde(default)]
        matcher: Option<String>,
        command: String,
    },
    /// copilot hook file: upsert our entry under `hooks.<event>`, replacing
    /// any entry that already runs `command`. Copilot's entries carry the
    /// command and the matcher themselves and the document declares the
    /// schema version it was written for, so none of the shape above fits
    /// (docs.github.com/en/copilot/reference/hooks-reference).
    UpsertCopilotHook {
        event: String,
        matcher: Option<String>,
        command: String,
        timeout: Option<u32>,
    },
    RemoveCopilotHook {
        event: Option<String>,
        #[serde(default)]
        matcher: Option<String>,
        command: String,
    },
    /// antigravity `hooks.json`: upsert our handler under `<name>.<event>`,
    /// grouped by matcher for the tool events and flat for the rest, the
    /// way its loader reads them (the CLI's embedded hooks guide).
    UpsertAntigravityHook {
        name: String,
        event: String,
        matcher: Option<String>,
        command: String,
        timeout: Option<u32>,
    },
    /// Remove our handler from under `name`, or from under every name when
    /// none is given; a name left holding no event is pruned with it.
    RemoveAntigravityHook {
        name: Option<String>,
        event: Option<String>,
        #[serde(default)]
        matcher: Option<String>,
        command: String,
    },
    /// `mcpServers.<name>` upsert with a full value.
    UpsertMcpServer {
        name: String,
        value: Value,
    },
    RemoveMcpServer {
        name: String,
    },
    /// `enabledPlugins.<key>` set/remove.
    SetPluginEnabled {
        key: String,
        enabled: Option<bool>,
    },
    /// gemini `mcp-server-enablement.json`, whose whole content is
    /// `{"<server>": {"enabled": bool}}` — one global file recording
    /// whether a server is on, wherever it was declared (matrix §1).
    SetGeminiMcpEnabled {
        name: String,
        enabled: Option<bool>,
    },
    /// gemini settings.json: ensure `context.fileName` names `name`,
    /// keeping whatever it named — Gemini's own default file where the key
    /// was absent, the one string it held, every entry of the list it
    /// held. Dropping any of those would change which files Gemini reads.
    GeminiAddContextFile {
        name: String,
    },
    /// opencode.json: ensure `instructions[]` carries `reference`; for
    /// PreToolUse:Bash hooks also `permission.bash = {"*": "ask"}`.
    OpencodeAddInstruction {
        reference: String,
        bash_permission: bool,
    },
    OpencodeRemoveInstruction {
        reference: String,
    },
    /// opencode.json: cut the `instructions[]` rows under `prefix` — the
    /// spelling every reference kendex renders starts with, directory and
    /// filename marker both — down to `keep`, the rows the current pass
    /// renders. A row not carrying that spelling is somebody else's and
    /// stays, whoever put it in the directory.
    OpencodePruneInstructions {
        prefix: String,
        keep: Vec<String>,
    },
    /// codex config.toml: text-level `[features] hooks = true` merge that
    /// preserves comments and ordering.
    CodexEnableHooksFeature,
    /// APPEND_SYSTEM.md-style marker block upsert/removal.
    UpsertMarkerBlock {
        name: String,
        block: String,
    },
    RemoveMarkerBlock {
        name: String,
    },
}

impl ConfigEdit {
    pub fn apply(&self, current: &str) -> Result<String, String> {
        match self {
            ConfigEdit::CodexEnableHooksFeature => Ok(codex_enable_hooks(current)),
            ConfigEdit::UpsertMarkerBlock { name, block } => {
                Ok(upsert_marker_block(current, name, block))
            }
            ConfigEdit::RemoveMarkerBlock { name } => Ok(remove_marker_block(current, name)),
            json_edit => {
                let mut root: Value = if current.trim().is_empty() {
                    json!({})
                } else {
                    serde_json::from_str(current).map_err(|e| e.to_string())?
                };
                json_edit.apply_json(&mut root)?;
                let mut text = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
                text.push('\n');
                Ok(text)
            }
        }
    }

    fn apply_json(&self, root: &mut Value) -> Result<(), String> {
        let object = root
            .as_object_mut()
            .ok_or("config root is not a JSON object")?;
        if let Some(applied) = self.apply_hook_edit(object) {
            return applied;
        }
        match self {
            ConfigEdit::UpsertMcpServer { name, value } => {
                let servers = ensure_object(object, "mcpServers")?;
                servers.insert(name.clone(), value.clone());
                Ok(())
            }
            ConfigEdit::RemoveMcpServer { name } => {
                remove_from_map(object, "mcpServers", name);
                Ok(())
            }
            ConfigEdit::SetPluginEnabled { key, enabled } => {
                match enabled {
                    Some(enabled) => {
                        ensure_object(object, "enabledPlugins")?
                            .insert(key.clone(), Value::Bool(*enabled));
                    }
                    None => remove_from_map(object, "enabledPlugins", key),
                }
                Ok(())
            }
            ConfigEdit::SetGeminiMcpEnabled { name, enabled } => {
                set_gemini_mcp_enabled(object, name, *enabled)
            }
            ConfigEdit::GeminiAddContextFile { name } => gemini_add_context_file(object, name),
            ConfigEdit::OpencodeAddInstruction {
                reference,
                bash_permission,
            } => opencode_add_instruction(object, reference, *bash_permission),
            ConfigEdit::OpencodeRemoveInstruction { reference } => {
                if let Some(list) = object.get_mut("instructions").and_then(Value::as_array_mut) {
                    list.retain(|v| v.as_str() != Some(reference));
                    if list.is_empty() {
                        object.shift_remove("instructions");
                    }
                }
                Ok(())
            }
            ConfigEdit::OpencodePruneInstructions { prefix, keep } => {
                if let Some(list) = object.get_mut("instructions").and_then(Value::as_array_mut) {
                    list.retain(|v| {
                        v.as_str().is_none_or(|row| {
                            !row.starts_with(prefix) || keep.iter().any(|k| k == row)
                        })
                    });
                    if list.is_empty() {
                        object.shift_remove("instructions");
                    }
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// The hook-registry edits, one shape per registry format, or `None`
    /// for an edit that touches no hook entry.
    fn apply_hook_edit(&self, object: &mut Map<String, Value>) -> Option<Result<(), String>> {
        Some(match self {
            ConfigEdit::UpsertHook {
                event,
                matcher,
                command,
                timeout,
            } => upsert_hook(object, event, matcher.as_deref(), command, *timeout),
            ConfigEdit::RemoveHook {
                event,
                matcher,
                command,
            } => {
                remove_hook(object, event.as_deref(), matcher.as_deref(), command);
                Ok(())
            }
            ConfigEdit::UpsertCopilotHook {
                event,
                matcher,
                command,
                timeout,
            } => upsert_copilot_hook(object, event, matcher.as_deref(), command, *timeout),
            ConfigEdit::RemoveCopilotHook {
                event,
                matcher,
                command,
            } => {
                remove_copilot_hook(object, event.as_deref(), matcher.as_deref(), command);
                Ok(())
            }
            ConfigEdit::UpsertAntigravityHook {
                name,
                event,
                matcher,
                command,
                timeout,
            } => {
                upsert_antigravity_hook(object, name, event, matcher.as_deref(), command, *timeout)
            }
            ConfigEdit::RemoveAntigravityHook {
                name,
                event,
                matcher,
                command,
            } => {
                remove_antigravity_hook(
                    object,
                    name.as_deref(),
                    event.as_deref(),
                    matcher.as_deref(),
                    command,
                );
                Ok(())
            }
            _ => return None,
        })
    }
}

/// Drop one entry from a map, and the map itself once it holds nothing —
/// an empty object left behind is a key the user never wrote.
fn remove_from_map(object: &mut Map<String, Value>, key: &str, entry: &str) {
    if let Some(map) = object.get_mut(key).and_then(Value::as_object_mut) {
        map.shift_remove(entry);
        if map.is_empty() {
            object.shift_remove(key);
        }
    }
}

fn opencode_add_instruction(
    object: &mut Map<String, Value>,
    reference: &str,
    bash_permission: bool,
) -> Result<(), String> {
    if object.is_empty() {
        object.insert(
            "$schema".into(),
            Value::String("https://opencode.ai/config.json".into()),
        );
    }
    let list = object
        .entry("instructions")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or("instructions is not an array")?;
    if !list.iter().any(|v| v.as_str() == Some(reference)) {
        list.push(Value::String(reference.to_owned()));
    }
    if bash_permission {
        let permission = ensure_object(object, "permission")?;
        permission
            .entry("bash")
            .or_insert_with(|| json!({"*": "ask"}));
    }
    Ok(())
}

fn ensure_object<'a>(
    object: &'a mut Map<String, Value>,
    key: &str,
) -> Result<&'a mut Map<String, Value>, String> {
    object
        .entry(key)
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or(format!("{key} is not an object"))
}

/// The whole file is a map of server name to its state, so clearing our
/// entry takes the name with it rather than leaving an empty object behind.
fn set_gemini_mcp_enabled(
    root: &mut Map<String, Value>,
    name: &str,
    enabled: Option<bool>,
) -> Result<(), String> {
    match enabled {
        Some(enabled) => {
            ensure_object(root, name)?.insert("enabled".into(), Value::Bool(enabled));
        }
        None => {
            root.shift_remove(name);
        }
    }
    Ok(())
}

/// The file Gemini reads when `context.fileName` is not set. Written in
/// beside the name a shim adds, since an absent key means this file and a
/// key naming only the shim's would stop Gemini reading it.
const GEMINI_DEFAULT_CONTEXT_FILE: &str = "GEMINI.md";

/// `context.fileName` gains `name` in whichever shape it already has: a
/// string becomes a two-element list with the string first, a list is
/// appended to, an absent key is the default file then `name`. Anything
/// else there is not a place that can take a name, and is refused rather
/// than replaced (invariant 2).
fn gemini_add_context_file(root: &mut Map<String, Value>, name: &str) -> Result<(), String> {
    let context = ensure_object(root, "context")?;
    match context.get_mut("fileName") {
        None => {
            let mut names = vec![GEMINI_DEFAULT_CONTEXT_FILE.to_owned()];
            if name != GEMINI_DEFAULT_CONTEXT_FILE {
                names.push(name.to_owned());
            }
            context.insert("fileName".into(), json!(names));
        }
        Some(Value::String(current)) => {
            if current != name {
                let kept = current.clone();
                context.insert("fileName".into(), json!([kept, name]));
            }
        }
        Some(Value::Array(list)) => {
            if !list.iter().any(|entry| entry.as_str() == Some(name)) {
                list.push(Value::String(name.to_owned()));
            }
        }
        Some(_) => return Err("context.fileName is neither a string nor a list".to_owned()),
    }
    Ok(())
}

/// How a registry spells a matcher: an entry naming none, or naming an
/// empty one, is the entry for every operation.
///
/// Everything that compares or records a matcher goes through this. Two
/// spellings of the same thing passing each other by is how a hook came
/// to be registered again beside itself on every refresh, for ever.
pub(crate) fn spelled(matcher: Option<&str>) -> &str {
    matcher
        .filter(|matcher| !matcher.is_empty())
        .unwrap_or(crate::scan::hooks::ANY_MATCHER)
}

/// Whether a matcher names this group or entry.
///
/// The one place any of these editors decides that something in the file
/// is the registration it is holding. Identifying by the command alone
/// would claim a person's own registration beside kendex's. `None` names
/// every matcher, which is what taking a whole
/// installation away means and never what putting one in does; an upsert
/// asks for the one it writes under.
///
/// What is stored is whatever the person wrote, so it is spelled here.
/// What is asked for arrives spelled already — every matcher becomes one
/// through [`spelled`], where it becomes a thing to look for.
pub(crate) fn names(entry: &Value, matcher: Option<&str>) -> bool {
    let Some(matcher) = matcher else {
        return true;
    };
    spelled(entry.get("matcher").and_then(Value::as_str)) == matcher
}

/// The matcher an upsert writes under, as a registry spells it — never
/// "every matcher", which is not something a registration can be.
pub(crate) fn one(matcher: Option<&str>) -> Option<&str> {
    Some(spelled(matcher))
}

#[cfg(test)]
mod tests;
