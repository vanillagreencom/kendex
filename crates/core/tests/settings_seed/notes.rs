//! What a pass SAYS about the keys it does not write: a key the template
//! marks `# required` that nothing here answers, and a key several
//! packages ship with different defaults. Both are said on every pass,
//! including the passes that cannot write the file at all — that one is
//! the arrival a marked key would otherwise have ridden in on, so silence
//! there loses the key entirely.

use std::fs;

use kendex_core::engine::audit;

use super::scope::{arrive, fixture, many_owners, names_unanswered, refresh_now, without_key};

/// A required key nothing writes is named on every pass, so a template
/// that gains one after release reaches the consumer as a note rather than
/// as a write into their file.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unanswered_required_key_is_reported_on_every_pass() {
    let f = fixture(true);
    let says_it = |report: &kendex_core::engine::EngineReport| {
        report
            .notes
            .iter()
            .filter(|note| note.contains("REVIEWERS") && note.contains("needs this key decided"))
            .count()
    };
    assert_eq!(says_it(&audit(&f.env, &f.scope).unwrap()), 1);

    // The arrival writes it, and has nothing left to report.
    arrive(&f, &["review"]);
    assert_eq!(says_it(&audit(&f.env, &f.scope).unwrap()), 0);

    // Deleted on purpose: the note comes back, and no write does.
    let settings_path = f.project.join("kendex.settings.toml");
    let text = fs::read_to_string(&settings_path).unwrap();
    fs::write(&settings_path, without_key(&text, "REVIEWERS")).unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(says_it(&report), 1, "{:?}", report.notes);
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| op.line().contains("kendex.settings.toml")),
        "reported, never written"
    );

    // A key with a working default is never reported.
    assert!(
        !report.notes.iter().any(|note| note.contains("DEPTH")),
        "{:?}",
        report.notes
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn occupied_settings_path_is_a_conflict_not_a_clobber() {
    let f = fixture(true);
    fs::create_dir_all(f.project.join("kendex.settings.toml")).unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.detail.contains("not a regular file"))
    );
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| op.line().contains("kendex.settings.toml"))
    );
    // A file kendex cannot see into answers no key, and the row saying so
    // does not excuse the pass from saying which keys went unanswered:
    // the conflict names the path, and this names what is still undecided.
    assert!(names_unanswered(&report, "REVIEWERS"), "{:?}", report.notes);
}

/// The one pass that would ever have written a marked key is the arrival,
/// and a pass that cannot write the file writes nothing. So the key has to
/// be named HERE. Built from the pass's own seeding the notes count it
/// answered and say nothing, and it is then dropped twice over: no line in
/// the file, and nothing said about it anywhere. The person heard about it
/// on their next refresh, which arrives nothing and so has none of it to
/// call answered.
#[test]
#[allow(clippy::unwrap_used)]
fn an_arrival_that_cannot_write_the_file_names_the_key_it_could_not_write() {
    let f = fixture(true);
    fs::create_dir_all(f.project.join("kendex.settings.toml")).unwrap();
    let report = arrive(&f, &["review"]);
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.detail.contains("not a regular file")),
        "{:?}",
        report
            .drift
            .iter()
            .map(|row| &row.detail)
            .collect::<Vec<_>>()
    );
    assert!(
        names_unanswered(&report, "REVIEWERS"),
        "the key the arrival could not write is named on that same pass: {:?}",
        report.notes
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_key_shipped_with_differing_defaults_gets_one_grouped_note() {
    let f = many_owners(&[
        (
            "alpha",
            "[env]\n# How long to wait.\nWAIT = \"900\" # required\n",
        ),
        (
            "beta",
            "[env]\n# How long to wait.\nWAIT = \"900\" # required\n",
        ),
        (
            "gamma",
            "[env]\n# How long to wait.\nWAIT = \"600\" # required\n",
        ),
    ]);
    let notes = audit(&f.env, &f.scope).unwrap().notes;
    let about: Vec<&String> = notes
        .iter()
        .filter(|note| note.contains("different defaults"))
        .collect();
    assert_eq!(about.len(), 1, "{notes:?}");
    // Every owner and every distinct default, in one line.
    assert!(about[0].contains("\"900\" (alpha, beta)"), "{about:?}");
    assert!(about[0].contains("\"600\" (gamma)"), "{about:?}");
    // This pass arrives nothing, so the note claims no write.
    assert!(
        about[0].contains("nothing here writes this key"),
        "{about:?}"
    );

    // The note changes nothing: the declaration seeding picked still lands.
    arrive(&f, &["alpha", "beta", "gamma"]);
    let seeded = fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap();
    assert!(seeded.contains("WAIT = \"900\""), "{seeded}");
    assert!(!seeded.contains("\"600\""), "{seeded}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_key_shipped_with_one_default_everywhere_is_silent() {
    let f = many_owners(&[
        ("alpha", "[env]\n# The gate.\nMODE = \"enforce\"\n"),
        ("beta", "[env]\n# The gate.\nMODE = \"enforce\"\n"),
    ]);
    let notes = audit(&f.env, &f.scope).unwrap().notes;
    assert!(!notes.iter().any(|note| note.contains("MODE")), "{notes:?}");
}

/// The disagreement fires on a key the file already assigns too, where
/// nothing would be written whatever the pass. It is still worth saying;
/// claiming a value landed there would not be — and neither would sending
/// them after a shipped default. Their line is what their scripts read,
/// and no default any package carries reaches those scripts at all, so a
/// note about one points at the wrong thing to change.
#[test]
#[allow(clippy::unwrap_used)]
fn the_note_names_the_line_the_file_has_rather_than_a_default_nothing_reads() {
    let f = many_owners(&[
        (
            "alpha",
            "[env]\n# How long to wait.\nWAIT = \"900\" # required\n",
        ),
        (
            "beta",
            "[env]\n# How long to wait.\nWAIT = \"600\" # required\n",
        ),
    ]);
    let settings = f.project.join("kendex.settings.toml");
    fs::write(&settings, "[env]\n# Mine.\nWAIT = \"5\"\n").unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let about: Vec<&String> = report
        .notes
        .iter()
        .filter(|note| note.contains("WAIT"))
        .collect();
    assert_eq!(about.len(), 1, "{:?}", report.notes);
    assert!(
        about[0].contains("this file already assigns it, so that value is what your scripts read"),
        "{about:?}"
    );
    assert!(
        !about[0].contains("whichever default they carry"),
        "their own line is what the scripts read: {about:?}"
    );
    // Nothing is planned for the settings file, so nothing was seeded.
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| op.line().contains("kendex.settings.toml")),
        "an assigned key must not be re-seeded"
    );
    refresh_now(&f);
    assert_eq!(
        fs::read_to_string(&settings).unwrap(),
        "[env]\n# Mine.\nWAIT = \"5\"\n"
    );
}
