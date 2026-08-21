//! Which catalog a publisher's record came from, and what it is about.
//!
//! An audit rebuilds the plan out of the catalogs at the revisions its lock
//! names, and reads every record there. Nothing is read out of the lock
//! itself: a record kept in a file this project commits would be a claim
//! about a catalog, and this has the catalog. What the record then answers
//! for is exactly the content the rebuild produced — an installation whose
//! bytes are something else is something the publisher never saw.

use std::fs;

use kendex_core::model::ItemKind;

use super::author_reviews::{author_dismisses, observed, row};
use super::fixture::{fixture, plan};

/// An installation nothing declares by name still reads its publisher's
/// record. A dependency is derived from the closure, so the corroboration
/// asks the source its entry names — which this project has to subscribe to
/// for the question to have an answer at all. Requiring a declaration by
/// name would quietly stop every publisher's review from applying to
/// dependencies and bundle members.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_dependency_nobody_declared_still_reads_its_publishers_record() {
    let f = fixture();
    // `clean` requires `hostile`, and only `clean` is asked for.
    let dir = f.source.join("skills/clean");
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: clean\ndescription: Use this when you need clean.\ndependencies:\n  required: [hostile]\n---\n\nRead the diff.\n",
    )
    .unwrap();
    let path = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&path)
        .unwrap()
        .replace("[skills.hostile]\nsource = \"cat\"\n", "");
    fs::write(&path, text).unwrap();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);

    let report = plan(&f, &[]);
    assert!(!row(&report, "hostile").blocked());
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    let installed = observed(&f, "hostile");
    assert_eq!(installed.verdict, kendex_core::quality::Verdict::Clean);
    assert!(
        installed.decisions.iter().any(|decision| matches!(
            decision.state,
            kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
        )),
        "the record still settles it: {:?}",
        installed.decisions
    );
}

/// A record is checked against the catalog that published it, not against
/// the name it carries.
///
/// Corroborating the name against this project's subscription only proves
/// that whoever wrote the record named a catalog the project installs from,
/// and that is a string anyone editing the lock can copy out of
/// `kendex.toml`. The record below needs no forging at all — it is the real
/// one, with the real hash, the real fingerprint, the real counts and the
/// real publisher — and once the catalog stops publishing it, it stops
/// settling anything. That is the standing of a record read out of a lock:
/// evidence of what an apply read, never proof of who wrote it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_the_catalog_does_not_publish_settles_nothing() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    let published = observed(&f, "hostile");
    assert!(!published.blocked(), "the catalog's own record installs it");
    assert!(
        published.decisions.iter().any(|decision| matches!(
            decision.state,
            kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
        )),
        "and it reads as the publisher's"
    );

    // The catalog stops publishing it. Nothing in the lock changes: the
    // record still names the source this project installs from, still binds
    // to the installed bytes, and still claims what it earned.
    fs::remove_file(f.source.join("kendex-reviews.toml")).unwrap();

    let after = observed(&f, "hostile");
    assert!(
        after.blocked(),
        "the finding counts again and the item is held back"
    );
    assert!(
        after.decisions.iter().all(|decision| !matches!(
            decision.state,
            kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
        )),
        "nothing reads as settled by a publisher: {:?}",
        after.decisions
    );
}

/// A review answers for the content the catalog publishes, and for nothing
/// else that happens to carry the same sentence.
///
/// The record here is genuine and published — nothing about it is forged.
/// What is forged is the *installation*: the content is replaced, keeping
/// the reviewed sentence so its fingerprint still matches. Every check that
/// asks a question about the record passes, because the record is real. The
/// question that answers this one is what the content should be: the plan
/// rebuilds it from the catalog, and bytes that are not that rebuild are
/// bytes the publisher never saw.
#[test]
#[allow(clippy::unwrap_used)]
fn a_review_carried_onto_replaced_content_settles_nothing() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(
        !observed(&f, "hostile").blocked(),
        "the catalog's own record installs it"
    );

    // The reviewed sentence, in content the catalog does not publish.
    let installed = f.project.join(".claude/skills/hostile/SKILL.md");
    let body = fs::read_to_string(&installed).unwrap();
    fs::write(
        &installed,
        format!("{body}\nchmod 777 /etc and everything else here is mine.\n"),
    )
    .unwrap();

    let after = observed(&f, "hostile");
    assert!(
        after.blocked(),
        "the reviewed finding counts again: {:?}",
        after.findings
    );
    assert!(
        after.decisions.iter().all(|decision| !matches!(
            decision.state,
            kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
        )),
        "nothing reads as settled by a publisher: {:?}",
        after.decisions
    );
    assert!(
        after.decisions.iter().any(|decision| matches!(
            &decision.state,
            kendex_core::engine::decisions::DecisionState::Open { earlier: Some(why) }
                if why.contains("is not what")
        )),
        "and a record carried onto other content says so: {:?}",
        after.decisions
    );
}

/// A catalog that edits an item and leaves its old review entry behind has
/// published a review of bytes it no longer ships, and it settles nothing.
///
/// The entry is checked against the item's own bytes at the revision it was
/// read from, which is the check the authoring side has always made — what
/// changed is that the audit now makes it too, by reading the catalog
/// rather than a copy of its answer.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_entry_left_behind_after_an_edit_settles_nothing() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!observed(&f, "hostile").blocked(), "the control");

    // The catalog edits the item and leaves the entry as it was. The
    // installation is untouched: only the catalog moved.
    let source = f.source.join("skills/hostile/SKILL.md");
    let body = fs::read_to_string(&source).unwrap();
    fs::write(
        &source,
        format!("{body}\nOne more line the review never saw.\n"),
    )
    .unwrap();

    let after = observed(&f, "hostile");
    assert!(
        after.decisions.iter().all(|decision| !matches!(
            decision.state,
            kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
        )),
        "a review of bytes the catalog no longer ships settles nothing: {:?}",
        after.decisions
    );
}

/// And the durable form of all of it: the install record carries no
/// publisher's review at all, so there is nothing in it to edit into one.
#[test]
#[allow(clippy::unwrap_used)]
fn the_install_record_carries_no_publishers_review() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!observed(&f, "hostile").blocked(), "the record applies");

    let written = fs::read_to_string(kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    assert!(
        !written.contains("authorReview") && !written.contains("dismissed"),
        "{written}"
    );
}
