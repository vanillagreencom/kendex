use std::path::Path;

use super::*;
use crate::error::CoreError;
use crate::settings_seed::{EnvEntry, SeededEnv};

fn seeded(owner: &str, key: &str, line: &str) -> SeededEnv {
    SeededEnv {
        entry: EnvEntry {
            key: key.to_owned(),
            comment: vec![format!("# what {key} does")],
            assignment: line.to_owned(),
            required: false,
        },
        owner: owner.to_owned(),
    }
}

fn set(skill: &str, key: &str, value: &str) -> SettingsEdit {
    SettingsEdit {
        skill: skill.to_owned(),
        key: key.to_owned(),
        value: SettingsEditValue::Set {
            value: value.to_owned(),
        },
    }
}

fn current(text: &str, key: &str) -> Current {
    current_of(&sites(text), key)
}

const FILE: &str = "[env]\n# how loud\nMODE = \"quiet\" # a trailing note\nOTHER = \"x\"\n";

#[test]
fn a_lone_env_assignment_is_the_one_state_a_default_compares_against() {
    assert_eq!(
        current(FILE, "MODE"),
        Current::Value {
            value: "quiet".to_owned(),
            line: 3,
        }
    );
    assert_eq!(current(FILE, "ABSENT"), Current::Absent);
}

/// Every shape that has something there and no value to show. Each names
/// the lines, because settling it is a person's job and they need to know
/// where to look.
#[test]
fn what_is_in_the_way_is_named_by_its_lines_rather_than_guessed_at() {
    let twice = "[env]\nMODE = \"a\"\nMODE = \"b\"\n";
    assert!(matches!(
        current(twice, "MODE"),
        Current::Ambiguous { lines, .. } if lines == vec![2, 3]
    ));

    // One inside, one outside: seeding's presence check is file-wide, so
    // both count and the key is no clearer for it.
    let split = "[other]\nMODE = \"a\"\n\n[env]\nMODE = \"b\"\n";
    assert!(matches!(
        current(split, "MODE"),
        Current::Ambiguous { lines, .. } if lines == vec![2, 5]
    ));

    let outside = "[other]\nMODE = \"a\"\n";
    assert!(matches!(
        current(outside, "MODE"),
        Current::Ambiguous { problem, lines }
            if lines == vec![2] && problem.contains("outside the [env] table")
    ));

    // A quoted key seeds nothing over and no shell exports it.
    let quoted = "[env]\n\"MODE\" = \"a\"\n";
    assert!(matches!(
        current(quoted, "MODE"),
        Current::Ambiguous { problem, .. } if problem.contains("not a name a shell can export")
    ));

    // A value the loaders refuse: multi-line, and a bare word.
    for text in ["[env]\nMODE = \"\"\"a\"\"\"\n", "[env]\nMODE = 3\n"] {
        assert!(
            matches!(current(text, "MODE"), Current::Ambiguous { .. }),
            "{text}"
        );
    }
}

/// The grammar an edit is held to is the loaders', spelled once: what
/// cannot survive a round trip through one double-quoted line is refused
/// rather than written and silently misread.
#[test]
fn a_value_that_no_quoted_line_could_hold_is_refused() {
    assert!(check_value("plain words, # and punctuation").is_ok());
    assert!(check_value("").is_ok());
    assert!(check_value("two\nlines").is_err());
    assert!(check_value("a \"quote\"").is_err());
    assert!(check_value("a \\ backslash").is_err());
}

/// The whole point of splicing rather than rewriting: an edit moves the
/// value's characters and nothing else — not the comment beside it, not
/// the blank lines, not the file's CRLF terminators.
#[test]
fn an_edit_moves_the_value_span_and_leaves_every_other_byte_alone() {
    let crlf = "# header\r\n\r\n[env]\r\n# how loud\r\nMODE = \"quiet\" # a trailing note\r\nOTHER = \"x\"\r\n";
    let (out, changed) = apply_edits(
        crlf,
        &[set("noise", "MODE", "loud")],
        &[seeded("noise", "MODE", "MODE = \"quiet\"")],
        Path::new("/w/kendex.settings.toml"),
    )
    .unwrap();
    assert_eq!(changed, vec!["MODE".to_owned()]);
    assert_eq!(
        out,
        "# header\r\n\r\n[env]\r\n# how loud\r\nMODE = \"loud\" # a trailing note\r\nOTHER = \"x\"\r\n"
    );
}

