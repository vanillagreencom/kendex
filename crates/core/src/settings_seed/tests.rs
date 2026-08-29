use std::collections::BTreeMap;

use super::*;

const TEMPLATE: &str = "# ignored preamble\n[env]\n# Which reviewer set to run.\n# Comma separated.\nREVIEWERS = \"arch,security\"\n\nDEPTH = \"2\"\n\n[other]\nX = \"1\"\n";

fn seeded(template: &str, owner: &str) -> Vec<SeededEnv> {
    extract_env_entries(template)
        .into_iter()
        .map(|entry| SeededEnv {
            entry,
            owner: owner.to_owned(),
        })
        .collect()
}

/// The ledger as seeding would have left it for these entries.
fn ledger_for(entries: &[SeededEnv]) -> BTreeMap<String, SettingsSeed> {
    entries
        .iter()
        .map(|seeded| (seeded.entry.key.clone(), seeded.seed_record()))
        .collect()
}

#[test]
fn entries_carry_their_comment_blocks() {
    let entries = extract_env_entries(TEMPLATE);
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].key, "REVIEWERS");
    assert_eq!(entries[0].comment.len(), 2);
    assert_eq!(entries[0].assignment, ["REVIEWERS = \"arch,security\""]);
    assert_eq!(entries[1].key, "DEPTH");
}

#[test]
fn merge_is_write_if_absent_with_file_wide_uniqueness() {
    let entries = seeded(TEMPLATE, "review");
    // Key already assigned under a DIFFERENT table still blocks the add.
    let existing = "[custom]\nREVIEWERS = \"mine\"\n\n[env]\nOTHER = \"x\"\n";
    let (merged, added) = merge(Some(existing), &entries).unwrap();
    assert_eq!(added, ["DEPTH"]);
    assert!(merged.contains("REVIEWERS = \"mine\""));
    assert!(!merged.contains("arch,security"));
    assert!(merged.contains("DEPTH = \"2\""));
    assert!(merged.ends_with("DEPTH = \"2\"\n"));

    assert!(merge(Some(&merged), &entries).is_none());
}

#[test]
fn fresh_file_gets_the_seeded_header() {
    let entries = seeded(TEMPLATE, "review");
    let (created, added) = merge(None, &entries).unwrap();
    assert_eq!(added, ["REVIEWERS", "DEPTH"]);
    assert!(created.starts_with("# Public kendex settings"));
    assert!(created.contains("[env]\n# Which reviewer set to run."));
}

#[test]
fn merge_changes_nothing_outside_the_inserted_block() {
    let entries = seeded("[env]\nDEPTH = \"2\"\n", "review");
    let original = "# mine\r\n[env]\r\nREVIEWERS = \"mine\"\r\n\r\n[custom]\r\nX = \"1\"\r\n";
    let (merged, added) = merge(Some(original), &entries).unwrap();
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
    let (merged, _) = merge(Some(original), &entries).unwrap();
    assert!(
        merged.starts_with("[env]\nREVIEWERS = \"mine\"\n"),
        "{merged:?}"
    );
    assert!(merged.ends_with("DEPTH = \"2\"\n"));
}

