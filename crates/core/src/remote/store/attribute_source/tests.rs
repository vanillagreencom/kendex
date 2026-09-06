use super::*;

/// The floor, held to in both directions on the sentence a person reads:
/// a git below it stops the write and says which git it found, what
/// kendex needs, and what to do; one at or above it names the tree with
/// no `.gitattributes` in it.
///
/// The numbers are written out rather than formatted from `GIT_FLOOR`: a
/// test that builds its expectation from the constant checks the sentence
/// against its own echo and holds nothing. Both neighbours are named,
/// because 2.40 is the value most likely to be reached for by mistake —
/// it is the release that taught `git check-attr` a tree-ish, one short
/// of the release that taught git itself the option.
///
/// The lines are the shapes real hosts print: Apple's command line tools
/// carry a build suffix, the Windows build a fourth number. A git below
/// the floor cannot be installed on the machine running this, so the
/// refusal is held to here instead.
#[test]
fn a_git_below_the_floor_is_refused_and_a_newer_one_writes_the_checkout() {
    let commit = "a".repeat(40);
    let (_, empty_tree) = NO_ATTRIBUTES[0];

    for cleared in [
        "git version 2.41.0",
        "git version 2.47.1.windows.1",
        "git version 2.55.0",
        "git version 3.0.0",
    ] {
        assert_eq!(checked(cleared, &commit).unwrap(), empty_tree, "{cleared}");
    }

    // Every answer that is not a git at the floor or above it, including
    // the ones no version can be read out of at all: the last row is what
    // a git that would not run, would not answer, or is not there leaves.
    for old in [
        "git version 2.40.1",
        "git version 2.39.5 (Apple Git-154)",
        "git version 2.34.1",
        "git version 1.9.1",
        "git version",
        "hg 5.9",
        "",
    ] {
        let refusal = checked(old, &commit)
            .expect_err("a git that cannot write a checkout was accepted")
            .to_string();
        assert!(
            refusal.contains(&format!("answered \"{old}\"")),
            "the refusal does not say which git it found: {refusal}"
        );
        assert!(
            refusal.contains("kendex needs git 2.41 or newer to write a checkout"),
            "the refusal does not say what kendex needs: {refusal}"
        );
        assert!(
            refusal.contains("install a current git and check that git --version answers here"),
            "the refusal does not say what to do about it: {refusal}"
        );
        // The refusal names the operation kendex declined, because no git
        // call was made: a reader sent looking for one in a log would find
        // no counterpart for it.
        assert!(
            refusal.starts_with(&format!("materializing {commit} failed:")),
            "the refusal names something other than what kendex declined: {refusal}"
        );
    }
}

/// The reading the floor is compared against comes off a real git, not a
/// string a test made up, and it arrives as the one line a refusal can
/// quote mid-sentence — git ends its own with a newline.
///
/// Both readings a real git gives are taken here, because they are the two
/// this host can produce: its own answer, which clears the floor, and the
/// same git pointed at a malformed config, which exits non-zero and says
/// what is wrong. That sentence is what a reading reduced to stdout throws
/// away, leaving the refusal quoting nothing.
#[test]
fn a_real_git_is_read_as_one_line_whether_it_answers_or_refuses() {
    let reported = git_version();

    assert!(reported.starts_with("git version "), "{reported}");
    assert!(!reported.contains('\n'), "{reported:?}");
    assert!(clears(&reported), "{reported}");

    let tmp = tempfile::tempdir().unwrap();
    let malformed = tmp.path().join("gitconfig");
    std::fs::write(&malformed, "this is not a config\n").unwrap();
    let refused = answer(
        Hardened::git(&["--version"], None).env("GIT_CONFIG_GLOBAL", malformed.to_str().unwrap()),
    );

    assert!(
        refused.contains("bad config line 1"),
        "git said what was wrong and the reading dropped it: {refused:?}"
    );
    assert!(!clears(&refused), "{refused}");
}

/// A commit id no object format has is refused rather than written under
/// no attribute source at all, which is the one answer that converts in
/// silence. Both formats git has are named, so neither loses its tree to
/// a typo.
#[test]
fn a_commit_id_no_object_format_has_is_refused() {
    let current = "git version 2.41.0";

    for (length, tree) in NO_ATTRIBUTES {
        assert_eq!(checked(current, &"a".repeat(length)).unwrap(), tree);
    }

    let refusal = checked(current, "abc1234")
        .expect_err("an id no object format has was accepted")
        .to_string();
    // Asserted through the join, not up to it: this sentence is the
    // module's one line continuation, and dropping that backslash would
    // ship a run of source indentation to the reader.
    assert!(
        refusal.contains(
            "no object format has ids of 7 characters, so the attribute source this checkout \
             must be written under cannot be named"
        ),
        "{refusal}"
    );
}
