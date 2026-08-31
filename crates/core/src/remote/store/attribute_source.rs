//! What the write has to be told, and the git that has to be able to hear
//! it.
//!
//! A checkout reads its `.gitattributes` out of a tree kendex names rather
//! than out of the commit it is writing, so nothing a catalog committed is
//! in force for any path. Naming that tree can fail two ways, and both end
//! the same: kendex refuses rather than writing a checkout git was free to
//! convert.

use std::sync::{Mutex, PoisonError};

use super::stdout;
use crate::error::{CoreError, Result};
use crate::process::Hardened;

/// This host's answer for this commit: the tree the write reads its
/// attributes from, or the refusal that stops the write before a file
/// exists.
pub(super) fn for_commit(commit: &str) -> Result<&'static str> {
    pinned(git_version().as_deref(), commit)
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

/// Asked once and then remembered — but only once it answers.
///
/// A host does not change its git mid-run, so an answer is worth a process
/// once and never again: a long session materializes many commits and only
/// the first of them spends a spawn. A failure is worth nothing, though,
/// and remembering one would be worse than not asking. `stdout` says
/// `None` for a spawn that did not happen as readily as for a git that is
/// not there, and a Mac without the command line tools installed has a
/// `/usr/bin/git` shim that exits non-zero until they are: remembered,
/// that one refusal would tell the user to install git and then keep
/// refusing after they had. So the answer is kept and the failure is not,
/// and the next checkout asks again.
///
/// The lock is held across the asking, not merely around the remembering,
/// so two publishes starting together spend one spawn between them rather
/// than one each. On the path that fails they each spend one, which is the
/// path that ends in a refusal either way.
fn git_version() -> Option<String> {
    static REPORTED: Mutex<Option<String>> = Mutex::new(None);
    remembered(&REPORTED, || stdout(Hardened::git(&["--version"], None)))
}

/// The remembering itself, given the cell to remember in, so that what it
/// keeps and what it does not can be shown without a git that fails.
fn remembered(
    cell: &Mutex<Option<String>>,
    ask: impl FnOnce() -> Option<String>,
) -> Option<String> {
    let mut kept = cell.lock().unwrap_or_else(PoisonError::into_inner);
    if kept.is_none() {
        *kept = ask();
    }
    kept.clone()
}

/// What a `git --version` line earns, or `None` when it clears the floor.
/// Kept apart from the reading of it so the sentence can be held to on
/// versions no test host has.
fn below_floor(reported: Option<&str>) -> Option<String> {
    let (want_major, want_minor) = GIT_FLOOR;
    let needed = format!(
        "kendex needs git {want_major}.{want_minor} or newer to write a checkout: it is the first git that can be told to read no attributes, and one that cannot be told converts the files in silence"
    );
    match reported.map(|line| (line, version_of(line))) {
        Some((_, Some(found))) if found >= GIT_FLOOR => None,
        Some((_, Some((major, minor)))) => {
            Some(format!("this host runs git {major}.{minor}, and {needed}"))
        }
        // Answered, but not with anything a version could be read out of.
        Some((line, None)) => Some(format!(
            "this host's git did not say which version it is, answering \"{line}\", and {needed}"
        )),
        // Never answered at all, which is a different thing and almost
        // never the user's git: a checkout runs only after a clone or a
        // fetch already spawned git here, so the probe is what did not come
        // back. Saying so keeps the refusal off the wrong suspect.
        None => Some(format!(
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
mod tests {
    use super::*;

    /// The number, written out rather than read back off the constant. The
    /// floor is a promise the README and a **Breaking:** changelog line
    /// both make in words, so a test that formats its expectation from
    /// `GIT_FLOOR` checks the sentence against its own echo and holds
    /// nothing. Both neighbours are named, because 2.40 is the value most
    /// likely to be reached for by mistake: it is the release that taught
    /// `git check-attr` a tree-ish, one short of the release that taught
    /// git itself the option.
    ///
    /// The lines are the shapes real hosts print: Apple's command line
    /// tools carry a build suffix, the Windows build carries a fourth
    /// number. A git below the floor cannot be installed on the machine
    /// running this, so the sentence is held to here instead.
    #[test]
    fn a_git_below_the_floor_is_refused_by_both_versions() {
        const NEEDED: &str = "git 2.41 or newer";

        assert_eq!(below_floor(Some("git version 2.41.0")), None);
        assert_eq!(below_floor(Some("git version 2.55.0")), None);
        assert_eq!(below_floor(Some("git version 3.0.0")), None);

        for (line, found) in [
            ("git version 2.40.1", "git 2.40"),
            ("git version 2.39.5 (Apple Git-154)", "git 2.39"),
            ("git version 2.34.1", "git 2.34"),
            ("git version 1.9.1", "git 1.9"),
        ] {
            let refusal = below_floor(Some(line)).expect("a git below the floor was accepted");
            assert!(refusal.contains(found), "{line}: {refusal}");
            assert!(refusal.contains(NEEDED), "{line}: {refusal}");
        }

        // An answer nothing could read is refused too, and separately from
        // no answer at all: only the first is about the user's git.
        for unreadable in ["", "git version", "hg 5.9"] {
            let refusal = below_floor(Some(unreadable)).expect("an unreadable answer was accepted");
            assert!(refusal.contains(unreadable), "{unreadable:?}: {refusal}");
            assert!(refusal.contains(NEEDED), "{unreadable:?}: {refusal}");
        }
        let silent = below_floor(None).expect("a silent probe was accepted");
        assert!(silent.contains("could not run git --version"), "{silent}");
        assert!(silent.contains(NEEDED), "{silent}");
    }

    /// An answer is kept, a failure is not. Remembering a failure would
    /// outlive its cause: a Mac whose `/usr/bin/git` shim exits non-zero
    /// until the command line tools are installed would be told to install
    /// them and then refused all the same, for the rest of the session.
    /// The keeping is what bounds the asking, so the count is asserted
    /// with it: one spawn for a host that answers, however many checkouts
    /// follow.
    #[test]
    fn only_an_answer_is_remembered_and_only_asked_for_once() {
        let cell = Mutex::new(None);
        let probes = std::cell::Cell::new(0);
        let ask = |answer: Option<&str>| {
            remembered(&cell, || {
                probes.set(probes.get() + 1);
                answer.map(str::to_owned)
            })
        };

        assert_eq!(ask(None), None);
        assert_eq!(ask(None), None);
        assert_eq!(
            probes.get(),
            2,
            "a failure was remembered instead of asked again"
        );

        let answer = Some("git version 2.55.0");
        assert_eq!(ask(answer).as_deref(), answer);
        for _ in 0..29 {
            assert_eq!(
                ask(None).as_deref(),
                answer,
                "the answer was not kept, so every checkout would ask again"
            );
        }
        assert_eq!(
            probes.get(),
            3,
            "the answer cost one asking and the 29 checkouts after it cost none"
        );
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
        // Every refusal the module can write, not a sample of them: the
        // one branch left out is the one a space run lands in next.
        let said = |reported| refused(commit, below_floor(reported).unwrap()).to_string();
        let refusals = [
            no_attributes(commit).unwrap_err().to_string(),
            said(Some("git version 2.34.1")),
            said(Some("hg 5.9")),
            said(None),
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