#[test]
fn unedited_seeded_comment_refreshes_when_the_template_revises_it() {
    let v1 = seeded("[env]\n# Old words.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&v1);
    let file = "[env]\n# Old words.\nDEPTH = \"9\"\n";

    let v2 = seeded(
        "[env]\n# New words.\n# Two lines now.\nDEPTH = \"2\"\n",
        "review",
    );
    let (out, updated) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert_eq!(
        out,
        "[env]\n# New words.\n# Two lines now.\nDEPTH = \"9\"\n"
    );
    assert_eq!(
        ledger.get("DEPTH").unwrap().hash,
        comment_hash(&["# New words.".to_owned(), "# Two lines now.".to_owned()]),
        "the ledger follows the rewrite"
    );

    // Idempotent: running again changes nothing.
    let (again, updated) = refresh_comments(&out, &v2, &mut ledger);
    assert_eq!(again, out);
    assert!(updated.is_empty());
}

#[test]
fn a_hand_edited_comment_is_preserved_forever() {
    let v1 = seeded("[env]\n# Old words.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&v1);
    let file = "[env]\n# My own explanation.\nDEPTH = \"9\"\n";

    let v2 = seeded("[env]\n# New words.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(out, file, "a hand-edited comment never rewrites");
    assert!(updated.is_empty());
}

#[test]
fn value_lines_are_untouched_byte_for_byte() {
    let v1 = seeded("[env]\n# Old.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&v1);
    // Odd spacing and a trailing comment on the value line must survive.
    let file = "[env]\n# Old.\nDEPTH   =\t\"9\"   # keep me\n";
    let v2 = seeded("[env]\n# New.\nDEPTH = \"2\"\n", "review");
    let (out, _) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(out, "[env]\n# New.\nDEPTH   =\t\"9\"   # keep me\n");
}

#[test]
fn crlf_and_missing_terminator_survive_outside_the_comment_block() {
    let v1 = seeded("[env]\n# Old.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&v1);
    let file = "# head\r\n[env]\r\n# Old.\r\nDEPTH = \"9\"\r\n\r\n[custom]\r\nX = \"1\"";
    let v2 = seeded("[env]\n# New.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert_eq!(
        out, "# head\r\n[env]\r\n# New.\r\nDEPTH = \"9\"\r\n\r\n[custom]\r\nX = \"1\"",
        "comment bytes are the only bytes that changed"
    );
}

#[test]
fn another_owners_template_never_rewrites_a_seeded_comment() {
    let original_owner = seeded("[env]\n# Old.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&original_owner);
    let file = "[env]\n# Old.\nDEPTH = \"9\"\n";
    // A different skill now ships the same key with new words.
    let intruder = seeded("[env]\n# Their words.\nDEPTH = \"3\"\n", "other-skill");
    let (out, updated) = refresh_comments(file, &intruder, &mut ledger);
    assert_eq!(out, file);
    assert!(updated.is_empty());
    assert_eq!(
        ledger.get("DEPTH").unwrap().owner.as_deref(),
        Some("review"),
        "the record stays with its owner"
    );
}

#[test]
fn a_v1_imported_record_verifies_but_never_rewrites() {
    let mut ledger = BTreeMap::new();
    ledger.insert(
        "DEPTH".to_owned(),
        SettingsSeed {
            owner: None,
            hash: comment_hash(&["# Old.".to_owned()]),
        },
    );
    let file = "[env]\n# Old.\nDEPTH = \"9\"\n";
    let v2 = seeded("[env]\n# New.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(out, file, "legacy-owned: preserved, never rewritten");
    assert!(updated.is_empty());
    assert_eq!(ledger.get("DEPTH").unwrap().owner, None);
}

#[test]
fn bootstrap_adopts_a_template_matching_comment_and_freezes_an_edited_one() {
    // Pre-ledger install: the file matches the current template exactly.
    let mut ledger = BTreeMap::new();
    let file = "[env]\n# Current words.\nDEPTH = \"9\"\n";
    let current = seeded("[env]\n# Current words.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &current, &mut ledger);
    assert_eq!(out, file);
    assert!(updated.is_empty());
    assert_eq!(
        ledger.get("DEPTH").unwrap().owner.as_deref(),
        Some("review"),
        "a matching comment is adopted into the ledger"
    );
    // The next template revision now refreshes it.
    let revised = seeded("[env]\n# Revised words.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(&out, &revised, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert!(out.contains("# Revised words."));

    // Pre-ledger install whose comment differs: hand-edited, never adopted.
    let mut ledger = BTreeMap::new();
    let edited = "[env]\n# Somebody's own words.\nDEPTH = \"9\"\n";
    let (out, updated) = refresh_comments(edited, &revised, &mut ledger);
    assert_eq!(out, edited);
    assert!(updated.is_empty());
    assert!(!ledger.contains_key("DEPTH"));
}

/// A bare key says nothing about who wrote it: an empty on-disk block
/// matching an empty template block is not adoption evidence, or a later
/// template revision would write prose above a line the user typed.
#[test]
fn a_bare_key_is_never_adopted() {
    let mut ledger = BTreeMap::new();
    let file = "[env]\nDEPTH = \"9\"\n";
    let bare = seeded("[env]\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &bare, &mut ledger);
    assert_eq!(out, file);
    assert!(updated.is_empty());
    assert!(!ledger.contains_key("DEPTH"), "nothing to adopt");

    let with_words = seeded("[env]\n# Now with words.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &with_words, &mut ledger);
    assert_eq!(out, file, "the user's bare key stays bare");
    assert!(updated.is_empty());
}

/// A v1 import names no owner. A template earns the record when the
/// comment on disk is provably what v1 seeded and matches the template
/// word for word; a comment that drifted stays legacy-owned.
#[test]
fn a_v1_record_is_adopted_only_by_a_matching_template_over_unedited_text() {
    let mut ledger = BTreeMap::new();
    ledger.insert(
        "DEPTH".to_owned(),
        SettingsSeed {
            owner: None,
            hash: comment_hash(&["# Old.".to_owned()]),
        },
    );
    let file = "[env]\n# Old.\nDEPTH = \"9\"\n";
    let same_words = seeded("[env]\n# Old.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &same_words, &mut ledger);
    assert_eq!(out, file);
    assert!(updated.is_empty());
    assert_eq!(
        ledger.get("DEPTH").unwrap().owner.as_deref(),
        Some("review"),
        "provably unedited and word-for-word the template: adopted"
    );
    let revised = seeded("[env]\n# Newer.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(&out, &revised, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert!(out.contains("# Newer."));

    // Hand-edited since v1 seeded it (hash no longer matches), even if the
    // words now happen to equal a template: legacy-owned, frozen.
    let mut ledger = BTreeMap::new();
    ledger.insert(
        "DEPTH".to_owned(),
        SettingsSeed {
            owner: None,
            hash: comment_hash(&["# What v1 wrote.".to_owned()]),
        },
    );
    let edited = "[env]\n# Old.\nDEPTH = \"9\"\n";
    refresh_comments(edited, &same_words, &mut ledger);
    assert_eq!(ledger.get("DEPTH").unwrap().owner, None);
}

/// Two skills ship one key. Seeding wrote the first declaration; a later
/// pass where the other skill enumerates first must still refresh from
/// the recorded owner's template — declaration order never shadows the
/// ledger.
#[test]
fn the_recorded_owner_speaks_for_a_key_several_skills_ship() {
    let review = seeded("[env]\n# Review's words.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&review);
    let file = "[env]\n# Review's words.\nDEPTH = \"9\"\n";
    let mut entries = seeded("[env]\n# Lint's words.\nDEPTH = \"1\"\n", "aaa-lint");
    entries.extend(seeded(
        "[env]\n# Review's better words.\nDEPTH = \"2\"\n",
        "review",
    ));
    let (out, updated) = refresh_comments(file, &entries, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert!(out.contains("# Review's better words."), "{out}");
    assert!(!out.contains("# Lint's words."));
    assert_eq!(
        ledger.get("DEPTH").unwrap().owner.as_deref(),
        Some("review")
    );
}

/// Seeding writes the first declaration of a key and the ledger records
/// that skill — the same choice, so the owner can refresh what it wrote.
#[test]
fn merge_seeds_the_first_declaration_and_records_it_as_owner() {
    let mut entries = seeded("[env]\n# First.\nDEPTH = \"1\"\n", "first");
    entries.extend(seeded("[env]\n# Second.\nDEPTH = \"2\"\n", "second"));
    let (out, added) = merge(Some("[env]\n"), &entries).unwrap();
    assert_eq!(added, ["DEPTH"]);
    assert!(out.contains("# First.\nDEPTH = \"1\""), "{out}");
    assert!(!out.contains("# Second."));
    let mut ledger = BTreeMap::new();
    record_seeds(&mut ledger, &entries, &added);
    assert_eq!(ledger.get("DEPTH").unwrap().owner.as_deref(), Some("first"));
}

/// A hand-made duplicate inside `[env]` is judged once, at its first
/// site — never two rewrites and never a key listed twice in the plan.
#[test]
fn a_duplicated_key_is_refreshed_once() {
    let v1 = seeded("[env]\n# Old.\nDEPTH = \"2\"\n", "review");
    let mut ledger = ledger_for(&v1);
    let file = "[env]\n# Old.\nDEPTH = \"9\"\n# Old.\nDEPTH = \"8\"\n";
    let v2 = seeded("[env]\n# New.\nDEPTH = \"2\"\n", "review");
    let (out, updated) = refresh_comments(file, &v2, &mut ledger);
    assert_eq!(updated, ["DEPTH"]);
    assert_eq!(out, "[env]\n# New.\nDEPTH = \"9\"\n# Old.\nDEPTH = \"8\"\n");
}

#[test]
fn comment_hash_matches_v1s_algorithm() {
    // Locked against v1's `format!("{:016x}", fnv1a(join("\n")))` so
    // imported ledgers verify without re-guessing.
    assert_eq!(comment_hash(&[]), "cbf29ce484222325");
    assert_eq!(comment_hash(&["# a".to_owned()]), {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in b"# a" {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("{h:016x}")
    });
}

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
            assignment: vec!["DEPTH = \"2\"".to_owned()],
        },
        owner: "review".to_owned(),
    }];

    // A nested array bracket is not a table header.
    let nested = "[env]\nLIST = [\n  []\n]\n";
    let (text, added) = merge(Some(nested), &seeded).expect("DEPTH is missing");
    assert_eq!(added, vec!["DEPTH".to_owned()]);
    assert!(
        text.starts_with("[env]\nLIST = [\n  []\n]\n"),
        "the array must come through whole:\n{text}"
    );
    assert!(text.contains("DEPTH = \"2\""), "{text}");

    // And a header the boundary test used to miss ends the section.
    let commented = "[env]\nMODE = \"a\"\n\n[other] # note\nKEEP = \"b\"\n";
    let (text, _) = merge(Some(commented), &seeded).expect("DEPTH is missing");
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
            assignment: vec!["DEPTH = \"2\"".to_owned()],
        },
        owner: "review".to_owned(),
    }];
    let file = "[env] # the table\nMODE = \"a\"\n\n[other]\nKEEP = \"b\"\n";
    let (text, _) = merge(Some(file), &seeded).expect("DEPTH is missing");

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
            assignment: vec!["DEPTH = \"2\"".to_owned()],
        },
        owner: "review".to_owned(),
    }];
    for header in ["[env]", "[env] # note", "[ env ]", "[\"env\"]", "['env']"] {
        let file = format!("{header}\nMODE = \"a\"\n\n[other]\nKEEP = \"b\"\n");
        let (text, _) = merge(Some(&file), &seeded).expect("DEPTH is missing");
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
            assignment: vec!["DEPTH = \"2\"".to_owned()],
        },
        owner: "review".to_owned(),
    }];
    let file = "[[env]]\nMODE = \"a\"\n";
    assert_eq!(env_blocked(file), Some(EnvBlocked::Array(1)));
    assert_eq!(
        merge(Some(file), &seeded),
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
            assignment: vec!["DEPTH = \"2\"".to_owned()],
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
            merge(Some(file), &seeded),
            None,
            "{file}: nothing may be written into a file with nowhere to write"
        );
    }
    // Under a header the name belongs to that table, not the top level,
    // so the `[env]` a seed opens is still free.
    let nested = "[other]\nenv.MODE = \"a\"\n";
    assert_eq!(env_blocked(nested), None);
    assert!(
        merge(Some(nested), &seeded).is_some(),
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
        // One assignment line per line of the value: the first carries
        // the `=`, the last closes it.
        assert_eq!(
            entries[0].assignment.len(),
            value.lines().count(),
            "{value}"
        );
        assert!(entries[0].closes(), "{value}");

        let (text, added) = merge(None, &seeded(&template, "review")).expect("both are missing");
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
    assert!(!entries[1].closes(), "{entries:?}");
    assert!(entries[1].assignment.is_empty(), "{entries:?}");

    let shipped = seeded(template, "review");
    let (text, added) = merge(None, &shipped).expect("DEPTH is missing");
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
    let (text, added) = merge(None, &both).expect("both are missing");
    assert_eq!(added, ["DEPTH", "BLOB"]);
    assert!(text.contains("BLOB = \"ok\""), "{text}");
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
