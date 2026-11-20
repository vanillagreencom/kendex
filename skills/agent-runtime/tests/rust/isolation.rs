//! A test child's isolation, for every row that starts a program: its
//! environment cleared and composed, refusing stand-ins for the tools that
//! reach a network, a keyring or a host, and git's ceilings. agent-runtime's
//! rows and orch's include this file by path.
#![allow(
    dead_code,
    reason = "each suite includes this module by path and uses a subset of it"
)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;

/// `name` as a test child under [`isolation_env`]: the one constructor for
/// every program a row starts that reads a home or a configuration (`git`,
/// a shipped script), so no row's own start reaches the operator's files,
/// such as `~/.gitconfig` and its includes.
pub fn program(name: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(name);
    isolation_env(&mut command);
    command
}

/// Git's ceilings for a test child: `root` and, where these tests live in a
/// repository (a clean copy of the index does not), its root, so a row that
/// hands the binary a fixture path inside the repository
/// (`tests/rust/fixtures/...`) resolves no project root there either. Git
/// stops below each ceiling, never at it: a child that starts in `root`
/// itself climbs past it, so `root` is a proper ancestor of the folder the
/// child starts in, and a wrapper whose child starts in a known folder
/// passes that folder's parent.
pub fn ceilings(root: &Path) -> std::ffi::OsString {
    let mut ceilings = root.as_os_str().to_owned();
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while dir.pop() {
        if std::fs::symlink_metadata(dir.join(".git")).is_ok() {
            ceilings.push(":");
            ceilings.push(dir.as_os_str());
            break;
        }
    }
    ceilings
}

/// The environment a test child runs with: cleared, then the tools' path,
/// the locale, the temporary root, a scratch home under that root (a tool
/// that reads a home, `gh` or `git`, finds nothing of the operator there),
/// a fixed git identity (a fixture commit needs one, and the operator's
/// is in the configuration no child reads), git's ceiling at the root,
/// so no checkout above a test directory is a project root
/// (`settings::roots` then reads the working directory), and tmux's
/// default socket directory under the root, so a child that names no
/// server finds none of the operator's. A row adds what it needs after.
/// [`program`] applies it to a program a row starts, [`isolated`] to the
/// binary, and the private tmux server to every pane.
pub fn isolation_env(command: &mut Command) -> &mut Command {
    let root = std::env::temp_dir();
    let home = root.join("isolated-home");
    std::fs::create_dir_all(&home).expect("the scratch home");
    command
        .env_clear()
        .env("PATH", tool_path(&[]))
        .env(
            "LANG",
            std::env::var_os("LANG").unwrap_or_else(|| "C.UTF-8".into()),
        )
        .env("TMPDIR", &root)
        .env("TMUX_TMPDIR", &root)
        .env("HOME", &home)
        .env("GIT_CEILING_DIRECTORIES", ceilings(&root));
    for (name, value) in [
        ("GIT_AUTHOR_NAME", "t"),
        ("GIT_AUTHOR_EMAIL", "t@t"),
        ("GIT_COMMITTER_NAME", "t"),
        ("GIT_COMMITTER_EMAIL", "t@t"),
    ] {
        command.env(name, value);
    }
    command
}

/// The tools directory under the temporary root that every test child sees
/// on `PATH` after a row's own prefixes: a `gh` that refuses, so a row that
/// names no `gh` fixture never reaches the operator's real `gh` by omission
/// (a real `gh` under the scratch home starts `gh send-telemetry` and
/// connects out), and a `loginctl` answering that the user manager does not
/// linger, so a detached job's launcher takes its `setsid` route and no row
/// starts a unit on the operator's user manager; a row that wants the unit
/// route plants its own manager fakes ahead of this directory. The programs
/// an account's usage, token or keyring read and a lane host's read run,
/// `curl`, `codex`, `secret-tool` and `ssh`, refuse as `gh` does, so a row
/// whose world plants no answer for them (the usage fixture as `curl`)
/// reaches no endpoint, keyring or host of the operator's. Each tool is
/// written once per process through [`publish`] (the rows of one test
/// binary start together on a cold temporary root).
pub fn isolated_bin() -> PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join("isolated-bin");
        std::fs::create_dir_all(&dir).expect("the isolated tools directory");
        for (name, text) in [
            (
                "gh",
                "#!/bin/sh\nprintf 'gh: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            (
                "curl",
                "#!/bin/sh\nprintf 'curl: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            (
                "codex",
                "#!/bin/sh\nprintf 'codex: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            (
                "secret-tool",
                "#!/bin/sh\nprintf 'secret-tool: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            (
                "ssh",
                "#!/bin/sh\nprintf 'ssh: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            ("loginctl", "#!/bin/sh\necho no\n"),
        ] {
            publish(&dir, name, text);
        }
        dir
    })
    .clone()
}

/// `text` as the executable `dir/name`, kept where the file already holds
/// it, else written under a name no other process or thread uses and
/// renamed into place, so test binaries writing it at once all read one
/// whole file.
pub fn publish(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    if std::fs::read_to_string(&path).is_ok_and(|held| held == text) {
        return path;
    }
    let tmp = dir.join(format!(
        ".{name}.{}.{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    write_executable(&tmp, text);
    std::fs::rename(&tmp, &path).expect("a published executable in place");
    path
}

/// A test child's `PATH`: a row's own `prefixes` first, then the isolated
/// tools directory, then the path this process inherited. Every row that
/// sets `PATH` composes it here, so a prefix never drops the refusing `gh`.
pub fn tool_path(prefixes: &[&Path]) -> String {
    let mut parts: Vec<String> = prefixes.iter().map(|p| p.display().to_string()).collect();
    parts.push(isolated_bin().display().to_string());
    parts.push(std::env::var("PATH").unwrap_or_default());
    parts.join(":")
}

/// `text` as the executable `path`, written by a child process. A file this
/// test process holds open for writing is held by every other test thread's
/// child between its fork and its exec as well, and running it then fails
/// `ETXTBSY`; a rename into place keeps that same file, so it does not help.
/// The child takes this process's `PATH`, not [`isolation_env`]'s: the tools
/// that path names are written here.
pub fn write_executable(path: &Path, text: impl AsRef<str>) {
    let out = Command::new("sh")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args([
            "-c",
            "printf '%s' \"$1\" > \"$2\" && chmod 755 \"$2\"",
            "write-executable",
        ])
        .arg(text.as_ref())
        .arg(path)
        .output()
        .expect("sh");
    assert!(
        out.status.success(),
        "write-executable {}: {}",
        path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
}

pub fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}
