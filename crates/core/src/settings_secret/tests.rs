use super::*;
use crate::settings_template::TemplateSource;

/// A template declaring one credential, owned by `skill`.
fn declaring(skill: &str, key: &str) -> Vec<DeclaredSecret> {
    declared(
        &[(
            skill.to_owned(),
            TemplateSource::Text(format!("[secrets]\n# The key.\n{key} = \"\"\n")),
        )]
        .into_iter()
        .collect(),
    )
}

fn set(skill: &str, key: &str, value: &str) -> SecretEdit {
    SecretEdit {
        skill: skill.to_owned(),
        key: key.to_owned(),
        value: SecretEditValue::Set {
            value: value.to_owned(),
        },
    }
}

fn clear(skill: &str, key: &str) -> SecretEdit {
    SecretEdit {
        skill: skill.to_owned(),
        key: key.to_owned(),
        value: SecretEditValue::Clear,
    }
}

#[allow(clippy::unwrap_used)]
fn write(text: &str, edits: &[SecretEdit]) -> String {
    apply_edits(
        text,
        edits,
        &declaring("linear", "LINEAR_API_KEY"),
        &[],
        Path::new(".env.local"),
    )
    .unwrap()
    .0
}

/// Every value a loader would read back as something other than what was
/// typed is refused, and the refusal names which one it is. A single
/// quote is the one byte a single-quoted shell string cannot hold, and
/// there is no escape of it both loaders read the same way — so it is
/// refused rather than encoded.
#[test]
fn a_value_no_loader_would_read_back_as_written_is_refused() {
    let rows: [(&str, &str); 5] = [
        ("", "clear the key instead"),
        ("one\ntwo", "line break"),
        ("one\rtwo", "line break"),
        ("it's", "single quote"),
        ("bell\u{7}", "control character"),
    ];
    for (value, said) in rows {
        let Err(problem) = env_file::check_value(value) else {
            panic!("{value:?} was accepted");
        };
        assert!(problem.contains(said), "{value:?}: {problem}");
    }
    // And what a real credential looks like, including the 1Password
    // reference both packages resolve for themselves.
    for value in [
        "lin_api_0aF-9",
        "op://vault/linear/credential",
        "a b#c\"d\\e",
    ] {
        assert_eq!(env_file::check_value(value), Ok(()), "{value}");
    }
}

/// Both loaders take the LAST assignment of a key, so a key kendex failed
/// to see would be appended under one already there and quietly decide
/// what loads. Every shape either loader reads is a shape this sees.
#[test]
fn every_assignment_either_loader_reads_is_seen() {
    let text =
        "PLAIN='a'\n  INDENTED='b'\nexport EXPORTED='c'\nSPACED = 'd'\n# NOT_A_KEY='e'\n1BAD='f'\n";
    let found: Vec<String> = env_file::assignments(text)
        .into_iter()
        .map(|one| one.key)
        .collect();
    assert_eq!(found, ["PLAIN", "INDENTED", "EXPORTED", "SPACED"]);
}

/// What kendex may write over is narrower than what it can read. A line it
/// did not write means something to the shell that a replacement would
/// drop, so the key is reported with its line and left alone.
#[test]
fn a_line_kendex_did_not_write_is_reported_rather_than_rewritten() {
    let rows: [(&str, &str); 5] = [
        ("K='a'\n", "writable"),
        ("K=\"a\"\n", "shape kendex does not write"),
        ("K=$OTHER\n", "shape kendex does not write"),
        ("export K='a'\n", "shape kendex does not write"),
        ("K='a'\nK='b'\n", "assigned more than once"),
    ];
    for (text, said) in rows {
        let standing = env_file::standing(&env_file::assignments(text), "K");
        match (said, &standing) {
            ("writable", env_file::Standing::At(_)) => {}
            (_, env_file::Standing::Blocked { problem, .. }) => {
                assert!(problem.contains(said), "{text:?}: {problem}");
            }
            _ => panic!("{text:?} read as {standing:?}"),
        }
    }
}

