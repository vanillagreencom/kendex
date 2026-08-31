//! What the write has to be told, and the git that has to be able to hear
//! it.
//!
//! A checkout reads its `.gitattributes` out of a tree kendex names rather
//! than out of the commit it is writing, so nothing a catalog committed is
//! in force for any path. Naming that tree can fail two ways — no object
//! format has ids of that length, or the git here cannot be told to read
//! that tree — and both end the same: kendex refuses rather than writing a
//! checkout git was free to convert.

use std::sync::{Mutex, PoisonError};

use crate::error::{CoreError, Result};
use crate::process::Hardened;

/// This host's answer for this commit: the tree the write reads its
/// attributes from, or the refusal that stops the write before a file
/// exists.
pub(super) fn for_commit(commit: &str) -> Result<&'static str> {
    pinned(&git_version(), commit)
}

/// Both halves of naming that tree are asked here — the id, and the git
/// that has to take it — because both have the same answer when they
/// cannot be met, and it is never "write it anyway".
///
/// The reading arrives as an argument so that this order can be held to
/// from a test: no host that runs the suite has a git below the floor, so
/// nothing else could show that the floor is asked about at all.
fn pinned(probe: &Probe, commit: &str) -> Result<&'static str> {
    if let Some(refusal) = below_floor(probe) {
        return Err(refused(commit, refusal));
    }
    no_attributes(commit)
}

/// A checkout kendex would not write, said as its own failure.
///
/// `GitFailed` carries it for the shape rather than the subject: nothing
/// was spawned, so `command` names the operation kendex refused and not a
/// git call — a reader sent looking for one in a log would find no
/// counterpart for it.
fn refused(commit: &str, reason: String) -> CoreError {
    CoreError::GitFailed {
        command: format!("materializing {commit}"),
        stderr: reason,
    }
}

/// The first git that takes `--attr-source`, and so the first git kendex
/// can write a checkout with. v2.41.0 introduced the option; v2.40 taught
/// `git check-attr` an optional tree-ish, which is a different thing.
///
/// Older is refused, not worked around. The two settings that would do the
/// same job — `attr.tree`, `GIT_ATTR_SOURCE` — are ignored without a word
/// by a git that does not know them, and a checkout nothing told to skip
/// attributes is one the catalog converted. Refusing is the only answer
/// that cannot be wrong in silence.
const GIT_FLOOR: (u32, u32) = (2, 41);

/// What asking this host's git for its version came back with.
///
/// Three answers rather than one, because they call for three different
/// sentences and only the first is about a version. A git that runs and
/// refuses has already written the sentence that fixes the problem — a
/// malformed gitconfig says `fatal: bad config line 1 in file ...` — and
/// routing that through "kendex could not run git" would throw away the
/// one useful thing said and point the reader at a version that is not
/// the fault.
#[cfg_attr(test, derive(Debug))]
enum Probe {
    /// The version line git printed, and where that git keeps its
    /// programs when the version is one that cannot write a checkout.
    Answered {
        line: String,
        installed: Option<String>,
    },
    /// git ran, refused, and said why.
    Refused(String),
    /// Nothing came back: the spawn did not happen, or the call did not
    /// return, or it failed without a word.
    Silent,
}

/// Asked once and then remembered — but only a reading that clears the
/// floor is worth remembering.
///
/// A host whose git can write a checkout does not stop being one mid-run,
/// so that answer is worth a process once and never again: a long session
/// materializes many commits and only the first of them spends a spawn.
///
/// Every other reading is worth nothing, and keeping one would outlive its
/// cause. Two of them are a person following the refusal's own advice: a
/// Mac without the command line tools has a `/usr/bin/git` shim that exits
/// non-zero until they are installed, and a host below the floor is told
/// to upgrade — remembered, either reading keeps refusing after they have
/// done it. Both recover on the next checkout instead of on the next
/// restart, and the cost is one spawn per checkout only while kendex is
/// refusing anyway.
///
/// The lock is held across the asking, not merely around the remembering,
/// so two publishes starting together spend one spawn between them rather
/// than one each. On the paths that ask again they each spend one, which
/// are the paths that end in a refusal either way.
fn git_version() -> Probe {
    static CLEARED: Mutex<Option<String>> = Mutex::new(None);
    reading(&CLEARED, ask_git)
}

/// The asking and the remembering, given the cell to remember in, so that
/// what it keeps and what it asks for again can be shown without a git
/// that fails and without a git that is old.
fn reading(cell: &Mutex<Option<String>>, ask: impl FnOnce() -> Probe) -> Probe {
    let mut kept = cell.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(cleared) = kept.as_deref() {
        return Probe::Answered {
            line: cleared.to_owned(),
            installed: None,
        };
    }
    let probe = ask();
    if let Probe::Answered { line, .. } = &probe
        && clears(line)
    {
        *kept = Some(line.clone());
    }
    probe
}

