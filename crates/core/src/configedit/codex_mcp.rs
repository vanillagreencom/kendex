//! One `[mcp_servers.<name>]` table in Codex's `config.toml`, edited the way
//! Codex edits it: through `toml_edit`, so the user's comments, ordering
//! and every other table survive (codex-rs/core/src/config/edit.rs does the
//! same). The table is written from the declared value in Codex's keys:
//! `command`, `args` and an `env` sub-table for a stdio server, `url` for a
//! streamable-HTTP one, never a `type`, and `enabled = false` when the
//! declaration is switched off (learn.chatgpt.com/docs/extend/mcp). Codex
//! reads an `env` value literally and passes a parent variable through by
//! its own name under `env_vars`, so the catalog's `$NAME` references become
//! that list; a reference under another name has no Codex spelling and the
//! table is refused.

use serde_json::Value as Json;
use toml_edit::{Array, DocumentMut, Item, Table, Value};

const SERVERS: &str = "mcp_servers";

pub(super) fn upsert(
    current: &str,
    name: &str,
    value: &Json,
    enabled: bool,
) -> Result<String, String> {
    let mut document: DocumentMut = current
        .parse()
        .map_err(|e: toml_edit::TomlError| e.to_string())?;
    let mut table = server_table(value)?;
    if !enabled {
        table.insert("enabled", Item::Value(Value::from(false)));
    }
    let servers = document
        .entry(SERVERS)
        .or_insert_with(|| {
            let mut parent = Table::new();
            parent.set_implicit(true);
            Item::Table(parent)
        })
        .as_table_mut()
        .ok_or(format!("{SERVERS} is not a table"))?;
    // A table already there keeps its place and the comment above it: the
    // fields are replaced inside it, the way Codex's own editor keeps decor.
    match servers.get_mut(name).and_then(Item::as_table_mut) {
        Some(existing) => {
            existing.clear();
            for (key, item) in table.iter() {
                existing.insert(key, item.clone());
            }
        }
        None => {
            servers.insert(name, Item::Table(table));
        }
    }
    Ok(document.to_string())
}

pub(super) fn remove(current: &str, name: &str) -> Result<String, String> {
    let mut document: DocumentMut = current
        .parse()
        .map_err(|e: toml_edit::TomlError| e.to_string())?;
    let Some(servers) = document.get_mut(SERVERS) else {
        return Ok(current.to_owned());
    };
    let servers = servers
        .as_table_mut()
        .ok_or(format!("{SERVERS} is not a table"))?;
    servers.remove(name);
    // A parent kendex itself brought in goes with its last child; one the
    // user wrote, with a header of their own, stays.
    if servers.is_empty() && servers.is_implicit() {
        document.remove(SERVERS);
    }
    Ok(document.to_string())
}

/// The declared server as Codex's table. `type` names the transport in the
/// catalog's shape and Codex reads the transport off which key is present,
/// so it is not carried over; `env` becomes `env_vars`.
fn server_table(value: &Json) -> Result<Table, String> {
    let object = value.as_object().ok_or("the server is not an object")?;
    let mut table = Table::new();
    for (key, entry) in object {
        match key.as_str() {
            "type" => {}
            "env" => {
                let mut names = Array::new();
                for name in env_vars(entry)? {
                    names.push(name);
                }
                table.insert("env_vars", Item::Value(Value::Array(names)));
            }
            _ => {
                table.insert(key, item(entry)?);
            }
        }
    }
    Ok(table)
}

/// The variables a catalog `env` table passes through, as Codex names them.
/// Codex has no rename: `env_vars = ["NAME"]` hands the process the parent's
/// `NAME`, so a reference that would land under another key is refused with
/// the reason rather than written as a literal the process would read.
pub(super) fn env_vars(env: &Json) -> Result<Vec<String>, String> {
    let Some(env) = env.as_object() else {
        return Err("env is not a table".into());
    };
    let mut names = Vec::new();
    for (key, value) in env {
        let reference = value.as_str().unwrap_or_default();
        let name = reference
            .strip_prefix("${")
            .and_then(|rest| rest.strip_suffix('}'))
            .or_else(|| reference.strip_prefix('$'))
            .unwrap_or(reference);
        if name != key {
            return Err(format!(
                "Codex passes an environment variable through under its own name only, and {key} would come from {reference} — name the variable {name} in the catalog, or drop Codex from this server's harnesses"
            ));
        }
        names.push(key.clone());
    }
    Ok(names)
}

