use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, ProjectPath, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

pub struct Pi;

/// The module files Pi loads loose under a root's `extensions/`: the
/// TypeScript and JavaScript spellings, ESM and CommonJS variants included.
/// The one list for the scan surface and the second-copy check
/// (`crate::pi_ext::shadows`).
pub const EXTENSION_EXTS: &[&str] = &["ts", "js", "mts", "mjs", "cts", "cjs"];

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

/// The first pi-hooks release that hands each hook its registration's scope
/// and root, as the overlap refusal names it.
const CARRIER_FLOOR: &str = "pi-hooks>=0.19.3";

/// Give one rendered Pi hook script the registration it was rendered for.
///
/// From pi-hooks 0.19.3 the carrier hands every hook the scope its registry
/// was read from in `KENDEX_HOOK_SCOPE` and that scope's root in
/// `KENDEX_HOOK_ROOT`. pi-hooks 0.19.2 and earlier set neither, and a hook
/// that takes its install from them would then lose its install: a
/// project-only refresh under an older global carrier would leave its
/// configured checks unread. Its path alone cannot say which install it is,
/// since a global root moved into a checkout has a project install's shape.
/// The render can: kendex writes this file for one scope, so the scope is
/// written into it, and the root is what that scope's registry anchored the
/// spawned path under. A carrier that sets either variable is left to say
/// both.
///
/// One file can be both scopes' install, when the project's hook directory
/// and the global one are one directory. Both registries then start the
/// same path with the same input, so no stamp can be right for both, and
/// the file says neither: a carrier that names no registration is refused.
/// Both scopes judge that from the same pair of directories and render the
/// same bytes, so neither plan rewrites the other's file, wherever the
/// global plan can find the project: see [`shares_hook_dir`].
///
/// Remove this when the oldest carrier kendex supports is [`CARRIER_FLOOR`].
pub(crate) fn stamp_hook(env: &Env, scope: &Scope, name: &str, script: &mut String) {
    let stamp = match (scope, shares_hook_dir(env, scope)) {
        (_, true) => overlap_stamp(name),
        (Scope::Project { .. }, false) => {
            registration_stamp("project", &format!("/.pi/{}", hook_rel(name)))
        }
        (Scope::Global, false) => registration_stamp("global", &format!("/{}", hook_rel(name))),
    };
    let mut at = stamp_offset(script);
    if at > 0 && !script[..at].ends_with('\n') {
        script.insert(at, '\n');
        at += 1;
    }
    script.insert_str(at, &stamp);
}

/// Where the stamp goes: after the shebang and the header block directly
/// below it, so the header still opens the file and the stamp runs before
/// the script's first statement. A script with no header there takes it
/// directly after the shebang, and one with no shebang at its top.
fn stamp_offset(script: &str) -> usize {
    let mut at = match script.strip_prefix("#!") {
        Some(_) => script
            .find('\n')
            .map_or(script.len(), |newline| newline + 1),
        None => return 0,
    };
    let after_shebang = at;
    let mut opened = false;
    for line in script[after_shebang..].split_inclusive('\n') {
        let trimmed = line.trim();
        if !trimmed.starts_with('#') {
            return after_shebang;
        }
        at += line.len();
        if trimmed == "# ---" {
            if opened {
                return at;
            }
            opened = true;
        } else if !opened {
            return after_shebang;
        }
    }
    after_shebang
}

/// Whether the project's hook directory and the global one are one
/// directory on disk. A project scope compares its own `.pi` with the global
/// root. The global scope compares with the project its root sits in, found
/// by the walk the carrier makes (`discover.rs`): the layout where a carrier
/// that names no registration starts one path from both registries. A global
/// plan cannot find a project whose `.pi` links into a global root outside
/// it, so in that layout the two plans stamp the file differently.
fn shares_hook_dir(env: &Env, scope: &Scope) -> bool {
    let global = Pi.default_global_root(env);
    let project = match scope {
        Scope::Project { root } => root.clone(),
        Scope::Global => match crate::discover::project_root_from(&global, env.real_home()) {
            Some(project) => project,
            None => return false,
        },
    };
    one_hook_dir(&project.join(".pi"), &global)
}

/// Whether two scope roots hold one hook directory. The same spelling is one
/// directory before anything exists. Otherwise the deepest level of the hook
/// directory's path that resolves under both roots decides, by canonical
/// path: a level that resolves under one root alone shows two directories.
fn one_hook_dir(a: &Path, b: &Path) -> bool {
    if hook_dir(a) == hook_dir(b) {
        return true;
    }
    for level in [hook_rel_dir(), HOOK_HOME.to_owned(), String::new()] {
        let below = |root: &Path| crate::paths::canonical(&root.join(&level)).ok();
        match (below(a), below(b)) {
            (Some(a), Some(b)) => return a == b,
            (None, None) => {}
            (Some(_), None) | (None, Some(_)) => return false,
        }
    }
    false
}

