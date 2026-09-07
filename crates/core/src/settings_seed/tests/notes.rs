//! What the plan says before a byte is written: shared keys with
//! different defaults, and keys no template can supply.

use super::*;
// Not re-exported from the seed: `seed_notes` is the one call a caller
// takes, and half an answer is a key silently left out. Here the halves
// are the subject, so the tests reach the module itself.
use crate::settings_seed::notes::unanswered_notes;

/// Every `[env]` entry each named owner's template ships, in the order the
/// owners are given — the order seeding resolves a shared key in.
fn shipped(owners: &[(&str, &str)]) -> Vec<SeededEnv> {
    owners
        .iter()
        .flat_map(|(owner, template)| seeded(template, owner))
        .collect()
}

/// The conflict notes for a pass that writes every key it is handed, into
/// a file that assigns none of them — where the note has an owner to name.
fn conflict_notes_all(entries: &[SeededEnv]) -> Vec<String> {
    conflict_notes(entries, &super::nothing(entries), &super::all(entries))
}

/// The one conflict note a key gets, whole: the defaults grouped by the
/// owners shipping each, and the owner whose value is written.
fn disagreement(key: &str, defaults: &str, written: &str) -> String {
    format!(
        "kendex.settings.toml {key}: packages ship different defaults — {defaults} — {written}'s is the one written, so set the value yourself if that is not the one you want"
    )
}

/// One row per set of templates sharing a key, and the conflict notes
/// they get. One note groups every owner and every distinct default, and
/// names the owner whose value merge actually seeds: alpha's default
/// carrying a trailing comment, which the loaders read and a stricter
/// decoder once threw away — dropping alpha from the note and naming beta
/// as the package whose value lands. A default no decoder reads still
/// names its owner. Packages agreeing on a shared key, a key only one
/// package ships, and a trailing comment on the same value say nothing.
/// Two packages shipping one key with different multiline values do
/// disagree, and shown from the `=` line alone both read as a bare `"""`
/// and would group as agreeing, so each value is shown whole on the one
/// line; two defaults that differ only in what the display collapses (the
/// display joins a value's lines with a space, so `a\nb` and `a b` render
/// alike) are still two defaults; and two shipping the same multiline
/// value still say nothing. Catalog text reaches a note escaped.
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one table: eleven template sets judged by one note builder, each row a set of its own"
)]
fn a_shared_key_gets_one_conflict_note_or_none() {
    /// The owners and their templates, and the notes they get.
    type Row = (Vec<(&'static str, String)>, Vec<String>);
    let blob = |body: &str| format!("[env]\n# A blob.\nBLOB = \"\"\"\n{body}\n\"\"\"\n");
    let rows: Vec<Row> = vec![
        (
            vec![
                ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n".to_owned()),
                ("beta", "[env]\n# Wait.\nWAIT = \"900\"\n".to_owned()),
                ("gamma", "[env]\n# Wait.\nWAIT = \"600\"\n".to_owned()),
            ],
            vec![disagreement(
                "WAIT",
                "\"900\" (alpha, beta), \"600\" (gamma)",
                "alpha",
            )],
        ),
        (
            vec![
                (
                    "alpha",
                    "[env]\n# Mode.\nMODE = \"enforce\"\n# Wait.\nWAIT = \"900\"\n".to_owned(),
                ),
                (
                    "beta",
                    "[env]\n# Mode.\nMODE = \"enforce\"\n# Wait.\nWAIT = \"900\"\n".to_owned(),
                ),
            ],
            vec![],
        ),
        (
            vec![
                ("alpha", "[env]\n# Depth.\nDEPTH = \"2\"\n".to_owned()),
                ("beta", "[env]\n# Width.\nWIDTH = \"3\"\n".to_owned()),
            ],
            vec![],
        ),
        (
            vec![
                (
                    "alpha",
                    "[env]\n# Wait.\nWAIT = \"900\" # seconds\n".to_owned(),
                ),
                ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n".to_owned()),
                ("gamma", "[env]\n# Wait.\nWAIT = \"300\"\n".to_owned()),
            ],
            vec![disagreement(
                "WAIT",
                "\"900\" (alpha), \"600\" (beta), \"300\" (gamma)",
                "alpha",
            )],
        ),
        (
            vec![
                ("alpha", "[env]\n# Wait.\nWAIT = 900\n".to_owned()),
                ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n".to_owned()),
            ],
            vec![disagreement("WAIT", "900 (alpha), \"600\" (beta)", "alpha")],
        ),
        (
            vec![
                ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n".to_owned()),
                (
                    "beta",
                    "[env]\n# Wait.\nWAIT = \"900\" # seconds\n".to_owned(),
                ),
            ],
            vec![],
        ),
        (
            vec![
                (
                    "alpha",
                    "[env]\n# Wait.\nWAIT = \"90\u{1b}[31m0\"\n".to_owned(),
                ),
                (
                    "be\u{1b}[31mta",
                    "[env]\n# Wait.\nWAIT = \"600\"\n".to_owned(),
                ),
            ],
            vec![disagreement(
                "WAIT",
                "\"90\\u{1b}[31m0\" (alpha), \"600\" (be\\u{1b}[31mta)",
                "alpha",
            )],
        ),
        (
            vec![("a", blob("from a")), ("b", blob("from b"))],
            vec![disagreement(
                "BLOB",
                "\"\"\" from a \"\"\" (a), \"\"\" from b \"\"\" (b)",
                "a",
            )],
        ),
        (vec![("a", blob("same")), ("b", blob("same"))], vec![]),
        (
            vec![("split", blob("a\nb")), ("joined", blob("a b"))],
            vec![disagreement(
                "BLOB",
                "\"\"\" a b \"\"\" (split), \"\"\" a b \"\"\" (joined)",
                "split",
            )],
        ),
        (vec![("one", blob("a\nb")), ("two", blob("a\nb"))], vec![]),
    ];
    for (owners, notes) in rows {
        let entries: Vec<SeededEnv> = owners
            .iter()
            .flat_map(|(owner, template)| seeded(template, owner))
            .collect();
        assert_eq!(conflict_notes_all(&entries), notes, "{owners:?}");
    }
}

/// The owner the note names is what merge writes: alpha's default, with
/// its trailing comment, is the value that lands.
#[test]
fn merge_writes_the_value_of_the_owner_the_note_names() {
    let entries = shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\" # seconds\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
        ("gamma", "[env]\n# Wait.\nWAIT = \"300\"\n"),
    ]);
    let (merged, added) = merge(None, &entries, &super::all(&entries)).unwrap();
    assert_eq!(added, ["WAIT"]);
    assert!(merged.contains("WAIT = \"900\" # seconds"), "{merged}");
}

