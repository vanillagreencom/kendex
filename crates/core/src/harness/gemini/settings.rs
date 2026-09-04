//! What Gemini's own configuration says about the surfaces kendex writes.
//! These are reads of the user's harness config, not of a catalog, so they
//! go through `crate::fs` rather than the sealed source API.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::harness::HarnessAdapter;
use crate::model::Scope;

/// Every category Gemini's nested settings schema defines at the top level
/// ([configuration reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md)).
/// A settings file carrying none of these is treated as the flat shape,
/// because the docs give no other signal for that format (matrix §R9).
const CATEGORIES: [&str; 25] = [
    "policyPaths",
    "adminPolicyPaths",
    "general",
    "output",
    "ui",
    "ide",
    "privacy",
    "billing",
    "model",
    "modelConfigs",
    "agents",
    "context",
    "tools",
    "mcp",
    "useWriteTodos",
    "security",
    "advanced",
    "experimental",
    "skills",
    "hooksConfig",
    "hooks",
    "mcpServers",
    "telemetry",
    "contextManagement",
    "admin",
];

/// Whether the installed CLI would read what kendex writes into this file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// Nothing there yet — a write creates the file in the current schema.
    Absent,
    Current,
    /// Flat keys only. Writing the current schema into it would leave the
    /// user with settings their CLI never reads.
    Legacy,
}

/// The settings facts the writing paths need, read once per scope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub shape: Shape,
    /// `experimental.enableAgents` as set. `None` is Gemini's own default,
    /// which is on — absence is not the feature being off.
    pub agents_enabled: Option<bool>,
}

impl Settings {
    /// Why this scope's settings-backed surfaces cannot be managed, or
    /// `None` when they can.
    pub fn unmanageable(&self) -> Option<String> {
        (self.shape == Shape::Legacy).then(|| {
            "its settings.json still holds the flat pre-v0.3.0 keys, so the installed Gemini CLI would not read what kendex writes".to_owned()
        })
    }
}

pub fn settings_file(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => super::Gemini.default_global_root(env).join("settings.json"),
        Scope::Project { root } => root.join(".gemini/settings.json"),
    }
}

/// Enablement state for MCP servers. One global file, whatever scope
/// declared the server (matrix §1).
pub fn mcp_enablement_file(env: &Env) -> PathBuf {
    super::Gemini
        .default_global_root(env)
        .join("mcp-server-enablement.json")
}

/// Whether the machine-wide record has this server switched off. Nothing
/// said about a server is Gemini's own default, which is on (matrix §1).
pub fn mcp_switched_off(env: &Env, name: &str) -> bool {
    json(&mcp_enablement_file(env))
        .as_ref()
        .and_then(|state| state.get(name))
        .and_then(|server| server.get("enabled"))
        .and_then(serde_json::Value::as_bool)
        .is_some_and(|enabled| !enabled)
}

/// The settings file that keeps this server out of the list Gemini loads,
/// if one does: `mcp.excluded` names it, or `mcp.allowed` exists and does
/// not. A project reads its own file and the user's, so both are asked
/// (matrix §1).
pub fn mcp_gated_out(env: &Env, scope: &Scope, name: &str) -> Option<PathBuf> {
    let mut files = vec![settings_file(env, scope)];
    let global = settings_file(env, &Scope::Global);
    if !files.contains(&global) {
        files.push(global);
    }
    files.into_iter().find(|path| {
        let Some(mcp) = json(path).and_then(|value| value.get("mcp").cloned()) else {
            return false;
        };
        let names = |key: &str| -> Option<Vec<String>> {
            let list = mcp.get(key)?.as_array()?;
            Some(
                list.iter()
                    .filter_map(|n| n.as_str())
                    .map(str::to_owned)
                    .collect(),
            )
        };
        let excluded = names("excluded").is_some_and(|list| list.iter().any(|n| n == name));
        let unlisted = names("allowed")
            .is_some_and(|list| !list.is_empty() && !list.iter().any(|n| n == name));
        excluded || unlisted
    })
}

/// The system settings layer, which outranks project scope on a managed
/// machine (matrix §R2). `GEMINI_CLI_SYSTEM_SETTINGS_PATH` relocates it.
pub fn system_settings_file(env: &Env) -> PathBuf {
    if let Some(path) = env.var("GEMINI_CLI_SYSTEM_SETTINGS_PATH") {
        return PathBuf::from(path);
    }
    match () {
        _ if cfg!(target_os = "macos") => {
            PathBuf::from("/Library/Application Support/GeminiCli/settings.json")
        }
        _ if cfg!(target_os = "windows") => {
            PathBuf::from(r"C:\ProgramData\gemini-cli\settings.json")
        }
        _ => PathBuf::from("/etc/gemini-cli/settings.json"),
    }
}

