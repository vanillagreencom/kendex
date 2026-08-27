use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface, shared_first};
use crate::env::Env;
use crate::model::{DetectedHarness, HarnessId, ItemKind, Scope};

pub struct Opencode;

const PLUGIN_EXTS: &[&str] = &["js", "ts", "mjs", "cjs"];

/// The filename marker every instruction file kendex renders carries. The
/// render (`hook_target`), the scan surface below, and the stale-row sweep
/// all read this one spelling, so what is written, observed, and claimed
/// as kendex's can never diverge.
pub(crate) const HOOK_INSTRUCTION_MARKER: &str = "kendex-hook-";

fn global_config_file(root: &Path, env: &Env) -> PathBuf {
    if let Some(explicit) = env.var("OPENCODE_CONFIG") {
        return PathBuf::from(explicit);
    }
    let jsonc = root.join("opencode.jsonc");
    if jsonc.is_file() {
        jsonc
    } else {
        root.join("opencode.json")
    }
}

fn project_config_file(project: &Path) -> PathBuf {
    let json = project.join("opencode.json");
    let jsonc = project.join("opencode.jsonc");
    if !json.is_file() && jsonc.is_file() {
        jsonc
    } else {
        json
    }
}

/// The one config file for a scope — the file the scanner reads MCP servers
/// and plugin refs from, and the file hook instruction refs are written to.
pub fn config_file(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => global_config_file(&Opencode.default_global_root(env), env),
        Scope::Project { root } => project_config_file(root),
    }
}

impl HarnessAdapter for Opencode {
    fn id(&self) -> HarnessId {
        HarnessId::Opencode
    }

    fn default_global_root(&self, env: &Env) -> PathBuf {
        if let Some(config) = env.var("OPENCODE_CONFIG")
            && let Some(parent) = Path::new(config).parent()
        {
            return parent.to_path_buf();
        }
        if let Some(dir) = env.var("OPENCODE_CONFIG_DIR") {
            return PathBuf::from(dir);
        }
        env.home.join(".config/opencode")
    }

    fn detect(&self, env: &Env, global_root: &Path) -> Option<DetectedHarness> {
        (global_root.is_dir() || global_config_file(global_root, env).is_file()).then(|| {
            DetectedHarness {
                harness: HarnessId::Opencode,
                root: global_root.to_path_buf(),
                version: None,
            }
        })
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[
            ProjectMarker::Dir(".opencode"),
            ProjectMarker::File("opencode.json"),
            ProjectMarker::File("opencode.jsonc"),
        ]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, env: &Env) -> Vec<Surface> {
        let config = global_config_file(root, env);
        surfaces(kind, root, config, None)
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let config = project_config_file(project);
        let shared = project.join(".agents/skills");
        surfaces(kind, &project.join(".opencode"), config, Some(&shared))
    }
}

fn surfaces(kind: ItemKind, base: &Path, config: PathBuf, shared: Option<&Path>) -> Vec<Surface> {
    match kind {
        ItemKind::Agent => vec![Surface::files(base.join("agents"), &["md"])],
        // opencode's skill search covers `.agents/skills` as well as its own
        // directory, so in a project the shared tree is where a skill goes
        // by default and its own directory is what a per-tool copy writes
        // (matrix §2). Both are read either way.
        ItemKind::Skill => shared_first(shared, base.join("skills")),
        // opencode has no native hook surface; only the instruction files the
        // engine itself renders are observable.
        ItemKind::Hook => vec![Surface::FileDir {
            dir: base.join("instructions"),
            exts: &["md"],
            prefixes: &[HOOK_INSTRUCTION_MARKER],
        }],
        ItemKind::Command => vec![
            Surface::files(base.join("commands"), &["md"]),
            Surface::files(base.join("command"), &["md"]),
        ],
        ItemKind::McpServer => vec![Surface::Structured {
            path: config,
            reader: Reader::OpencodeMcp,
        }],
        ItemKind::Plugin => vec![
            Surface::FileDir {
                dir: base.join("plugins"),
                exts: PLUGIN_EXTS,
                prefixes: &[],
            },
            Surface::Structured {
                path: config,
                reader: Reader::OpencodePluginRefs,
            },
        ],
        ItemKind::PiExtension => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn root_resolution_honors_env_overrides_in_order() {
        let env = Env::fake("/h", FakeOs::Linux);
        assert_eq!(
            Opencode.default_global_root(&env),
            PathBuf::from("/h/.config/opencode")
        );

        let with_dir = env.clone().with_var("OPENCODE_CONFIG_DIR", "/oc");
        assert_eq!(
            Opencode.default_global_root(&with_dir),
            PathBuf::from("/oc")
        );

        let with_config = with_dir.with_var("OPENCODE_CONFIG", "/explicit/opencode.json");
        assert_eq!(
            Opencode.default_global_root(&with_config),
            PathBuf::from("/explicit")
        );
    }

    #[test]
    fn commands_scan_both_plural_and_legacy_singular_dirs() {
        let env = Env::fake("/h", FakeOs::Linux);
        let found = Opencode.project_surfaces(ItemKind::Command, Path::new("/p"), &env);
        assert_eq!(
            found,
            [
                Surface::files(PathBuf::from("/p/.opencode/commands"), &["md"]),
                Surface::files(PathBuf::from("/p/.opencode/command"), &["md"]),
            ]
        );
    }

    #[test]
    fn config_file_follows_the_scope_and_the_jsonc_variant() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        std::fs::create_dir_all(&project).unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };
        assert_eq!(config_file(&env, &scope), project.join("opencode.json"));

        std::fs::write(project.join("opencode.jsonc"), "{}").unwrap();
        assert_eq!(config_file(&env, &scope), project.join("opencode.jsonc"));
        assert_eq!(
            config_file(&env, &Scope::Global),
            tmp.path().join(".config/opencode/opencode.json")
        );
    }

    #[test]
    fn missing_config_defaults_to_json_variant() {
        let env = Env::fake("/h", FakeOs::Linux);
        let mcp = Opencode.project_surfaces(ItemKind::McpServer, Path::new("/p"), &env);
        assert_eq!(
            mcp,
            [Surface::Structured {
                path: PathBuf::from("/p/opencode.json"),
                reader: Reader::OpencodeMcp,
            }]
        );
    }
}
