use super::*;
const DECLARED: &str = "---\nname: commit-guards\nrepo-effects:\n  summary: Arms git hooks.\n  writes:\n    - .git/hooks/pre-commit\n  installer: scripts/install-git-hooks\n  uninstaller: scripts/install-git-hooks --uninstall\n---\nbody\n";

/// A block with a summary and the field text given, in a package body.
fn block(field: &str) -> String {
    format!("---\nname: x\nrepo-effects:\n  summary: s\n{field}---\nbody\n")
}

/// Every declaration that reads, whole. A summary alone is a
/// declaration, and an explicit null is an absent field, not a shape
/// kendex cannot read; the ordinary written paths read, `.git/` included,
/// which is the whole point of the mapping the refusals below guard; a
/// script path that leaves the package is dropped, so nothing outside it
/// is ever resolved as an installer.
#[test]
fn a_declaration_reads_whole() {
    let summary_only = RepoEffects {
        summary: "s".to_owned(),
        writes: Vec::new(),
        installer: None,
        uninstaller: None,
        removal: None,
        notes: Vec::new(),
        companions: Vec::new(),
    };
    let rows = [
        (
            DECLARED.to_owned(),
            RepoEffects {
                summary: "Arms git hooks.".to_owned(),
                writes: vec![".git/hooks/pre-commit".to_owned()],
                installer: Some("scripts/install-git-hooks".to_owned()),
                uninstaller: Some("scripts/install-git-hooks --uninstall".to_owned()),
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
            },
        ),
        (block(""), summary_only.clone()),
        (block("  writes: ~\n  installer: ~\n"), summary_only.clone()),
        (
            block("  writes:\n    - .git/hooks/pre-commit\n    - ./tools/guard\n"),
            RepoEffects {
                writes: vec![
                    ".git/hooks/pre-commit".to_owned(),
                    "./tools/guard".to_owned(),
                ],
                ..summary_only.clone()
            },
        ),
        (
            block("  writes:\n    - .git/hooks/pre-commit\n"),
            RepoEffects {
                writes: vec![".git/hooks/pre-commit".to_owned()],
                ..summary_only.clone()
            },
        ),
        (block("  installer: /bin/sh\n"), summary_only.clone()),
        (
            block("  installer: ../../elsewhere/run\n"),
            summary_only.clone(),
        ),
        (
            block("  installer: scripts/../../run\n"),
            summary_only.clone(),
        ),
    ];
    for (text, read) in rows {
        assert_eq!(
            declaration(&text),
            Declaration::Effects(read.clone()),
            "{text}"
        );
        assert_eq!(declared(&text), Some(read), "{text}");
    }
}

/// Every package that declares nothing, or declares something kendex
/// cannot read, one row per shape, and which of the two it is. Absent
/// and unreadable are the same `None` to a caller that arms an effect
/// and different answers to one that undoes it: the first package has
/// no uninstaller, the second may have one kendex could not read, and
/// removing the second as though it were the first strands whatever it
/// armed.
///
/// Unreadable: broken YAML, so the key is never even looked for; a block
/// that is not a block; frontmatter that opens and never closes; the key
/// with its colon lost, which is the key written wrong and never a
/// package with nothing to declare; a summary missing, since the
/// disclosure is made of it and without one there is nothing to show
/// and nothing to authorize. A field of the wrong shape refuses the
/// whole declaration, one shape per field because the fail-open
/// (`unwrap_or_default` reading a `writes:` map as empty while the
/// installer went on writing) was per field; a key kendex does not know
/// (`writse:`) is a key it did not read. A written path that leaves the
/// repository is not a written path: these are mapped onto real
/// locations, so a `..` hop or an absolute path names somewhere else,
/// and one that climbed out of the git directory and back in would have
/// been announced as shared by every work tree. A path field is a list
/// and only a list — a comma is a character a filename may contain, so a
/// comma-split scalar read `.git/hooks/a,b` as two files that do not
/// exist — every member says something, and a list with a member kendex
/// cannot read is not a shorter list, because a short list of written
/// paths reads as the complete account it is not.
#[test]
fn a_declaration_that_will_not_read_is_unreadable_and_absent_stays_absent() {
    let rows = [
        (
            "---\nname: deploy\n---\nbody\n".to_owned(),
            Declaration::Absent,
        ),
        ("no frontmatter at all\n".to_owned(), Declaration::Absent),
        (
            "---\nname: x\nrepo-effects:\n  summary: s\n installer: \"scripts/run\n---\nbody\n"
                .to_owned(),
            Declaration::Unreadable,
        ),
        (
            "---\nname: x\nrepo-effects: arms things\n---\nbody\n".to_owned(),
            Declaration::Unreadable,
        ),
        (
            "---\nname: x\nrepo-effects:\n  summary: s\n  uninstaller: scripts/off\nbody\n"
                .to_owned(),
            Declaration::Unreadable,
        ),
        (
            "---\nname: x\nrepo-effects\n  summary: s\n  uninstaller: scripts/off\n---\nbody\n"
                .to_owned(),
            Declaration::Unreadable,
        ),
        (
            "---\nname: x\nrepo-effects:\n  writes:\n    - .git/hooks/pre-commit\n---\n".to_owned(),
            Declaration::Unreadable,
        ),
        (block("  writes:\n    a: b\n"), Declaration::Unreadable),
        (block("  notes:\n    a: b\n"), Declaration::Unreadable),
        (block("  companions:\n    a: b\n"), Declaration::Unreadable),
        (
            block("  installer:\n    - scripts/run\n"),
            Declaration::Unreadable,
        ),
        (block("  uninstaller:\n    a: b\n"), Declaration::Unreadable),
        (
            block("  removal:\n    - by hand\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writse:\n    - .git/hooks/pre-commit\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes:\n    - \".git/../../elsewhere/hook\"\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes:\n    - \"/etc/profile\"\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes:\n    - \"../outside\"\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes:\n    - \"./.git/hooks/../../../x\"\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes: .git/hooks/pre-commit,.git/hooks/commit-msg\n"),
            Declaration::Unreadable,
        ),
        (
            block("  companions: doc-limits,preflight\n"),
            Declaration::Unreadable,
        ),
        (block("  notes: one,two\n"), Declaration::Unreadable),
        (
            block("  writes:\n    - .git/hooks/pre-commit\n    - \"   \"\n"),
            Declaration::Unreadable,
        ),
        (
            block("  writes:\n    - .git/hooks/pre-commit\n    - a: b\n"),
            Declaration::Unreadable,
        ),
        (
            block("  notes:\n    - a real note\n    - a: b\n"),
            Declaration::Unreadable,
        ),
        (
            block("  companions:\n    - doc-limits\n    - a: b\n"),
            Declaration::Unreadable,
        ),
    ];
    for (text, read) in rows {
        assert_eq!(declaration(&text), read, "{text}");
        assert_eq!(declared(&text), None, "arming reads it as nothing: {text}");
    }
}