pub fn read(path: &Path) -> Settings {
    let Some(value) = json(path) else {
        return Settings {
            shape: Shape::Absent,
            agents_enabled: None,
        };
    };
    let object = value.as_object();
    let known = object.is_some_and(|map| map.keys().any(|key| CATEGORIES.contains(&key.as_str())));
    let empty = object.is_none_or(serde_json::Map::is_empty);
    Settings {
        shape: match known || empty {
            true => Shape::Current,
            false => Shape::Legacy,
        },
        agents_enabled: value
            .get("experimental")
            .and_then(|experimental| experimental.get("enableAgents"))
            .and_then(serde_json::Value::as_bool),
    }
}

/// Whether the system layer sets `key` itself. It sits above project scope,
/// so a project-scope write of the same key can be inert (matrix §R2).
pub fn system_defines(env: &Env, key: &str) -> bool {
    json(&system_settings_file(env)).is_some_and(|value| value.get(key).is_some())
}

/// A settings file we cannot parse reads as current: the structured-edit
/// path parses it again and reports the failure against its own path, which
/// is a better error than a shape guess made here.
fn json(path: &Path) -> Option<serde_json::Value> {
    let text = crate::fs::read_if_exists(path).ok().flatten()?;
    Some(serde_json::from_str(&text).unwrap_or(serde_json::Value::Null))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    fn written(text: &str) -> (tempfile::TempDir, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("settings.json");
        std::fs::write(&path, text).unwrap();
        (tmp, path)
    }

    #[test]
    fn a_file_with_no_current_category_is_the_old_flat_shape() {
        let (_tmp, path) = written(r#"{"contextFileName": "GEMINI.md", "theme": "Dark"}"#);
        let settings = read(&path);
        assert_eq!(settings.shape, Shape::Legacy);
        assert!(
            settings
                .unmanageable()
                .is_some_and(|reason| reason.contains("flat pre-v0.3.0 keys"))
        );

        let (_tmp, path) = written(r#"{"theme": "Dark", "mcpServers": {}}"#);
        assert_eq!(read(&path).shape, Shape::Current);
        let (_tmp, path) = written("{}");
        assert_eq!(read(&path).shape, Shape::Current);
        assert_eq!(
            read(Path::new("/nowhere/settings.json")).shape,
            Shape::Absent
        );
    }

    #[test]
    fn the_agents_flag_is_only_off_when_it_says_so() {
        let (_tmp, path) = written(r#"{"experimental": {"enableAgents": false}}"#);
        assert_eq!(read(&path).agents_enabled, Some(false));
        let (_tmp, path) = written(r#"{"experimental": {"enableAgents": true}}"#);
        assert_eq!(read(&path).agents_enabled, Some(true));
        let (_tmp, path) = written(r#"{"experimental": {}}"#);
        assert_eq!(read(&path).agents_enabled, None);
    }

    #[test]
    fn the_system_layer_is_read_where_the_env_var_points() {
        let (tmp, path) = written(r#"{"hooks": {"BeforeTool": []}}"#);
        let env = Env::fake(tmp.path(), FakeOs::Linux)
            .with_var("GEMINI_CLI_SYSTEM_SETTINGS_PATH", &path.to_string_lossy());
        assert_eq!(system_settings_file(&env), path);
        assert!(system_defines(&env, "hooks"));
        assert!(!system_defines(&env, "mcpServers"));
        assert!(!system_defines(
            &Env::fake(tmp.path(), FakeOs::Linux),
            "hooks"
        ));
    }

    #[test]
    fn both_scopes_settle_on_their_own_settings_file() {
        let env = Env::fake("/h", FakeOs::Linux);
        assert_eq!(
            settings_file(&env, &Scope::Global),
            PathBuf::from("/h/.gemini/settings.json")
        );
        assert_eq!(
            settings_file(
                &env,
                &Scope::Project {
                    root: PathBuf::from("/p")
                }
            ),
            PathBuf::from("/p/.gemini/settings.json")
        );
        assert_eq!(
            mcp_enablement_file(&env),
            PathBuf::from("/h/.gemini/mcp-server-enablement.json")
        );
    }
}
