use super::*;

fn answered(line: &str) -> Probe {
    Probe::Answered {
        line: line.to_owned(),
        installed: None,
    }
}

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

    assert_eq!(below_floor(&answered("git version 2.41.0")), None);
    assert_eq!(below_floor(&answered("git version 2.55.0")), None);
    assert_eq!(below_floor(&answered("git version 3.0.0")), None);

    for (line, found) in [
        ("git version 2.40.1", "git 2.40"),
        ("git version 2.39.5 (Apple Git-154)", "git 2.39"),
        ("git version 2.34.1", "git 2.34"),
        ("git version 1.9.1", "git 1.9"),
    ] {
        let refusal = below_floor(&answered(line)).expect("a git below the floor was accepted");
        assert!(refusal.contains(found), "{line}: {refusal}");
        assert!(refusal.contains(NEEDED), "{line}: {refusal}");
    }

    // An answer nothing could read is quoted back, the empty one
    // included — `contains(sample)` would be true of every refusal for
    // that one and so would hold nothing.
    for unreadable in ["", "git version", "hg 5.9"] {
        let refusal =
            below_floor(&answered(unreadable)).expect("an unreadable answer was accepted");
        assert!(
            refusal.contains(&format!("answering \"{unreadable}\"")),
            "{unreadable:?}: {refusal}"
        );
        assert!(refusal.contains(NEEDED), "{unreadable:?}: {refusal}");
    }

    // Three ways of not having a version, and they are three sentences:
    // only the first is about the version, only the second has git's
    // own words to pass on, and only the third is kendex's own failure.
    let refused_by_git = below_floor(&Probe::Refused(
        "fatal: bad config line 1 in file /home/x/.gitconfig".to_owned(),
    ))
    .expect("a git that refused to answer was accepted");
    assert!(
        refused_by_git.contains("bad config line 1 in file /home/x/.gitconfig"),
        "git said what was wrong and kendex dropped it: {refused_by_git}"
    );
    assert!(refused_by_git.contains(NEEDED), "{refused_by_git}");

    let silent = below_floor(&Probe::Silent).expect("a silent probe was accepted");
    assert!(silent.contains("could not run git --version"), "{silent}");
    assert!(silent.contains(NEEDED), "{silent}");
}

/// The three readings, taken off a real git rather than made up: this
/// host's own answers a version, and the same git pointed at a
/// malformed config exits non-zero with the one sentence that fixes
/// the problem. That sentence is what a probe reduced to its stdout
/// throws away.
#[test]
fn a_git_that_refuses_to_answer_is_kept_word_for_word() {
    let answered = probed(Hardened::git(&["--version"], None));
    let Probe::Answered { line, .. } = &answered else {
        panic!("this host's git did not answer its version: {answered:?}");
    };
    assert!(line.starts_with("git version"), "{line}");

    let tmp = tempfile::tempdir().unwrap();
    let malformed = tmp.path().join("gitconfig");
    std::fs::write(&malformed, "this is not a config\n").unwrap();
    let refused = probed(
        Hardened::git(&["--version"], None).env("GIT_CONFIG_GLOBAL", malformed.to_str().unwrap()),
    );
    let Probe::Refused(said) = &refused else {
        panic!("a git that refused to answer was not kept: {refused:?}");
    };
    assert!(
        said.contains("bad config line 1"),
        "git said what was wrong and the probe dropped it: {said}"
    );

    // What a below-floor reading would be asked to say about itself.
    // Only the asking can be shown here — this host's git clears the
    // floor, so nothing on it takes the branch that spends this call.
    let at = exec_path().expect("git did not say where it keeps its programs");
    assert!(at.contains("git"), "{at}");
}

/// Where the git it found keeps its programs, said alongside the version
/// it reported. On a Mac a newer git can sit in another directory while
/// the one kendex reaches is Xcode's, and a refusal naming only the
/// version tells that person to install what they already have.
#[test]
fn a_refusal_names_where_the_git_it_found_keeps_its_programs() {
    let xcode = "/Library/Developer/CommandLineTools/usr/libexec/git-core";
    let refusal = below_floor(&Probe::Answered {
        line: "git version 2.39.5 (Apple Git-154)".to_owned(),
        installed: Some(xcode.to_owned()),
    })
    .expect("a git below the floor was accepted");

    assert!(refusal.contains("git 2.39"), "{refusal}");
    assert!(refusal.contains(xcode), "{refusal}");
}

/// Only a reading that clears the floor is kept, and every other one
/// is asked for again on the next checkout.
///
/// Every other one is a person doing what the refusal told them to. A
/// Mac whose `/usr/bin/git` shim exits non-zero until the command line
/// tools arrive would be told to install them and then refused all the
/// same; a host on 2.34 would be told to upgrade and then refused
/// after upgrading. Remembering either makes the app's own advice take
/// a restart to work.
///
/// The keeping is what bounds the asking, so the count is asserted
/// with it: one spawn for a host that clears the floor, however many
/// checkouts follow.
#[test]
fn only_a_reading_that_clears_the_floor_is_remembered() {
    let cell = Mutex::new(None);
    let probes = std::cell::Cell::new(0);
    let line = |probe: &Probe| match probe {
        Probe::Answered { line, .. } => Some(line.clone()),
        _ => None,
    };
    let ask = |probe: Probe| {
        let mut once = Some(probe);
        line(&reading(&cell, || {
            probes.set(probes.get() + 1);
            once.take().expect("asked twice for one reading")
        }))
    };

    assert_eq!(ask(Probe::Silent), None);
    assert_eq!(ask(Probe::Refused("fatal: nope".to_owned())), None);
    assert_eq!(
        probes.get(),
        2,
        "a failure was remembered instead of asked again"
    );

    let old = "git version 2.34.1";
    assert_eq!(ask(answered(old)).as_deref(), Some(old));
    assert_eq!(ask(answered(old)).as_deref(), Some(old));
    assert_eq!(
        probes.get(),
        4,
        "a git below the floor was remembered, so upgrading it would take a restart"
    );

    let current = "git version 2.55.0";
    assert_eq!(ask(answered(current)).as_deref(), Some(current));
    for _ in 0..29 {
        assert_eq!(
            ask(Probe::Silent).as_deref(),
            Some(current),
            "the reading was not kept, so every checkout would ask again"
        );
    }
    assert_eq!(
        probes.get(),
        5,
        "the reading cost one asking and the 29 checkouts after it cost none"
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
        pinned(&answered("git version 2.41.0"), &commit).unwrap(),
        sha1_empty_tree
    );
    let refusal = pinned(&answered("git version 2.34.1"), &commit)
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
    // one branch left out is the one a space run lands in next. What
    // git said arrives wrapped, so the branch carrying it is given a
    // wrapped sentence here too.
    let said = |probe| refused(commit, below_floor(&probe).unwrap()).to_string();
    let refusals = [
        no_attributes(commit).unwrap_err().to_string(),
        said(answered("git version 2.34.1")),
        said(Probe::Answered {
            line: "git version 2.34.1".to_owned(),
            installed: Some("/usr/lib/git-core".to_owned()),
        }),
        said(answered("hg 5.9")),
        said(Probe::Refused(collapsed(
            b"fatal: bad config line 1\n  in file /home/x/.gitconfig",
        ))),
        said(Probe::Silent),
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
