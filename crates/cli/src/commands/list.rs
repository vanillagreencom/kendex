use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::scan::WarningStanding;
use kendex_core::{scan, settings};

use super::{CliResult, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::report::PlainColumns;
use crate::ui::{self, Span, Status, Style};

pub fn run(env: &Env, filter: ScopeFilter, harness: Option<String>) -> CliResult {
    let harness = harness
        .map(|h| HarnessId::parse(&h).ok_or(format!("unknown harness '{h}'")))
        .transpose()?;
    let scopes = resolve_scopes(env, filter)?;
    let app_settings = settings::load(env)?;
    let result = scan::scan_scopes(env, &app_settings.harness_roots, &scopes);

    let rows: Vec<Vec<String>> = result
        .items
        .iter()
        .filter(|i| harness.is_none_or(|h| i.harness == h))
        .map(|i| {
            vec![
                i.kind.name().to_owned(),
                i.name.clone(),
                i.harness.name().to_owned(),
                match &i.scope {
                    Scope::Global => "global".to_owned(),
                    Scope::Project { .. } => "project".to_owned(),
                },
                match i.enabled {
                    Some(false) => "switched off".to_owned(),
                    _ => String::new(),
                },
            ]
        })
        .collect();

    let style = ui::style();
    let target = scopes
        .iter()
        .map(Scope::label)
        .collect::<Vec<_>>()
        .join(", ");
    ui::stderr(&style.header("list", &target));
    ui::stderr(&listing(&style, &rows));
    for warning in &result.warnings {
        let text = warning.to_string();
        ui::stderr(&match warning.standing {
            WarningStanding::Actionable => style.report_warning(&text),
            WarningStanding::UnusedEmptyContainer => {
                style.report_row(Status::Notice, &[Span::Prose(&text)], "")
            }
        });
    }
    Ok(())
}

fn listing(style: &Style, rows: &[Vec<String>]) -> Vec<String> {
    if rows.is_empty() {
        return style.summary(Status::Done, "no packages found");
    }
    style.report_table(
        "packages",
        &["kind", "name", "harness", "scope", "state"],
        rows,
        PlainColumns::Padded,
    )
}

#[cfg(test)]
mod tests;
