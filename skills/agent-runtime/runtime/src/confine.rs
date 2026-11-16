//! The confinement a worker's harness runs under: the paths its launch
//! grants, the per-harness answer whether it can run confined at all, the
//! wrapper's words that hold the harness and everything it starts, and the
//! probe that tells a host without the mechanism.
//!
//! The kernel holds the boundary, not the harness: on Linux `bwrap` mounts
//! the whole tree read-only, a private `/tmp`, the user's runtime folder
//! hidden, and binds back only what the grants name, so every child the
//! harness starts is inside too. A refused write is the kernel's, and the
//! grants file says why.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::harness::Harness;

/// Set to `1` inside the wrapper, so a program the harness runs knows its
/// writes outside the grants are refused and takes no route that leaves
/// the tree.
pub const CONFINED_VAR: &str = "AGENT_RUNTIME_CONFINED";

/// Names the grants file inside the wrapper.
pub const GRANTS_VAR: &str = "AGENT_RUNTIME_GRANTS";

/// The Linux wrapper, found on the pane's `PATH`.
pub const WRAPPER: &str = "bwrap";

/// The words every wrapped run opens with: the whole tree read-only, fresh
/// `/dev` and `/proc`, a private `/tmp`; the wrapper's whole tree ends when
/// its parent does. No new session (the harness keeps its terminal, so the
/// observer finds it in the pane's foreground group) and no pid namespace
/// (the observer reads it below the pane's process); the network is shared.
const BASE: [&str; 10] = [
    "--die-with-parent",
    "--ro-bind",
    "/",
    "/",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    "--tmpfs",
    "/tmp",
];

/// The X server's socket folder, under the private `/tmp` and bound back
/// for a desktop grant.
const X11_SOCKETS: &str = "/tmp/.X11-unix";

/// The name a desktop bind falls back to where the window holds no
/// `WAYLAND_DISPLAY`: no such socket stands, so `--bind-try` skips it,
/// where an empty name would bind the whole runtime folder back.
const NO_DISPLAY: &str = ".agent-runtime-no-display";

/// How long the probe's trial run may take before it reads as refused.
const TRIAL: Duration = Duration::from_secs(30);

/// What a worker's launch may reach. Every path is absolute; the rest of
/// the tree stays readable and unwritable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Grants {
    /// Folders the lane writes: its worktree, its mailbox, its own state.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub writable: Vec<PathBuf>,
    /// Account seats bound writable: the lane's own and any its review
    /// may run on. Apart from `writable` so a launch record names them,
    /// since a confined lane still holds those accounts' credentials.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub seats: Vec<PathBuf>,
    /// Paths inside a writable grant kept read-only, such as a seat's
    /// settings, which run code in the operator's next session there.
    /// Each must stand: the wrapper refuses a missing one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_only: Vec<PathBuf>,
    /// The user's runtime folder, hidden whole: the tmux, session-bus,
    /// service-manager and display sockets in it are out of reach.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime_dir: Option<PathBuf>,
    /// Sockets bound back after the hiding; one that is gone is skipped.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sockets: Vec<PathBuf>,
    /// The overseer authorized the owner's live display: its sockets are
    /// bound back and the display names kept.
    #[serde(default)]
    pub desktop: bool,
    /// A file whose text the line hands the harness as `GH_TOKEN`: `gh`
    /// reads its login over the session bus, which the wrapper hides. The
    /// text is read as the line runs, so no record holds it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gh_token: Option<PathBuf>,
    /// Where the launch writes these grants for the lane to read.
    pub file: PathBuf,
}

/// The variable `gh` takes its token from before any stored login.
pub const GH_TOKEN_VAR: &str = "GH_TOKEN";

/// Why a harness runs unconfined.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Cause {
    /// Copilot CLI reads its token over the session bus the wrapper hides;
    /// its launcher shim also locks a file in the primary home and its
    /// settings sync renames the seat's settings file, both read-only
    /// under the wrapper, so a wrapped Copilot lane cannot start.
    TokenOnSessionBus,
    /// The host is not Linux: only bwrap's words are spelled, so a launch
    /// there runs as it did before any confinement.
    MacosProfileUnbuilt,
}

/// Whether a harness runs inside the wrapper.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "state")]
pub enum Answer {
    Confined,
    Unconfined { cause: Cause },
}

/// The host a launch runs on, as the confinement tells it apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Host {
    Linux,
    Other,
}

impl Host {
    pub fn this() -> Host {
        if cfg!(target_os = "linux") {
            Host::Linux
        } else {
            Host::Other
        }
    }
}

