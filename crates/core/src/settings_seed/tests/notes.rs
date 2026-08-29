//! What the plan says before a byte is written: shared keys with
//! different defaults, and keys no template can supply.

use super::*;

/// Every `[env]` entry each named owner's template ships, in the order the
/// owners are given — the order seeding resolves a shared key in.
fn shipped(owners: &[(&str, &str)]) -> Vec<SeededEnv> {
    owners
        .iter()
        .flat_map(|(owner, template)| seeded(template, owner))
        .collect()
}

#[test]
fn one_note_groups_every_owner_and_every_distinct_default() {
    let notes = conflict_notes(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("gamma", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — \"900\" (alpha, beta), \"600\" (gamma) — where this file does not already assign it, alpha's is the one seeded, so set the value yourself if that is not the one you want"
        ]
    );
}

#[test]
fn packages_agreeing_on_a_shared_key_say_nothing() {
    let notes = conflict_notes(&shipped(&[
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
    let notes = conflict_notes(&shipped(&[
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
    let notes = conflict_notes(&entries);
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — \"900\" (alpha), \"600\" (beta), \"300\" (gamma) — where this file does not already assign it, alpha's is the one seeded, so set the value yourself if that is not the one you want"
        ]
    );
    // And alpha is what merge writes, which is what the note claims.
    let (merged, added) = merge(None, &entries).unwrap();
    assert_eq!(added, ["WAIT"]);
    assert!(merged.contains("WAIT = \"900\" # seconds"), "{merged}");
}

#[test]
fn a_default_no_decoder_reads_still_names_its_owner() {
    let notes = conflict_notes(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = 900\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"600\"\n"),
    ]));
    assert_eq!(
        notes,
        [
            "kendex.settings.toml WAIT: packages ship different defaults — 900 (alpha), \"600\" (beta) — where this file does not already assign it, alpha's is the one seeded, so set the value yourself if that is not the one you want"
        ]
    );
}

#[test]
fn a_trailing_comment_is_not_a_different_default() {
    let notes = conflict_notes(&shipped(&[
        ("alpha", "[env]\n# Wait.\nWAIT = \"900\"\n"),
        ("beta", "[env]\n# Wait.\nWAIT = \"900\" # seconds\n"),
    ]));
    assert!(notes.is_empty(), "{notes:?}");
}

#[test]
fn catalog_text_reaches_a_note_escaped() {
    let notes = conflict_notes(&shipped(&[
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
    let notes = conflict_notes(&shipped);
    assert_eq!(notes.len(), 1, "{notes:?}");
    // Each value shown whole on the one line, so the two read as the
    // different defaults they are.
    assert!(notes[0].contains("\"\"\" from a \"\"\" (a)"), "{notes:?}");
    assert!(notes[0].contains("\"\"\" from b \"\"\" (b)"), "{notes:?}");

    // And two shipping the SAME multiline value still say nothing.
    let mut agreeing = seeded(&template("same"), "a");
    agreeing.extend(seeded(&template("same"), "b"));
    assert!(conflict_notes(&agreeing).is_empty());
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

    let notes = conflict_notes(&shipped);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("(split)"), "{notes:?}");
    assert!(notes[0].contains("(joined)"), "{notes:?}");

    // Two that really are the same value still say nothing.
    let mut agreeing = seeded(&template("a\nb"), "one");
    agreeing.extend(seeded(&template("a\nb"), "two"));
    assert!(conflict_notes(&agreeing).is_empty());
}
