use std::fs;
use std::path::Path;

use super::RawEntry;
use super::readers::read_json;
use crate::env::Env;
use crate::fs::read_if_exists;

/// `~/.claude/plugins/installed_plugins.json` (`{"plugins": {"name@mkt": …}}`)
/// joined with `enabledPlugins` from `~/.claude/settings.json`.
pub fn claude_registry(path: &Path, env: &Env) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let value = read_json(path)?;
    let Some(registry) = value.get("plugins").and_then(|p| p.as_object()) else {
        return Ok(Vec::new());
    };
    let enabled_map = claude_enabled_map(&env.home.join(".claude/settings.json"));
    Ok(registry
        .iter()
        .map(|(name, _)| RawEntry {
            name: name.clone(),
            enabled: enabled_map
                .as_ref()
                .and_then(|m| m.get(name).and_then(|v| v.as_bool())),
            // A version is not a description: see the note below.
            description: None,
            source_path: None,
        })
        .collect())
}

fn claude_enabled_map(settings: &Path) -> Option<serde_json::Map<String, serde_json::Value>> {
    let value = read_json(settings).ok()?;
    value.get("enabledPlugins")?.as_object().cloned()
}

/// Project `.claude/settings*.json` `enabledPlugins` entries.
pub fn claude_settings(path: &Path) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let value = read_json(path)?;
    let Some(map) = value.get("enabledPlugins").and_then(|p| p.as_object()) else {
        return Ok(Vec::new());
    };
    Ok(map
        .iter()
        .map(|(name, enabled)| RawEntry {
            name: name.clone(),
            enabled: enabled.as_bool(),
            description: None,
            source_path: None,
        })
        .collect())
}

/// `<root>/plugins/cache/<marketplace>/<plugin>/<version>/.codex-plugin/plugin.json`,
/// newest version wins; disabled via `[plugins."name@mkt"] enabled = false`
/// in the sibling config.toml.
pub fn codex_cache(plugins_dir: &Path) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let mut entries = Vec::new();
    let disabled = codex_disabled_set(plugins_dir);
    let cache = plugins_dir.join("cache");
    for marketplace in dirs_in(&cache) {
        let Some(marketplace_name) = file_name(&marketplace) else {
            continue;
        };
        for plugin in dirs_in(&marketplace) {
            let Some(plugin_name) = file_name(&plugin) else {
                continue;
            };
            let mut versions: Vec<String> = dirs_in(&plugin)
                .iter()
                .filter(|v| v.join(".codex-plugin/plugin.json").is_file())
                .filter_map(|v| file_name(v))
                .collect();
            versions.sort_by(|a, b| numeric_aware_cmp(a, b));
            let Some(newest) = versions.pop() else {
                continue;
            };
            let key = format!("{plugin_name}@{marketplace_name}");
            entries.push(RawEntry {
                enabled: Some(!disabled.contains(&key)),
                name: key,
                source_path: Some(plugin.join(&newest)),
                // A version folder name is not a description of anything.
                // Nobody recognises a plugin by "1.2.0", and putting it where
                // a description goes makes a list of plugins read as a list
                // of numbers.
                description: None,
            });
        }
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}

fn codex_disabled_set(plugins_dir: &Path) -> Vec<String> {
    let Some(root) = plugins_dir.parent() else {
        return Vec::new();
    };
    let Ok(Some(text)) = read_if_exists(&root.join("config.toml")) else {
        return Vec::new();
    };
    let Ok(value) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let Some(table) = value.get("plugins").and_then(|p| p.as_table()) else {
        return Vec::new();
    };
    table
        .iter()
        .filter(|(_, entry)| entry.get("enabled").and_then(|e| e.as_bool()) == Some(false))
        .map(|(name, _)| name.clone())
        .collect()
}