/// The one call, kept whole rather than reduced to its stdout: a failing
/// git says what is wrong on stderr, and the status is what tells the two
/// apart.
///
/// Whitespace in what git said is collapsed on the way in, because it
/// lands mid-sentence in a refusal a person reads and git wraps its own
/// output.
fn ask_git() -> Probe {
    probed(Hardened::git(&["--version"], None))
}

/// The call arrives built so that a test can hand over one that really
/// fails — a git pointed at a malformed config exits non-zero and says so
/// — rather than asserting against a `Probe` the test made up.
fn probed(call: Hardened) -> Probe {
    let Ok(output) = call.run() else {
        return Probe::Silent;
    };
    if !output.status.success() {
        let said = collapsed(&output.stderr);
        return match said.is_empty() {
            true => Probe::Silent,
            false => Probe::Refused(said),
        };
    }
    let line = collapsed(&output.stdout);
    // Only a reading that cannot write a checkout has to say where it came
    // from, and only that reading pays the second spawn for it.
    let installed = (!clears(&line)).then(exec_path).flatten();
    Probe::Answered { line, installed }
}

/// Where the git that just answered keeps its programs, asked of git
/// rather than worked out here: kendex searches no directories of its own
/// and reads no `PATH`, it runs `git --exec-path` and repeats the answer.
/// A second spawn, resolved the way the first one was.
///
/// Worth saying at all because a person who installed a newer git
/// elsewhere can see from it that this is not the one kendex reached.
fn exec_path() -> Option<String> {
    let output = Hardened::git(&["--exec-path"], None).run().ok()?;
    let path = collapsed(&output.stdout);
    output
        .status
        .success()
        .then_some(path)
        .filter(|at| !at.is_empty())
}

fn collapsed(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether a version line is one a checkout can be written under.
fn clears(line: &str) -> bool {
    version_of(line).is_some_and(|found| found >= GIT_FLOOR)
}

/// What a reading earns, or `None` when it clears the floor. Kept apart
/// from the taking of it so every sentence can be held to on hosts that
/// have none of these gits.
fn below_floor(probe: &Probe) -> Option<String> {
    let (want_major, want_minor) = GIT_FLOOR;
    let needed = format!(
        "kendex needs git {want_major}.{want_minor} or newer to write a checkout: it is the first git that can be told to read no attributes, and one that cannot be told converts the files in silence"
    );
    match probe {
        // `clears` and nothing beside it, so the memo and the refusal
        // cannot come to differ: a line one keeps and the other rejects
        // would be remembered and then refused at every later checkout.
        Probe::Answered { line, .. } if clears(line) => None,
        Probe::Answered { line, installed } => match version_of(line) {
            // Which git it was, when git said: a Mac that has a newer one
            // in another directory is otherwise told to install what it
            // already has.
            Some((major, minor)) => Some(format!(
                "this host runs git {major}.{minor}{}, and {needed}",
                installed
                    .as_deref()
                    .map_or(String::new(), |at| format!(", whose programs live at {at}"))
            )),
            None => Some(format!(
                "this host's git did not say which version it is, answering \"{line}\", and {needed}"
            )),
        },
        // git's own sentence, which is the one that fixes the problem.
        Probe::Refused(said) => Some(format!(
            "git here answered \"{said}\" instead of a version, and {needed}"
        )),
        Probe::Silent => Some(format!(
            "kendex could not run git --version here, and {needed}"
        )),
    }
}

/// `git version 2.41.0`, Apple's `git version 2.39.5 (Apple Git-154)` and
/// the Windows build's `git version 2.47.1.windows.1` all put major and
/// minor in the same two places, which is the whole of what the floor is
/// compared on.
fn version_of(reported: &str) -> Option<(u32, u32)> {
    let mut numbers = reported.strip_prefix("git version ")?.split('.');
    Some((numbers.next()?.parse().ok()?, numbers.next()?.parse().ok()?))
}

/// The empty tree, which is the tree with no `.gitattributes` in it, in
/// each object format git has. Both are constants of the format rather
/// than of any repository: git answers for the empty tree whether or not
/// the object was ever stored.
const NO_ATTRIBUTES: [(usize, &str); 2] = [
    (40, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"),
    (
        64,
        "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
    ),
];

/// Which of them this repository owes, read off the length of the commit
/// id in hand — the id git itself printed out of this mirror, so its
/// length is that mirror's hash size and no extra call has to ask.
///
/// Wrong would be loud, not quiet: git refuses an attribute source in the
/// other format outright (`fatal: bad --attr-source or GIT_ATTR_SOURCE`),
/// and a length that is neither is refused here for the same reason. The
/// one answer that must never be reachable is a checkout written with no
/// attribute source at all, because that one converts in silence.
fn no_attributes(commit: &str) -> Result<&'static str> {
    NO_ATTRIBUTES
        .iter()
        .find(|(length, _)| *length == commit.len())
        .map(|(_, tree)| *tree)
        .ok_or_else(|| {
            refused(
                commit,
                format!(
                    "no object format has ids of {} characters, so the attribute source \
                     this checkout must be written under cannot be named",
                    commit.len()
                ),
            )
        })
}

#[cfg(test)]
mod tests;
