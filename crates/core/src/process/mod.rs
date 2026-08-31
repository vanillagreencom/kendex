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

use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::error::{CoreError, Result};

/// Long enough for a cold clone over a slow link, short enough that a wedged
/// call surfaces as an error instead of a frozen window.
///
/// Public so a caller under no tighter budget can NAME it rather than take
/// it by omission. A builder default is invisible at the call site, which
/// is how a lane that needed a smaller bound could lose it and read as a
/// lane that never wanted one.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

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
///
/// `GIT_ATTR_SOURCE` is here rather than beside the materialising settings
/// because redirecting git's input is the whole of what it does, which is
/// what this list is: it names a treeish to read `.gitattributes` from
/// instead of the tree in hand, so it is neither the repository's answer
/// nor the user's configuration but a redirect the ambient environment
/// supplies. On the write it would convert a checkout past every setting
/// below; on a read it would have `status` judge a working tree against
/// some other commit's rules. The second is the worse of the two and only
/// scrubbing everywhere prevents it.
const GIT_REDIRECTS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_ATTR_SOURCE",
];

/// Configuration every git call settles on its own command line, where no
/// gitconfig — the host's, the user's, or one a downloaded repository ships
/// — can reopen it.
///
/// The `ext::` transport runs a shell command named in the URL, and a
/// manifest's `repo` string is what reaches `git clone`.
const PINNED: &[&str] = &["protocol.ext.allow=never"];

/// Settled on top of [`PINNED`], for the one call that writes catalog
/// content this machine then reads.
///
/// The rule is what the operation does, not which constructor it came
/// through: git converts as it writes a working tree, so an operation that
/// writes one is what needs this and nothing else does. `git_into` is
/// where the only such operation kendex runs lives, `checkout-index` out
/// of the mirror. A later call that writes a working tree owes them too,
/// wherever it is built.
///
/// What the host's git is configured to do to line endings must not decide
/// what a catalog checks out. Both settings tell git to rewrite them as it
/// writes a working tree, and Git for Windows' installer puts
/// `autocrlf=true` in the system config — which is what the GitHub Actions
/// Windows runner carries — so the same catalog gave one set of bytes
/// there and another on Linux. Settled here, that configuration no longer
/// reaches the write. Both rather than one, because `core.eol` decides for
/// a repository that marks its files as text and `core.autocrlf` for one
/// that does not.
///
/// Attributes outrank configuration, and the host can supply those too: a
/// global attributes file, named by `core.attributesFile` or found at its
/// default path, and a system-wide one. Either holding `* text eol=crlf`
/// converts the checkout with the settings above already in place. So
/// `core.attributesFile` is emptied here, which is git's documented unset,
/// and `GIT_ATTR_NOSYSTEM` in the environment takes the system file out.
///
/// That is the boundary, and it is the line worth holding rather than
/// narrowing the claim again: what the *host* says is silenced, what the
/// *catalog* says is not. A repository's own committed `.gitattributes`
/// still decides — `* text eol=crlf` still gets CRLF, and an attribute
/// selecting `filter=<driver>` still reaches for a `smudge` command that
/// lives in configuration, so one commit can land differently on a host
/// defining that driver. Neither is bypassed, because whose intent wins
/// between a catalog author and the machine reading them is a product
/// question rather than this module's. KEN-850 owns it.
///
/// It goes nowhere else, and the reach is the point rather than an
/// oversight. A call that only *inspects* a repository is asking what that
/// repository thinks, and its own normalisation is part of the answer:
/// `git status` compares the working tree against the index through it, so
/// forcing the conversion off there reports a line-ending-only change
/// nobody made and the submit preflight refuses a clean tree. That is a
/// repository the person in front of kendex owns, not one kendex
/// downloaded.
const MATERIALISING: &[&str] = &[
    "core.autocrlf=false",
    "core.eol=lf",
    // An empty value is how git spells "no attributes file", and it
    // displaces the default path as well as any the host configured.
    "core.attributesFile=",
];

mod programs;

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
    /// One environment variable on the child, for a caller that reads its
    /// output rather than merely relaying it.
    pub fn env(mut self, key: &str, value: &str) -> Hardened {
        self.command.env(key, value);
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Hardened {
        self.timeout = timeout;
        self
    }

    pub fn max_output(mut self, bytes: usize) -> Hardened {
        self.max_output = Some(bytes);
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
        // The deadline covers the READ, not only the wait: breaking on the
        // direct child's exit handed the pipes to `collect` with nothing
        // timing them, and a descendant that inherited them holds
        // `read_to_end` open — `sleep 60 & exit 0` returned at once and then
        // held collection for a minute, past every bound asked for. Reaped
        // last because `try_wait` reaps, and `end_tree` signals the group by
        // the leader's pid: a number held only while the group still has a
        // member, so a kill after the reap can land on a stranger.
        let status = loop {
            if reading_out.is_finished() && reading_err.is_finished() {
                match child.try_wait() {
                    Ok(Some(status)) => break status,
                    Ok(None) => {}
                    Err(error) => return Err(CoreError::io(&self.label, error)),
                }
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
        Hardened::git_settled(PINNED, args, cwd)
    }

    /// The same, for the call that writes catalog content — see
    /// [`MATERIALISING`].
    fn git_materialising_command(args: Vec<OsString>, cwd: Option<&Path>) -> Hardened {
        let settled: Vec<&str> = PINNED.iter().chain(MATERIALISING).copied().collect();
        let mut hardened = Hardened::git_settled(&settled, args, cwd);
        // The system attributes file has no config key to empty, so the
        // one switch git offers for it is this.
        hardened.command.env("GIT_ATTR_NOSYSTEM", "1");
        hardened
    }

    fn git_settled(settings: &[&str], args: Vec<OsString>, cwd: Option<&Path>) -> Hardened {
        let settled = settings
            .iter()
            .flat_map(|setting| [OsString::from("-c"), OsString::from(*setting)]);
        let mut hardened = Hardened::new("git", settled.chain(args).collect());
        hardened.scrub_git_redirects();
        let inherited = std::env::var("GIT_SSH_COMMAND").ok();
        hardened
            .command
            .env("GIT_SSH_COMMAND", ssh_command(inherited.as_deref()));
        if let Some(cwd) = cwd {
            hardened.command.current_dir(cwd);
        }
        hardened
    }

    /// No inherited redirect reaches the child, and no prompt can wait on
    /// a terminal nobody is watching.
    fn scrub_git_redirects(&mut self) {
        for variable in GIT_REDIRECTS {
            self.command.env_remove(variable);
        }
        self.command.env("GIT_TERMINAL_PROMPT", "0");
    }

    fn new(program: &str, args: Vec<OsString>) -> Hardened {
        Hardened::spawning(OsStr::new(program), args)
    }

    /// The same, for a program that is a path rather than a name.
    ///
    /// A path is bytes on Unix, not text: `to_string_lossy` on the way to
    /// `Command` substitutes U+FFFD for anything not UTF-8, and the child
    /// is then spawned against a filename that does not exist. It failed
    /// closed, but with a diagnostic naming a path nobody has — the label
    /// still goes through `to_string_lossy`, because a label is for reading
    /// and only the program has to survive intact.
    fn spawning(program: &OsStr, args: Vec<OsString>) -> Hardened {
        let label = std::iter::once(program.to_string_lossy().into_owned())
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