/// The one answer whether `harness` runs confined on `host`: no setting
/// changes it. The harness's own cause stands on any host.
pub fn answer(host: Host, harness: Harness) -> Answer {
    match (harness, host) {
        (Harness::Copilot, Host::Linux | Host::Other) => Answer::Unconfined {
            cause: Cause::TokenOnSessionBus,
        },
        (Harness::Claude | Harness::Codex | Harness::Pi, Host::Other) => Answer::Unconfined {
            cause: Cause::MacosProfileUnbuilt,
        },
        (Harness::Claude | Harness::Codex | Harness::Pi, Host::Linux) => Answer::Confined,
    }
}

/// One wrapper word as the pane's shell reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Word {
    Plain(String),
    /// The Wayland socket under this folder that the window's own
    /// `WAYLAND_DISPLAY` names, expanded by the pane's shell when the line
    /// runs: the display names a desktop grant keeps are the window's.
    Display(PathBuf),
    /// This file's text, read by the pane's shell when the line runs.
    Text(PathBuf),
}

impl Word {
    pub fn shell(&self) -> String {
        match self {
            Word::Plain(word) => crate::launch::shell_quote(word),
            Word::Display(dir) => format!(
                "{}/\"${{WAYLAND_DISPLAY:-{NO_DISPLAY}}}\"",
                crate::launch::shell_quote(&dir.display().to_string())
            ),
            Word::Text(file) => format!(
                "\"$(cat {})\"",
                crate::launch::shell_quote(&file.display().to_string())
            ),
        }
    }
}

/// The wrapper a confined launch runs its harness under, and the grants
/// file its line writes first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Wrapper {
    pub program: String,
    /// Ends with `--`; the harness's program and words follow.
    pub words: Vec<Word>,
    pub file: PathBuf,
    /// The grants as JSON, the file's one line.
    pub text: String,
}

/// What a launch that names grants runs under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "state")]
pub enum Confinement {
    Confined { wrapper: Wrapper },
    Unconfined { cause: Cause },
}

impl Confinement {
    pub fn answer(&self) -> Answer {
        match self {
            Confinement::Confined { .. } => Answer::Confined,
            Confinement::Unconfined { cause } => Answer::Unconfined { cause: *cause },
        }
    }
}

/// The confinement a launch of `harness` on `host` under `grants` runs
/// with: the answer, and for a confined one the wrapper. A relative path
/// is refused, since the pane's directory is not this process's.
pub fn confinement(host: Host, harness: Harness, grants: &Grants) -> Result<Confinement> {
    let paths = grants
        .writable
        .iter()
        .chain(&grants.seats)
        .chain(&grants.read_only)
        .chain(&grants.runtime_dir)
        .chain(&grants.sockets)
        .chain(&grants.gh_token)
        .chain([&grants.file]);
    for path in paths {
        if !path.is_absolute() {
            return Err(Error::refused(
                "grant-relative",
                &[
                    ("harness", harness.name()),
                    ("path", &path.display().to_string()),
                ],
            ));
        }
    }
    Ok(match answer(host, harness) {
        Answer::Unconfined { cause } => Confinement::Unconfined { cause },
        Answer::Confined => Confinement::Confined {
            wrapper: Wrapper {
                program: WRAPPER.to_owned(),
                words: linux_words(grants),
                file: grants.file.clone(),
                text: serde_json::to_string(grants).expect("grants serialize"),
            },
        },
    })
}

/// bwrap's words for `grants`. bwrap applies them in order, so the
/// runtime folder's tmpfs comes before the binds that reach into it, and
/// the read-only carve-outs after the writable binds they sit inside.
pub fn linux_words(grants: &Grants) -> Vec<Word> {
    let mut words: Vec<Word> = BASE.iter().map(|w| plain(w)).collect();
    if let Some(dir) = &grants.runtime_dir {
        words.push(plain("--tmpfs"));
        words.push(plain(&dir.display().to_string()));
    }
    for path in grants.writable.iter().chain(&grants.seats) {
        pair(&mut words, "--bind", path);
    }
    for path in &grants.read_only {
        pair(&mut words, "--ro-bind", path);
    }
    for path in &grants.sockets {
        pair(&mut words, "--bind-try", path);
    }
    if grants.desktop {
        if let Some(dir) = &grants.runtime_dir {
            words.push(plain("--bind-try"));
            words.push(Word::Display(dir.clone()));
            words.push(Word::Display(dir.clone()));
        }
        pair(&mut words, "--bind-try", Path::new(X11_SOCKETS));
    }
    for (name, value) in [
        (CONFINED_VAR, "1".to_owned()),
        (GRANTS_VAR, grants.file.display().to_string()),
        ("TMPDIR", "/tmp".to_owned()),
    ] {
        words.extend([plain("--setenv"), plain(name), Word::Plain(value)]);
    }
    if let Some(file) = &grants.gh_token {
        words.extend([
            plain("--setenv"),
            plain(GH_TOKEN_VAR),
            Word::Text(file.clone()),
        ]);
    }
    for name in ["TMUX", "TMUX_PANE"] {
        words.extend([plain("--unsetenv"), plain(name)]);
    }
    words.push(plain("--"));
    words
}

