//! What Copilot's own configuration says about the surfaces kendex writes.
//! These are reads of the user's harness config, not of a catalog, so they
//! go through `crate::fs` rather than the sealed source API.
//!
//! Three facts drive everything here: Copilot moved its user-editable
//! settings out of `config.json` into `settings.json` (matrix §R9), a
//! repository file may add to a disabled-list but never take a name off one
//! (§R7), and the CLI reads a handful of keys out of Claude Code's settings
//! files as well (§R6).

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::harness::HarnessAdapter;
use crate::model::{ItemKind, Scope};

/// Where a scope's own settings live — the file kendex writes plugin
/// toggles into. Only a fixed list of keys is honored in a repository file
/// and the rest are ignored in silence, so `enabledPlugins` is the one key
/// kendex ever writes there; everything else it manages for Copilot is a
/// file of its own (matrix §2).
pub fn settings_file(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => user_settings_file(env),
        Scope::Project { root } => root.join(".github/copilot/settings.json"),
    }
}

pub fn user_settings_file(env: &Env) -> PathBuf {
    super::Copilot
        .default_global_root(env)
        .join("settings.json")
}

/// The pre-migration home of the same user settings. Read so an older
/// machine is understood, never written (matrix §R9).
pub fn legacy_user_settings_file(env: &Env) -> PathBuf {
    super::Copilot.default_global_root(env).join("config.json")
}

/// The shared repository file and the personal one beside it, in the order
/// Copilot layers them.
pub fn repo_settings_files(project: &Path) -> [PathBuf; 2] {
    let dir = project.join(".github/copilot");
    [dir.join("settings.json"), dir.join("settings.local.json")]
}

/// Claude Code's settings files, which Copilot reads for a shared cross-tool
/// subset: `companyAnnouncements`, `disableAllHooks`, `enabledPlugins`,
/// `extraKnownMarketplaces`, `hooks` (matrix §2, §R6). Inputs to Copilot's
/// effective state — never a Copilot installation.
pub fn claude_settings_files(project: &Path) -> [PathBuf; 2] {
    [
        super::CLAUDE_SETTINGS.at(project),
        super::CLAUDE_SETTINGS_LOCAL.at(project),
    ]
}

/// Every file Copilot reads settings from for this scope, lowest layer
/// first. Later files win on the keys they both set.
fn layers(env: &Env, scope: &Scope) -> Vec<PathBuf> {
    let mut files = vec![legacy_user_settings_file(env), user_settings_file(env)];
    if let Scope::Project { root } = scope {
        files.extend(claude_settings_files(root));
        files.extend(repo_settings_files(root));
    }
    files
}

/// The file that switched every hook off, or `None` when none did. Only
/// what is on disk is observable, so callers say how things are configured
/// and never claim what a run will do.
pub fn hooks_switched_off_by(env: &Env, scope: &Scope) -> Option<PathBuf> {
    let mut off = None;
    for path in layers(env, scope) {
        let Some(value) = json(&path) else {
            continue;
        };
        match value.get("disableAllHooks").and_then(|v| v.as_bool()) {
            Some(true) => off = Some(path),
            Some(false) => off = None,
            None => {}
        }
    }
    off
}

/// The settings key holding the names of the kind Copilot has switched off.
fn disabled_key(kind: ItemKind) -> Option<&'static str> {
    match kind {
        ItemKind::Skill => Some("disabledSkills"),
        ItemKind::McpServer => Some("disabledMcpServers"),
        _ => None,
    }
}

