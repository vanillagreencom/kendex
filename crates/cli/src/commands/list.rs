use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::scan::WarningStanding;
use kendex_core::{scan, settings};

use super::{CliResult, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::{self, Span, Status, Style};

pub fn run(env: &Env, filter: ScopeFilter, harness: Option<String>) -> CliResult {
    let harness = harness
        .map(|h| HarnessId::parse(&h).ok_or(format!("unknown harness '{h}'")))
        .transpose()?;
    let scopes = resolve_scopes(env, filter)?;
    let app_settings = settings::load(env)?;
    let result = scan::scan_scopes(env, &app_settings.harness_roots, &scopes);

    let rows: Vec<[String; 5]> = result
        .items
        .iter()
        .filter(|i| harness.is_none_or(|h| i.harness == h))
        .map(|i| {
            [
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
            WarningStanding::Actionable => {
                style.report_row(Status::Decision, &[Span::Prose(&text)], "warning: ")
            }
            WarningStanding::UnusedEmptyContainer => {
                style.report_row(Status::Notice, &[Span::Prose(&text)], "")
            }
        });
    }
    Ok(())
}

fn listing(style: &Style, rows: &[[String; 5]]) -> Vec<String> {
    if rows.is_empty() {
        return style.summary(Status::Done, "no packages found");
    }
    if matches!(style.look, ui::Look::Plain) {
        // Keep the existing byte-padded, headerless script table.
        let mut widths = [0usize; 5];
        for row in rows {
            for (w, cell) in widths.iter_mut().zip(row) {
                *w = (*w).max(cell.len());
            }
        }
        let mut lines = Vec::new();
        for row in rows {
            let line = row
                .iter()
                .zip(widths)
                .map(|(cell, w)| format!("{cell:w$}"))
                .collect::<Vec<_>>()
                .join("  ");
            lines.extend(style.note(&[Span::Prose(line.trim_end())]));
        }
        return lines;
    }
    let mut lines = style.section("packages", rows.len(), Status::Notice);
    lines.extend(style.table(
        &["kind", "name", "harness", "scope", "state"],
        &rows.iter().map(|row| row.to_vec()).collect::<Vec<_>>(),
    ));
    lines
}

#[cfg(test)]
mod tests;
