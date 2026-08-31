use std::collections::BTreeSet;

use super::*;

mod notes;

const TEMPLATE: &str = "# ignored preamble\n[env]\n# Which reviewer set to run.\n# Comma separated.\nREVIEWERS = \"arch,security\"\n\nDEPTH = \"2\"\n\n[other]\nX = \"1\"\n";

/// A [`Seeding`] admitting every declaration handed to it. What a test
/// whose subject is the bytes a write produces wants: which keys an
/// install chooses is a different question, pinned by its own tests.
fn all(entries: &[SeededEnv]) -> Seeding {
    Seeding::new([], entries.iter().map(|s| s.entry.key.clone()))
}

/// A file that answers nothing: what a test whose subject is the bytes or
/// the defaults wants, so a note about the consumer's own file cannot come
/// out of a fixture that has none.
fn nothing(entries: &[SeededEnv]) -> Answered {
    Answered::read(None, entries)
}

fn seeded(template: &str, owner: &str) -> Vec<SeededEnv> {
    extract_env_entries(template)
        .into_iter()
        .map(|entry| SeededEnv {
            entry,
            owner: owner.to_owned(),
        })
        .collect()
}

#[test]
fn entries_carry_their_comment_blocks() {
    let entries = extract_env_entries(TEMPLATE);
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].key, "REVIEWERS");
    assert_eq!(entries[0].comment.len(), 2);
    assert_eq!(entries[0].assignment, "REVIEWERS = \"arch,security\"");
    assert_eq!(entries[1].key, "DEPTH");
}

/// The marker says the key is one the consumer must decide, and it is the
/// template's own word: what gets written is the assignment without it.
#[test]
fn the_required_marker_marks_the_entry_and_never_reaches_the_bytes() {
    let entries = extract_env_entries(
        "[env]\n# The team.\nTEAM = \"\" # required\n\n# How deep.\nDEPTH = \"2\"\n",
    );
    assert_eq!(entries[0].key, "TEAM");
    assert!(entries[0].required);
    assert_eq!(entries[0].assignment, "TEAM = \"\"");
    assert!(!entries[1].required);
    assert_eq!(entries[1].assignment, "DEPTH = \"2\"");

    // A `#` inside the value is the value's, not a marker.
    let inside = extract_env_entries("[env]\n# A hash.\nA = \"x # required\"\n");
    assert!(!inside[0].required);
    assert_eq!(inside[0].assignment, "A = \"x # required\"");
}

/// What an install writes: the marked keys of the skills arriving, and the
/// keys a save names. Nothing else, on any pass.
#[test]
fn seeding_admits_the_marked_keys_of_an_arriving_skill_and_the_edited_ones() {
    let entries = seeded(
        "[env]\n# The team.\nTEAM = \"\" # required\n\n# How deep.\nDEPTH = \"2\"\n",
        "review",
    );
    let arriving = Seeding::new(["review".to_owned()], []);
    let (_, added) = merge(Some("[env]\n"), &entries, &arriving).expect("TEAM is missing");
    assert_eq!(added, ["TEAM"]);

    // The same skill on a later pass is not arriving, and writes nothing.
    assert!(merge(Some("[env]\n"), &entries, &Seeding::new([], [])).is_none());

    // Another skill arriving does not carry this one's keys in with it.
    let others = Seeding::new(["elsewhere".to_owned()], []);
    assert!(merge(Some("[env]\n"), &entries, &others).is_none());

    // A save reaches a key no arrival ever writes.
    let editing = Seeding::new([], ["DEPTH".to_owned()]);
    let (_, added) = merge(Some("[env]\n"), &entries, &editing).expect("DEPTH is missing");
    assert_eq!(added, ["DEPTH"]);
}

