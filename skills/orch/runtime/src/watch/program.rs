//! The watch's own program against its checkout's current sources. A
//! `watch run` keeps the program it started as, `<cache>/bin/orch-runtime-<key>`,
//! while an update rewrites the sources beside the orch install and places
//! a program under their new key. At the start of each long pass the
//! shared thread reads that key the way the install's wrapper does,
//! through agent-runtime's `lib/key.sh` beside it, which owns the key's
//! rule and the cache layout; a key other than its own names the program
//! to replace itself with ([`Current`]).
//!
//! A program whose file name carries no key (a build run from its cargo
//! target) was placed by no setup: it has no key to compare, and the watch
//! follows nothing.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;

/// What every placed program's file name holds before its key.
const PREFIX: &str = "orch-runtime-";

/// The field a program's `version` result carries, `true`, where it
/// resumes a claim naming its own identity. A program built from sources
/// without it reads the inherited claim live and refuses, ending the watch,
/// so the watch never becomes one.
pub const RESUMES: &str = "watch_resumes_claim";

/// The shell line that prints the cache root and the key of the sources
/// at `$2` through the key reader at `$1`, the wrapper's own two reads. The
/// reader's refusals print their line on stderr.
const KEY_READ: &str = "refuse() { printf '%s\\n' \"$*\" >&2; exit 1; }; . \"$1\"; agent_runtime_cache; agent_runtime_key \"$2\"";

/// The key a placed program's path carries: 64 lowercase hex digits after
/// `orch-runtime-`, as key.sh prints them.
pub fn key_of(program: &Path) -> Option<&str> {
    let key = program.file_name()?.to_str()?.strip_prefix(PREFIX)?;
    is_key(key).then_some(key)
}

fn is_key(word: &str) -> bool {
    word.len() == 64 && word.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The running program and the orch install it was placed for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Program {
    key: String,
    /// The install's scripts directory, where its wrapper resolves from.
    scripts: PathBuf,
    /// The bound on each read: the key, and a placed program's `version`.
    bound: Duration,
}

/// What the checkout's sources name against the running program.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Current {
    /// The sources' key is the program's own.
    Same,
    /// Another key, whose program stands placed at `binary` and answered
    /// `version`.
    Placed { key: String, binary: PathBuf },
    /// Another key, whose program cannot take over: `absent` or
    /// `not-executable` where it is no program to run, `unanswered` where
    /// it did not answer `version` (a build for another host),
    /// `unresumable` where its answer does not declare [`RESUMES`].
    Unready { key: String, cause: &'static str },
    /// The key did not read; `cause` names the step and what said so.
    Unread { cause: String },
}

impl Program {
    /// The program `exe` names, placed for the orch install under
    /// `project`; `None` where its name carries no key.
    pub fn of(exe: &Path, project: &Path, bound: Duration) -> Option<Program> {
        Some(Program {
            key: key_of(exe)?.to_owned(),
            scripts: crate::watch::overseer::scripts_dir(project),
            bound,
        })
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    /// The checkout's key now, and whether its program stands placed. The
    /// scripts directory is resolved first, as the wrapper resolves its own
    /// location, so the key reader and the sources are the siblings of the
    /// install it runs from. A placed program is asked `version` first: the
    /// exec is the point of no return, and a file the kernel refuses is run
    /// as a shell script by the exec's fallback, which would end the watch.
    #[allow(
        clippy::disallowed_methods,
        reason = "the watch's reads of its checkout's key, through key.sh under bash, and of the placed program's `version`, each bounded and no act"
    )]
    pub fn current(&self) -> Current {
        let unread = |cause: String| Current::Unread { cause };
        let scripts = match std::fs::canonicalize(&self.scripts) {
            Ok(scripts) => scripts,
            Err(e) => {
                return unread(format!(
                    "scripts-unresolved path={} cause={e}",
                    self.scripts.display()
                ));
            }
        };
        let key_lib = scripts.join("../../agent-runtime/scripts/lib/key.sh");
        let runtime = scripts.join("../runtime");
        let (Some(key_lib), Some(runtime)) = (key_lib.to_str(), runtime.to_str()) else {
            return unread(format!("path-unreadable path={}", scripts.display()));
        };
        let out = match host::run_tagged(
            "watch",
            "bash",
            Path::new("bash"),
            "program-key",
            &["-c", KEY_READ, "program-key", key_lib, runtime],
            self.bound,
        ) {
            Ok(out) => out,
            Err(e) => return unread(format!("key-unread cause={e}")),
        };
        let stdout = String::from_utf8_lossy(&out.stdout);
        let mut lines = stdout.lines();
        let (Some(cache), Some(key), None) = (lines.next(), lines.next(), lines.next()) else {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return unread(format!(
                "key-unread status={} stderr={}",
                out.status,
                stderr.trim()
            ));
        };
        if !out.status.success() || !is_key(key) {
            return unread(format!("key-unread status={} key={key}", out.status));
        }
        if key == self.key {
            return Current::Same;
        }
        let binary = Path::new(cache).join("bin").join(format!("{PREFIX}{key}"));
        let key = key.to_owned();
        if let Some(cause) = crate::ready::executable(&binary) {
            return Current::Unready { key, cause };
        }
        let answer = match host::run_tagged(
            "watch",
            "orch-runtime",
            &binary,
            "version",
            &["version"],
            self.bound,
        ) {
            Ok(out) if out.status.success() => {
                serde_json::from_slice::<serde_json::Value>(&out.stdout).ok()
            }
            Ok(_) | Err(_) => None,
        };
        let cause = match answer {
            None => "unanswered",
            Some(answer) if answer["result"][RESUMES] == true => {
                return Current::Placed { key, binary };
            }
            Some(_) => "unresumable",
        };
        Current::Unready { key, cause }
    }
}

/// Replace this process with `binary` under its own arguments and
/// environment: the pid and the process start stay, so the claim still
/// names the runner, and the arguments carry the credential the start
/// selected. Returns only where the exec failed, with its cause.
pub fn replace(binary: &Path) -> std::io::Error {
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    host::exec(binary.as_os_str(), &args, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A placed program's name carries its key; a cargo build's carries
    /// none, so a watch run from its target follows nothing.
    #[test]
    fn a_key_reads_only_off_a_placed_programs_name() {
        let digest = "0123456789abcdef".repeat(4);
        assert_eq!(
            key_of(Path::new(&format!("/c/bin/orch-runtime-{digest}"))),
            Some(digest.as_str())
        );
        assert_eq!(key_of(Path::new("/w/target/debug/orch-runtime")), None);
    }
}