/// A secret is appended as a single-quoted assignment, and every other
/// byte of the file stays where it was.
#[test]
fn a_new_key_is_appended_and_nothing_else_moves() {
    let before = "# my keys\nOTHER='kept'\n";
    let after = write(before, &[set("linear", "LINEAR_API_KEY", "lin_api_1")]);
    assert_eq!(
        after,
        "# my keys\nOTHER='kept'\nLINEAR_API_KEY='lin_api_1'\n"
    );
}

/// A file that never ended in a terminator gains one before the new line
/// rather than joining it to the last, and a CRLF file stays one.
#[test]
fn an_appended_line_takes_the_file_s_own_shape() {
    assert_eq!(
        write("OTHER='kept'", &[set("linear", "LINEAR_API_KEY", "k")]),
        "OTHER='kept'\nLINEAR_API_KEY='k'\n"
    );
    assert_eq!(
        write("OTHER='kept'\r\n", &[set("linear", "LINEAR_API_KEY", "k")]),
        "OTHER='kept'\r\nLINEAR_API_KEY='k'\r\n"
    );
    assert_eq!(
        write("", &[set("linear", "LINEAR_API_KEY", "k")]),
        "LINEAR_API_KEY='k'\n"
    );
}

/// Replacing writes over the one line the key sits on. The comment beside
/// it, the keys around it and the file's terminators come through
/// untouched.
#[test]
fn replacing_a_key_leaves_every_other_line_alone() {
    let before = "# top\nA='one'\nLINEAR_API_KEY='old'\n# note\nB='two'\n";
    let after = write(before, &[set("linear", "LINEAR_API_KEY", "new")]);
    assert_eq!(
        after,
        "# top\nA='one'\nLINEAR_API_KEY='new'\n# note\nB='two'\n"
    );
}

/// Clearing takes the assignment out and nothing else.
#[test]
fn clearing_a_key_removes_its_line_and_no_other() {
    let before = "A='one'\nLINEAR_API_KEY='old'\nB='two'\n";
    assert_eq!(
        write(before, &[clear("linear", "LINEAR_API_KEY")]),
        "A='one'\nB='two'\n"
    );
    // A key that is not there is already cleared: nothing is written and
    // nothing is refused.
    assert_eq!(
        write("A='one'\n", &[clear("linear", "LINEAR_API_KEY")]),
        "A='one'\n"
    );
}

/// An edit is written against a declaration. A package that does not
/// declare the key has no field for it, so an edit naming one is a
/// caller writing under somebody else's name.
#[test]
fn an_edit_naming_a_package_that_declares_nothing_is_refused() {
    let refused = apply_edits(
        "",
        &[set("other", "LINEAR_API_KEY", "k")],
        &declaring("linear", "LINEAR_API_KEY"),
        &[],
        Path::new(".env.local"),
    );
    assert!(
        matches!(
            refused,
            Err(crate::error::CoreError::SecretRefused(
                SecretRefusal::Undeclared { .. }
            ))
        ),
        "{refused:?}"
    );
}

/// A key one package declares public and another a credential is refused
/// by this route as well as by the public one. Nothing chooses between
/// two declarations that disagree about where a value may be written.
#[test]
fn a_contested_key_is_refused_and_nothing_is_written() {
    let against = contested(
        &[
            (
                "one".to_owned(),
                TemplateSource::Text("[env]\n# Why.\nSHARED = \"\"\n".to_owned()),
            ),
            (
                "two".to_owned(),
                TemplateSource::Text("[secrets]\n# The key.\nSHARED = \"\"\n".to_owned()),
            ),
        ]
        .into_iter()
        .collect(),
    );
    let refused = apply_edits(
        "",
        &[set("two", "SHARED", "k")],
        &declaring("two", "SHARED"),
        &against,
        Path::new(".env.local"),
    );
    assert!(
        matches!(
            refused,
            Err(crate::error::CoreError::SecretRefused(
                SecretRefusal::Sensitivity { .. }
            ))
        ),
        "{refused:?}"
    );
}

/// Two answers for one key in one save would have the later silently win,
/// and the choice made in the other would be gone with nothing said.
#[test]
fn one_key_answered_twice_in_one_save_is_refused() {
    let refused = apply_edits(
        "",
        &[
            set("linear", "LINEAR_API_KEY", "one"),
            set("linear", "LINEAR_API_KEY", "two"),
        ],
        &declaring("linear", "LINEAR_API_KEY"),
        &[],
        Path::new(".env.local"),
    );
    assert!(
        matches!(
            refused,
            Err(crate::error::CoreError::SecretRefused(
                SecretRefusal::Twice { .. }
            ))
        ),
        "{refused:?}"
    );
}

