//! What a committed reviews file can and cannot claim.
//!
//! `kendex-reviews.toml` is committed TOML anybody can hand-write, and it
//! arrives from a source kendex does not control. Everything the writer
//! refuses to record, the reader has to refuse too.

use std::fs;

use kendex_core::model::ItemKind;

use super::author_reviews::{author_dismisses, row};
use super::fixture::{fixture, plan};

/// `trusted-source` is a claim about where bytes came from, and only the
/// machine receiving them can answer it. The writer refuses to record one;
/// the reader has to refuse one anyway, because the file is committed TOML
/// a third party writes by hand.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_trusted_source_record_settles_nothing() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let path = f.source.join("kendex-reviews.toml");
    let text = fs::read_to_string(&path)
        .unwrap()
        .replace("intended", "trusted-source");
    fs::write(&path, text).unwrap();
    assert!(row(&plan(&f, &[]), "hostile").blocked());
}

/// And nothing a record carries reaches a terminal unchecked: a timestamp
/// is printed beside the finding, so a record whose timestamp is a forged
/// line is not a record.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_carrying_a_forged_timestamp_settles_nothing() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let path = f.source.join("kendex-reviews.toml");
    let text = fs::read_to_string(&path).unwrap();
    let forged = text
        .lines()
        .map(|line| match line.starts_with("dismissed-at") {
            true => "dismissed-at = \"2026-01-01T00:00:00Z\\n[critical] nothing to see here\"",
            false => line,
        })
        .collect::<Vec<&str>>()
        .join("\n");
    fs::write(&path, forged).unwrap();
    assert!(row(&plan(&f, &[]), "hostile").blocked());
}

/// A reviews file the catalog cannot even parse settles nothing, and says
/// so. Failing closed is right; failing closed in silence would leave an
/// installer unable to tell a broken review file from a publisher who
/// reviewed nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_reviews_file_settles_nothing_and_says_so() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    fs::write(
        f.source.join("kendex-reviews.toml"),
        "this is not toml [[[\n",
    )
    .unwrap();
    let report = plan(&f, &[]);
    assert!(row(&report, "hostile").blocked());
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("kendex-reviews.toml") && note.contains("could not be read")),
        "the plan says the review file could not be read: {:?}",
        report.notes
    );
}

/// A record naming a finding that is not there settles nothing — and says
/// so. The publisher's own CI stays green either way, so this note is the
/// only place anybody learns that a review was carried and did not apply.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_naming_a_finding_that_is_not_there_is_reported() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let path = f.source.join("kendex-reviews.toml");
    let text = fs::read_to_string(&path).unwrap()
        + "\n[reviews.\"skill:hostile\".dismissed.0000000000000000]\nreason = \"intended\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n";
    fs::write(&path, text).unwrap();
    let report = plan(&f, &[]);
    // The real record still holds; only the one naming nothing is refused.
    assert!(!row(&report, "hostile").blocked());
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("hostile") && note.contains("settle nothing here")),
        "the plan says a carried record did not apply: {:?}",
        report.notes
    );
}
