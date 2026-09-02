use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

pub struct Pi;

const EXTENSION_EXTS: &[&str] = &["ts", "js"];

fn pi_root_is_absolute_for(value: &str, windows: bool) -> bool {
    if !windows {
        return value.starts_with('/');
    }
    let bytes = value.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
    {
        return true;
    }
    let Some(rest) = value
        .strip_prefix(r"\\")
        .or_else(|| value.strip_prefix("//"))
    else {
        return false;
    };
    let mut parts = rest.split(['\\', '/']);
    matches!((parts.next(), parts.next()), (Some(server), Some(share)) if !server.is_empty() && !share.is_empty())
}

fn pi_global_root(env: &Env) -> PathBuf {
    let default = || env.home.join(".pi/agent");
    let Some(dir) = env
        .var("PI_CODING_AGENT_DIR")
        .map(str::trim)
        .filter(|dir| !dir.is_empty())
    else {
        return default();
    };
    let root = crate::paths::expand_tilde(&env.home, dir);
    if pi_root_is_absolute_for(&root.to_string_lossy(), env.is_windows()) {
        root
    } else {
        default()
    }
}

#[cfg(test)]
const PI_ROOT_ABSOLUTE_CASES: &[(&str, bool, bool)] = &[
    ("/root", true, false),
    ("C:/root", false, true),
    ("C:\\root", false, true),
    ("//server/share", true, true),
    ("\\\\server\\share", false, true),
    ("\\root", false, false),
    ("relative/root", false, false),
];

/// The segment kendex parks its Pi hook storage under, at both scopes.
/// Pi warns about a `hooks/` directory sitting directly beside a root it
/// loads on the name alone, whatever it holds, and the migration it names
/// — into `extensions/` — is not one these files can take: they are shell
/// scripts the `pi-hooks` carrier runs, not Pi extensions. Under a segment
/// of kendex's own, Pi never looks — the same segment its Pi extensions
/// already keep per-session state in.
pub const HOOK_HOME: &str = "kendex";

/// The scope's root — the directory Pi loads its settings, agents and
/// prompts from, and the one kendex hangs `HOOK_HOME` off.
pub fn scope_root(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => Pi.default_global_root(env),
        Scope::Project { root } => root.join(".pi"),
    }
}

/// The registry the carrier reads, for one scope root.
pub fn hook_registry(root: &Path) -> PathBuf {
    root.join(HOOK_HOME).join("hooks.json")
}

/// Where this scope's hooks are observed: the registry the carrier reads.
fn hook_surfaces(root: &Path) -> Vec<Surface> {
    vec![Surface::Structured {
        path: hook_registry(root),
        reader: Reader::HooksObject,
    }]
}

/// Where hook scripts live inside a scope root, slash-separated: the one
/// spelling both a `Path` and a POSIX command line are built from.
fn hook_rel_dir() -> String {
    format!("{HOOK_HOME}/hooks")
}

/// One hook's file name.
pub fn hook_file(name: &str) -> String {
    format!("{name}.sh")
}

/// One hook script's place inside a scope root, as the text a registered
/// command spells.
pub fn hook_rel(name: &str) -> String {
    format!("{}/{}", hook_rel_dir(), hook_file(name))
}

/// The directory the hook scripts live in, for one scope root.
pub fn hook_dir(root: &Path) -> PathBuf {
    root.join(hook_rel_dir())
}

/// One hook script's path, for one scope root.
pub fn hook_path(root: &Path, name: &str) -> PathBuf {
    root.join(hook_rel(name))
}

impl HarnessAdapter for Pi {
    fn id(&self) -> HarnessId {
        HarnessId::Pi
    }