#[test]
fn merge_is_write_if_absent_with_file_wide_uniqueness() {
    let entries = seeded(TEMPLATE, "review");
    // Key already assigned under a DIFFERENT table still blocks the add.
    let existing = "[custom]\nREVIEWERS = \"mine\"\n\n[env]\nOTHER = \"x\"\n";
    let (merged, added) = merge(Some(existing), &entries, &all(&entries)).unwrap();
    assert_eq!(added, ["DEPTH"]);
    assert!(merged.contains("REVIEWERS = \"mine\""));
    assert!(!merged.contains("arch,security"));
    assert!(merged.contains("DEPTH = \"2\""));
    assert!(merged.ends_with("DEPTH = \"2\"\n"));

    assert!(merge(Some(&merged), &entries, &all(&entries)).is_none());
}

#[test]
fn fresh_file_gets_the_seeded_header() {
    let entries = seeded(TEMPLATE, "review");
    let (created, added) = merge(None, &entries, &all(&entries)).unwrap();
    assert_eq!(added, ["REVIEWERS", "DEPTH"]);
    assert!(created.starts_with("# Public kendex settings"));
    assert!(created.contains("[env]\n# Which reviewer set to run."));
}

#[test]
fn merge_changes_nothing_outside_the_inserted_block() {
    let entries = seeded("[env]\nDEPTH = \"2\"\n", "review");
    let original = "# mine\r\n[env]\r\nREVIEWERS = \"mine\"\r\n\r\n[custom]\r\nX = \"1\"\r\n";
    let (merged, added) = merge(Some(original), &entries, &all(&entries)).unwrap();
    assert_eq!(added, ["DEPTH"]);
    // The block lands inside [env] in the file's own line terminator; every
    // original byte survives, in order.
    assert!(merged.contains("DEPTH = \"2\"\r\n"), "{merged:?}");
    let without_block = merged.replacen("DEPTH = \"2\"\r\n\r\n", "", 1);
    assert_eq!(without_block, original, "only the block was inserted");
}

#[test]
fn merge_at_file_end_repairs_a_missing_terminator_once() {
    let entries = seeded("[env]\nDEPTH = \"2\"\n", "review");
    let original = "[env]\nREVIEWERS = \"mine\"";
    let (merged, _) = merge(Some(original), &entries, &all(&entries)).unwrap();
    assert!(
        merged.starts_with("[env]\nREVIEWERS = \"mine\"\n"),
        "{merged:?}"
    );
    assert!(merged.ends_with("DEPTH = \"2\"\n"));
}

/// A container the reader does not track ends the `[env]` section where
/// no table starts, and the seed lands inside somebody's value. Both
/// shapes: a nested `[` taken for a header, and a header the boundary
/// test failed to recognise.
#[test]
fn a_seed_lands_after_the_env_table_and_never_inside_a_value() {
    let seeded = [SeededEnv {
        entry: EnvEntry {
            key: "DEPTH".to_owned(),
            comment: vec!["# How deep.".to_owned()],
            assignment: "DEPTH = \"2\"".to_owned(),
            required: false,
        },
        owner: "review".to_owned(),
    }];

    // A nested array bracket is not a table header.
    let nested = "[env]\nLIST = [\n  []\n]\n";
    let (text, added) = merge(Some(nested), &seeded, &all(&seeded)).expect("DEPTH is missing");
    assert_eq!(added, vec!["DEPTH".to_owned()]);
    assert!(
        text.starts_with("[env]\nLIST = [\n  []\n]\n"),
        "the array must come through whole:\n{text}"
    );
    assert!(text.contains("DEPTH = \"2\""), "{text}");

    // And a header the boundary test used to miss ends the section.
    let commented = "[env]\nMODE = \"a\"\n\n[other] # note\nKEEP = \"b\"\n";
    let (text, _) = merge(Some(commented), &seeded, &all(&seeded)).expect("DEPTH is missing");
    let depth = text.find("DEPTH").expect("seeded");
    let other = text.find("[other]").expect("kept");
    assert!(
        depth < other,
        "the seed belongs to [env], not [other]:\n{text}"
    );
}

