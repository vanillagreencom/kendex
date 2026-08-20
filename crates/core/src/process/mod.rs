//! Every external process this crate launches is built here (invariant 13):
//! environment that can redirect it is cleared, every prompt path is closed,
//! and every call carries a timeout. A per-call-site discipline misses call
//! sites — v1 had 27 unguarded `Command::new("git")` invocations — so the
//! raw pattern is guard-banned everywhere but this file.
//!
//! The threat that shapes `git_in`: a catalog repository is other people's
//! data. Its `.git/config` may set `core.worktree` to a directory outside
//! the cache, and a refresh (`reset --hard`) then writes the repository's
//! files over whatever lives there — the user's own work, one directory up.
//! Clearing `GIT_WORK_TREE` does not help, because the setting comes from
//! the downloaded repository rather than the environment. Only the command
//! line outranks config, so operations inside a cache pin `--git-dir` and
//! `--work-tree` explicitly and the hostile setting is ignored.

use std::ffi::OsString;
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::error::{CoreError, Result};

/// Long enough for a cold clone over a slow link, short enough that a wedged
/// call surfaces as an error instead of a frozen window.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

/// What a person waiting on a button will sit through. A refresh they asked
/// for and are watching is a different promise from a clone running behind
/// them: two minutes of nothing reads as broken, so an interactive call
/// gives up early and says so while the window is still theirs.
pub const INTERACTIVE_TIMEOUT: Duration = Duration::from_secs(30);

const POLL: Duration = Duration::from_millis(10);

/// How long a timed-out process tree gets to end on its own before it is
/// ended for it.
const GROUP_GRACE: Duration = Duration::from_millis(100);

/// Environment that points git at a different repository than the caller
/// named — inherited from whatever launched the app, including another
/// harness mid-operation.
const GIT_REDIRECTS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
];

pub struct Hardened {
    command: Command,
    /// What the caller asked for, for error messages. Plumbing arguments
    /// this module adds are deliberately left out.
    label: String,
    timeout: Duration,
    /// Cap on captured stdout/stderr, for callers whose peer is a network
    /// service rather than a local tool — a hostile server must not be
    /// able to stream the process out of memory. None = uncapped.
    max_output: Option<usize>,
}

impl Hardened {
    pub fn git(args: &[&str], cwd: Option<&Path>) -> Hardened {
        let mut hardened = Hardened::git_command(owned(args), cwd);
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git against a downloaded repository. The working tree is pinned on
    /// the command line, where it outranks a `core.worktree` the repository
    /// ships, so the call cannot reach outside `repo`.
    pub fn git_in(repo: &Path, args: &[&str]) -> Hardened {
        let mut pinned = vec![
            OsString::from("--git-dir"),
            repo.join(".git").into_os_string(),
            OsString::from("--work-tree"),
            repo.as_os_str().to_owned(),
        ];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_command(pinned, Some(repo));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git against a bare mirror in the cache. No working tree is attached,
    /// so no operation on it can write a file anywhere: a mirror only ever
    /// gains objects and refs.
    pub fn git_bare(git_dir: &Path, args: &[&str]) -> Hardened {
        let mut pinned = vec![OsString::from("--git-dir"), git_dir.as_os_str().to_owned()];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_command(pinned, Some(git_dir));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git materializing a commit out of a bare mirror into `work_tree`.
    /// Both ends are pinned on the command line, where they outrank any
    /// `core.worktree` in the mirror, so the write lands in the directory
    /// named here and nowhere else.
    pub fn git_into(git_dir: &Path, work_tree: &Path, args: &[&str]) -> Hardened {
        let mut pinned = vec![
            OsString::from("--git-dir"),
            git_dir.as_os_str().to_owned(),
            OsString::from("--work-tree"),
            work_tree.as_os_str().to_owned(),
        ];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_command(pinned, Some(work_tree));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    pub fn npm(args: &[&str], cwd: Option<&Path>) -> Hardened {
        let mut hardened = Hardened::new("npm", owned(args));
        if let Some(cwd) = cwd {
            hardened.command.current_dir(cwd);
        }
        hardened
    }

    pub fn gh(args: &[&str]) -> Hardened {
        Hardened::new("gh", owned(args))
    }

    pub fn curl(args: &[&str]) -> Hardened {
        Hardened::new("curl", owned(args))
    }

    /// The machine-locally configured guard extension: an executable the
    /// user pointed the pre-commit chain at, run from the repository root
    /// under the standard hardening (no stdin, captured output, a
    /// timeout). Never configured from a committed file.
    pub fn local_guard(program: &Path, cwd: &Path) -> Hardened {
        let mut hardened = Hardened::new(&program.to_string_lossy(), Vec::new());
        hardened.command.current_dir(cwd);
        hardened
    }

    pub fn timeout(mut self, timeout: Duration) -> Hardened {
        self.timeout = timeout;
        self
    }

    pub fn max_output(mut self, bytes: usize) -> Hardened {
        self.max_output = Some(bytes);
        self
    }

    /// The one sanctioned redirect: a commit-time guard must judge the
    /// index git actually named in `GIT_INDEX_FILE` — during `git commit`
    /// that is a temporary index, and scrubbing it would silently judge
    /// the wrong one. The value never arrives straight from the process
    /// environment: the guard context captured and canonicalized it once,
    /// and threads it here explicitly.
    pub fn index_file(mut self, path: &Path) -> Hardened {
        self.command.env("GIT_INDEX_FILE", path);
        self
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn run(mut self) -> Result<Output> {
        let mut child = match self.command.spawn() {
            Ok(child) => child,
            Err(error) => return Err(CoreError::io(&self.label, error)),
        };
        let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take())
        else {
            return Err(CoreError::io(
                &self.label,
                io::Error::other("child was spawned without pipes"),
            ));
        };
        // Drained on threads: a child that fills a pipe buffer would block
        // forever while we sat polling for its exit.
        let cap = self.max_output;
        let reading_out = std::thread::spawn(move || read(&mut stdout, cap));
        let reading_err = std::thread::spawn(move || read(&mut stderr, cap));

        let deadline = Instant::now() + self.timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {}
                Err(error) => return Err(CoreError::io(&self.label, error)),
            }
            if Instant::now() >= deadline {
                end_tree(&mut child);
                return Err(CoreError::io(
                    &self.label,
                    io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("no result after {:?}", self.timeout),
                    ),
                ));
            }
            std::thread::sleep(POLL);
        };
        Ok(Output {
            status,
            stdout: collect(reading_out, &self.label)?,
            stderr: collect(reading_err, &self.label)?,
        })
    }

    fn git_command(args: Vec<OsString>, cwd: Option<&Path>) -> Hardened {
        // The `ext::` transport runs a shell command named in the URL. A
        // manifest's `repo` string is what reaches `git clone`, so it is
        // shut on the command line, where a gitconfig cannot reopen it.
        let mut hardened = Hardened::new(
            "git",
            [
                OsString::from("-c"),
                OsString::from("protocol.ext.allow=never"),
            ]
            .into_iter()
            .chain(args)
            .collect(),
        );
        for variable in GIT_REDIRECTS {
            hardened.command.env_remove(variable);
        }
        hardened.command.env("GIT_TERMINAL_PROMPT", "0");
        let inherited = std::env::var("GIT_SSH_COMMAND").ok();
        hardened
            .command
            .env("GIT_SSH_COMMAND", ssh_command(inherited.as_deref()));
        if let Some(cwd) = cwd {
            hardened.command.current_dir(cwd);
        }
        hardened
    }

    fn new(program: &str, args: Vec<OsString>) -> Hardened {
        let label = std::iter::once(program.to_owned())
            .chain(args.iter().map(|arg| arg.to_string_lossy().into_owned()))
            .collect::<Vec<_>>()
            .join(" ");
        let mut command = Command::new(program);
        command
            .args(&args)
            // No prompt can block: nothing to read from.
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // The child leads a group of its own, so a timeout can end
        // everything it started rather than only the process we hold.
        #[cfg(unix)]
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
        Hardened {
            command,
            label,
            timeout: DEFAULT_TIMEOUT,
            max_output: None,
        }
    }

    #[cfg(test)]
    fn program(program: &str, args: &[&str]) -> Hardened {
        Hardened::new(program, owned(args))
    }
}

fn owned(args: &[&str]) -> Vec<OsString> {
    args.iter().map(OsString::from).collect()
}

/// SSH must never sit at a prompt, and a caller who set its own ssh command
/// — a deploy key, a jump host — must keep it: a catalog that only fetches
/// with that key stops fetching the moment we replace it. BatchMode rides
/// along with whatever was inherited.
fn ssh_command(inherited: Option<&str>) -> String {
    match inherited.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => format!("{value} -oBatchMode=yes"),
        None => "ssh -oBatchMode=yes".to_owned(),
    }
}

