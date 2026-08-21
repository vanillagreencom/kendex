//! Where a lock-carried record came from, and what happens when this
//! project cannot say.
//!
//! The lock travels in the project repository and a pull request can edit
//! it. Every other check on a record read back out of it answers a question
//! about shape — is the hash this content's, is the fingerprint one this
//! build could have written — and none of those can answer provenance,
//! which is what a publisher's record trades on.

use std::fs;

use kendex_core::model::ItemKind;

use super::author_reviews::{author_dismisses, observed, observed_rows, row};
use super::fixture::{fixture, plan};

/// Provenance is the one thing a shape check cannot answer, and the one
/// thing a publisher's record trades on: it removes findings from the score
/// and unblocks an install, where a person's own dismissal never unblocks
/// anything. A forgery with the right hash, a real fingerprint, a plausible
/// name and an in-range count passes everything a shape can be asked — so
/// the audit asks the manifest instead, and a record naming a publisher
/// this project does not install the item from settles nothing.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_lock_record_this_project_cannot_vouch_for_settles_nothing() {
    use kendex_core::engine::decisions::DecisionState;
    use kendex_core::quality::Verdict;

    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let report = plan(&f, &[]);
    assert!(
        !row(&report, "hostile").blocked(),
        "the publisher's own record is what lets it install"
    );
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    let vouched = observed(&f, "hostile");
    assert_eq!(vouched.verdict, Verdict::Clean);

    // Everything the record claims stays valid — the bytes it binds to, the
    // fingerprint it names, the count it earned. Only the name changes, to
    // a catalog this project has never subscribed to.
    let path = kendex_core::lock::lock_path(&f.env, &f.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let mut forged = 0;
    for entry in lock["entries"].as_object_mut().unwrap().values_mut() {
        let Some(review) = entry.get_mut("authorReview") else {
            continue;
        };
        review["publisher"] = "trusted-corp/skills".into();
        forged += 1;
    }
    assert_eq!(forged, 1, "the fixture writes one record to forge");
    fs::write(&path, lock.to_string()).unwrap();

    let after = observed(&f, "hostile");
    assert_eq!(
        after.verdict,
        Verdict::Block,
        "the finding counts again and the item is held back"
    );
    assert!(
        after
            .decisions
            .iter()
            .all(|decision| !matches!(decision.state, DecisionState::AuthorDismissed { .. })),
        "nothing reads as settled by a publisher: {:?}",
        after.decisions
    );
    assert!(
        after.decisions.iter().any(|decision| matches!(
            &decision.state,
            DecisionState::Open { earlier: Some(why) }
                if why.contains("trusted-corp/skills") && why.contains("settles nothing")
        )),
        "and the record is still reported, saying why it bought nothing: {:?}",
        after.decisions
    );
}

/// The record is looked for across every entry that names this content, and
/// one entry that does not hold up must not end the search. Several tools
/// load one shared tree and each writes its own entry, so only one of them
/// has to be intact for the publisher's decision to stand — asking whether
/// an entry is honest only after the first match had been picked let a
/// single corrupt copy take the decision away from every row.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn one_corrupt_entry_does_not_hide_a_valid_one() {
    let f = fixture();
    author_dismisses(&f.source, ItemKind::Skill, "hostile", &[]);
    let manifest = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&manifest).unwrap().replace(
        "harnesses = [\"claude\"]",
        "harnesses = [\"claude\", \"codex\"]",
    );
    fs::write(&manifest, text).unwrap();
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(observed_rows(&f, "hostile").len() > 1);

    // The first entry holding a record, by the order the lookup walks them,
    // claims more occurrences than there are findings — everything
    // `is_honest` is for.
    let path = kendex_core::lock::lock_path(&f.env, &f.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let entries = lock["entries"].as_object_mut().unwrap();
    let first = entries
        .iter()
        .filter(|(_, entry)| entry.get("authorReview").is_some())
        .map(|(key, _)| key.clone())
        .min()
        .expect("the apply wrote a record");
    let corrupt = entries.get_mut(&first).unwrap();
    for dismissal in corrupt["authorReview"]["dismissed"]
        .as_object_mut()
        .unwrap()
        .values_mut()
    {
        dismissal["occurrences"] = serde_json::json!({ "critical": 4294967295u32 });
    }
    fs::write(&path, lock.to_string()).unwrap();

    for row in observed_rows(&f, "hostile") {
        assert!(
            !row.blocked(),
            "{} still reads the intact copy of the record",
            row.harness.name()
        );
    }
}

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
    assert!(
        after.decisions.iter().any(|decision| matches!(
            &decision.state,
            kendex_core::engine::decisions::DecisionState::Open { earlier: Some(why) }
                if why.contains("does not publish")
        )),
        "and the record is still reported, saying why: {:?}",
        after.decisions
    );
}
