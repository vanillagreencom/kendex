//! Every way a dismissal refuses to be looser than one exact decision: a
//! token that no longer names what is installed, an item that is settled
//! or held back, a source nobody can name, and a manifest that moved
//! underneath the write.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::decisions::{DecisionState, DecisionToken};
use kendex_core::engine::ops::{self, dismiss};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::quality::reviews::DismissReason;

use super::decisions::{first_token, row, with_mild};
use super::fixture::{fixture, grant, manifest_of, plan};

/// A token names the content it was read in. Content that moved between
/// the reading and the decision is a different question, and the answer to
/// the old one is not written down against the new one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_stale_token_writes_nothing() {
    let f = with_mild();
    let token = first_token(&row(&f, "mild"));
    let installed_skill = f.project.join(".claude/skills/mild/SKILL.md");
    let edited = fs::read_to_string(&installed_skill).unwrap() + "\nOne more line.\n";
    fs::write(&installed_skill, edited).unwrap();

    let refused = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&token).unwrap()],
        DismissReason::WrongCall,
    );
    assert!(
        matches!(refused, Err(CoreError::DecisionStale { .. })),
        "{refused:?}"
    );
    assert!(manifest_of(&f).safety_reviews.is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_token_for_a_finding_that_is_gone_writes_nothing() {
    let f = with_mild();
    let token = DecisionToken::parse(&first_token(&row(&f, "mild"))).unwrap();
    let forged = DecisionToken {
        fingerprint: "0000000000000000".to_owned(),
        ..token
    };
    let refused = dismiss(&f.env, &f.scope, &[forged], DismissReason::WrongCall);
    assert!(matches!(refused, Err(CoreError::DecisionStale { .. })));
    assert!(manifest_of(&f).safety_reviews.is_empty());
}

/// One bad token in a batch stops the batch: a partial write would look
/// like every decision landed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_batch_with_one_bad_token_writes_nothing() {
    let f = with_mild();
    let good = DecisionToken::parse(&first_token(&row(&f, "mild"))).unwrap();
    let bad = DecisionToken {
        hash: "000000000000".to_owned(),
        ..good.clone()
    };
    let refused = dismiss(&f.env, &f.scope, &[good, bad], DismissReason::WrongCall);
    assert!(refused.is_err());
    assert!(manifest_of(&f).safety_reviews.is_empty());
}

/// A held-back item is decided by accepting or removing it. A dismissal
/// there would look like a decision and decide nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_back_items_findings_cannot_be_dismissed() {
    let f = with_mild();
    // Installed under an acceptance, then the acceptance withdrawn: the
    // copy is still on disk and blocked again, which is the only way a
    // held-back item is ever observed.
    let granted = plan(&f, &[grant(&f).as_str()]);
    apply::execute(&f.env, &granted.plan, None).unwrap();
    let revoke = ops::revoke_override(&f.env, &f.scope, "skill:hostile:claude").unwrap();
    apply::execute(&f.env, &revoke, None).unwrap();
    let hostile = row(&f, "hostile");
    assert!(hostile.blocked());
    assert!(
        hostile.decisions.iter().all(|d| d.token.is_none()),
        "a held-back item's findings are not offered for dismissal"
    );
    // A token forged from what the row does carry is refused on arrival.
    let forged = DecisionToken {
        key: "skill:hostile:claude".to_owned(),
        fingerprint: hostile.decisions[0].fingerprint.clone(),
        hash: hostile.review_hash.clone().unwrap(),
        scope: kendex_core::engine::decisions::scope_tag(&f.scope),
    };
    let refused = dismiss(&f.env, &f.scope, &[forged], DismissReason::WrongCall);
    assert!(
        matches!(refused, Err(CoreError::DecisionStale { why, .. }) if why.contains("held back"))
    );
}

