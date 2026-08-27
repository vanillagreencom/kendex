use super::*;
const DECLARED: &str = "---\nname: growth-guards\nrepo-effects:\n  summary: Arms git hooks.\n  writes:\n    - .git/hooks/pre-commit\n  installer: scripts/install-git-hooks\n  uninstaller: scripts/install-git-hooks --uninstall\n---\nbody\n";

#[test]
fn a_declaration_reads_whole() {
    let effects = declared(DECLARED).expect("declared");
    assert_eq!(effects.summary, "Arms git hooks.");
    assert_eq!(effects.writes, [".git/hooks/pre-commit"]);
    assert_eq!(
        effects.installer.as_deref(),
        Some("scripts/install-git-hooks")
    );
}

#[test]
fn a_package_declaring_nothing_reads_as_nothing() {
    assert!(declared("---\nname: deploy\n---\nbody\n").is_none());
    assert!(declared("no frontmatter at all\n").is_none());
}

/// A summary is what the disclosure is made of; without one there is
/// nothing to show, so there is nothing to authorize either.
#[test]
fn a_declaration_without_a_summary_is_not_a_declaration() {
    let text = "---\nname: x\nrepo-effects:\n  writes:\n    - .git/hooks/pre-commit\n---\n";
    assert!(declared(text).is_none());
}

/// A field kendex could not read is not a field with nothing in it.
///
/// `unwrap_or_default` could not tell "absent" from "present and not a
/// list", so a `writes:` written as a map — an easy thing to do by hand
/// — disclosed no written paths while the installer went on writing
/// them. One shape per field, because the fail-open was per field.
#[test]
fn a_field_of_the_wrong_shape_refuses_the_whole_declaration() {
    let wrong = [
        "  writes:\n    a: b\n",
        "  notes:\n    a: b\n",
        "  companions:\n    a: b\n",
        "  installer:\n    - scripts/run\n",
        "  uninstaller:\n    a: b\n",
        "  removal:\n    - by hand\n",
        // A key kendex does not know is a key it did not read: `writse:`
        // is a package declaring what it writes and a block naming none
        // of it, with the installer writing it regardless.
        "  writse:\n    - .git/hooks/pre-commit\n",
    ];
    for field in wrong {
        let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n");
        assert!(
            declared(&text).is_none(),
            "a malformed field was read as empty: {field}"
        );
    }
}

/// A written path that leaves the repository is not a written path.
///
/// These strings are mapped onto real locations for the block, so a
/// `..` hop or an absolute path names somewhere else — and one that
/// climbed out of the git directory and back in would have been
/// announced as shared by every work tree of the repository.
#[test]
fn a_written_path_that_escapes_refuses_the_declaration() {
    let escaping = [
        ".git/../../elsewhere/hook",
        "/etc/profile",
        "../outside",
        "./.git/hooks/../../../x",
    ];
    for path in escaping {
        let text = format!(
            "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - \"{path}\"\n---\nbody\n"
        );
        assert!(
            declared(&text).is_none(),
            "an escaping written path was accepted: {path}"
        );
    }

    // The ordinary ones still read, `.git/` included — that is the
    // whole point of the mapping this guards.
    let good = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n    - ./tools/guard\n---\nbody\n";
    let effects = declared(good).expect("contained paths read");
    assert_eq!(effects.writes.len(), 2);
}

/// A path field is a list, and only a list.
///
/// The reader these grew from also took a scalar and split it on commas.
/// Every one of these fields is a list of PATHS, and a comma is a
/// character a filename may contain — so `.git/hooks/a,b` would have
/// been read as two files that do not exist, in the block a person
/// authorizes. And a member that trims to nothing is dropped by that
/// same reader, which comes back as a shorter list.
#[test]
fn a_path_field_is_a_list_and_every_member_says_something() {
    let not_lists = [
        "  writes: .git/hooks/pre-commit,.git/hooks/commit-msg\n",
        "  companions: size-ratchet,preflight\n",
        "  notes: one,two\n",
    ];
    for field in not_lists {
        let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n");
        assert!(
            declared(&text).is_none(),
            "a comma-separated scalar was read as a list: {field}"
        );
    }

    let empty_member = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n    - \"   \"\n---\nbody\n";
    assert!(
        declared(empty_member).is_none(),
        "a member that says nothing came back as a shorter list"
    );

    // A real list of one still reads, which is what the rule is for.
    let good = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n---\nbody\n";
    assert_eq!(declared(good).expect("a list reads").writes.len(), 1);
}

/// A list with a member kendex cannot read is not a shorter list.
///
/// `string_list` drops what it cannot read, so a `writes:` with one map
/// among its paths came back short — and a short list of written paths
/// is worse than none, because it reads as the complete account it is
/// not.
#[test]
fn a_list_with_an_unreadable_member_refuses_the_declaration() {
    let mixed = [
        "  writes:\n    - .git/hooks/pre-commit\n    - a: b\n",
        "  notes:\n    - a real note\n    - a: b\n",
        "  companions:\n    - size-ratchet\n    - a: b\n",
    ];
    for field in mixed {
        let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n");
        assert!(
            declared(&text).is_none(),
            "a list came back short instead of refusing: {field}"
        );
    }

    // And a list of scalars is still a list of scalars.
    let good = "---\nname: x\nrepo-effects:\n  summary: s\n  writes:\n    - .git/hooks/pre-commit\n    - .git/hooks/commit-msg\n---\nbody\n";
    let effects = declared(good).expect("a list of paths is readable");
    assert_eq!(effects.writes.len(), 2);
}

/// Absent stays absent. The refusal above must not turn every package
/// that declares only a summary into one kendex cannot read.
#[test]
fn an_absent_field_is_absent_and_the_declaration_stands() {
    let text = "---\nname: x\nrepo-effects:\n  summary: s\n---\nbody\n";
    let effects = declared(text).expect("a summary alone is a declaration");
    assert_eq!(effects.summary, "s");
    assert!(effects.writes.is_empty());
    assert!(effects.notes.is_empty());
    assert!(effects.companions.is_empty());
    assert_eq!(effects.installer, None);
    assert_eq!(effects.uninstaller, None);
    assert_eq!(effects.removal, None);

    // An explicit null is absent too, not a shape kendex cannot read.
    let nulls =
        "---\nname: x\nrepo-effects:\n  summary: s\n  writes: ~\n  installer: ~\n---\nbody\n";
    let effects = declared(nulls).expect("an explicit null is absent");
    assert!(effects.writes.is_empty());
    assert_eq!(effects.installer, None);
}

/// A path that leaves the package is dropped, so nothing outside it is
/// ever resolved as an installer.
#[test]
fn an_escaping_script_path_is_dropped() {
    for path in ["/bin/sh", "../../elsewhere/run", "scripts/../../run"] {
        let text = format!("---\nname: x\nrepo-effects:\n  summary: s\n  installer: {path}\n---\n");
        let effects = declared(&text).expect("declared");
        assert_eq!(effects.installer, None, "{path} was accepted");
    }
}
