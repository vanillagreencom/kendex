//! `kendex index [<dir>] --json`: the per-marketplace summary the community
//! directory's builder consumes, emitted from the same core that subscribing
//! reads through. Works on a plain directory — no git, no network.

use std::path::PathBuf;

use kendex_core::source;
use kendex_core::source_read::SealedSource;

use super::{CliResult, answer, say};

pub fn run(dir: Option<PathBuf>, json: bool) -> CliResult {
    let dir = match dir {
        Some(dir) => dir,
        None => std::env::current_dir()?,
    };
    let sealed = SealedSource::open(&dir)?;
    let display = source::repo_leaf(&sealed.root().display().to_string()).to_owned();
    let report = source::index::index(&sealed, &display)?;
    if json {
        answer(&serde_json::to_string_pretty(&report)?);
        return Ok(());
    }
    say(&format!(
        "{}: {} package(s), {} bundle(s), {} finding(s)",
        report.name,
        report.counts.packages,
        report.counts.bundles,
        report.findings.len()
    ));
    for row in &report.found {
        say(&format!(
            "  {} {}(s) under {}",
            row.count, row.kind, row.root
        ));
    }
    for finding in &report.findings {
        say(&format!(
            "  problem: {}: {} — fix: {}",
            finding.location, finding.problem, finding.fix
        ));
    }
    Ok(())
}
