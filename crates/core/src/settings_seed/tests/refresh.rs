//! Seeded comments staying current: what a refresh may rewrite, and
//! everything it must preserve forever.

use std::collections::BTreeMap;

use super::*;

/// The ledger as seeding would have left it for these entries.
fn ledger_for(entries: &[SeededEnv]) -> BTreeMap<String, SettingsSeed> {
    entries
        .iter()
        .map(|seeded| (seeded.entry.key.clone(), seeded.seed_record()))
        .collect()
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

/// Two skills ship one key. Seeding wrote one of them; a later pass where
/// the other skill enumerates first must still refresh from the recorded
/// owner's template — declaration order never shadows the ledger.
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

/// Seeding writes the first declaration that can be written whole and the
/// ledger records that skill — one selection, so the owner can refresh
/// what it wrote.
#[test]
fn merge_seeds_the_first_writable_declaration_and_records_it_as_owner() {
    let mut entries = seeded("[env]\n# First.\nDEPTH = \"1\"\n", "first");
    entries.extend(seeded("[env]\n# Second.\nDEPTH = \"2\"\n", "second"));
    let (out, added) = merge(Some("[env]\n"), &entries, &super::all(&entries)).unwrap();
    assert_eq!(added, ["DEPTH"]);
    assert!(out.contains("# First.\nDEPTH = \"1\""), "{out}");
    assert!(!out.contains("# Second."));
    let mut ledger = BTreeMap::new();
    record_seeds(&mut ledger, &entries, &added, &super::all(&entries));
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