fn plain(word: &str) -> Word {
    Word::Plain(word.to_owned())
}

/// `verb path path`: bwrap's mounts name the host path and the place
/// inside, the same path here.
fn pair(words: &mut Vec<Word>, verb: &str, path: &Path) {
    let path = path.display().to_string();
    words.extend([plain(verb), plain(&path), plain(&path)]);
}

fn unavailable(cause: &str, detail: Option<&str>) -> Error {
    let mut fields = vec![("cause", cause)];
    if let Some(detail) = detail {
        fields.push(("detail", detail));
    }
    Error::refused("confinement-unavailable", &fields)
}

/// What `host` answers for a launch the harness's own answer confines,
/// judged on `path_var` (the `PATH` the launch's shell searches): on Linux
/// `bwrap` must be found and a trial run of its base words must succeed,
/// which it cannot where the kernel refuses an unprivileged user namespace,
/// and either failure refuses with bwrap's own first line as `detail`. A
/// host other than Linux answers unconfined by name and runs nothing.
pub fn probe(host: Host, path_var: Option<&OsStr>) -> Result<Answer> {
    if host == Host::Other {
        return Ok(Answer::Unconfined {
            cause: Cause::MacosProfileUnbuilt,
        });
    }
    let Some(bwrap) = find(path_var, WRAPPER) else {
        return Err(unavailable("bwrap-missing", None));
    };
    let mut args: Vec<&str> = BASE.to_vec();
    args.extend(["--", "/bin/sh", "-c", ":"]);
    match crate::host::run(WRAPPER, &bwrap, "confinement-trial", &args, TRIAL) {
        Ok(out) if out.status.success() => Ok(Answer::Confined),
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let line = stderr.lines().next().unwrap_or("").trim();
            Err(unavailable("userns-off", Some(line)))
        }
        Err(e) => Err(unavailable("userns-off", Some(&e.to_string()))),
    }
}

/// The executable `name` in the first folder of `path_var` that holds one.
fn find(path_var: Option<&OsStr>, name: &str) -> Option<PathBuf> {
    std::env::split_paths(path_var?)
        .map(|dir| dir.join(name))
        .find(|candidate| executable(candidate))
}

#[cfg(unix)]
fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn executable(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grants(writable: &str) -> Grants {
        Grants {
            writable: vec![PathBuf::from(writable)],
            seats: Vec::new(),
            read_only: Vec::new(),
            runtime_dir: None,
            sockets: Vec::new(),
            desktop: false,
            gh_token: None,
            file: PathBuf::from("/x/grants.json"),
        }
    }

    #[test]
    fn copilot_alone_answers_unconfined() {
        for h in Harness::ALL {
            let expected = match h {
                Harness::Copilot => Answer::Unconfined {
                    cause: Cause::TokenOnSessionBus,
                },
                Harness::Claude | Harness::Codex | Harness::Pi => Answer::Confined,
            };
            assert_eq!(answer(Host::Linux, h), expected, "{h}");
        }
        assert_eq!(
            serde_json::to_value(answer(Host::Linux, Harness::Copilot)).unwrap(),
            serde_json::json!({"state": "unconfined", "cause": "token-on-session-bus"})
        );
    }

    /// A host other than Linux keeps launching as before: every harness
    /// answers unconfined by name (Copilot by its own cause), the launch
    /// gets no wrapper, and the probe answers the same word, refusing
    /// nothing and running nothing.
    #[test]
    fn a_host_other_than_linux_answers_unconfined_by_name_and_spells_no_wrapper() {
        let host_cause = Answer::Unconfined {
            cause: Cause::MacosProfileUnbuilt,
        };
        for h in Harness::ALL {
            let expected = match h {
                Harness::Copilot => Answer::Unconfined {
                    cause: Cause::TokenOnSessionBus,
                },
                Harness::Claude | Harness::Codex | Harness::Pi => host_cause,
            };
            assert_eq!(answer(Host::Other, h), expected, "{h}");
            assert_eq!(
                confinement(Host::Other, h, &grants("/w/tree"))
                    .unwrap()
                    .answer(),
                expected,
                "{h}"
            );
        }
        assert_eq!(probe(Host::Other, None).unwrap(), host_cause);
        assert_eq!(
            serde_json::to_value(host_cause).unwrap(),
            serde_json::json!({"state": "unconfined", "cause": "macos-profile-unbuilt"})
        );
    }

    #[test]
    fn a_relative_grant_is_refused() {
        assert!(matches!(
            confinement(Host::Linux, Harness::Claude, &grants("work/tree")),
            Err(Error::Refused {
                key: "grant-relative",
                ..
            })
        ));
    }
}