/// Two edits in one pass. The second's span is read after the first has
/// moved every byte behind it — a span read once for both would write
/// into the wrong characters as soon as the values differ in length.
#[test]
fn a_second_edit_writes_where_the_first_one_left_the_file() {
    let templates = [
        seeded("noise", "MODE", "MODE = \"quiet\""),
        seeded("noise", "OTHER", "OTHER = \"x\""),
    ];
    let (out, changed) = apply_edits(
        FILE,
        &[
            set("noise", "MODE", "considerably louder"),
            set("noise", "OTHER", "y"),
        ],
        &templates,
        Path::new("/w/kendex.settings.toml"),
    )
    .unwrap();
    assert_eq!(changed, vec!["MODE".to_owned(), "OTHER".to_owned()]);
    assert_eq!(
        out,
        "[env]\n# how loud\nMODE = \"considerably louder\" # a trailing note\nOTHER = \"y\"\n"
    );
}

#[test]
fn a_value_already_in_the_file_is_not_a_change() {
    let (out, changed) = apply_edits(
        FILE,
        &[set("noise", "MODE", "quiet")],
        &[seeded("noise", "MODE", "MODE = \"quiet\"")],
        Path::new("/w/kendex.settings.toml"),
    )
    .unwrap();
    assert!(changed.is_empty());
    assert_eq!(out, FILE);
}

#[test]
fn a_reset_writes_the_named_skill_template_default() {
    let (out, _) = apply_edits(
        FILE,
        &[SettingsEdit {
            skill: "noise".to_owned(),
            key: "MODE".to_owned(),
            value: SettingsEditValue::Reset,
        }],
        &[seeded("noise", "MODE", "MODE = \"stock\"")],
        Path::new("/w/kendex.settings.toml"),
    )
    .unwrap();
    assert!(out.contains("MODE = \"stock\" # a trailing note"), "{out}");
}

/// The declaration is what an edit is checked against, so the skill it
/// names has to be the one that ships the key. Otherwise a value could be
/// written under a package that never explained it.
#[test]
fn an_edit_naming_a_skill_that_does_not_ship_the_key_is_refused() {
    let templates = [seeded("noise", "MODE", "MODE = \"quiet\"")];
    for edit in [set("other", "MODE", "loud"), set("noise", "NOPE", "loud")] {
        let refused = apply_edits(FILE, &[edit], &templates, Path::new("/w/f.toml")).unwrap_err();
        assert!(
            matches!(
                refused,
                CoreError::SettingsRefused(SettingsRefusal::Undeclared { .. })
            ),
            "{refused:?}"
        );
    }
}

/// A key nothing here can read is a key nothing here writes: picking one
/// of two assignments would leave the other deciding what the scripts see.
#[test]
fn an_edit_on_an_unreadable_key_refuses_and_names_the_lines() {
    let twice = "[env]\nMODE = \"a\"\nMODE = \"b\"\n";
    let refused = apply_edits(
        twice,
        &[set("noise", "MODE", "c")],
        &[seeded("noise", "MODE", "MODE = \"quiet\"")],
        Path::new("/w/kendex.settings.toml"),
    )
    .unwrap_err();
    let CoreError::SettingsRefused(SettingsRefusal::Ambiguous { lines, .. }) = &refused else {
        panic!("{refused:?}");
    };
    assert_eq!(lines, &[2, 3]);
    assert!(refused.to_string().contains("lines 2, 3"), "{refused}");
    assert!(
        refused.to_string().contains("/w/kendex.settings.toml"),
        "{refused}"
    );
}

#[test]
fn a_value_the_grammar_refuses_never_reaches_the_file() {
    let refused = apply_edits(
        FILE,
        &[set("noise", "MODE", "a \"quoted\" word")],
        &[seeded("noise", "MODE", "MODE = \"quiet\"")],
        Path::new("/w/f.toml"),
    )
    .unwrap_err();
    assert!(
        matches!(
            refused,
            CoreError::SettingsRefused(SettingsRefusal::Value { .. })
        ),
        "{refused:?}"
    );
}