/// A key already assigned in a shape kendex does not write is refused
/// with the line to look at, and the file is left exactly as it was.
#[test]
fn a_blocked_key_is_refused_with_its_lines() {
    let before = "LINEAR_API_KEY='one'\nLINEAR_API_KEY='two'\n";
    let refused = apply_edits(
        before,
        &[set("linear", "LINEAR_API_KEY", "three")],
        &declaring("linear", "LINEAR_API_KEY"),
        &[],
        Path::new(".env.local"),
    );
    let Err(crate::error::CoreError::SecretRefused(SecretRefusal::Blocked { lines, .. })) = refused
    else {
        panic!("a key assigned twice must be refused: {refused:?}");
    };
    assert_eq!(lines, [1, 2]);
}

/// A refusal is shown to a person, so it carries keys, files and lines
/// and never a value.
#[test]
fn no_refusal_carries_a_value() {
    let said = |edits: &[SecretEdit], text: &str| {
        apply_edits(
            text,
            edits,
            &declaring("linear", "LINEAR_API_KEY"),
            &[],
            Path::new(".env.local"),
        )
        .err()
        .map(|error| error.to_string())
        .unwrap_or_default()
    };
    let secret = "sk-live-must-not-appear";
    for (edits, text) in [
        (vec![set("other", "LINEAR_API_KEY", secret)], ""),
        (
            vec![
                set("linear", "LINEAR_API_KEY", secret),
                set("linear", "LINEAR_API_KEY", secret),
            ],
            "",
        ),
        (
            vec![set("linear", "LINEAR_API_KEY", secret)],
            "LINEAR_API_KEY='a'\nLINEAR_API_KEY='b'\n",
        ),
        (vec![set("linear", "LINEAR_API_KEY", "it's")], ""),
    ] {
        let words = said(&edits, text);
        assert!(!words.is_empty(), "{edits:?} was not refused");
        assert!(!words.contains(secret), "{words}");
    }
}

/// The strict reader is what declares: a template with any defect
/// declares no credential here, so a malformed one cannot smuggle a field
/// past the check that reports it.
#[test]
fn a_template_the_strict_reader_refuses_declares_nothing() {
    let templates = [
        (
            "good".to_owned(),
            TemplateSource::Text("[secrets]\n# The key.\nA = \"\"\n".to_owned()),
        ),
        (
            "bad".to_owned(),
            TemplateSource::Text("[secrets]\nB = \"\"\n".to_owned()),
        ),
        ("gone".to_owned(), TemplateSource::Absent),
        (
            "unread".to_owned(),
            TemplateSource::Unreadable("switched off".to_owned()),
        ),
    ]
    .into_iter()
    .collect();
    let found: Vec<String> = declared(&templates)
        .into_iter()
        .map(|one| format!("{}:{}", one.owner, one.entry.key))
        .collect();
    assert_eq!(found, ["good:A".to_owned()]);
}

/// Two packages agreeing that a key is a credential is not a
/// disagreement: they share it, and it is offered once under each.
#[test]
fn two_packages_declaring_one_secret_do_not_contest_it() {
    let shared = |owner: &str| {
        (
            owner.to_owned(),
            TemplateSource::Text("[secrets]\n# The key.\nSHARED = \"\"\n".to_owned()),
        )
    };
    assert_eq!(
        contested(&[shared("one"), shared("two")].into_iter().collect()),
        []
    );
}

/// The read says a key is set and never what it is set to, and the whole
/// view serialises without one.
#[test]
fn a_read_carries_presence_and_never_a_value() {
    let read = read_of(Some("LINEAR_API_KEY='sk-live-secret'\n"));
    assert_eq!(read.state_of("LINEAR_API_KEY"), SecretState::Set);
    assert_eq!(read.state_of("OTHER"), SecretState::NotSet);
    let shown = serde_json::to_string(&read.view).unwrap_or_default();
    assert!(!shown.contains("sk-live-secret"), "{shown}");
}
