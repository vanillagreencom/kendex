//! `kendex check --catalog`: the authoring passes live in
//! `kendex_core::check_catalog`; this prints what they found, as lines or
//! as the versioned JSON envelope a CI step consumes.
//!
//! Exit code is the whole point: 1 when something is broken or blocked,
//! and with `--strict`, 1 for advisories and warnings too.

use std::path::Path;

use kendex_core::check_catalog::{CHECK_SCHEMA, CatalogCheck, CheckFinding};
use kendex_core::quality::Verdict;
use kendex_core::source_read::SealedSource;

use super::{CliResult, out, say};

pub fn run(catalog: &Path, strict: bool, json: bool) -> CliResult {
    let sealed = SealedSource::open(catalog)?;
    let display = catalog
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "catalog".to_owned());
    let report = kendex_core::check_catalog::check(&sealed, &display)?;
    let failing = report.failing(strict);
    match json {
        true => machine(&report, failing == 0)?,
        false => lines(&report),
    }
    match failing {
        0 => Ok(()),
        count => {
            Err(format!("{count} problem(s) must be fixed before this catalog installs").into())
        }
    }
}

/// The machine envelope. serde_json preserves insertion order, so the
/// written order here is the field order a consumer sees.
fn machine(report: &CatalogCheck, ok: bool) -> CliResult {
    let tally = report.tally();
    out(&serde_json::to_string_pretty(&serde_json::json!({
        "schema": CHECK_SCHEMA,
        "findings": report.findings().collect::<Vec<&CheckFinding>>(),
        "breakage": tally.breakage,
        "held_back": tally.held_back,
        "warned": tally.warned,
        "ok": ok,
    }))?);
    Ok(())
}

fn lines(report: &CatalogCheck) {
    for finding in &report.catalog {
        say(&format!(
            "[{}] {}: {}: {}",
            finding.severity, finding.pass, finding.file, finding.message
        ));
        say(&format!("    fix: {}", finding.fix));
    }
    for item in &report.items {
        for finding in &item.findings {
            match &finding.rule {
                None => say(&format!(
                    "[{}] {}: {}: {}",
                    finding.severity, finding.pass, finding.file, finding.message
                )),
                // Safety findings carry their own severity rather than being
                // relabelled error/warning: only the verdict below decides
                // whether this run fails, and a line that says "error"
                // without failing anything is a line people learn to scroll
                // past.
                Some(rule) if finding.dismissed => {
                    say(&format!(
                        "[dismissed {}] safety: {}: {} ({rule})",
                        finding.severity, finding.file, finding.message
                    ));
                    continue;
                }
                Some(rule) => say(&format!(
                    "[{}] safety: {}: {} ({rule})",
                    finding.severity, finding.file, finding.message
                )),
            }
            say(&format!("    fix: {}", finding.fix));
            // A held-back item is waiting on the maintainer's review; the
            // token is how a reviewed finding is recorded as intended.
            // A hook has none — its review cannot travel to an install — so
            // the reason arrives here rather than after the maintainer acts
            // on a token the tool printed and then refuses.
            if item.verdict == Verdict::Block && finding.rule.is_some() {
                match &finding.token {
                    Some(token) => say(&format!(
                        "    reviewed and intended? kendex dismiss --catalog <dir> --reason intended '{token}'"
                    )),
                    None => say(
                        "    a hook's review cannot travel to an install — it is scored from its script here and from the harness's settings file once installed, so narrow what the script does",
                    ),
                }
            }
        }
        if item.verdict != Verdict::Clean {
            say(&format!(
                "[{}] safety: {}: {} {} scores {}/100",
                match item.verdict {
                    Verdict::Block => "error",
                    _ => "warning",
                },
                item.file,
                item.kind.name(),
                item.name,
                item.score
            ));
        }
    }
    let tally = report.tally();
    say(&format!(
        "{} item(s): {} breakage, {} advisory, {} held back, {} warned",
        tally.items, tally.breakage, tally.advisory, tally.held_back, tally.warned
    ));
}