/// Where a table ENDS is TOML's answer, not the loaders'. A header the
/// loaders refuse is still that table to TOML, so a seed belongs inside
/// it: missing it appends a second `[env]`, and a file with a typo in one
/// header becomes a file with two of the same table, which nothing reads
/// at all.
#[test]
fn a_header_the_loaders_refuse_is_still_the_table_a_seed_lands_in() {
    let seeded = [SeededEnv {
        entry: EnvEntry {
            key: "DEPTH".to_owned(),
            comment: vec!["# How deep.".to_owned()],
            assignment: "DEPTH = \"2\"".to_owned(),
            required: false,
        },
        owner: "review".to_owned(),
    }];
    let file = "[env] # the table\nMODE = \"a\"\n\n[other]\nKEEP = \"b\"\n";
    let (text, _) = merge(Some(file), &seeded, &all(&seeded)).expect("DEPTH is missing");

    // Counted through the reader rather than by string, because what
    // matters is how many rows OPEN the table, not how the header reads.
    assert_eq!(
        crate::settings_toml::rows(&text)
            .iter()
            .filter(|row| opens_env(row))
            .count(),
        1,
        "a second [env] would stop the file loading at all:\n{text}"
    );
    let depth = text.find("DEPTH").expect("seeded");
    let other = text.find("[other]").expect("kept");
    assert!(depth < other, "the seed belongs to [env]:\n{text}");
}

/// And the other half of the pair stays the loaders': a key under a header
/// they refuse is a key nothing reads, which is what the view reports.
#[test]
fn membership_tracks_the_loaders_where_the_boundary_tracks_toml() {
    assert!(loaders_read_env("[env]"));
    for refused in ["[env] # the table", "[other]", "[envx]", "[ env ]"] {
        assert!(!loaders_read_env(refused), "{refused}");
    }
    let sites = crate::settings_file::sites("[env] # the table\nMODE = \"a\"\n");
    assert!(
        matches!(
            crate::settings_file::current_of(&sites, "MODE"),
            crate::settings_file::Current::Ambiguous { .. }
        ),
        "a key no loader reads is not a value to compare with a default"
    );
}

/// Every spelling TOML gives the env table is the table a seed lands in.
/// Missing one appends a second `[env]`, which is the duplicate-table
/// corruption this has now been fixed for three spellings running.
#[test]
fn any_spelling_of_the_env_header_is_the_table_a_seed_lands_in() {
    let seeded = [SeededEnv {
        entry: EnvEntry {
            key: "DEPTH".to_owned(),
            comment: vec!["# How deep.".to_owned()],
            assignment: "DEPTH = \"2\"".to_owned(),
            required: false,
        },
        owner: "review".to_owned(),
    }];
    for header in ["[env]", "[env] # note", "[ env ]", "[\"env\"]", "['env']"] {
        let file = format!("{header}\nMODE = \"a\"\n\n[other]\nKEEP = \"b\"\n");
        let (text, _) = merge(Some(&file), &seeded, &all(&seeded)).expect("DEPTH is missing");
        assert_eq!(
            crate::settings_toml::rows(&text)
                .iter()
                .filter(|row| opens_env(row))
                .count(),
            1,
            "{header}: a second env table would stop the file loading:\n{text}"
        );
        let depth = text.find("DEPTH").expect("seeded");
        let other = text.find("[other]").expect("kept");
        assert!(depth < other, "{header}: the seed belongs to env:\n{text}");
    }
}

/// `[[env]]` declares `env` as an array of tables, and TOML lets one name
/// be a table or an array of tables, never both. So there is nowhere a
/// seed can go: writing `[env]` beside it declares `env` twice and the
/// file stops loading, and writing inside it puts a setting where no
/// loader looks. The file is left exactly as it was.
#[test]
fn an_env_declared_as_an_array_of_tables_is_refused_rather_than_seeded() {
    let seeded = [SeededEnv {
        entry: EnvEntry {
            key: "DEPTH".to_owned(),
            comment: vec!["# How deep.".to_owned()],
            assignment: "DEPTH = \"2\"".to_owned(),
            required: false,
        },
        owner: "review".to_owned(),
    }];
    let file = "[[env]]\nMODE = \"a\"\n";
    assert_eq!(env_blocked(file), Some(EnvBlocked::Array(1)));
    assert_eq!(
        merge(Some(file), &seeded, &all(&seeded)),
        None,
        "nothing may be written into a file with nowhere to write"
    );
}

