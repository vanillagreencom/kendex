//! The safety findings in installed content, the decisions recorded about
//! them, and the verbs that make and take back those decisions.
//!
//! Every finding is printed with the token that names exactly it on exactly
//! this content; `dismiss` takes that token and nothing looser, the way
//! `--allow-unsafe` takes `name@hash` — a bare name in a shell history must
//! never dismiss whatever replaced what was read.

use clap::Args;
use kendex_core::apply;
use kendex_core::engine::decisions::{DecisionState, DecisionToken, short_token};
use kendex_core::engine::ops::{
    DecisionRecord, RecordState, dismiss, list_decisions, revoke_dismissal, revoke_override,
};
use kendex_core::engine::{
    ItemSafety, PlanOptions, allow_unsafe_flag, observed_safety, plan_apply,
};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::quality::reviews::DismissReason;

use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct FindingsArgs {
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
}

/// What the safety rules found in what is installed right now, each finding
/// with the token a dismissal takes and what has already been decided about
/// it.
pub fn findings(env: &Env, args: FindingsArgs) -> CliResult {
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::All)?;
    for scope in resolve_scopes(env, filter)? {
        // Each row carries whether the gate is what is holding it: only a
        // row the plan produced can be accepted with `--allow-unsafe`.
        let mut rows: Vec<(ItemSafety, bool)> = held_back(env, &scope)?
            .into_iter()
            .map(|row| (row, true))
            .collect();
        let held: Vec<String> = rows.iter().map(|(row, _)| row.key()).collect();
        rows.extend(
            observed_safety(env, &scope)?
                .into_iter()
                .filter(|row| !row.findings.is_empty() && !held.contains(&row.key()))
                .map(|row| (row, false)),
        );
        if rows.is_empty() {
            say(&format!("{}: nothing found", scope.label()));
            continue;
        }
        rows.sort_by_key(|(row, _)| (!row.blocked(), row.safety.score));
        say(&format!("{}:", scope.label()));
        for (row, gated) in &rows {
            print_row(row, *gated);
        }
    }
    Ok(())
}

/// What the gate would refuse to install in this scope, judged on the bytes
/// it would write.
///
/// A declared item is held back over its *desired* render, and that is the
/// content `--allow-unsafe` accepts. Scoring the copy already on disk would
/// show findings from bytes the gate never reads and hand out a token the
/// gate rejects — a printed instruction that does nothing when followed. So
/// a held-back item is reported from the plan, and everything else from
/// disk, which is where its dismissal tokens bind.
fn held_back(env: &Env, scope: &kendex_core::model::Scope) -> Result<Vec<ItemSafety>, CoreError> {
    let report = plan_apply(env, scope, &PlanOptions::default())?;
    Ok(report
        .safety
        .into_iter()
        .filter(ItemSafety::blocked)
        .collect())
}

fn print_row(row: &ItemSafety, gated: bool) {
    let held = match row.blocked() {
        true => " — held back",
        false => "",
    };
    say(&format!(
        "  {} {} for {} scores {}/100{held}",
        row.kind.name(),
        row.name,
        row.harness.display_name(),
        row.safety.score
    ));
    for (finding, decision) in row.findings.iter().zip(&row.decisions) {
        say(&format!(
            "    [{}] {}: {}",
            finding.severity.name(),
            finding.location,
            finding.message
        ));
        say(&format!("      fix: {}", finding.remediation));
        match &decision.state {
            DecisionState::Open { earlier } => {
                if let Some(token) = &decision.token {
                    let printed = match DecisionToken::parse(token) {
                        Ok(parsed) => short_token(&parsed),
                        Err(_) => token.clone(),
                    };
                    say(&format!("      token: {printed}"));
                }
                if let Some(earlier) = earlier {
                    say(&format!("      dismissed before, but {earlier}"));
                }
            }
            DecisionState::Dismissed {
                reason,
                dismissed_at,
            } => say(&format!(
                "      dismissed {dismissed_at} — {}",
                reason.name()
            )),
            DecisionState::Accepted { granted_at } => {
                say(&format!("      accepted {granted_at}"));
            }
        }
    }
    // Only what the gate is holding back can be accepted this way. Content
    // already on disk that nothing declares is not waiting on a grant, and
    // offering one would name bytes no plan is about.
    if let Some(review_hash) = &row.review_hash
        && gated
    {
        say(&format!(
            "    to install it anyway, review the findings above and apply with --allow-unsafe {}",
            allow_unsafe_flag(&row.name, review_hash)
        ));
    }
}

#[derive(Args)]
pub struct DismissArgs {
    /// The finding tokens printed by `kendex findings`, or with --catalog
    /// the kind:name#fingerprint tokens printed by `check --catalog`
    #[arg(required = true)]
    tokens: Vec<String>,
    /// wrong-call | intended | trusted-source
    #[arg(long)]
    reason: String,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Record an authoring decision in this catalog directory's
    /// kendex-reviews.toml instead of dismissing an installed finding
    #[arg(long)]
    catalog: Option<std::path::PathBuf>,
}

/// Record that these findings are not problems. One journaled manifest
/// write for the scope; a token that no longer names what is installed
/// stops the whole call before it.
pub fn dismiss_cmd(env: &Env, args: DismissArgs) -> CliResult {
    let reason = DismissReason::parse(&args.reason).ok_or_else(|| {
        format!(
            "unknown --reason '{}'; expected one of: {}",
            args.reason,
            DismissReason::ALL
                .iter()
                .map(|r| r.name())
                .collect::<Vec<_>>()
                .join(", ")
        )
    })?;
    if let Some(catalog) = &args.catalog {
        return dismiss_catalog(catalog, &args.tokens, reason);
    }
    let tokens = args
        .tokens
        .iter()
        .map(|token| DecisionToken::parse(token))
        .collect::<Result<Vec<_>, _>>()?;
    // A token names one installation in one scope; a batch is one journaled
    // write to one manifest. Whatever the filter spells, one scope is taken.
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let plan = dismiss(env, &scope, &tokens, reason)?;
    apply::execute(env, &plan, None)?;
    say(&format!(
        "{}: dismissed {} finding{} as {}",
        scope.label(),
        tokens.len(),
        if tokens.len() == 1 { "" } else { "s" },
        reason.name()
    ));
    Ok(())
}

