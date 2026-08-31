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
    conflict_notes(entries, &BTreeSet::new(), &super::all(entries))
}

#[test]
fn one_note_groups_every_owner_and_every_distinct_default() {
    let notes = conflict_notes_all(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("gamma", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — \"900\" (alpha, beta), \"600\" (gamma) — where this file does not already assign it, alpha's is the one written, so set the value yourself if that is not the one you want"
        ]
    );
}

#[test]
fn packages_agreeing_on_a_shared_key_say_nothing() {
    let notes = conflict_notes_all(&shipped(&[
        (
            "alpha",
            "[env]\n# Mode.\nMODE = \"enforce\"\n# Wait.\nWAIT = \"900\"\n",
        ),
        (
            "beta",
            "[env]\n# Mode.\nMODE = \"enforce\"\n# Wait.\nWAIT = \"900\"\n",
        ),
    ]));
    assert!(notes.is_empty(), "{notes:?}");
}

#[test]
fn a_key_only_one_package_ships_says_nothing() {
    let notes = conflict_notes_all(&shipped(&[
        ("alpha", "[env]\n# Depth.\nDEPTH = \"2\"\n"),
        ("beta", "[env]\n# Width.\nWIDTH = \"3\"\n"),
    ]));
    assert!(notes.is_empty(), "{notes:?}");
}

#[test]
fn the_note_names_the_owner_whose_value_merge_actually_seeds() {
    // alpha's default carries a trailing comment, which the loaders read
    // and a stricter decoder once threw away — dropping alpha from the note
    // and naming beta as the package whose value lands.
    let entries = shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\" # seconds\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
        ("gamma", "[env]\n# Wait.\nWAIT = \"300\"\n"),
    ]);
    let notes = conflict_notes(&entries, &BTreeSet::new(), &super::all(&entries));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — \"900\" (alpha), \"600\" (beta), \"300\" (gamma) — where this file does not already assign it, alpha's is the one written, so set the value yourself if that is not the one you want"
        ]
    );
    // And alpha is what merge writes, which is what the note claims.
    let (merged, added) = merge(None, &entries, &super::all(&entries)).unwrap();
    assert_eq!(added, ["WAIT"]);
    assert!(merged.contains("WAIT = \"900\" # seconds"), "{merged}");
}

#[test]
fn a_default_no_decoder_reads_still_names_its_owner() {
    let notes = conflict_notes_all(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = 900\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — 900 (alpha), \"600\" (beta) — where this file does not already assign it, alpha's is the one written, so set the value yourself if that is not the one you want"
        ]
    );
}

#[test]
fn a_trailing_comment_is_not_a_different_default() {
    let notes = conflict_notes_all(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"900\" # seconds\n"),
    ]));
    assert!(notes.is_empty(), "{notes:?}");
}

#[test]
fn catalog_text_reaches_a_note_escaped() {
    let notes = conflict_notes_all(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"90\u{1b}[31m0\"\n"),
        ("be\u{1b}[31mta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]));
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(!notes[0].contains('\u{1b}'), "{notes:?}");
    assert!(notes[0].contains("\\u{1b}[31m"), "{notes:?}");
}

/// Two packages shipping one key with different multiline values do
/// disagree, and the note has to say so. Shown from the `=` line alone
/// both read as a bare `"""` and the note would group them as agreeing.
#[test]
fn two_different_multiline_defaults_are_not_one_default() {
    let template = |body: &str| format!("[env]\n# A blob.\nBLOB = \"\"\"\n{body}\n\"\"\"\n");
    let mut shipped = seeded(&template("from a"), "a");
    shipped.extend(seeded(&template("from b"), "b"));
    let notes = conflict_notes_all(&shipped);
    assert_eq!(notes.len(), 1, "{notes:?}");
    // Each value shown whole on the one line, so the two read as the
    // different defaults they are.
    assert!(notes[0].contains("\"\"\" from a \"\"\" (a)"), "{notes:?}");
    assert!(notes[0].contains("\"\"\" from b \"\"\" (b)"), "{notes:?}");

    // And two shipping the SAME multiline value still say nothing.
    let mut agreeing = seeded(&template("same"), "a");
    agreeing.extend(seeded(&template("same"), "b"));
    assert!(conflict_notes_all(&agreeing).is_empty());
}
/// Two defaults that differ only in what the display collapses are still
/// two defaults. `default_shown` joins a value's lines with a space for
/// reading, so a multiline holding `a\nb` and one holding `a b` render
/// alike; grouped on that text the disagreement disappears, which is the
/// one thing this note exists to catch.
#[test]
fn defaults_the_display_collapses_alike_are_still_a_disagreement() {
    let template = |body: &str| format!("[env]\n# A blob.\nBLOB = \"\"\"\n{body}\n\"\"\"\n");
    let mut shipped = seeded(&template("a\nb"), "split");
    shipped.extend(seeded(&template("a b"), "joined"));
    // The display cannot tell them apart; the note still must.
    assert_eq!(shipped[0].default_shown(), shipped[1].default_shown());
    assert_ne!(shipped[0].default_key(), shipped[1].default_key());

    let notes = conflict_notes_all(&shipped);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("(split)"), "{notes:?}");
    assert!(notes[0].contains("(joined)"), "{notes:?}");

    // Two that really are the same value still say nothing.
    let mut agreeing = seeded(&template("a\nb"), "one");
    agreeing.extend(seeded(&template("a\nb"), "two"));
    assert!(conflict_notes_all(&agreeing).is_empty());
}

/// A marked key nothing answers, on the ordinary pass: nothing arriving,
/// nothing edited, and a file that assigns none of it.
fn unanswered_now(entries: &[SeededEnv]) -> Vec<String> {
    unanswered_notes(entries, &BTreeSet::new(), &Seeding::default())
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
    let unread = BTreeSet::new();

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
/// `catalog_text_reaches_a_note_escaped` holds the conflict note.
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
