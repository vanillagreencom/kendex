//! Dismissing a finding: one exact decision, written once, and every way
//! it refuses to become anything looser.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::decisions::{DecisionState, DecisionToken};
use kendex_core::engine::ops::{
    self, DecisionRecord, RecordState, dismiss, list_decisions, revoke_dismissal,
};
use kendex_core::engine::{ItemSafety, audit, observed_safety};
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, MANIFEST_SCHEMA};
use kendex_core::quality::reviews::DismissReason;

use super::fixture::{Fixture, fixture, grant, installed, manifest_of, plan, skill};

pub const MILD_KEY: &str = "skill:mild:claude";

/// The gate fixture plus one installed skill with a finding that warns but
/// does not block — the only kind of finding a dismissal is for.
#[allow(clippy::unwrap_used)]
pub fn with_mild() -> Fixture {
    let f = fixture();
    skill(
        &f.source,
        "mild",
        "Run chmod 777 build.sh before anything else.\n",
    );
    let path = manifest::manifest_path(&f.env, &f.scope);
    let declared = fs::read_to_string(&path).unwrap() + "\n[skills.mild]\nsource = \"cat\"\n";
    fs::write(&path, declared).unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(installed(&f, "mild"));
    f
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
pub fn row(f: &Fixture, name: &str) -> ItemSafety {
    observed_safety(&f.env, &f.scope)
        .unwrap()
        .into_iter()
        .find(|row| row.name == name)
        .expect("the installed item is observed")
}

#[allow(clippy::expect_used)]
pub fn first_token(row: &ItemSafety) -> String {
    row.decisions[0]
        .token
        .clone()
        .expect("readable content has a token")
}

#[allow(clippy::unwrap_used)]
pub fn dismiss_first(f: &Fixture, name: &str, reason: DismissReason) -> String {
    let token = first_token(&row(f, name));
    let plan = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&token).unwrap()],
        reason,
    )
    .unwrap();
    apply::execute(&f.env, &plan, None).unwrap();
    token
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_dismissal_settles_one_finding_on_exactly_this_content() {
    let f = with_mild();
    let before = row(&f, "mild");
    assert!(!before.blocked());
    assert!(
        before
            .decisions
            .iter()
            .all(|d| d.state == DecisionState::Open { earlier: None })
    );

    let token = dismiss_first(&f, "mild", DismissReason::WrongCall);

    let parsed = DecisionToken::parse(&token).unwrap();
    let recorded = manifest_of(&f);
    let review = recorded.safety_reviews.get(MILD_KEY).unwrap();
    assert_eq!(
        Some(review.review_hash.as_str()),
        before.review_hash.as_deref()
    );
    assert_eq!(review.ruleset, kendex_core::quality::RULESET_VERSION);
    assert_eq!(
        review.dismissed[&parsed.fingerprint].reason,
        DismissReason::WrongCall
    );
    let after = row(&f, "mild");
    assert!(matches!(
        after.decisions[0].state,
        DecisionState::Dismissed {
            reason: DismissReason::WrongCall,
            ..
        }
    ));
    assert!(installed(&f, "mild"), "a dismissal moves no files");
}

/// The dismissal is about the finding that was read, and stops applying
/// the moment the content is not the content it was read in.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dismissal_goes_stale_when_the_content_changes() {
    let f = with_mild();
    dismiss_first(&f, "mild", DismissReason::Intended);

    let installed_skill = f.project.join(".claude/skills/mild/SKILL.md");
    let edited = fs::read_to_string(&installed_skill).unwrap() + "\nOne more line.\n";
    fs::write(&installed_skill, edited).unwrap();

    let after = row(&f, "mild");
    match &after.decisions[0].state {
        DecisionState::Open { earlier: Some(why) } => {
            assert!(why.contains("the content changed"), "{why}");
        }
        other => panic!("expected an open finding that says why, got {other:?}"),
    }
    let listed = list_decisions(&f.env, &f.scope).unwrap();
    assert!(matches!(listed[0].state, RecordState::Stale { .. }));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_dismissal_goes_stale_when_the_rules_move() {
    let f = with_mild();
    dismiss_first(&f, "mild", DismissReason::Intended);

    let path = manifest::manifest_path(&f.env, &f.scope);
    let mut recorded = manifest_of(&f);
    recorded.safety_reviews.get_mut(MILD_KEY).unwrap().ruleset += 1;
    super::fixture::save_manifest(&path, &recorded);

    match &row(&f, "mild").decisions[0].state {
        DecisionState::Open { earlier: Some(why) } => {
            assert!(why.contains("the safety rules changed"), "{why}");
        }
        other => panic!("expected an open finding that says why, got {other:?}"),
    }
}