/// The display cannot tell `a\nb` from `a b`; the key the note groups on
/// still must.
#[test]
fn the_display_collapses_what_the_default_key_keeps_apart() {
    let template = |body: &str| format!("[env]\n# A blob.\nBLOB = \"\"\"\n{body}\n\"\"\"\n");
    let mut shipped = seeded(&template("a\nb"), "split");
    shipped.extend(seeded(&template("a b"), "joined"));
    assert_eq!(shipped[0].default_shown(), shipped[1].default_shown());
    assert_ne!(shipped[0].default_key(), shipped[1].default_key());
}

/// A marked key nothing answers, on the ordinary pass: nothing arriving,
/// nothing edited, and a file that assigns none of it.
fn unanswered_now(entries: &[SeededEnv]) -> Vec<String> {
    unanswered_notes(entries, &super::nothing(entries), &Seeding::default())
}

/// Every skill that wants the key decided is named, on the one line.
/// Naming the first alone sends a person to change one template while the
/// rest go on wanting the same answer.
#[test]
fn one_unanswered_note_names_every_owner_that_wants_the_key() {
    let marked = "[env]\n# The team.\nTEAM = \"\" # required\n";
    let notes = unanswered_now(&shipped(&[
        ("alpha", marked),
        ("beta", marked),
        ("gamma", marked),
    ]));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml TEAM: alpha, beta, gamma needs this key decided and nothing here assigns it — no default stands in for it, so set it yourself"
        ]
    );
}

/// The note is about a gap, so the pass that closes it says nothing. Asked
/// only whether the file assigns the key, an arrival reports the very key
/// it is writing on the way past — the one pass where there is nothing for
/// anyone to do.
#[test]
fn the_pass_that_writes_the_key_is_silent_and_the_pass_that_does_not_names_it() {
    let entries = shipped(&[("alpha", "[env]\n# The team.\nTEAM = \"\" # required\n")]);
    let unread = Answered::read(Some("[env]\n"), &entries);

    // The arrival that writes it, and the save that sets it.
    for writing in [
        Seeding::new(["alpha".to_owned()], []),
        Seeding::new([], ["TEAM".to_owned()]),
    ] {
        assert!(
            unanswered_notes(&entries, &unread, &writing).is_empty(),
            "{:?}",
            unanswered_notes(&entries, &unread, &writing)
        );
        // And the write is real, so the silence is not a claim about
        // nothing: the same seeding puts the key in the file.
        let (text, added) = merge(Some("[env]\n"), &entries, &writing).expect("TEAM is missing");
        assert_eq!(added, ["TEAM"]);
        assert!(text.contains("TEAM = \"\""), "{text}");
    }

    // Same entries, same file, a pass that writes none of it: the gap is
    // named. Somebody else arriving does not answer this skill's key.
    let elsewhere = Seeding::new(["elsewhere".to_owned()], []);
    let notes = unanswered_notes(&entries, &unread, &elsewhere);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("TEAM"), "{notes:?}");
    assert!(notes[0].contains("alpha"), "{notes:?}");
}

/// Owner names come from a catalog a download supplied, and the note is
/// read on a terminal: what reaches it is escaped, the way
/// `a_shared_key_gets_one_conflict_note_or_none` holds the conflict note.
#[test]
fn catalog_text_reaches_an_unanswered_note_escaped() {
    let notes = unanswered_now(&shipped(&[(
        "al\u{1b}[31mpha",
        "[env]\n# The team.\nTEAM = \"\" # required\n",
    )]));
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(!notes[0].contains('\u{1b}'), "{notes:?}");
    assert!(notes[0].contains("\\u{1b}[31m"), "{notes:?}");
}