/// End the timed-out child and everything it started. Git shells out to ssh,
/// and killing only the process we hold leaves that grandchild running past
/// the deadline with a reader thread blocked on its pipe. The child leads its
/// own group, so the group is what goes: a chance to end cleanly, then not.
#[cfg(unix)]
fn end_tree(child: &mut std::process::Child) {
    // The `--` is load-bearing: procps kill (Ubuntu) without it folds a
    // negative pid to its leading digits — `kill -TERM -1234` becomes
    // kill(-1, SIGTERM), every process the user owns, the CI runner
    // included. util-linux and BSD kill accept the same spelling.
    let group = format!("-{}", child.id());
    for signal in ["TERM", "KILL"] {
        let _ = Command::new("kill")
            .args(["-s", signal, "--", &group])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if signal == "TERM" {
            std::thread::sleep(GROUP_GRACE);
        }
    }
    let _ = child.wait();
}

#[cfg(not(unix))]
fn end_tree(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn read(pipe: &mut impl Read, cap: Option<usize>) -> io::Result<Vec<u8>> {
    let mut buffer = Vec::new();
    match cap {
        None => {
            pipe.read_to_end(&mut buffer)?;
        }
        Some(cap) => {
            // One byte past the cap distinguishes "exactly at" from "over";
            // over is refused rather than silently truncated to garbage.
            pipe.take(cap as u64 + 1).read_to_end(&mut buffer)?;
            if buffer.len() > cap {
                return Err(io::Error::other(format!(
                    "output exceeded the {cap}-byte cap"
                )));
            }
        }
    }
    Ok(buffer)
}

/// Re-launch this same binary, detached: no stdio, never waited on. Not a
/// tool invocation — the one caller is the session check spawning its own
/// background refresh — so none of [`Hardened`]'s tool posture (timeouts,
/// captured output) applies; what does apply is living in this file, where
/// process creation is audited.
pub fn respawn_detached(args: &[&str]) {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let _ = Command::new(exe)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn collect(reader: JoinHandle<io::Result<Vec<u8>>>, label: &str) -> Result<Vec<u8>> {
    match reader.join() {
        Ok(Ok(bytes)) => Ok(bytes),
        Ok(Err(error)) => Err(CoreError::io(label, error)),
        Err(_) => Err(CoreError::io(
            label,
            io::Error::other("output reader panicked"),
        )),
    }
}

#[cfg(test)]
mod tests;
