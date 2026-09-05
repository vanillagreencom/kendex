use std::path::Path;

use super::{RawEntry, antigravity, copilot, hooks, jsonc, plugins};
use crate::env::Env;
use crate::fs::read_if_exists;
use crate::harness::Reader;

pub fn read_structured(path: &Path, reader: &Reader, env: &Env) -> Result<Vec<RawEntry>, String> {
    match reader {
        Reader::McpServersJson | Reader::ClaudeUserMcp => {
            Ok(mcp_object(read_json(path)?.get("mcpServers")))
        }
        Reader::ClaudeUserProjectMcp { project } => {
            let value = read_json(path)?;
            let servers = value
                .get("projects")
                .and_then(|p| p.get(project.to_string_lossy().as_ref()))
                .and_then(|p| p.get("mcpServers"));
            Ok(mcp_object(servers))
        }
        Reader::GeminiMcp => gemini_mcp(path, env),
        Reader::McpServersToml => mcp_toml(path),
        Reader::OpencodeMcp => opencode_mcp(path),
        Reader::OpencodePluginRefs => opencode_plugin_refs(path),
        Reader::HooksObject => hooks::read(path),
        Reader::CopilotHooks => copilot::read(path),
        Reader::AntigravityHooks => antigravity::read(path),
        Reader::CopilotPlugins => copilot::plugins(path),
        Reader::ClaudePluginRegistry => plugins::claude_registry(path, env),
        Reader::ClaudeSettingsPlugins => plugins::claude_settings(path),
        Reader::CodexPluginCache => plugins::codex_cache(path),
        Reader::CursorPluginDirs => Ok(plugins::cursor_dirs(path)),
        Reader::PiPackages => super::pi_packages::pi_packages(path),
    }
}

/// jsonc-tolerant read: comments and trailing commas never block a scan.
pub fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let text = read_if_exists(path)
        .map_err(|e| e.to_string())?
        .ok_or("file vanished mid-scan")?;
    serde_json::from_str(&jsonc::to_json(&text)).map_err(|e| e.to_string())
}

fn mcp_object(servers: Option<&serde_json::Value>) -> Vec<RawEntry> {
    let Some(map) = servers.and_then(|s| s.as_object()) else {
        return Vec::new();
    };
    map.iter()
        .map(|(name, entry)| RawEntry {
            name: name.clone(),
            enabled: None,
            description: mcp_summary(entry),
            source_path: None,
        })
        .collect()
}

