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
/// is ever resolved as an installer. The checker field has its own two
/// tiers and its own case below, and a key kendex does not know its own
/// case too: it reads past the key and names it.
#[test]
fn a_declaration_reads_whole() {
    let summary_only = RepoEffects {
        summary: "s".to_owned(),
        writes: Vec::new(),
        installer: None,
        uninstaller: None,
        checker: None,
        staged_checker: None,
        removal: None,
        notes: Vec::new(),
        companions: Vec::new(),
        unknown_keys: Vec::new(),
    };
    let rows = [
        (
            DECLARED.to_owned(),
            RepoEffects {
                summary: "Arms git hooks.".to_owned(),
                writes: vec![".git/hooks/pre-commit".to_owned()],
                installer: Some("scripts/install-git-hooks".to_owned()),
                uninstaller: Some("scripts/install-git-hooks --uninstall".to_owned()),
                checker: None,
                staged_checker: None,
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
                unknown_keys: Vec::new(),
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
            Declaration::Effects(Box::new(read.clone())),
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
/// installer went on writing) was per field. A written path that leaves the
/// repository is not a written path: these are mapped onto real
/// locations, so a `..` hop or an absolute path names somewhere else,
/// and one that climbed out of the git directory and back in would have
/// been announced as shared by every work tree. A path field is a list
/// and only a list — a comma is a character a filename may contain, so a
/// comma-split scalar read `.git/hooks/a,b` as two files that do not
/// exist — every member says something, and a list with a member kendex
/// cannot read is not a shorter list, because a short list of written
/// paths reads as the complete account it is not. The checker block is
/// judged the same way, in its own case below.
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

/// The checker and the staged checker, held to the same rule as the other
/// two scripts: a scalar that stays inside the package reads, a wrong shape
/// refuses the whole declaration, and a path that leaves the package is
/// dropped while the rest stands.
///
/// Nothing else about it is the declaration's to say. What licenses
/// running the checker is kendex's own record of having armed the effect
/// (`repo_effects::armed`), so a declaration has no field to nominate one
/// with and no way to widen when its own script runs.
#[test]
fn the_checker_is_a_script_field_like_the_others() {
    let summary_only = RepoEffects {
        summary: "s".to_owned(),
        writes: Vec::new(),
        installer: None,
        uninstaller: None,
        checker: None,
        staged_checker: None,
        removal: None,
        notes: Vec::new(),
        companions: Vec::new(),
        unknown_keys: Vec::new(),
    };
    let read = [
        (
            block("  checker: scripts/check --read-only\n"),
            RepoEffects {
                checker: Some("scripts/check --read-only".to_owned()),
                staged_checker: None,
                ..summary_only.clone()
            },
        ),
        (
            block("  staged-checker: scripts/check --staged\n"),
            RepoEffects {
                staged_checker: Some("scripts/check --staged".to_owned()),
                ..summary_only.clone()
            },
        ),
        (
            block("  staged-checker: ../../elsewhere/check\n"),
            summary_only.clone(),
        ),
        (block("  checker: ~\n"), summary_only.clone()),
        (
            block("  checker: ../../elsewhere/check\n"),
            summary_only.clone(),
        ),
        (block("  checker: /bin/sh\n"), summary_only.clone()),
        (
            block("  checker: scripts/../../check\n"),
            summary_only.clone(),
        ),
    ];
    for (text, effects) in read {
        assert_eq!(
            declaration(&text),
            Declaration::Effects(Box::new(effects.clone())),
            "{text}"
        );
        assert_eq!(declared(&text), Some(effects), "{text}");
    }
    let refused = [
        block("  checker:\n    - scripts/check\n"),
        block("  checker:\n    script: scripts/check\n"),
        block("  staged-checker:\n    - scripts/check\n"),
    ];
    for text in refused {
        assert_eq!(declaration(&text), Declaration::Unreadable, "{text}");
        assert_eq!(declared(&text), None, "arming reads it as nothing: {text}");
    }
}

/// A key this kendex has no reader for is read past and carried by name,
/// never refused.
///
/// The producer is a catalog key the installed reader predates: the
/// catalog is refreshed on every checkout and the binary is not, so a key
/// added to a declaration reaches readers that have no field for it. The
/// shipped bot-instructions declaration is read here with one key added
/// after every field this reader knows, the shape the next such key takes,
/// and the fields it does know are read as before. A key spelled wrong
/// takes the same route: `writse:` is not a refusal but a key named in the
/// disclosure, where the one person who can see it is mistyped reads it.
/// The required key is still required, and a field of the wrong shape
/// still refuses: those rows stand in the case above.
///
/// The control is the reader before this rule, which refused every row.
#[test]
#[allow(clippy::unwrap_used)]
fn a_key_this_kendex_does_not_know_is_read_past_and_named() {
    let shipped = shipped_declarations().remove("bot-instructions").unwrap();
    let last_known = "  staged-checker: \"scripts/bot-instructions check --staged\"\n";
    assert!(
        shipped.contains(last_known),
        "the shipped declaration moved"
    );
    let ahead = shipped.replace(
        last_known,
        &format!("{last_known}  later-key: \"a field this kendex predates\"\n"),
    );
    let Declaration::Effects(as_shipped) = declaration(&shipped) else {
        panic!("the shipped declaration reads: {:?}", declaration(&shipped));
    };
    // The field before the added key is read, so the row below proves the
    // known fields survive the unknown one rather than two empty reads
    // agreeing.
    assert_eq!(
        as_shipped.staged_checker.as_deref(),
        Some("scripts/bot-instructions check --staged")
    );
    let rows = [
        (
            ahead,
            vec!["later-key".to_owned()],
            RepoEffects {
                unknown_keys: vec!["later-key".to_owned()],
                ..*as_shipped.clone()
            },
        ),
        (
            block("  writse:\n    - .git/hooks/pre-commit\n  installer: scripts/run\n"),
            vec!["writse".to_owned()],
            RepoEffects {
                summary: "s".to_owned(),
                writes: Vec::new(),
                installer: Some("scripts/run".to_owned()),
                uninstaller: None,
                checker: None,
                staged_checker: None,
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
                unknown_keys: vec!["writse".to_owned()],
            },
        ),
    ];
    for (text, unknown, read) in rows {
        let Declaration::Effects(effects) = declaration(&text) else {
            panic!("refused: {text}");
        };
        assert_eq!(effects.unknown_keys, unknown, "{text}");
        assert_eq!(*effects, read, "{text}");
        assert_eq!(declared(&text), Some(read), "{text}");
    }
}

/// Every `repo-effects` declaration this repository's own catalog ships
/// reads whole, with no key this reader does not know.
///
/// The reader reads past a key it has no field for, so a `writse:` in a
/// shipped declaration is a name in the disclosure rather than a refusal,
/// and a key that reaches a declaration before the reader for it ships is
/// the thing `skills/AGENTS.md` forbids. This sweep is where either one in
/// this catalog fails, before it reaches a checkout.
///
/// The discovery is every `skills/*/SKILL.md` the reader finds a
/// declaration in, floored at two and required to hold `bot-instructions`
/// and `commit-guards`, so a walk that finds nothing, or a reader that
/// loses one, fails as a broken sweep rather than passing an empty set.
/// Over-inclusion stays open: a package the reader wrongly sees declaring
/// is swept too, and fails on its own read.
#[test]
#[allow(clippy::unwrap_used)]
fn every_shipped_declaration_reads_with_no_unknown_key() {
    let declarations = shipped_declarations();
    assert!(
        declarations.len() >= 2,
        "the sweep found {} declaring skill(s); the walk is broken, not the catalog sparse: {:?}",
        declarations.len(),
        declarations.keys().collect::<Vec<_>>()
    );
    for required in ["bot-instructions", "commit-guards"] {
        assert!(
            declarations.contains_key(required),
            "{required} declares repo-effects and the sweep did not find it: {:?}",
            declarations.keys().collect::<Vec<_>>()
        );
    }
    for (name, text) in &declarations {
        let Declaration::Effects(effects) = declaration(text) else {
            panic!(
                "{name}: the shipped declaration reads: {:?}",
                declaration(text)
            );
        };
        assert!(
            effects.unknown_keys.is_empty(),
            "{name}: the shipped declaration carries a key this reader does not know, \
             mistyped or ahead of the reader: {:?}",
            effects.unknown_keys
        );
    }
}

/// The catalog's own `SKILL.md` texts the reader finds a declaration in,
/// by skill name. A directory without a `SKILL.md` is not a skill; any
/// other read failure fails the walk, since an unread catalog is never an
/// empty one.
#[allow(clippy::unwrap_used)]
fn shipped_declarations() -> std::collections::BTreeMap<String, String> {
    let skills = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills");
    let mut found = std::collections::BTreeMap::new();
    for entry in std::fs::read_dir(&skills).unwrap() {
        let entry = entry.unwrap();
        if !entry.file_type().unwrap().is_dir() {
            continue;
        }
        let text = match std::fs::read_to_string(entry.path().join("SKILL.md")) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => panic!("{}: {error}", entry.path().display()),
        };
        if declaration(&text) != Declaration::Absent {
            found.insert(entry.file_name().to_string_lossy().into_owned(), text);
        }
    }
    found
}