/// A top-level assignment of `env` declares the name the seeded table
/// would open. `env = "a"` makes it a value; `env.MODE = "a"` makes it a
/// table by dotted key, which a `[env]` header may not reopen. Either way
/// appending `[env]` defines `env` twice and the file stops parsing, so
/// the shape is refused where `[[env]]` already is.
#[test]
fn a_top_level_env_assignment_is_refused_rather_than_seeded() {
    let seeded = [SeededEnv {
        entry: EnvEntry {
            key: "DEPTH".to_owned(),
            comment: vec!["# How deep.".to_owned()],
            assignment: "DEPTH = \"2\"".to_owned(),
            required: false,
        },
        owner: "review".to_owned(),
    }];
    for (file, line) in [
        ("env.MODE = \"a\"\n", 1),
        ("env = \"a\"\n", 1),
        ("# note\nenv.\"MODE\" = \"a\"\n[other]\nX = \"y\"\n", 2),
    ] {
        assert_eq!(
            env_blocked(file),
            Some(EnvBlocked::Assigned(line)),
            "{file}"
        );
        assert_eq!(
            merge(Some(file), &seeded, &all(&seeded)),
            None,
            "{file}: nothing may be written into a file with nowhere to write"
        );
    }
    // Under a header the name belongs to that table, not the top level,
    // so the `[env]` a seed opens is still free.
    let nested = "[other]\nenv.MODE = \"a\"\n";
    assert_eq!(env_blocked(nested), None);
    assert!(
        merge(Some(nested), &seeded, &all(&seeded)).is_some(),
        "another table's env is not this file's env"
    );
}

/// Every entry key in declaration order.
fn entry_keys(entries: &[EnvEntry]) -> Vec<&str> {
    entries.iter().map(|entry| entry.key.as_str()).collect()
}

/// A value TOML lets span lines is seeded whole. Stopping at the line
/// carrying the `=` would write `BLOB = """` with nothing under it: the
/// string never closes, every key seeded after it falls inside it, and the
/// consumer's file stops parsing from there down.
#[test]
fn a_value_spanning_lines_is_seeded_whole() {
    for value in [
        "\"\"\"\nsome text\n\"\"\"",
        "'''\nsome text\n'''",
        "[\n  \"a\",\n  \"b\",\n]",
    ] {
        let template = format!("[env]\n# A blob.\nBLOB = {value}\n\n# How deep.\nDEPTH = \"2\"\n");
        let entries = extract_env_entries(&template);
        assert_eq!(entry_keys(&entries), ["BLOB", "DEPTH"], "{value}");
        // The value's continuation lines are the assignment's, and the
        // comment above it is still only the comment.
        assert_eq!(entries[0].comment, ["# A blob."], "{value}");
        // The whole assignment, spelled as the template spells it.
        assert_eq!(entries[0].assignment, format!("BLOB = {value}"), "{value}");
        assert!(entries[0].complete(), "{value}");

        let shipped = seeded(&template, "review");
        let (text, added) = merge(None, &shipped, &all(&shipped)).expect("both are missing");
        assert_eq!(added, ["BLOB", "DEPTH"], "{value}");
        // Spelled as the template spells it, and closed: the seeded file
        // parses, and BLOB reads back as the value the template declares.
        assert!(
            text.contains(&format!("BLOB = {value}\n")),
            "{value}: {text}"
        );
        let want: toml::Table = template.parse().expect("the template parses");
        let got: toml::Table = text
            .parse()
            .unwrap_or_else(|error| panic!("{value}: seeded file must parse: {error}\n{text}"));
        assert_eq!(got["env"]["BLOB"], want["env"]["BLOB"], "{value}");
        assert_eq!(got["env"]["DEPTH"], want["env"]["DEPTH"], "{value}");
    }
}