    fn default_global_root(&self, env: &Env) -> PathBuf {
        pi_global_root(env)
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[ProjectMarker::Dir(".pi"), ProjectMarker::Dir(".agents")]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        match kind {
            ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: root.join("skills"),
                marker: "SKILL.md",
            }],
            // Hooks ride the pi-hooks carrier: the registry kendex renders
            // is what the carrier's listeners execute. pi has no MCP.
            ItemKind::Hook => hook_surfaces(root),
            ItemKind::McpServer | ItemKind::Plugin => vec![],
            ItemKind::Command => vec![Surface::files(root.join("prompts"), &["md"])],
            ItemKind::PiExtension => vec![
                Surface::Structured {
                    path: root.join("settings.json"),
                    reader: Reader::PiPackages,
                },
                Surface::FileDir {
                    dir: root.join("extensions"),
                    exts: EXTENSION_EXTS,
                    prefixes: &[],
                },
            ],
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let dot = project.join(".pi");
        match kind {
            ItemKind::Agent => vec![Surface::files(dot.join("agents"), &["md"])],
            // Shared physical target with codex — scan dedupe couples them.
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: project.join(".agents/skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Hook => hook_surfaces(&dot),
            ItemKind::McpServer | ItemKind::Plugin => vec![],
            ItemKind::Command => vec![Surface::files(dot.join("prompts"), &["md"])],
            ItemKind::PiExtension => vec![
                Surface::Structured {
                    path: dot.join("settings.json"),
                    reader: Reader::PiPackages,
                },
                Surface::FileDir {
                    dir: dot.join("extensions"),
                    exts: EXTENSION_EXTS,
                    prefixes: &[],
                },
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn agent_dir_var_relocates_the_root() {
        let base = Env::fake("/h", FakeOs::Linux);
        for (value, root) in [
            (None, "/h/.pi/agent"),
            (Some("/pi-root"), "/pi-root"),
            (Some(""), "/h/.pi/agent"),
            (Some("   "), "/h/.pi/agent"),
            (Some("~"), "/h"),
            (Some("~/elsewhere"), "/h/elsewhere"),
            (Some("relative/root"), "/h/.pi/agent"),
        ] {
            let env = match value {
                Some(value) => base.clone().with_var("PI_CODING_AGENT_DIR", value),
                None => base.clone(),
            };
            assert_eq!(
                Pi.default_global_root(&env),
                PathBuf::from(root),
                "{value:?}"
            );
        }
    }

    #[test]
    fn global_root_uses_the_environment_platform_rule() {
        let posix_env = Env::fake("/home/pat", FakeOs::Linux);
        let windows_env = Env::fake(r"C:\Users\pat", FakeOs::Windows);
        for (value, posix_absolute, windows_absolute) in PI_ROOT_ABSOLUTE_CASES {
            assert_eq!(
                Pi.default_global_root(&posix_env.clone().with_var("PI_CODING_AGENT_DIR", value)),
                if *posix_absolute {
                    PathBuf::from(value)
                } else {
                    posix_env.home.join(".pi/agent")
                },
                "POSIX {value}"
            );
            assert_eq!(
                Pi.default_global_root(&windows_env.clone().with_var("PI_CODING_AGENT_DIR", value)),
                if *windows_absolute {
                    PathBuf::from(value)
                } else {
                    windows_env.home.join(".pi/agent")
                },
                "Windows {value}"
            );
        }
    }

    #[test]
    fn skills_share_the_codex_tree_and_packages_live_in_settings() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            assert_eq!(
                Pi.project_surfaces(ItemKind::Skill, Path::new("/p"), &env),
                [Surface::SubdirPerItem {
                    dir: PathBuf::from("/p/.agents/skills"),
                    marker: "SKILL.md",
                }]
            );
            assert_eq!(
                Pi.project_surfaces(ItemKind::PiExtension, Path::new("/p"), &env),
                [
                    Surface::Structured {
                        path: PathBuf::from("/p/.pi/settings.json"),
                        reader: Reader::PiPackages,
                    },
                    Surface::FileDir {
                        dir: PathBuf::from("/p/.pi/extensions"),
                        exts: EXTENSION_EXTS,
                        prefixes: &[],
                    },
                ]
            );
        }
    }
}