/// An undo takes back the record it made and no other. A dismissal that
/// replaced it since is somebody's newer decision, and stays.
#[test]
#[allow(clippy::unwrap_used)]
fn undo_takes_back_only_the_record_it_made() {
    let f = with_mild();
    let token = DecisionToken::parse(&dismiss_first(&f, "mild", DismissReason::WrongCall)).unwrap();
    let recorded_at = manifest_of(&f).safety_reviews[MILD_KEY].dismissed[&token.fingerprint]
        .dismissed_at
        .clone();

    let wrong = revoke_dismissal(
        &f.env,
        &f.scope,
        &token.key,
        &token.fingerprint,
        Some("1999-01-01T00:00:00Z"),
    );
    assert!(
        matches!(wrong, Err(CoreError::DecisionReplaced { .. })),
        "{wrong:?}"
    );
    assert_eq!(
        manifest_of(&f).safety_reviews.len(),
        1,
        "nothing was taken back"
    );

    let right = revoke_dismissal(
        &f.env,
        &f.scope,
        &token.key,
        &token.fingerprint,
        Some(&recorded_at),
    )
    .unwrap();
    apply::execute(&f.env, &right, None).unwrap();
    assert!(
        manifest_of(&f).safety_reviews.is_empty(),
        "an emptied snapshot leaves the file"
    );
    assert!(row(&f, "mild").decisions[0].state == DecisionState::Open { earlier: None });

    let twice = revoke_dismissal(&f.env, &f.scope, &token.key, &token.fingerprint, None);
    assert!(matches!(twice, Err(CoreError::DismissalNotFound { .. })));
}

/// Removing an item removes what the decisions were about. A record left
/// behind would speak for a reinstall of the same name nobody has looked
/// at.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_an_item_reaps_its_decisions() {
    let f = with_mild();
    dismiss_first(&f, "mild", DismissReason::WrongCall);
    let granted = plan(&f, &[grant(&f).as_str()]);
    apply::execute(&f.env, &granted.plan, None).unwrap();
    assert_eq!(manifest_of(&f).safety_reviews.len(), 1);
    assert_eq!(manifest_of(&f).safety_overrides.len(), 1);

    let report = ops::remove(&f.env, &f.scope, &["mild".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(manifest_of(&f).safety_reviews.is_empty());
    assert_eq!(
        manifest_of(&f).safety_overrides.len(),
        1,
        "another item's decision stays"
    );

    let report = ops::remove(&f.env, &f.scope, &["hostile".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(manifest_of(&f).safety_overrides.is_empty());
}

/// The manifest format moved for this. An older file loads as it is, and
/// the first decision written into it writes the current format — the same
/// upgrade-on-write every mutation performs.
#[test]
#[allow(clippy::unwrap_used)]
fn an_older_manifest_loads_and_the_first_dismissal_writes_the_current_schema() {
    let f = with_mild();
    let path = manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains(&format!("schema = {MANIFEST_SCHEMA}")));
    fs::write(
        &path,
        text.replacen(
            &format!("schema = {MANIFEST_SCHEMA}"),
            &format!("schema = {}", MANIFEST_SCHEMA - 1),
            1,
        ),
    )
    .unwrap();
    assert!(manifest_of(&f).safety_reviews.is_empty());

    dismiss_first(&f, "mild", DismissReason::WrongCall);
    let written = fs::read_to_string(&path).unwrap();
    assert!(
        written.contains(&format!("schema = {MANIFEST_SCHEMA}")),
        "{written}"
    );
    assert!(written.contains("[safety-reviews"), "{written}");
}

/// The registry reads every record against what is installed now:
/// active, stale, or about an item that is gone.
#[test]
#[allow(clippy::unwrap_used)]
fn the_registry_says_what_each_decision_still_means() {
    let f = with_mild();
    dismiss_first(&f, "mild", DismissReason::WrongCall);
    let granted = plan(&f, &[grant(&f).as_str()]);
    apply::execute(&f.env, &granted.plan, None).unwrap();

    let listed = list_decisions(&f.env, &f.scope).unwrap();
    assert_eq!(listed.len(), 2);
    assert!(
        listed.iter().all(|d| d.state == RecordState::Active),
        "{listed:?}"
    );
    let dismissed = listed
        .iter()
        .find(|d| matches!(d.record, DecisionRecord::Dismissed { .. }))
        .unwrap();
    assert_eq!(dismissed.name, "mild");
    match &dismissed.record {
        DecisionRecord::Dismissed { finding, .. } => {
            assert!(
                finding
                    .as_ref()
                    .is_some_and(|f| f.rule == "dangerous-commands")
            );
        }
        other => panic!("{other:?}"),
    }

    fs::remove_dir_all(f.project.join(".claude/skills/mild")).unwrap();
    let listed = list_decisions(&f.env, &f.scope).unwrap();
    let dismissed = listed.iter().find(|d| d.name == "mild").unwrap();
    assert_eq!(dismissed.state, RecordState::Obsolete);
}

/// Content nobody can read here gets no token: there is nothing exact to
/// bind a decision to, so none can be made.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plugin_that_is_only_a_switch_gets_no_token() {
    let f = fixture();
    let settings = f.project.join(".claude/settings.json");
    fs::write(&settings, r#"{"enabledPlugins":{"ghost@mkt":true}}"#).unwrap();
    let ghost = row(&f, "ghost@mkt");
    assert!(ghost.review_hash.is_none());
    assert!(ghost.decisions.iter().all(|d| d.token.is_none()));
}