#[test]
fn one_line_reads_as_one_line_however_it_is_written() {
    assert_eq!(lines_phrase(&[7]), "line 7");
    assert_eq!(lines_phrase(&[7, 12]), "lines 7, 12");
}

/// The corruption this reader exists to stop. Read a line at a time,
/// `MODE` here is an assignment inside `BLOB`, the view shows `shadow` as
/// its value, and an edit writes over bytes in the middle of somebody
/// else's string.
#[test]
fn a_key_that_only_exists_inside_a_multiline_value_is_absent_and_unwritable() {
    for open in ["\"\"\"", "'''"] {
        let file = format!("[env]\n# what it holds\nBLOB = {open}\nMODE = \"shadow\"\n{open}\n");
        assert_eq!(current(&file, "MODE"), Current::Absent, "{open}");
        assert!(
            !sites(&file).iter().any(|site| site.key == "MODE"),
            "{open}"
        );

        // And an edit naming it refuses rather than writing into BLOB.
        let refused = apply_edits(
            &file,
            &[set("noise", "MODE", "loud")],
            &[seeded("noise", "MODE", "MODE = \"quiet\"")],
            Path::new("/w/kendex.settings.toml"),
        )
        .unwrap_err();
        assert!(
            matches!(
                refused,
                CoreError::SettingsRefused(SettingsRefusal::Value { .. })
            ),
            "{open}: {refused:?}"
        );
    }
}

/// TOML reads all three spellings as one key, and the shell loaders read
/// only the bare one. So a quoted spelling is ambiguous — never absent,
/// which would let seeding insert the same key a second time and stop the
/// file loading at all.
#[test]
fn either_quoted_spelling_is_ambiguous_and_blocks_a_seed() {
    for spelling in ["\"MODE\"", "'MODE'", "\"MO\\u0044E\""] {
        let file = format!("[env]\n{spelling} = \"a\"\n");
        assert!(
            matches!(
                current(&file, "MODE"),
                Current::Ambiguous { ref problem, ref lines }
                    if lines == &[2] && problem.contains("quoted key")
            ),
            "{spelling}: {:?}",
            current(&file, "MODE")
        );
        assert!(
            crate::settings_seed::assigned_keys(&file).contains(&"MODE".to_owned()),
            "{spelling} must block a seed of MODE"
        );
        assert!(
            crate::settings_seed::merge(
                Some(&file),
                &[seeded("noise", "MODE", "MODE = \"q\"")],
                &crate::settings_seed::Seeding::new([], ["MODE".to_owned()]),
            )
            .is_none(),
            "{spelling} must not be seeded over"
        );
    }
}

/// A dotted key declares its first segment as a table: `MODE.part` makes
/// `MODE` a table, not a value any script reads. So `MODE` is ambiguous
/// rather than absent — absent would let seeding write a scalar `MODE`
/// beside it, defining `env.MODE` twice and stopping the file loading.
#[test]
fn a_dotted_key_is_ambiguous_and_blocks_a_seed_of_its_first_segment() {
    for spelling in ["MODE.part", "MODE.\"part\"", "\"MODE\".part"] {
        let file = format!("[env]\n{spelling} = \"a\"\n");
        assert!(
            matches!(
                current(&file, "MODE"),
                Current::Ambiguous { ref problem, ref lines }
                    if lines == &[2] && problem.contains("dotted key")
            ),
            "{spelling}: {:?}",
            current(&file, "MODE")
        );
        assert!(
            crate::settings_seed::assigned_keys(&file).contains(&"MODE".to_owned()),
            "{spelling} must block a seed of MODE"
        );
        assert!(
            crate::settings_seed::merge(
                Some(&file),
                &[seeded("noise", "MODE", "MODE = \"q\"")],
                &crate::settings_seed::Seeding::new([], ["MODE".to_owned()]),
            )
            .is_none(),
            "{spelling} must not be seeded over"
        );

        // And the edit refuses through the span it never produced.
        let refused = apply_edits(
            &file,
            &[set("noise", "MODE", "loud")],
            &[seeded("noise", "MODE", "MODE = \"quiet\"")],
            Path::new("/w/kendex.settings.toml"),
        )
        .unwrap_err();
        assert!(
            matches!(
                refused,
                CoreError::SettingsRefused(SettingsRefusal::Ambiguous { .. })
            ),
            "{spelling}: {refused:?}"
        );
    }
}