/// A value nothing closes is not a multiline value: there is no complete
/// text to copy, and writing the opening line alone is the corruption
/// itself. Seeding writes nothing for that key — and says so, naming it.
/// A silent drop would leave a key nobody finds until a script reads it.
#[test]
fn a_value_nothing_closes_is_refused_by_name() {
    let template = "[env]\n# How deep.\nDEPTH = \"2\"\n\n# A blob.\nBLOB = \"\"\"\nsome text\n";
    let entries = extract_env_entries(template);
    assert_eq!(entry_keys(&entries), ["DEPTH", "BLOB"]);
    assert!(!entries[1].complete(), "{entries:?}");
    assert!(entries[1].assignment.is_empty(), "{entries:?}");

    let shipped = seeded(template, "review");
    let (text, added) = merge(None, &shipped, &all(&shipped)).expect("DEPTH is missing");
    assert_eq!(added, ["DEPTH"]);
    assert!(
        !text.contains("BLOB"),
        "no part of it may be written:\n{text}"
    );
    text.parse::<toml::Table>().expect("the seeded file parses");

    let notes = unterminated_notes(&shipped);
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("BLOB"), "the key is named: {notes:?}");
    assert!(notes[0].contains("review"), "and who ships it: {notes:?}");

    // Where another skill ships the same key whole, that one is seeded
    // and nothing is reported: there is nothing for a person to do.
    let whole = seeded("[env]\n# A blob.\nBLOB = \"ok\"\n", "other");
    let both: Vec<SeededEnv> = shipped.iter().cloned().chain(whole).collect();
    assert!(unterminated_notes(&both).is_empty(), "{both:?}");
    let (text, added) = merge(None, &both, &all(&both)).expect("both are missing");
    assert_eq!(added, ["DEPTH", "BLOB"]);
    assert!(text.contains("BLOB = \"ok\""), "{text}");
}

/// Closing and being finished are different questions, and the shape that
/// proves it is the one closest to what this all exists to prevent: a
/// single-line string ends with its line by definition, so `TOKEN = "`
/// carries nothing onto the next line and is still unfinished. Read
/// completeness off the absence of a carry and it seeds, putting an
/// unterminated line in the consumer's file — the exact outcome refused
/// everywhere else here.
#[test]
fn a_one_line_value_left_unterminated_is_refused_by_name() {
    for template in [
        "[env]\n# A token.\nTOKEN = \"\n",
        // With the file continuing under it, and with no terminator.
        "[env]\n# A token.\nTOKEN = \"\n\n# How deep.\nDEPTH = \"2\"\n",
        "[env]\n# A token.\nTOKEN = \"",
    ] {
        let entries = extract_env_entries(template);
        assert!(!entries[0].complete(), "{template:?}: {entries:?}");
        assert!(entries[0].assignment.is_empty(), "{template:?}");

        let shipped = seeded(template, "review");
        let written = merge(None, &shipped, &all(&shipped));
        assert!(
            !written
                .as_ref()
                .is_some_and(|(text, _)| text.contains("TOKEN")),
            "{template:?}: nothing may be written for it: {written:?}"
        );
        if let Some((text, _)) = &written {
            text.parse::<toml::Table>()
                .unwrap_or_else(|e| panic!("{template:?}: seeded file must parse: {e}\n{text}"));
        }
        let notes = unterminated_notes(&shipped);
        assert_eq!(notes.len(), 1, "{template:?}: {notes:?}");
        assert!(notes[0].contains("TOKEN"), "{template:?}: {notes:?}");
    }
}