/// The command or URL — how a list view tells servers apart.
fn mcp_summary(entry: &serde_json::Value) -> Option<String> {
    for key in ["command", "url", "serverUrl"] {
        if let Some(value) = entry.get(key).and_then(|v| v.as_str()) {
            return Some(value.to_owned());
        }
    }
    entry
        .get("command")
        .and_then(|c| c.as_array())
        .map(|parts| {
            parts
                .iter()
                .filter_map(|p| p.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        })
}

/// Gemini declares servers per scope but records whether each one is
/// switched on in a single file for the whole machine, and the settings
/// `mcp.excluded` list gates them too — so a server a project declared can
/// still be off, and reading the declaration alone would say otherwise
/// (matrix §1). Nothing said about a server means Gemini's own default: on.
fn gemini_mcp(path: &Path, env: &Env) -> Result<Vec<RawEntry>, String> {
    let settings = read_json(path)?;
    let state = crate::harness::gemini::settings::mcp_enablement_file(env);
    let state = read_if_exists(&state)
        .ok()
        .flatten()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .unwrap_or(serde_json::Value::Null);
    let excluded = settings
        .get("mcp")
        .and_then(|mcp| mcp.get("excluded"))
        .and_then(|list| list.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|name| name.as_str().map(str::to_owned))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(mcp_object(settings.get("mcpServers"))
        .into_iter()
        .map(|entry| RawEntry {
            enabled: Some(
                !excluded.contains(&entry.name)
                    && state
                        .get(&entry.name)
                        .and_then(|server| server.get("enabled"))
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(true),
            ),
            ..entry
        })
        .collect())
}

fn mcp_toml(path: &Path) -> Result<Vec<RawEntry>, String> {
    let text = read_if_exists(path)
        .map_err(|e| e.to_string())?
        .ok_or("file vanished mid-scan")?;
    let value: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
    let Some(servers) = value.get("mcp_servers").and_then(|s| s.as_table()) else {
        return Ok(Vec::new());
    };
    Ok(servers
        .iter()
        .map(|(name, entry)| RawEntry {
            name: name.clone(),
            enabled: None,
            description: entry
                .get("command")
                .or_else(|| entry.get("url"))
                .and_then(|v| v.as_str())
                .map(str::to_owned),
            source_path: None,
        })
        .collect())
}

fn opencode_mcp(path: &Path) -> Result<Vec<RawEntry>, String> {
    let value = read_json(path)?;
    let Some(map) = value.get("mcp").and_then(|m| m.as_object()) else {
        return Ok(Vec::new());
    };
    Ok(map
        .iter()
        .map(|(name, entry)| RawEntry {
            name: name.clone(),
            enabled: Some(
                entry
                    .get("enabled")
                    .and_then(|e| e.as_bool())
                    .unwrap_or(true),
            ),
            description: mcp_summary(entry),
            source_path: None,
        })
        .collect())
}

fn opencode_plugin_refs(path: &Path) -> Result<Vec<RawEntry>, String> {
    let value = read_json(path)?;
    let Some(refs) = value.get("plugin").and_then(|p| p.as_array()) else {
        return Ok(Vec::new());
    };
    Ok(refs
        .iter()
        .filter_map(|r| r.as_str())
        .map(|spec| RawEntry {
            name: spec.to_owned(),
            enabled: None,
            description: Some("npm plugin ref".to_owned()),
            source_path: None,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_mcp_toml_lists_server_names() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("config.toml");
        std::fs::write(
            &path,
            "[mcp_servers.github]\ncommand = \"gh-mcp\"\n[mcp_servers.db]\nurl = \"https://x\"\n",
        )
        .unwrap();
        let mut entries = mcp_toml(&path).unwrap();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(entries[0].name, "db");
        assert_eq!(entries[1].description.as_deref(), Some("gh-mcp"));
    }

    /// A project can declare a Gemini server, but whether it is switched on
    /// is machine-wide — so the declaration alone never settles the answer.
    #[test]
    fn a_gemini_server_reads_off_when_the_machine_says_it_is() {
        let tmp = tempfile::tempdir().unwrap();
        let env = crate::env::Env::fake(tmp.path(), crate::env::FakeOs::Linux);
        let settings = tmp.path().join(".gemini/settings.json");
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            r#"{"mcpServers": {"gh": {"command": "gh-mcp"}, "docs": {"url": "https://d"},
                "old": {"command": "x"}}, "mcp": {"excluded": ["old"]}}"#,
        )
        .unwrap();
        std::fs::write(
            tmp.path().join(".gemini/mcp-server-enablement.json"),
            r#"{"gh": {"enabled": false}}"#,
        )
        .unwrap();

        let mut entries = gemini_mcp(&settings, &env).unwrap();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(
            entries
                .iter()
                .map(|e| (e.name.as_str(), e.enabled))
                .collect::<Vec<_>>(),
            [
                ("docs", Some(true)),
                ("gh", Some(false)),
                ("old", Some(false))
            ]
        );
        assert_eq!(entries[1].description.as_deref(), Some("gh-mcp"));
    }

    #[test]
    fn opencode_mcp_honors_enabled_and_jsonc() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("opencode.jsonc");
        std::fs::write(
            &path,
            r#"{
  // servers
  "mcp": {
    "on": {"type": "remote", "url": "https://x"},
    "off": {"type": "local", "command": ["db", "run"], "enabled": false},
  },
}"#,
        )
        .unwrap();
        let mut entries = opencode_mcp(&path).unwrap();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(
            entries
                .iter()
                .map(|e| (e.name.as_str(), e.enabled))
                .collect::<Vec<_>>(),
            [("off", Some(false)), ("on", Some(true))]
        );
        assert_eq!(entries[0].description.as_deref(), Some("db run"));
    }
}
