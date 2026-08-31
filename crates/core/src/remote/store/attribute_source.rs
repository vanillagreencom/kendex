//! What the write has to be told, and the git that has to be able to hear
//! it.
//!
//! A checkout reads its `.gitattributes` out of a tree kendex names rather
//! than out of the commit it is writing, so nothing a catalog committed is
//! in force for any path. Naming that tree can fail two ways, and both end
//! the same: kendex refuses rather than writing a checkout git was free to
//! convert.

use std::sync::OnceLock;

use super::stdout;
use crate::error::{CoreError, Result};
use crate::process::Hardened;

/// This host's answer for this commit: the tree the write reads its
/// attributes from, or the refusal that stops the write before a file
/// exists.
pub(super) fn for_commit(commit: &str) -> Result<&'static str> {
    pinned(git_version(), commit)
}

/// Both halves of naming that tree are asked here — the id, and the git
/// that has to take it — because both have the same answer when they
/// cannot be met, and it is never "write it anyway".
///
/// The version arrives as an argument so that this order can be held to
/// from a test: no host that runs the suite has a git below the floor, so
/// nothing else could show that the floor is asked about at all.
fn pinned(reported: Option<&str>, commit: &str) -> Result<&'static str> {
    if let Some(refusal) = below_floor(reported) {
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

/// Asked once, at the first checkout: a host does not change its git
/// mid-run, and every answer after the first would cost a process to
/// learn what this one already knows.
fn git_version() -> Option<&'static str> {
    static REPORTED: OnceLock<Option<String>> = OnceLock::new();
    REPORTED
        .get_or_init(|| stdout(Hardened::git(&["--version"], None)))
        .as_deref()
}

/// What a `git --version` line earns, or `None` when it clears the floor.
/// Kept apart from the reading of it so the sentence can be held to on
/// versions no test host has.
fn below_floor(reported: Option<&str>) -> Option<String> {
    let (want_major, want_minor) = GIT_FLOOR;
    let needed = format!(
        "kendex needs git {want_major}.{want_minor} or newer to write a checkout: it is the first git that can be told to read no attributes, and one that cannot be told converts the files in silence"
    );
    match reported.and_then(version_of) {
        Some(found) if found >= GIT_FLOOR => None,
        Some((major, minor)) => Some(format!("this host runs git {major}.{minor}, and {needed}")),
        None => Some(format!(
            "this host's git did not say which version it is, answering {}, and {needed}",
            reported.map_or("nothing at all".to_owned(), |line| format!("\"{line}\""))
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
mod tests {
    use super::*;

    /// The version line every host answers with, read the way the floor has to
    /// read it. A git below the floor cannot be installed on the machine
    /// running this, so the sentence is held to here instead — including on
    /// the shapes real hosts print: Apple's command line tools carry a build
    /// suffix, and the Windows build carries a fourth number.
    #[test]
    fn a_git_below_the_floor_is_refused_by_both_versions() {
        let (major, minor) = GIT_FLOOR;
        let needed = format!("git {major}.{minor} or newer");

        assert_eq!(below_floor(Some("git version 2.41.0")), None);
        assert_eq!(below_floor(Some("git version 2.55.0")), None);
        assert_eq!(below_floor(Some("git version 3.0.0")), None);

        for (line, found) in [
            ("git version 2.39.5 (Apple Git-154)", "git 2.39"),
            ("git version 2.34.1", "git 2.34"),
            ("git version 1.9.1", "git 1.9"),
        ] {
            let refusal = below_floor(Some(line)).expect("a git below the floor was accepted");
            assert!(refusal.contains(found), "{line}: {refusal}");
            assert!(refusal.contains(&needed), "{line}: {refusal}");
        }

        // A version nothing could read is refused too: proceeding would spend
        // the refusal on git's own usage wall, which names no version at all.
        for unreadable in [None, Some(""), Some("git version"), Some("hg 5.9")] {
            let refusal = below_floor(unreadable).expect("an unreadable version was accepted");
            assert!(refusal.contains(&needed), "{unreadable:?}: {refusal}");
        }
    }

    /// The floor is asked before anything else about a checkout, and a git
    /// below it stops the write whatever the commit is. Only reachable from
    /// here: every host that runs this suite carries a git above the floor,
    /// so no end-to-end test can put one below it.
    #[test]
    fn a_checkout_is_refused_on_an_old_git_whatever_the_commit_is() {
        let commit = "a".repeat(40);
        let (_, sha1_empty_tree) = NO_ATTRIBUTES[0];

        assert_eq!(
            pinned(Some("git version 2.41.0"), &commit).unwrap(),
            sha1_empty_tree
        );
        let refusal = pinned(Some("git version 2.34.1"), &commit)
            .expect_err("an old git was allowed to write a checkout")
            .to_string();
        assert!(refusal.contains("git 2.34"), "{refusal}");
    }

    /// Every refusal this file writes is a sentence a person reads, and it is
    /// written where nothing reflows it: rustfmt leaves string contents alone,
    /// so a line continuation that keeps the source narrow can leave a run of
    /// indentation in the message. The refusals name the operation kendex
    /// declined rather than a git call, because none was made.
    #[test]
    fn a_refusal_reads_as_one_sentence_about_what_kendex_declined() {
        let commit = "abc1234";
        let refusals = [
            no_attributes(commit).unwrap_err().to_string(),
            refused(commit, below_floor(Some("git version 2.34.1")).unwrap()).to_string(),
        ];
        for refusal in refusals {
            assert!(
                !refusal.contains("  "),
                "a run of spaces reached the reader: {refusal}"
            );
            assert!(
                refusal.starts_with(&format!("materializing {commit} failed:")),
                "the refusal names something other than what kendex declined: {refusal}"
            );
            assert!(
                !refusal.contains("git checkout-index"),
                "the refusal names a git call that was never made: {refusal}"
            );
        }
    }
}