/// One key, one winner, and everyone has to name it. A broken template
/// declaring a key before a valid one had `merge` write the valid skill's
/// bytes while the notes named the broken one — a note pointing at a
/// template that supplied nothing.
#[test]
fn a_broken_declaration_before_a_valid_one_never_becomes_the_owner() {
    let mut shipped = seeded("[env]\n# Theirs.\nMODE = \"\n", "broken");
    shipped.extend(seeded("[env]\n# Ours.\nMODE = \"real\"\n", "good"));
    assert_eq!(shipped.len(), 2, "both declarations are entries");

    // The bytes written.
    let (text, added) = merge(None, &shipped, &all(&shipped)).expect("MODE is missing");
    assert_eq!(added, ["MODE"]);
    assert!(text.contains("MODE = \"real\""), "{text}");
    assert!(text.contains("# Ours."), "the winner's comment too: {text}");

    // The selection everyone asks.
    assert_eq!(
        writable_all(&shipped, "MODE")
            .next()
            .map(|s| s.owner.as_str()),
        Some("good")
    );
    assert_eq!(
        written_for(&shipped, "MODE", &all(&shipped), &BTreeSet::new()).map(|s| s.owner.as_str()),
        Some("good")
    );

    // And the notes: a broken declaration is not a competing default that
    // lands, so nothing claims the broken skill's value was written.
    for note in seed_notes(&shipped, &nothing(&shipped), &all(&shipped)) {
        assert!(!note.contains("broken's is the one written"), "{note}");
    }
}

/// An inline table the file never closes is refused like any other
/// container the file never closes: the carry runs to the end and nothing
/// completes it. Completeness comes off the grammar's own split rather
/// than a rule per form, so this needs no case of its own.
#[test]
fn an_inline_table_left_open_is_refused_by_name() {
    for template in [
        "[env]\n# A map.\nMAP = {\n",
        "[env]\n# A map.\nMAP = { a = 1,\n\n# How deep.\nDEPTH = \"2\"\n",
        "[env]\n# A map.\nMAP = { a = { b = 1 }\n",
        "[env]\n# A map.\nMAP = {",
    ] {
        let entries = extract_env_entries(template);
        assert!(!entries[0].complete(), "{template:?}: {entries:?}");

        let shipped = seeded(template, "review");
        let written = merge(None, &shipped, &all(&shipped));
        assert!(
            !written
                .as_ref()
                .is_some_and(|(text, _)| text.contains("MAP")),
            "{template:?}: nothing may be written for it: {written:?}"
        );
        if let Some((text, _)) = &written {
            text.parse::<toml::Table>()
                .unwrap_or_else(|e| panic!("{template:?}: must parse: {e}\n{text}"));
        }
        let notes = unterminated_notes(&shipped);
        assert_eq!(notes.len(), 1, "{template:?}: {notes:?}");
        assert!(notes[0].contains("MAP"), "{template:?}: {notes:?}");
    }
}

/// The other half: an inline table that closes is an ordinary complete
/// value and seeds like any other. A completeness rule that refused every
/// brace would be as wrong as one that accepted every brace.
#[test]
fn an_inline_table_that_closes_seeds_like_any_other_value() {
    for value in [
        "{ a = 1 }",
        "{ a = { b = 1 } }",
        "{ a = \"}\" }",
        "{ a = [1, 2] }",
    ] {
        let template = format!("[env]\n# A map.\nMAP = {value}\n");
        let entries = extract_env_entries(&template);
        assert!(entries[0].complete(), "{value}: {entries:?}");
        assert_eq!(entries[0].assignment, format!("MAP = {value}"), "{value}");

        let shipped = seeded(&template, "review");
        assert!(unterminated_notes(&shipped).is_empty(), "{value}");
        let (text, added) = merge(None, &shipped, &all(&shipped)).expect("MAP is missing");
        assert_eq!(added, ["MAP"], "{value}");
        let want: toml::Table = template.parse().expect("the template parses");
        let got: toml::Table = text
            .parse()
            .unwrap_or_else(|e| panic!("{value}: seeded file must parse: {e}\n{text}"));
        assert_eq!(got["env"]["MAP"], want["env"]["MAP"], "{value}");
    }
}

