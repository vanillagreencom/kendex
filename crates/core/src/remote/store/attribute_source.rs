//! What the write has to be told, and the git that has to be able to hear
//! it.
//!
//! A checkout reads its `.gitattributes` out of a tree kendex names rather
//! than out of the commit it is writing, so nothing a catalog committed is
//! in force for any path. Naming that tree can fail two ways — the git
//! here cannot be told to read a tree, or no object format has ids of that
//! length — and both end the same: kendex refuses rather than writing a
//! checkout git was free to convert.

use crate::error::{CoreError, Result};
use crate::process::Hardened;

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

/// This host's answer for this commit: the tree the write reads its
/// attributes from, or the refusal that stops the write before a file
/// exists.
pub(super) fn for_commit(commit: &str) -> Result<&'static str> {
    checked(&git_version(), commit)
}

/// The floor is asked before anything else about the checkout, and a git
/// below it stops the write whatever the commit is.
///
/// The reading arrives as an argument so that this order can be held to
/// from a test: no host that runs the suite has a git below the floor, so
/// nothing else could show that the floor is asked about at all.
fn checked(reported: &str, commit: &str) -> Result<&'static str> {
    if !clears(reported) {
        return Err(refused(commit, too_old(reported)));
    }
    no_attributes(commit)
}

/// What git said here when asked its version, on one line — or nothing at
/// all, which is what a git that is not there or would not start comes
/// back as. Every one of those is the same answer to the only question
/// asked: this is not a git that can write a checkout.
fn git_version() -> String {
    answer(Hardened::git(&["--version"], None))
}

/// The call arrives built so that a test can hand over one that really
/// fails — a git pointed at a malformed config exits non-zero and says so
/// — rather than asserting against an answer the test made up.
///
/// A git that ran and refused is kept word for word rather than reduced to
/// its empty stdout: `fatal: bad config line 1 in file ...` is the one
/// sentence that fixes that host, and a refusal quoting nothing throws it
/// away. Whitespace is collapsed on the way out, because what git said
/// lands mid-sentence in a refusal a person reads and git wraps its own
/// output.
fn answer(call: Hardened) -> String {
    let Ok(output) = call.run() else {
        return String::new();
    };
    let said = match output.status.success() {
        true => &output.stdout,
        false => &output.stderr,
    };
    String::from_utf8_lossy(said)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The one sentence a git that cannot write a checkout earns: what this
/// host answered, what kendex needs instead, and what to do about it.
///
/// The remedy is both halves of it, because one sentence answers every
/// reading: a git below the floor is upgraded, and a git that would not
/// answer at all is not upgraded into one — it is made to answer first.
fn too_old(reported: &str) -> String {
    let (major, minor) = GIT_FLOOR;
    format!(
        "this host's git answered \"{reported}\", and kendex needs git {major}.{minor} or newer to write a checkout: install a current git and check that git --version answers here"
    )
}

/// Whether a version line is one a checkout can be written under.
fn clears(reported: &str) -> bool {
    version_of(reported).is_some_and(|found| found >= GIT_FLOOR)
}

/// `git version 2.41.0`, Apple's `git version 2.39.5 (Apple Git-154)` and
/// the Windows build's `git version 2.47.1.windows.1` all put major and
/// minor in the same two places, which is the whole of what the floor is
/// compared on.
fn version_of(reported: &str) -> Option<(u32, u32)> {
    let mut numbers = reported.strip_prefix("git version ")?.split('.');
    Some((numbers.next()?.parse().ok()?, numbers.next()?.parse().ok()?))
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