/// Whether the machine's own Copilot settings switch `name` off from a layer
/// this scope cannot answer. A repository file adds to `disabledSkills` and
/// `disabledMcpServers` but can never take a name off one, so a project that
/// declares an item on is not the last word on it (matrix §R7).
pub fn disabled_above(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Option<PathBuf> {
    if matches!(scope, Scope::Global) {
        return None;
    }
    let key = disabled_key(kind)?;
    [legacy_user_settings_file(env), user_settings_file(env)]
        .into_iter()
        .find(|path| names_in(path, key).iter().any(|listed| listed == name))
}

fn names_in(path: &Path, key: &str) -> Vec<String> {
    let Some(value) = json(path) else {
        return Vec::new();
    };
    value
        .get(key)
        .and_then(|list| list.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|name| name.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// Why this scope's settings-backed surfaces cannot be managed, or `None`
/// when they can. A machine still holding the old `config.json` and no
/// `settings.json` has never run a CLI that reads what kendex would write,
/// so the write is refused rather than left somewhere nothing loads it.
pub fn unmanageable(env: &Env, scope: &Scope) -> Option<String> {
    let stale = matches!(scope, Scope::Global)
        && !user_settings_file(env).exists()
        && legacy_user_settings_file(env).exists();
    stale.then(|| {
        "this machine still keeps Copilot's settings in the older config.json, so the installed CLI would not read what kendex writes".to_owned()
    })
}

/// The model ids a repository allows, as glob patterns
/// ([supported models](https://docs.github.com/en/copilot/reference/ai-models/supported-models),
/// matrix §4). `None` where the repository restricts nothing.
pub fn allowed_models(scope: &Scope) -> Option<Vec<String>> {
    let Scope::Project { root } = scope else {
        return None;
    };
    let text = crate::fs::read_if_exists(&allowed_models_file(root))
        .ok()
        .flatten()?;
    let patterns: Vec<String> = text
        .lines()
        .map(str::trim)
        // A `fallback:` line names what to use when nothing matches; it is
        // not itself a pattern the allowlist accepts.
        .filter(|line| !line.is_empty() && !line.starts_with('#') && !line.contains(':'))
        .map(str::to_owned)
        .collect();
    (!patterns.is_empty()).then_some(patterns)
}

/// The file a repository names its allowed models in.
pub fn allowed_models_file(project: &Path) -> PathBuf {
    super::ALLOWED_MODELS.at(project)
}

/// Whether any pattern admits this model id. `*` stands for any run of
/// characters, which is the whole of the syntax the allowlist file uses.
pub fn model_allowed(patterns: &[String], model: &str) -> bool {
    patterns.iter().any(|pattern| glob_matches(pattern, model))
}

fn glob_matches(pattern: &str, value: &str) -> bool {
    let mut rest = value;
    let mut parts = pattern.split('*');
    let Some(first) = parts.next() else {
        return false;
    };
    let Some(stripped) = rest.strip_prefix(first) else {
        return false;
    };
    rest = stripped;
    let mut last: Option<&str> = None;
    for part in parts {
        last = Some(part);
        if part.is_empty() {
            continue;
        }
        let Some(at) = rest.find(part) else {
            return false;
        };
        rest = &rest[at + part.len()..];
    }
    match last {
        // No `*` at all: the pattern had to consume the whole value.
        None => rest.is_empty(),
        // Trailing `*` swallows whatever is left; a trailing literal has to
        // land at the end.
        Some(part) => part.is_empty() || rest.is_empty(),
    }
}

fn json(path: &Path) -> Option<serde_json::Value> {
    let text = crate::fs::read_if_exists(path).ok().flatten()?;
    serde_json::from_str(&text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    fn fixture() -> (tempfile::TempDir, Env, Scope) {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("dev/app");
        std::fs::create_dir_all(project.join(".github/copilot")).unwrap();
        std::fs::create_dir_all(project.join(".claude")).unwrap();
        std::fs::create_dir_all(tmp.path().join(".copilot")).unwrap();
        let scope = Scope::Project { root: project };
        (tmp, env, scope)
    }

    /// Copilot reads Claude Code's settings for this key, so a switch thrown
    /// there is the one that decides whether Copilot's hooks run.
    #[test]
    fn hooks_switched_off_in_claudes_file_count_and_a_repo_can_switch_them_back_on() {
        let (_tmp, env, scope) = fixture();
        let Scope::Project { root } = &scope else {
            unreachable!("fixture scope is a project");
        };
        assert_eq!(hooks_switched_off_by(&env, &scope), None);

        let claude = root.join(".claude/settings.json");
        std::fs::write(&claude, r#"{"disableAllHooks": true}"#).unwrap();
        assert_eq!(hooks_switched_off_by(&env, &scope), Some(claude));

        // The repository file is the later layer, so its answer is the one
        // Copilot ends up with.
        std::fs::write(
            root.join(".github/copilot/settings.json"),
            r#"{"disableAllHooks": false}"#,
        )
        .unwrap();
        assert_eq!(hooks_switched_off_by(&env, &scope), None);
    }

    #[test]
    fn a_personal_disable_is_visible_from_a_project_and_a_global_scope_has_nothing_above_it() {
        let (_tmp, env, scope) = fixture();
        std::fs::write(
            user_settings_file(&env),
            r#"{"disabledSkills": ["deploy"], "disabledMcpServers": ["gh"]}"#,
        )
        .unwrap();
        assert_eq!(
            disabled_above(&env, &scope, ItemKind::Skill, "deploy"),
            Some(user_settings_file(&env))
        );
        assert!(disabled_above(&env, &scope, ItemKind::McpServer, "gh").is_some());
        assert_eq!(disabled_above(&env, &scope, ItemKind::Skill, "other"), None);
        assert_eq!(
            disabled_above(&env, &Scope::Global, ItemKind::Skill, "deploy"),
            None
        );
    }

    #[test]
    fn a_machine_with_only_the_old_settings_file_is_not_written_to() {
        let (_tmp, env, scope) = fixture();
        assert_eq!(unmanageable(&env, &Scope::Global), None);

        std::fs::write(legacy_user_settings_file(&env), "{}").unwrap();
        assert!(
            unmanageable(&env, &Scope::Global)
                .is_some_and(|reason| reason.contains("older config.json"))
        );
        // A repository file has no older shape to be confused with.
        assert_eq!(unmanageable(&env, &scope), None);

        std::fs::write(user_settings_file(&env), "{}").unwrap();
        assert_eq!(unmanageable(&env, &Scope::Global), None);
    }

    #[test]
    fn a_repository_allowlist_names_the_models_it_takes() {
        let (_tmp, _env, scope) = fixture();
        let Scope::Project { root } = &scope else {
            unreachable!("fixture scope is a project");
        };
        assert_eq!(allowed_models(&scope), None);

        std::fs::write(
            root.join(".github/allowed_models.txt"),
            "# what this repo allows\nclaude-sonnet-*\ngpt-5.4\n\nfallback: gpt-5.4\n",
        )
        .unwrap();
        let patterns = allowed_models(&scope).unwrap();
        assert_eq!(patterns, ["claude-sonnet-*", "gpt-5.4"]);
        assert!(model_allowed(&patterns, "claude-sonnet-4.6"));
        assert!(model_allowed(&patterns, "gpt-5.4"));
        assert!(!model_allowed(&patterns, "gpt-5.3-codex"));
        assert!(!model_allowed(&patterns, "claude-haiku-4.5"));
    }

    #[test]
    fn a_glob_matches_at_both_ends_and_in_the_middle() {
        assert!(glob_matches("*", "anything"));
        assert!(glob_matches("gpt-*-codex", "gpt-5.3-codex"));
        assert!(!glob_matches("gpt-*-codex", "gpt-5.3-codex-preview"));
        assert!(glob_matches("*-preview", "gemini-3-pro-preview"));
        assert!(!glob_matches("claude-*", "gpt-5.4"));
    }
}