/// Two kinds of newline meet in a seeded block and only one of them is the
/// file's. The terminators between entries and around the block are the
/// destination's; the ones INSIDE a multiline value are the value's own
/// content, and rewriting them hands the consumer a different string from
/// the one the template declared.
#[test]
fn a_values_own_newlines_survive_a_file_that_spells_them_differently() {
    let template = "[env]\n# A blob.\nBLOB = \"\"\"\nline one\nline two\n\"\"\"\n";
    let file = "[env]\r\nMODE = \"a\"\r\n";
    let shipped = seeded(template, "review");
    let (out, added) = merge(Some(file), &shipped, &all(&shipped)).expect("BLOB is missing");
    assert_eq!(added, ["BLOB"]);

    // The value arrives exactly as the template spelled it.
    assert!(
        out.contains("BLOB = \"\"\"\nline one\nline two\n\"\"\""),
        "{out:?}"
    );
    // And the lines around it are the file's own.
    assert!(out.contains("# A blob.\r\n"), "{out:?}");
    assert!(out.ends_with("\"\"\"\r\n"), "{out:?}");
    assert!(
        out.starts_with(file),
        "the original bytes are untouched: {out:?}"
    );

    // What the consumer reads back is the template's value, unchanged.
    let want: toml::Table = template.parse().expect("the template parses");
    let got: toml::Table = out.parse().expect("the seeded file parses");
    assert_eq!(got["env"]["BLOB"], want["env"]["BLOB"], "{out:?}");

    // The other direction too: a CRLF template into an LF file.
    let crlf = "[env]\r\n# A blob.\r\nBLOB = \"\"\"\r\nline one\r\n\"\"\"\r\n";
    let shipped = seeded(crlf, "review");
    let (out, _) = merge(Some("[env]\nMODE = \"a\"\n"), &shipped, &all(&shipped)).expect("missing");
    assert!(
        out.contains("BLOB = \"\"\"\r\nline one\r\n\"\"\""),
        "{out:?}"
    );
    assert!(out.contains("# A blob.\n"), "{out:?}");
}

/// An incomplete declaration ships no default, so it cannot disagree with
/// one. Grouped as if it did, a broken declaration beside a valid one
/// produced a conflict note between two skills where only one had said
/// anything — and the seed itself was already correct, so the note sent a
/// person to arbitrate a disagreement that did not exist.
#[test]
fn an_incomplete_declaration_is_not_a_default_to_disagree_with() {
    let mut shipped = seeded("[env]\n# Theirs.\nBLOB = \"\"\"\n", "broken");
    shipped.extend(seeded("[env]\n# Ours.\nBLOB = \"ok\"\n", "good"));

    assert!(
        conflict_notes(&shipped, &nothing(&shipped), &all(&shipped)).is_empty(),
        "one default is not a disagreement: {:?}",
        conflict_notes(&shipped, &nothing(&shipped), &all(&shipped))
    );
    // The key is supplied, so nothing is refused either: no note at all.
    assert!(unterminated_notes(&shipped).is_empty());
    assert!(
        seed_notes(&shipped, &nothing(&shipped), &all(&shipped)).is_empty(),
        "{:?}",
        seed_notes(&shipped, &nothing(&shipped), &all(&shipped))
    );

    let (text, added) = merge(None, &shipped, &all(&shipped)).expect("BLOB is missing");
    assert_eq!(added, ["BLOB"]);
    assert!(text.contains("BLOB = \"ok\""), "{text}");

    // Two complete declarations that really do differ still say so.
    let mut real = seeded("[env]\n# Theirs.\nBLOB = \"theirs\"\n", "one");
    real.extend(seeded("[env]\n# Ours.\nBLOB = \"ours\"\n", "two"));
    assert_eq!(
        conflict_notes(&real, &nothing(&real), &all(&real)).len(),
        1,
        "{:?}",
        conflict_notes(&real, &nothing(&real), &all(&real))
    );
}