/// A name the file takes is not a key the file answers, and every shape
/// that takes one without answering it is the same trap: the file-wide
/// presence check stops the write, so the note is the only thing left to
/// say the key is still undecided — and read off that same wide check the
/// note goes quiet too. The key ends up neither written nor reported,
/// which is the silence this whole rule exists to stop.
///
/// Run on the arrival, because that is the one pass a marked key would
/// ever have been written on.
#[test]
fn an_assignment_no_script_reads_leaves_the_key_unanswered_and_says_which_line() {
    let entries = shipped(&[("alpha", "[env]\n# The team.\nTEAM = \"\" # required\n")]);
    let arriving = Seeding::new(["alpha".to_owned()], []);
    for (file, expect) in [
        (
            "[other]\nTEAM = \"x\"\n",
            "it is assigned outside the [env] table, where no script reads it (line 2)",
        ),
        (
            "[env]\n\"TEAM\" = \"x\"\n",
            "it is assigned as a quoted key, which is not a name a shell can export — spell it TEAM (line 2)",
        ),
        (
            "[env]\nTEAM.part = \"x\"\n",
            "it is assigned as a dotted key, which makes TEAM a table rather than a setting (line 2)",
        ),
        (
            "[env]\nTEAM = \"a\"\nTEAM = \"b\"\n",
            "it is assigned more than once, and nothing here can say which one wins (lines 2, 3)",
        ),
        (
            "[env]\nTEAM = 7\n",
            "its value is not a one-line double-quoted string free of \" and \\ (line 2)",
        ),
    ] {
        // Nothing is written: the name is taken, whatever took it.
        assert!(
            merge(Some(file), &entries, &arriving).is_none(),
            "the name is taken, so no write: {file}"
        );
        // So the note is owed, and it names the line rather than claiming
        // nothing assigns the key.
        let notes = unanswered_notes(&entries, &Answered::read(Some(file), &entries), &arriving);
        assert_eq!(notes.len(), 1, "{file}: {notes:?}");
        assert_eq!(
            notes[0],
            format!(
                "kendex.settings.toml TEAM: alpha needs this key decided and this file's assignment is not one — {expect} — so set it yourself"
            ),
            "{file}"
        );
    }

    // And the line the loaders DO read still answers the key: the note is
    // about a gap, and this is not one.
    let answered = Answered::read(Some("[env]\nTEAM = \"ours\"\n"), &entries);
    assert!(
        unanswered_notes(&entries, &answered, &arriving).is_empty(),
        "{:?}",
        unanswered_notes(&entries, &answered, &arriving)
    );
}

/// The conflict note has the same three states to tell apart, and the
/// middle one is the one a wide presence check loses: an assignment no
/// script reads leaves the scripts on their own carried defaults exactly
/// as an absent key does, while the line sitting in the file makes seeding
/// leave the key alone. Told they already assign it, a person goes looking
/// at a line that is doing nothing.
#[test]
fn a_shared_key_assigned_where_nothing_reads_it_says_so_rather_than_claiming_an_answer() {
    let entries = shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]);
    let ordinary = Seeding::default();
    let consequence = |file: &str| {
        let notes = conflict_notes(&entries, &Answered::read(Some(file), &entries), &ordinary);
        assert_eq!(notes.len(), 1, "{file}: {notes:?}");
        notes[0]
            .split_once("(alpha), \"600\" (beta) — ")
            .map(|(_, rest)| rest.to_owned())
            .unwrap_or_else(|| panic!("{file}: {}", notes[0]))
    };
    assert_eq!(
        consequence("[other]\nWAIT = \"1\"\n"),
        "this file's assignment is not one your scripts read — it is assigned outside the [env] table, where no script reads it (line 2) — so what they read is whichever default they carry, and nothing here writes over the line that is there"
    );
    // The two states either side of it are unchanged.
    assert_eq!(
        consequence("[env]\nWAIT = \"1\"\n"),
        "this file already assigns it, so that value is what your scripts read and none of these defaults reaches them"
    );
    assert_eq!(
        consequence("[env]\n"),
        "nothing here writes this key, so what your scripts read is whichever default they carry, so set the value yourself if that is not the one you want"
    );
}

/// The owner a conflict note names is the one whose bytes land, and a key
/// the file already holds has no bytes landing at all — so the note may
/// not name a package as the one written. Asked without the file, the
/// admission alone names alpha and points at a value that never arrives.
#[test]
fn a_key_the_file_already_holds_names_no_package_as_the_one_written() {
    let entries = shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\" # required\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\" # required\n"),
    ]);
    let arriving = Seeding::new(["alpha".to_owned(), "beta".to_owned()], []);
    let file = "[other]\nWAIT = \"1\"\n";
    assert!(merge(Some(file), &entries, &arriving).is_none());
    let notes = conflict_notes(&entries, &Answered::read(Some(file), &entries), &arriving);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(
        !notes[0].contains("is the one written"),
        "nothing is written: {}",
        notes[0]
    );
}
