//! What the safety rules found in the content of this machine's scopes —
//! what a tool would load right now, and what an apply would put there.
//!
//! Every open finding is printed with the token that names exactly it on
//! exactly this content, and every held-back item with the flag that
//! accepts exactly the bytes shown above it. Both are the same discipline:
//! a decision names the content it was made against, so the reader can
//! never rule on bytes nobody put in front of them.

use clap::Args;
use kendex_core::engine::decisions::{DecisionState, DecisionToken, short_token};
use kendex_core::engine::{
    ItemSafety, PlanOptions, allow_unsafe_flag, observed_safety, plan_apply,
};
use kendex_core::env::Env;
use kendex_core::error::CoreError;

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
        let rows = rows(env, &scope)?;
        if rows.is_empty() {
            say(&format!("{}: nothing found", scope.label()));
            continue;
        }
        say(&format!("{}:", scope.label()));
        for row in &rows {
            print_row(row);
        }
    }
    Ok(())
}

/// One reading of one item, and which bytes it read.
struct Reading {
    row: ItemSafety,
    /// Read from the plan — the bytes an apply would write, which are the
    /// bytes the gate judges and `--allow-unsafe` accepts.
    planned: bool,
    /// This item's other reading is listed too, so each has to say which
    /// side it is. False where one reading says everything.
    paired: bool,
}

impl Reading {
    /// Which bytes, and what is happening to them. An item with one
    /// reading says only whether it is held back, as it always has.
    fn about(&self) -> &'static str {
        match (self.paired, self.planned, self.row.blocked()) {
            (true, true, _) => " — the update, held back",
            (true, false, _) => " — installed now",
            (false, _, true) => " — held back",
            (false, _, false) => "",
        }
    }
}

/// Every safety reading this scope has to show, worst first.
///
/// A declared item is held back over its *desired* render, and that is the
/// content `--allow-unsafe` accepts. Reporting the copy on disk instead
/// would show findings from bytes the gate never reads and hand out a token
/// the gate rejects — a printed instruction that does nothing when
/// followed. So a held-back item is read from the plan.
///
/// The installed copy is read beside it whenever the two are different
/// bytes: something unsafe that a tool is loading this second is not made
/// less true by an update stuck behind the gate, and the installed bytes
/// are where this item's dismissal tokens bind. Where the plan would write
/// exactly what is already there, one reading says everything.
fn rows(env: &Env, scope: &kendex_core::model::Scope) -> Result<Vec<Reading>, CoreError> {
    let held: Vec<ItemSafety> = plan_apply(env, scope, &PlanOptions::default())?
        .safety
        .into_iter()
        .filter(ItemSafety::blocked)
        .collect();
    let installed: Vec<ItemSafety> = observed_safety(env, scope)?
        .into_iter()
        .filter(|row| !row.findings.is_empty())
        .collect();

    // Same installation, same bytes: one reading, not two.
    let same = |row: &ItemSafety, others: &[ItemSafety]| {
        others
            .iter()
            .any(|other| other.key() == row.key() && other.review_hash == row.review_hash)
    };
    let mut rows: Vec<Reading> = held
        .iter()
        .map(|row| Reading {
            row: row.clone(),
            planned: true,
            paired: !same(row, &installed)
                && installed.iter().any(|other| other.key() == row.key()),
        })
        .collect();
    rows.extend(
        installed
            .iter()
            .filter(|row| !same(row, &held))
            .map(|row| Reading {
                row: row.clone(),
                planned: false,
                paired: held.iter().any(|other| other.key() == row.key()),
            }),
    );
    rows.sort_by_key(|reading| (!reading.row.blocked(), reading.row.safety.score));
    Ok(rows)
}

fn print_row(reading: &Reading) {
    let (row, gated) = (&reading.row, reading.planned);
    say(&format!(
        "  {} {} for {} scores {}/100{}",
        row.kind.name(),
        row.name,
        row.harness.display_name(),
        row.safety.score,
        reading.about()
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
            DecisionState::AuthorDismissed {
                reason,
                dismissed_at,
                publisher,
            } => say(&format!(
                "      {publisher} reviewed this {dismissed_at} and recorded it as {}",
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