/// The stamp for a file that is one scope's install alone. The carrier
/// spawns `<root><tail>`, the tail spelled with `/` here and with the
/// platform's separator by a Windows carrier, so the root is the spawned
/// path less the tail, in the carrier's own spelling. A path that does not
/// end in the tail, or leaves no absolute root, was not started by a
/// registry, and the stamp says nothing.
fn registration_stamp(scope: &str, tail: &str) -> String {
    format!(
        r#"# kendex: rendered as the {scope} Pi install of this hook. A pi-hooks
# carrier before 0.19.3 names no registration, so the render names it.
if [ -z "${{KENDEX_HOOK_SCOPE+set}}${{KENDEX_HOOK_ROOT+set}}" ]; then
  kendex_hook_at=${{BASH_SOURCE[0]-}}
  kendex_hook_tail={tail}
  case ${{kendex_hook_at//\\//}} in
    *"$kendex_hook_tail")
      kendex_hook_root=${{kendex_hook_at:0:${{#kendex_hook_at}}-${{#kendex_hook_tail}}}}
      case ${{kendex_hook_root//\\//}} in
        '') kendex_hook_root=${{kendex_hook_at:0:1}} ;;
        [A-Za-z]:) kendex_hook_root+=${{kendex_hook_at:2:1}} ;;
      esac
      case ${{kendex_hook_root//\\//}} in
        /* | [A-Za-z]:/*) export KENDEX_HOOK_SCOPE={scope} KENDEX_HOOK_ROOT="$kendex_hook_root" ;;
      esac
      ;;
  esac
  unset kendex_hook_at kendex_hook_tail kendex_hook_root
fi
"#,
        tail = crate::names::quoted(tail),
    )
}

/// The stamp for a file that is both scopes' install: a carrier that names
/// no registration gets a refusal, the guard having no install to judge from.
fn overlap_stamp(name: &str) -> String {
    format!(
        r#"# kendex: this file is both the project and the global Pi install of this
# hook. A pi-hooks carrier before 0.19.3 starts it the same way from either
# registry, so only a carrier that names the registration may run it.
if [ -z "${{KENDEX_HOOK_SCOPE+set}}${{KENDEX_HOOK_ROOT+set}}" ]; then
  printf '%s\n' {key} "${{BASH_SOURCE[0]-this hook}} is both the project and the global Pi install of this hook, and this pi-hooks carrier does not say which registration started it, so the hook cannot tell which install's skills and settings to use. Update pi-hooks to 0.19.3 or later, which passes the registration scope, or install the hook at one scope." >&2
  exit 2
fi
"#,
        key = crate::names::quoted(&format!(
            "kendex-hook-scope-overlap: hook={} carrier={CARRIER_FLOOR}",
            crate::names::shown(name)
        )),
    )
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

    fn project_reads(&self) -> &'static [ProjectPath] {
        &[]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, env: &Env) -> Vec<Surface> {
        match kind {
            ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
            ItemKind::OutputStyle => vec![Surface::Structured {
                path: root.join("APPEND_SYSTEM.md"),
                reader: Reader::OutputStyleBlocks,
            }],
            // Pi loads `~/.agents/skills` as well as its own global tree, so
            // the shared one leads here as it does in a project.
            ItemKind::Skill => {
                super::shared_first(Some(&env.global_skills_dir()), root.join("skills"))
            }
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
            ItemKind::OutputStyle => vec![Surface::Structured {
                path: dot.join("APPEND_SYSTEM.md"),
                reader: Reader::OutputStyleBlocks,
            }],
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

    /// What `stamp_hook` adds to a script with no body, for one scope.
    fn stamped(env: &Env, scope: &Scope) -> String {
        let mut script = "#!/bin/bash\n".to_owned();
        stamp_hook(env, scope, "g", &mut script);
        script
    }

    #[cfg(unix)]
    #[test]
    fn both_scopes_stamp_one_shared_hook_directory_alike() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let project = home.join("app");
        std::fs::create_dir_all(project.join(".pi/kendex/hooks")).unwrap();
        let in_project = Scope::Project {
            root: project.clone(),
        };
        let env = Env::fake(&home, FakeOs::Linux);
        let overlap = format!("#!/bin/bash\n{}", overlap_stamp("g"));

        // Apart, each scope names itself.
        let (own, global) = (stamped(&env, &in_project), stamped(&env, &Scope::Global));
        assert!(own != overlap && global != overlap && own != global);

        // The global root is the project's `.pi`: one registry, one file.
        let env = env.with_var(
            "PI_CODING_AGENT_DIR",
            &project.join(".pi").to_string_lossy(),
        );
        assert_eq!(stamped(&env, &in_project), overlap);
        assert_eq!(stamped(&env, &Scope::Global), overlap);

        // The project's hook directory links into the global one.
        let agent = home.join(".pi/agent/kendex/hooks");
        std::fs::create_dir_all(&agent).unwrap();
        std::fs::remove_dir(project.join(".pi/kendex/hooks")).unwrap();
        std::os::unix::fs::symlink(&agent, project.join(".pi/kendex/hooks")).unwrap();
        let env = Env::fake(&home, FakeOs::Linux);
        assert_eq!(stamped(&env, &in_project), overlap);
    }

    #[test]
    fn the_stamp_follows_the_header_so_the_header_still_reads() {
        let env = Env::fake("/h", FakeOs::Linux);
        let header = "#!/usr/bin/env bash\n# ---\n# name: g\n# event: PreToolUse\n# ---\n";
        let body = "\nset -eu\nexit 0\n";
        let mut script = format!("{header}{body}");
        stamp_hook(&env, &Scope::Global, "g", &mut script);
        let stamp = &script[header.len()..script.len() - body.len()];
        assert_eq!(stamp, registration_stamp("global", "/kendex/hooks/g.sh"));
        let hook = crate::hook::parse_hook(&script).unwrap();
        assert_eq!(
            (hook.name.as_str(), hook.event.as_str()),
            ("g", "PreToolUse")
        );
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
                    // Spelled out rather than read from `EXTENSION_EXTS`, so a
                    // spelling dropped from the surface reddens here.
                    Surface::FileDir {
                        dir: PathBuf::from("/p/.pi/extensions"),
                        exts: &["ts", "js", "mts", "mjs", "cts", "cjs"],
                        prefixes: &[],
                    },
                ]
            );
        }
    }
}