/// A token is minted for one scope's view. The same skill installed in a
/// project and personally has the same key, bytes and finding; only the
/// file of record differs, and a token must not cross from one to the
/// other.
#[test]
#[allow(clippy::unwrap_used)]
fn a_token_from_another_scope_writes_nothing() {
    let f = with_mild();
    let token = DecisionToken::parse(&first_token(&row(&f, "mild"))).unwrap();
    let elsewhere = DecisionToken {
        scope: kendex_core::engine::decisions::scope_tag(&kendex_core::model::Scope::Global),
        ..token
    };
    let refused = dismiss(&f.env, &f.scope, &[elsewhere], DismissReason::WrongCall);
    assert!(
        matches!(refused, Err(CoreError::DecisionStale { why, .. }) if why.contains("another scope"))
    );
    assert!(manifest_of(&f).safety_reviews.is_empty());
}

/// Once an item's findings are accepted as a whole, each one reads as
/// accepted — there is nothing left to dismiss.
#[test]
#[allow(clippy::unwrap_used)]
fn an_accepted_items_findings_read_as_accepted() {
    let f = with_mild();
    let granted = plan(&f, &[grant(&f).as_str()]);
    apply::execute(&f.env, &granted.plan, None).unwrap();

    let hostile = row(&f, "hostile");
    assert!(
        hostile
            .decisions
            .iter()
            .all(|d| matches!(d.state, DecisionState::Accepted { .. }))
    );
    let refused = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&first_token(&hostile)).unwrap()],
        DismissReason::WrongCall,
    );
    assert!(
        matches!(refused, Err(CoreError::DecisionStale { why, .. }) if why.contains("accepted"))
    );
}

/// Two writers, one scope: the manifest changing under a planned dismissal
/// makes the plan stale rather than letting it revert the other write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_concurrent_manifest_write_makes_the_dismissal_stale() {
    let f = with_mild();
    let token = first_token(&row(&f, "mild"));
    let planned = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&token).unwrap()],
        DismissReason::WrongCall,
    )
    .unwrap();

    let path = manifest::manifest_path(&f.env, &f.scope);
    let mut recorded = manifest_of(&f);
    recorded
        .skill_instructions
        .insert("all".to_owned(), "someone else's edit".to_owned());
    super::fixture::save_manifest(&path, &recorded);

    let executed = apply::execute(&f.env, &planned, None);
    let message = executed
        .expect_err("a stale plan must not write")
        .to_string();
    assert!(message.contains("plan is stale"), "{message}");
    assert!(manifest_of(&f).safety_reviews.is_empty());
}

/// A source nobody can name cannot be trusted: an item whose provenance is
/// unknown gets every reason but that one.
#[test]
#[allow(clippy::unwrap_used)]
fn trusting_an_unknown_source_is_refused() {
    let f = fixture();
    let dir = f.project.join(".claude/skills/loose");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: loose\n---\nRun chmod 777 x.sh\n",
    )
    .unwrap();
    let loose = row(&f, "loose");
    assert!(loose.provenance.is_none());
    let refused = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&first_token(&loose)).unwrap()],
        DismissReason::TrustedSource,
    );
    assert!(matches!(refused, Err(CoreError::DecisionStale { why, .. }) if why.contains("source")));
    let allowed = dismiss(
        &f.env,
        &f.scope,
        &[DecisionToken::parse(&first_token(&loose)).unwrap()],
        DismissReason::WrongCall,
    );
    assert!(allowed.is_ok());
}

/// A reason is a closed vocabulary. A hand edit that writes one nobody
/// defined is a manifest this build cannot vouch for, and it says so at
/// load rather than reading the record as some default.
#[test]
#[allow(clippy::unwrap_used)]
fn a_reason_outside_the_vocabulary_refuses_to_load() {
    let f = with_mild();
    let path = manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&path).unwrap()
        + "\n[safety-reviews.\"skill:mild:claude\"]\nreview-hash = \"abc\"\nruleset = 1\n\n[safety-reviews.\"skill:mild:claude\".dismissed.\"0000000000000000\"]\nreason = \"because\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n";
    fs::write(&path, text).unwrap();
    let loaded = manifest::load(&path);
    assert!(
        matches!(loaded, Err(CoreError::TomlParse { .. })),
        "{loaded:?}"
    );
}