/// The same shape reaching the editor: a key that exists only inside a
/// string an array element opened is not a site, so no span is ever
/// produced for it and an edit naming it refuses.
#[test]
fn a_key_inside_a_string_an_array_element_opened_is_not_writable() {
    for open in ["\"\"\"", "'''"] {
        let file = format!("BLOB = [\n  [{open}\n[env]\nMODE = \"shadow\"\n{open}]\n]\n");
        // Without the carried state this reads as a writable value with a
        // span inside BLOB — a save would put the new bytes in the middle
        // of somebody else's string.
        assert_eq!(current(&file, "MODE"), Current::Absent, "{open}");
        assert!(sites(&file).iter().all(|site| site.key != "MODE"), "{open}");
        let refused = apply_edits(
            &file,
            &[set("noise", "MODE", "loud")],
            &[seeded("noise", "MODE", "MODE = \"quiet\"")],
            Path::new("/w/kendex.settings.toml"),
        )
        .unwrap_err();
        assert!(
            matches!(
                refused,
                CoreError::SettingsRefused(SettingsRefusal::Value { .. })
            ),
            "{open}: {refused:?}"
        );
    }
}

/// A control character between the quotes is not TOML and is not
/// something the shell loader survives either, so the grammar refuses it
/// where it refuses the rest.
#[test]
fn a_control_character_never_reaches_the_file() {
    assert!(check_value("plain words").is_ok());
    assert!(check_value("a\ttab is fine").is_ok());
    for bad in ["a\0b", "a\u{1}b", "a\u{7f}b", "a\u{1b}[0m"] {
        assert!(check_value(bad).is_err(), "{bad:?}");
    }
    let refused = apply_edits(
        FILE,
        &[set("noise", "MODE", "a\0b")],
        &[seeded("noise", "MODE", "MODE = \"quiet\"")],
        Path::new("/w/f.toml"),
    )
    .unwrap_err();
    assert!(
        matches!(
            refused,
            CoreError::SettingsRefused(SettingsRefusal::Value { .. })
        ),
        "{refused:?}"
    );
}

/// Two skills can declare one key — the shared-key conflict note exists
/// because they do — so the view shows that key under each of them and a
/// save can carry an edit from both rows. Applied in sequence the later
/// one silently wins and the person's other choice is gone with nothing
/// said. Two edits that agree are not a disagreement; two that differ are
/// refused, because losing what somebody typed is worse than refusing it.
#[test]
fn two_edits_on_one_key_agree_or_the_save_refuses() {
    let templates = [
        seeded("noise", "MODE", "MODE = \"quiet\""),
        seeded("other", "MODE", "MODE = \"loud\""),
    ];
    let agreeing = [set("noise", "MODE", "same"), set("other", "MODE", "same")];
    let (out, changed) = apply_edits(FILE, &agreeing, &templates, Path::new("/w/f.toml")).unwrap();
    assert_eq!(changed, vec!["MODE".to_owned()], "one key, applied once");
    assert!(out.contains("MODE = \"same\" # a trailing note"), "{out}");

    let differing = [set("noise", "MODE", "mine"), set("other", "MODE", "theirs")];
    let refused = apply_edits(FILE, &differing, &templates, Path::new("/w/f.toml")).unwrap_err();
    let CoreError::SettingsRefused(SettingsRefusal::Contested { key, wanted, .. }) = &refused
    else {
        panic!("{refused:?}");
    };
    assert_eq!(key, "MODE");
    assert_eq!(wanted, &["mine".to_owned(), "theirs".to_owned()]);
    // And nothing is written: the file is not half-saved.
    assert!(refused.to_string().contains("noise"), "{refused}");
    assert!(refused.to_string().contains("other"), "{refused}");

    // A reset resolves against each skill's own default, so two resets on
    // one key disagree exactly when the skills ship different defaults.
    let resets = [
        SettingsEdit {
            skill: "noise".to_owned(),
            key: "MODE".to_owned(),
            value: SettingsEditValue::Reset,
        },
        SettingsEdit {
            skill: "other".to_owned(),
            key: "MODE".to_owned(),
            value: SettingsEditValue::Reset,
        },
    ];
    assert!(apply_edits(FILE, &resets, &templates, Path::new("/w/f.toml")).is_err());
}
