use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::{scan, settings};

use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

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
                    Some(false) => "disabled".to_owned(),
                    _ => String::new(),
                },
            ]
        })
        .collect();

    if rows.is_empty() {
        say("nothing observed");
    } else {
        let mut widths = [0usize; 5];
        for row in &rows {
            for (w, cell) in widths.iter_mut().zip(row) {
                *w = (*w).max(cell.len());
            }
        }
        for row in &rows {
            let line = row
                .iter()
                .zip(widths)
                .map(|(cell, w)| format!("{cell:w$}"))
                .collect::<Vec<_>>()
                .join("  ");
            say(line.trim_end());
        }
    }
    for warning in &result.warnings {
        say(&format!("warning: {}", warning));
    }
    Ok(())
}