fn item(value: &Json) -> Result<Item, String> {
    Ok(match value {
        Json::String(text) => Item::Value(Value::from(text.as_str())),
        Json::Bool(flag) => Item::Value(Value::from(*flag)),
        Json::Number(number) => match (number.as_i64(), number.as_f64()) {
            (Some(whole), _) => Item::Value(Value::from(whole)),
            (None, Some(real)) => Item::Value(Value::from(real)),
            (None, None) => return Err(format!("{number} is not a TOML number")),
        },
        Json::Array(items) => {
            let mut array = Array::new();
            for entry in items {
                match item(entry)? {
                    Item::Value(scalar) => array.push(scalar),
                    _ => return Err("a nested table inside an array is not a server field".into()),
                }
            }
            Item::Value(Value::Array(array))
        }
        Json::Object(map) => {
            let mut table = Table::new();
            for (key, entry) in map {
                table.insert(key, item(entry)?);
            }
            Item::Table(table)
        }
        Json::Null => return Err("a null is not a server field".into()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const THEIRS: &str = "# the user's file\nmodel = \"gpt-6-astra\"\n\n[features]\nhooks = true # keep\n\n[mcp_servers.other]\ncommand = \"x\"\n";

    #[test]
    fn a_server_table_is_added_beside_the_users_tables_and_comments() {
        let gh =
            json!({"command": "gh-mcp", "args": ["--stdio"], "env": {"GH_TOKEN": "$GH_TOKEN"}});
        let once = upsert(THEIRS, "gh", &gh, true).unwrap();
        assert!(
            once.starts_with("# the user's file\nmodel = \"gpt-6-astra\"\n"),
            "{once}"
        );
        assert!(once.contains("hooks = true # keep\n"), "{once}");
        let parsed: toml::Table = once.parse().unwrap();
        assert_eq!(
            parsed["mcp_servers"]["other"]["command"].as_str(),
            Some("x")
        );
        assert_eq!(
            parsed["mcp_servers"]["gh"]["command"].as_str(),
            Some("gh-mcp")
        );
        assert_eq!(
            parsed["mcp_servers"]["gh"]["args"][0].as_str(),
            Some("--stdio")
        );
        assert_eq!(
            parsed["mcp_servers"]["gh"]["env_vars"][0].as_str(),
            Some("GH_TOKEN")
        );
        assert!(parsed["mcp_servers"]["gh"].get("env").is_none());
        let renamed = json!({"command": "gh-mcp", "env": {"GITHUB_TOKEN": "$GH_TOKEN"}});
        assert!(
            upsert(THEIRS, "gh", &renamed, true)
                .unwrap_err()
                .contains("GITHUB_TOKEN")
        );
        assert_eq!(upsert(&once, "gh", &gh, true).unwrap(), once);

        let off = upsert(&once, "gh", &gh, false).unwrap();
        let parsed: toml::Table = off.parse().unwrap();
        assert_eq!(
            parsed["mcp_servers"]["gh"]["enabled"].as_bool(),
            Some(false)
        );
        assert_eq!(upsert(&off, "gh", &gh, true).unwrap(), once);

        let removed = remove(&once, "gh").unwrap();
        assert_eq!(removed, THEIRS);
    }

    #[test]
    fn a_replaced_table_keeps_its_comment_and_place_and_an_explicit_parent_stays() {
        let theirs = "# my notes\n[mcp_servers.gh]\ncommand = \"old\"\n\n[tools]\nx = 1\n";
        let replaced = upsert(theirs, "gh", &json!({"command": "gh-mcp"}), true).unwrap();
        assert_eq!(
            replaced,
            "# my notes\n[mcp_servers.gh]\ncommand = \"gh-mcp\"\n\n[tools]\nx = 1\n"
        );

        let explicit = "# servers I keep\n[mcp_servers]\n\n[mcp_servers.gh]\ncommand = \"gh-mcp\"\n\n[features]\nk = 1\n";
        let removed = remove(explicit, "gh").unwrap();
        assert!(
            removed.contains("# servers I keep\n[mcp_servers]\n"),
            "{removed}"
        );
        assert!(removed.contains("[features]\nk = 1\n"), "{removed}");
    }

    #[test]
    fn a_url_server_keeps_the_url_and_not_the_type_and_an_empty_parent_leaves() {
        let docs = json!({"type": "http", "url": "https://mcp.example"});
        let text = upsert("", "docs", &docs, true).unwrap();
        assert_eq!(text, "[mcp_servers.docs]\nurl = \"https://mcp.example\"\n");
        assert_eq!(remove(&text, "docs").unwrap(), "");
        assert_eq!(
            remove("model = \"x\"\n", "docs").unwrap(),
            "model = \"x\"\n"
        );
    }

    #[test]
    fn an_inline_servers_table_is_refused_rather_than_rewritten() {
        let inline = "mcp_servers = { other = { command = \"x\" } }\n";
        assert!(upsert(inline, "gh", &json!({"command": "gh-mcp"}), true).is_err());
    }
}