/// The refusal fires for every form the grammar can leave open, so it may
/// not name a subset of them. Naming "a string or an array" sent somebody
/// whose inline table was unclosed to the wrong part of their template,
/// and any list goes stale the moment the enumerated grammar grows.
#[test]
fn the_refusal_names_the_key_and_no_particular_delimiter() {
    for (template, key) in [
        ("[env]\n# A.\nTOKEN = \"\n", "TOKEN"),
        ("[env]\n# A.\nMAP = {\n", "MAP"),
        ("[env]\n# A.\nLIST = [\n", "LIST"),
        ("[env]\n# A.\nBLOB = \"\"\"\n", "BLOB"),
    ] {
        let notes = unterminated_notes(&seeded(template, "review"));
        assert_eq!(notes.len(), 1, "{template:?}: {notes:?}");
        assert!(notes[0].contains(key), "the key is named: {notes:?}");
        for named in ["string", "array", "inline table", "quote", "bracket"] {
            assert!(
                !notes[0].contains(named),
                "{template:?}: names {named}, which is only true of some: {notes:?}"
            );
        }
    }
}

/// An inline table spanning lines is a value like any other under the spec
/// this workspace parses with. Treated as line-local it was refused, and
/// worse: the lines holding it read as structure, so `a = 1` beneath
/// `MAP = {` seeded as a key of its own that the template never declared.
#[test]
fn an_inline_table_spanning_lines_is_seeded_whole() {
    for value in [
        "{\na = 1\n}",
        "{ items = [\n  1,\n] }",
        "{\n  a = { b = 1 },\n}",
        "{\n  a = \"\"\"\n  text\n  \"\"\",\n}",
    ] {
        let template = format!("[env]\n# A map.\nMAP = {value}\n");
        let entries = extract_env_entries(&template);
        // One entry, not one per line the value happens to hold.
        assert_eq!(entry_keys(&entries), ["MAP"], "{value}");
        assert!(entries[0].complete(), "{value}: {entries:?}");
        assert_eq!(entries[0].assignment, format!("MAP = {value}"), "{value}");

        let shipped = seeded(&template, "review");
        assert!(
            seed_notes(&shipped, &nothing(&shipped), &all(&shipped)).is_empty(),
            "{value}"
        );
        let (text, added) = merge(None, &shipped, &all(&shipped)).expect("MAP is missing");
        assert_eq!(added, ["MAP"], "{value}");
        let want: toml::Table = template.parse().expect("the template parses");
        let got: toml::Table = text
            .parse()
            .unwrap_or_else(|e| panic!("{value}: seeded file must parse: {e}\n{text}"));
        assert_eq!(got["env"]["MAP"], want["env"]["MAP"], "{value}");
    }
}

/// A key beneath a multiline value belongs to the value, and one beneath a
/// closed one belongs to the file. Both directions, because reading the
/// first as structure is what invented a declaration.
#[test]
fn a_key_under_an_inline_table_belongs_to_whichever_owns_its_line() {
    let inside = "[env]\n# A map.\nMAP = {\na = 1\n}\n\n# How deep.\nDEPTH = \"2\"\n";
    assert_eq!(entry_keys(&extract_env_entries(inside)), ["MAP", "DEPTH"]);

    let shipped = seeded(inside, "review");
    let (text, added) = merge(None, &shipped, &all(&shipped)).expect("both are missing");
    assert_eq!(added, ["MAP", "DEPTH"]);
    let got: toml::Table = text.parse().expect("the seeded file parses");
    assert!(got["env"]["MAP"].get("a").is_some(), "{text}");
    assert!(
        got["env"].get("a").is_none(),
        "a is MAP's, not the table's: {text}"
    );
}
