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

/// What a hook does with the registration that started it, read from the
/// two declarations `hooks/AGENTS.md` names, so the class cannot drift from
/// the hook.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum InstallUse {
    /// Declares no `reads-registration`, so it finds its install from its
    /// own path, and both registrations of one file give it one answer.
    None,
    /// Declares `reads-registration` and an advisory reader, a `safety`
    /// line opening `Advisory reader.`. What it cannot read it reports at
    /// exit 0.
    Advisory,
    /// Declares `reads-registration` and no advisory reader, so it refuses
    /// what it cannot judge.
    Gate,
}

/// The declaration that makes a hook an advisory reader.
const ADVISORY_READER: &str = "Advisory reader.";

fn install_use(hook: &crate::hook::HookSource) -> InstallUse {
    match (
        hook.reads_registration,
        hook.safety
            .as_deref()
            .is_some_and(|safety| safety.starts_with(ADVISORY_READER)),
    ) {
        (false, _) => InstallUse::None,
        (true, true) => InstallUse::Advisory,
        (true, false) => InstallUse::Gate,
    }
}

/// Give one rendered Pi hook script the registration a carrier that names
/// none started it under.
///
/// From pi-hooks 0.19.3 the carrier hands every hook the scope its registry
/// was read from in `KENDEX_HOOK_SCOPE` and that scope's root in
/// `KENDEX_HOOK_ROOT`. pi-hooks 0.19.2 and earlier set neither, and spawn
/// `<root>/kendex/hooks/<name>.sh` under the root whose registry named the
/// hook. Which root that was is decided when the hook runs, not when kendex
/// renders it: one file can be both scopes' install, and Pi can be pointed
/// at a checkout after its files were written. So the stamp is the same for
/// both scopes, and neither plan rewrites the other's file.
///
/// The spawned path ends in `/.pi/kendex/hooks/<name>.sh` from the project
/// registry and `/kendex/hooks/<name>.sh` from the global one. A project
/// spelling is the global registry's spawn too only where the global root
/// the carrier resolved is that `.pi`, spelled the same. Even then the
/// project registry is this file only where the carrier's project is the
/// directory above that `.pi`. The stamp finds that project as the
/// carrier does, from the working directory the carrier spawns the hook
/// in: it follows `pi-extensions/pi-hooks/extensions/config.ts::walkProjectRoot`,
/// unchanged from pi-hooks 0.19.2. Any other project, or none, leaves the
/// global registration. Where it is that project, the hook cannot tell the
/// registrations apart, and what it does follows [`InstallUse`]: a hook that
/// reads no registration runs, an advisory one reports the overlap at exit
/// 0 and lets the call through, and a gate refuses with exit 2. A carrier
/// that sets either variable is left to say both.
///
/// The global root is resolved as the carrier resolves it
/// (`pi-extensions/pi-hooks/extensions/package-config.ts::userDir`, which
/// [`pi_global_root`] restates for the renderer): a trimmed
/// `PI_CODING_AGENT_DIR` with a leading `~` expanded, used only where it is
/// root-anchored. Any other value is the default `~/.pi/agent`, which no
/// project spelling ends in.
///
/// Remove this when the oldest carrier kendex supports is [`CARRIER_FLOOR`].
pub(crate) fn stamp_hook(name: &str, script: &mut String) {
    // A script body is the catalog file the hook was parsed from, so this
    // parses. Were it ever not to, the hook is judged a gate, which refuses.
    let stamp = match crate::hook::parse_hook(script) {
        Ok(hook) => registration_stamp(name, &hook.event, install_use(&hook)),
        Err(_) => registration_stamp(name, "", InstallUse::Gate),
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

/// The stamp [`stamp_hook`] inserts. The tail is spelled with `/` here and
/// with the platform's separator by a Windows carrier, so every comparison
/// reads the path with `\` as `/`, and the root keeps the carrier's own
/// spelling.
fn registration_stamp(name: &str, event: &str, install: InstallUse) -> String {
    let key = crate::names::quoted(&format!(
        "kendex-hook-scope-overlap: hook={} carrier={CARRIER_FLOOR}",
        crate::names::shown(name)
    ));
    let cause = "PI_CODING_AGENT_DIR names this project's .pi, so one Pi registry file is both the project's and the global one, and this pi-hooks carrier does not say which registration started the hook.";
    let remedy = "Update pi-hooks to 0.19.3 or later, which names the registration, or point PI_CODING_AGENT_DIR at a directory outside the project.";
    let overlap = match install {
        InstallUse::None => String::new(),
        InstallUse::Advisory => format!(
            r#"  if [ "$kendex_hook_scope" = both ]; then
    printf '%s\n' {key} {text}
    exit 0
  fi
"#,
            text = crate::names::quoted(&format!(
                "The hook did not run, and the call goes ahead: {cause} {remedy}"
            )),
        ),
        InstallUse::Gate => format!(
            r#"  if [ "$kendex_hook_scope" = both ]; then
    printf '%s\n' {key} {text} >&2
    exit 2
  fi
"#,
            text = crate::names::quoted(&format!(
                "{outcome} {cause} The hook cannot tell which install's skills and settings to use. {remedy}",
                // Pi refuses only a tool call on exit 2 (`caps.rs::pi_listener`).
                outcome = if event == "PreToolUse" {
                    "This call is refused:"
                } else {
                    "The hook did not run:"
                }
            )),
        ),
    };
    let markers = crate::discover::MARKER_DIRS.join(" ");
    format!(
        r#"# kendex: a pi-hooks carrier before 0.19.3 names no registration, so this
# render reads it from the path the registry spawned (docs/adapters/pi.md).
if [ -z "${{KENDEX_HOOK_SCOPE+set}}${{KENDEX_HOOK_ROOT+set}}" ]; then
  kendex_hook_at=${{BASH_SOURCE[0]-}}
  kendex_hook_tail={tail}
  kendex_hook_scope=''
  case ${{kendex_hook_at//\\//}} in
    */.pi"$kendex_hook_tail") kendex_hook_scope=project ;;
    *"$kendex_hook_tail") kendex_hook_scope=global ;;
  esac
  if [ "$kendex_hook_scope" = project ]; then
    kendex_hook_win=''
    case ${{OSTYPE-}} in msys* | cygwin* | win32*) kendex_hook_win=1 ;; esac
    kendex_hook_home=${{HOME-}}
    [ -z "$kendex_hook_win" ] || kendex_hook_home=${{USERPROFILE-}}
    kendex_hook_rest=${{PI_CODING_AGENT_DIR-}}
    kendex_hook_rest=${{kendex_hook_rest#"${{kendex_hook_rest%%[![:space:]]*}}"}}
    kendex_hook_rest=${{kendex_hook_rest%"${{kendex_hook_rest##*[![:space:]]}}"}}
    case $kendex_hook_rest in
      '~') kendex_hook_rest=$kendex_hook_home ;;
      '~/'*) kendex_hook_rest=$kendex_hook_home/${{kendex_hook_rest:2}} ;;
    esac
    kendex_hook_rest=${{kendex_hook_rest//\\//}}
    kendex_hook_lead=''
    if [ -z "$kendex_hook_win" ]; then
      case $kendex_hook_rest in /*) ;; *) kendex_hook_rest='' ;; esac
    else
      case $kendex_hook_rest in
        [A-Za-z]:/*) kendex_hook_lead=${{kendex_hook_rest:0:2}} kendex_hook_rest=${{kendex_hook_rest:2}} ;;
        //[!/]*/[!/]*) kendex_hook_lead=/ ;;
        *) kendex_hook_rest='' ;;
      esac
    fi
    kendex_hook_global=''
    if [ -n "$kendex_hook_rest" ]; then
      while [ -n "$kendex_hook_rest" ]; do
        kendex_hook_part=${{kendex_hook_rest%%/*}}
        case $kendex_hook_rest in */*) kendex_hook_rest=${{kendex_hook_rest#*/}} ;; *) kendex_hook_rest='' ;; esac
        case $kendex_hook_part in
          '' | .) ;;
          ..) kendex_hook_global=${{kendex_hook_global%/*}} ;;
          *) kendex_hook_global=$kendex_hook_global/$kendex_hook_part ;;
        esac
      done
      kendex_hook_global=$kendex_hook_lead${{kendex_hook_global:-/}}
    fi
    kendex_hook_pi=${{kendex_hook_at//\\//}}
    kendex_hook_pi=${{kendex_hook_pi%"$kendex_hook_tail"}}
    if [ -n "$kendex_hook_global" ] && [ "$kendex_hook_global" = "$kendex_hook_pi" ]; then
      kendex_hook_scope=global
      kendex_hook_project=${{kendex_hook_pi%/.pi}}
      case $kendex_hook_project in '' | [A-Za-z]:) kendex_hook_project=$kendex_hook_project/ ;; esac
      # The carrier's project: config.ts::walkProjectRoot from its cwd.
      kendex_hook_here=$(pwd -P 2>/dev/null) || kendex_hook_here=''
      while [ -n "$kendex_hook_here" ]; do
        [ ! -f "$kendex_hook_here/{lock}" ] || break
        if [ "$kendex_hook_here" -ef "$kendex_hook_home" ]; then
          kendex_hook_here=''
          break
        fi
        for kendex_hook_marker in {markers}; do
          [ ! -d "$kendex_hook_here/$kendex_hook_marker" ] || break 2
        done
        case $kendex_hook_here in
          */?*)
            kendex_hook_here=${{kendex_hook_here%/*}}
            kendex_hook_here=${{kendex_hook_here:-/}}
            ;;
          *) kendex_hook_here='' ;;
        esac
      done
      if [ -n "$kendex_hook_here" ] && [ "$kendex_hook_here" -ef "$kendex_hook_project" ]; then
        kendex_hook_scope=both
      fi
    else
      kendex_hook_tail=/.pi$kendex_hook_tail
    fi
  fi
{overlap}  case $kendex_hook_scope in
    project | global)
      kendex_hook_root=${{kendex_hook_at:0:${{#kendex_hook_at}}-${{#kendex_hook_tail}}}}
      case ${{kendex_hook_root//\\//}} in
        '') kendex_hook_root=${{kendex_hook_at:0:1}} ;;
        [A-Za-z]:) kendex_hook_root+=${{kendex_hook_at:2:1}} ;;
      esac
      case ${{kendex_hook_root//\\//}} in
        /* | [A-Za-z]:/*) export KENDEX_HOOK_SCOPE=$kendex_hook_scope KENDEX_HOOK_ROOT="$kendex_hook_root" ;;
      esac
      ;;
  esac
  unset kendex_hook_at kendex_hook_tail kendex_hook_scope kendex_hook_win kendex_hook_home \
    kendex_hook_rest kendex_hook_lead kendex_hook_global kendex_hook_part kendex_hook_pi \
    kendex_hook_project kendex_hook_here kendex_hook_marker kendex_hook_root
fi
"#,
        tail = crate::names::quoted(&format!("/{}", hook_rel(name))),
        lock = crate::lock::LOCK_FILE,
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

    #[test]
    fn the_stamp_follows_the_header_so_the_header_still_reads() {
        let header = "#!/usr/bin/env bash\n# ---\n# name: g\n# event: PreToolUse\n# ---\n";
        let body = "\nset -eu\nexit 0\n";
        let mut script = format!("{header}{body}");
        stamp_hook("g", &mut script);
        let stamp = &script[header.len()..script.len() - body.len()];
        assert_eq!(
            stamp,
            registration_stamp("g", "PreToolUse", InstallUse::None)
        );
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