/// The authoring flavor: one committed record in the catalog's
/// kendex-reviews.toml, validated against the catalog's bytes right now the
/// same way an install-side dismissal is — a token whose content or finding
/// has moved on is refused, and a batch with one bad token writes nothing.
fn dismiss_catalog(
    catalog: &std::path::Path,
    tokens: &[String],
    reason: DismissReason,
) -> CliResult {
    use kendex_core::check_catalog::dismissals;
    if reason == DismissReason::TrustedSource {
        return Err(
            "trusted-source is about where an install came from; an authoring decision is \
             wrong-call or intended"
                .into(),
        );
    }
    let sealed = kendex_core::source_read::SealedSource::open(catalog)?;
    let config = kendex_core::source::source_config(&sealed, "catalog")?;
    // (kind, name, content hash, fingerprints) per token, all validated
    // before anything is written.
    let mut batches: Vec<(kendex_core::model::ItemKind, String, String, Vec<String>)> = Vec::new();
    for token in tokens {
        let Some((kind, name, fingerprint)) = dismissals::parse_token(token) else {
            return Err(format!("'{token}' is not a kind:name#fingerprint token").into());
        };
        let Some(path) = kendex_core::source::find_item(&sealed, &config, kind, name) else {
            return Err(format!("{}: no {} '{name}' in this catalog", token, kind.name()).into());
        };
        let item = kendex_core::check_catalog::check_item(&sealed, kind, name, &path, None)?;
        let known = item.findings.iter().any(|finding| {
            finding
                .token
                .as_deref()
                .is_some_and(|printed| printed == *token)
        });
        if !known {
            return Err(format!(
                "{token}: the finding is no longer there — re-run check --catalog and use the tokens it prints"
            )
            .into());
        }
        let Some(hash) = dismissals::content_hash(&sealed, &path) else {
            return Err(format!("{token}: the item's content cannot be read").into());
        };
        match batches
            .iter_mut()
            .find(|(k, n, _, _)| *k == kind && n == name)
        {
            Some((_, _, _, prints)) => prints.push(fingerprint.to_owned()),
            None => batches.push((kind, name.to_owned(), hash, vec![fingerprint.to_owned()])),
        }
    }
    let mut count = 0;
    for (kind, name, hash, prints) in batches {
        let records: Vec<(String, DismissReason)> =
            prints.into_iter().map(|print| (print, reason)).collect();
        count += records.len();
        dismissals::record(&sealed, kind, &name, &hash, &records)?;
    }
    say(&format!(
        "{}: recorded {count} authoring dismissal{} as {} in {}",
        catalog.display(),
        if count == 1 { "" } else { "s" },
        reason.name(),
        dismissals::REVIEWS_FILE
    ));
    Ok(())
}

#[derive(Args)]
pub struct DecisionsArgs {
    /// Take a decision back by its id: kind:name:harness for an acceptance,
    /// kind:name:harness#fingerprint for a dismissal
    #[arg(long)]
    revoke: Vec<String>,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
}

/// Every recorded decision — acceptances and dismissals — with whether it
/// still describes what is installed, and the way out of one.
pub fn decisions(env: &Env, args: DecisionsArgs) -> CliResult {
    let default = match args.revoke.is_empty() {
        true => ScopeFilter::All,
        false => ScopeFilter::Project,
    };
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, default)?;
    let mut scopes = resolve_scopes(env, filter)?;
    if !args.revoke.is_empty() {
        // An id names a record in one manifest; the revoke is one scope's.
        let scope = scopes.remove(0);
        for id in &args.revoke {
            let plan = match id.rsplit_once('#') {
                Some((key, fingerprint)) => revoke_dismissal(env, &scope, key, fingerprint, None)?,
                None => revoke_override(env, &scope, id)?,
            };
            apply::execute(env, &plan, None)?;
            say(&format!("{}: took back the decision {id}", scope.label()));
        }
        return Ok(());
    }
    for scope in scopes {
        let recorded = list_decisions(env, &scope)?;
        if recorded.is_empty() {
            say(&format!("{}: no decisions recorded", scope.label()));
            continue;
        }
        say(&format!("{}:", scope.label()));
        for decision in recorded {
            let state = match &decision.state {
                RecordState::Active => "active".to_owned(),
                RecordState::Stale { why } => format!("stale: {why}"),
                RecordState::Obsolete => {
                    "obsolete: the item is no longer installed here".to_owned()
                }
            };
            match &decision.record {
                DecisionRecord::Accepted {
                    findings,
                    granted_at,
                } => say(&format!(
                    "  accepted   {} — {findings} finding{} accepted {granted_at} [{state}]",
                    decision.key,
                    if *findings == 1 { "" } else { "s" }
                )),
                DecisionRecord::Dismissed {
                    fingerprint,
                    reason,
                    dismissed_at,
                    finding,
                } => {
                    say(&format!(
                        "  dismissed  {}#{fingerprint} — {} {dismissed_at} [{state}]",
                        decision.key,
                        reason.name()
                    ));
                    if let Some(finding) = finding {
                        say(&format!(
                            "             [{}] {}: {}",
                            finding.severity.name(),
                            finding.location,
                            finding.message
                        ));
                    }
                }
            }
        }
    }
    Ok(())
}