/// `~/.cursor/plugins/local/<p>/` (always enabled) and
/// `~/.cursor/plugins/cache/<marketplace>/<p>/`.
pub fn cursor_dirs(plugins_dir: &Path) -> Vec<RawEntry> {
    let mut entries = Vec::new();
    for plugin in dirs_in(&plugins_dir.join("local")) {
        if !plugin.join(".cursor-plugin/plugin.json").is_file() {
            continue;
        }
        if let Some(name) = file_name(&plugin) {
            entries.push(RawEntry {
                name,
                enabled: Some(true),
                description: None,
                source_path: Some(plugin.clone()),
            });
        }
    }
    for marketplace in dirs_in(&plugins_dir.join("cache")) {
        let Some(marketplace_name) = file_name(&marketplace) else {
            continue;
        };
        for plugin in dirs_in(&marketplace) {
            if let Some(name) = file_name(&plugin) {
                entries.push(RawEntry {
                    name: format!("{name}@{marketplace_name}"),
                    enabled: None,
                    description: None,
                    source_path: Some(plugin.clone()),
                });
            }
        }
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    entries
}

fn dirs_in(dir: &Path) -> Vec<std::path::PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut dirs: Vec<_> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    dirs
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name().and_then(|n| n.to_str()).map(str::to_owned)
}

/// `1.10.0` sorts above `1.9.0` — segment-wise numeric compare with a
/// lexicographic fallback for non-numeric segments.
fn numeric_aware_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |s: &str| -> Vec<Result<u64, String>> {
        s.split('.')
            .map(|seg| seg.parse::<u64>().map_err(|_| seg.to_owned()))
            .collect()
    };
    parse(a).cmp(&parse(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_cache_picks_newest_version_and_honors_disable_table() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        for version in ["1.9.0", "1.10.0"] {
            fs::create_dir_all(
                root.join(format!("plugins/cache/mkt/tool/{version}/.codex-plugin")),
            )
            .unwrap();
            fs::write(
                root.join(format!(
                    "plugins/cache/mkt/tool/{version}/.codex-plugin/plugin.json"
                )),
                "{}",
            )
            .unwrap();
        }
        fs::write(
            root.join("config.toml"),
            "[plugins.\"tool@mkt\"]\nenabled = false\n",
        )
        .unwrap();

        let entries = codex_cache(&root.join("plugins")).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "tool@mkt");
        assert_eq!(entries[0].enabled, Some(false));
        // The version identifies a build, not the plugin — it belongs in the
        // path below, never in the line a person reads to tell plugins apart.
        assert_eq!(entries[0].description, None);
        // Its own version directory, not the shared cache the entry was
        // read from — every plugin in that cache would otherwise be scored
        // on every other plugin's files.
        assert_eq!(
            entries[0].source_path.as_deref(),
            Some(root.join("plugins/cache/mkt/tool/1.10.0").as_path())
        );
    }

    #[test]
    fn cursor_dirs_point_each_plugin_at_its_own_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("local/fmt/.cursor-plugin")).unwrap();
        fs::write(root.join("local/fmt/.cursor-plugin/plugin.json"), "{}").unwrap();
        fs::create_dir_all(root.join("cache/mkt/lint")).unwrap();

        let entries = cursor_dirs(root);
        let by_name = |name: &str| {
            entries
                .iter()
                .find(|e| e.name == name)
                .unwrap()
                .source_path
                .clone()
                .unwrap()
        };
        assert_eq!(by_name("fmt"), root.join("local/fmt"));
        assert_eq!(by_name("lint@mkt"), root.join("cache/mkt/lint"));
    }

    #[test]
    fn claude_registry_joins_enabled_state_from_settings() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        fs::create_dir_all(home.join(".claude/plugins")).unwrap();
        fs::write(
            home.join(".claude/plugins/installed_plugins.json"),
            r#"{"plugins":{"fmt@main":{"version":"2.0.0"},"lint@main":{}}}"#,
        )
        .unwrap();
        fs::write(
            home.join(".claude/settings.json"),
            r#"{"enabledPlugins":{"fmt@main":false}}"#,
        )
        .unwrap();
        let env = Env::fake(home, crate::env::FakeOs::Linux);

        let mut entries =
            claude_registry(&home.join(".claude/plugins/installed_plugins.json"), &env).unwrap();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(entries[0].name, "fmt@main");
        assert_eq!(entries[0].enabled, Some(false));
        assert_eq!(entries[0].description, None);
        assert_eq!(entries[1].enabled, None);
    }
}
