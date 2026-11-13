//! The marketplace authoring verbs. Every wizard question the app asks has
//! a flag here, so CI and scripts can do what the dialogs do.

use std::path::PathBuf;

use kendex_core::author::{self, CreateRequest, ImportSelection, License};
use kendex_core::env::Env;
use kendex_core::model::ItemKind;
use kendex_core::process::Hardened;

use super::{CliResult, Lines, answer, escaped, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::{self, Cell, Span, Status, Style};

pub fn new(
    env: &Env,
    name: &str,
    description: Option<String>,
    author: Option<String>,
    license: Option<String>,
    dir: Option<PathBuf>,
) -> CliResult {
    let license = match license.as_deref() {
        None | Some("none") => License::NoneYet,
        Some("mit") => License::Mit,
        Some("apache-2.0") => License::Apache2,
        Some(other) => {
            return Err(format!("unknown --license '{other}' (mit | apache-2.0 | none)").into());
        }
    };
    let author = match author {
        Some(author) => author,
        None => git_config_name().unwrap_or_default(),
    };
    let dir = match dir {
        Some(dir) => dir,
        None => std::env::current_dir()?.join(name),
    };
    let style = ui::style();
    ui::stderr(&style.header("marketplace new", &[Span::Prose(name)]));
    let row = author::create(
        env,
        &CreateRequest {
            name: name.to_owned(),
            description: description.unwrap_or_default(),
            author,
            license,
            dir: dir.clone(),
        },
    )?;
    let mut lines = folder_line(
        &style,
        "created ",
        &dir,
        " — a git repository with kendex.toml, README.md and the check workflow",
    );
    lines.extend(summarized(&style, &row));
    ui::stderr(&lines);
    Ok(())
}

pub fn use_existing(env: &Env, dir: &std::path::Path) -> CliResult {
    let style = ui::style();
    ui::stderr(&style.header(
        "marketplace use",
        &[Span::Command(&dir.display().to_string())],
    ));
    let row = author::use_existing(env, dir)?;
    let mut lines = folder_line(
        &style,
        "registered ",
        dir,
        " under Mine — nothing inside it was changed",
    );
    lines.extend(summarized(&style, &row));
    ui::stderr(&lines);
    Ok(())
}

/// The marketplace folder a verb made or took, drawn whole.
fn folder_line(style: &Style, lead: &str, dir: &std::path::Path, tail: &str) -> Vec<String> {
    let dir = dir.display().to_string();
    style.report_row(
        Status::Done,
        &[Span::Prose(lead), Span::Command(&dir), Span::Prose(tail)],
        "",
    )
}

pub fn mine(env: &Env, json: bool) -> CliResult {
    let style = ui::style();
    if !json {
        ui::stderr(&style.header("marketplace mine", &[Span::Prose("your marketplaces")]));
    }
    let mut rows = Vec::new();
    for path in author::list(env)? {
        match author::status(&path) {
            Ok(row) => rows.push(row),
            Err(error) => ui::stderr(&unread(&style, &path, &error.to_string())),
        }
    }
    if json {
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": kendex_core::author::status::MINE_SCHEMA,
            "marketplaces": rows,
        }))?);
        return Ok(());
    }
    ui::stdout(&mine_lines(&style, &rows));
    Ok(())
}

/// A marketplace on Mine whose folder could not be read: nothing about it
/// can be shown until it can.
fn unread(style: &Style, path: &std::path::Path, error: &str) -> Vec<String> {
    let path = path.display().to_string();
    style.report_row(
        Status::of(kendex_core::decision::Need::Blocked),
        &[Span::Command(&path), Span::Prose(": "), Span::Prose(error)],
        "",
    )
}

/// One row per marketplace on Mine: its name, what it holds, and where.
fn mine_lines(style: &Style, rows: &[author::MineRow]) -> Vec<String> {
    let cells: Vec<Vec<Cell>> = rows
        .iter()
        .map(|row| {
            let packages: u32 = row.counts.values().sum();
            vec![
                row.name.clone().into(),
                format!(
                    "{packages} package(s), {} bundle(s), {} problem(s)",
                    row.bundles, row.breakage
                )
                .into(),
                Cell::default().copy(row.path.clone()),
            ]
        })
        .collect();
    style.report_table(
        "marketplaces",
        &["name", "holds", "folder"],
        &cells,
        ui::report::PlainColumns::Joined,
    )
}

pub struct ImportArgs {
    pub target: PathBuf,
    pub skills: Vec<String>,
    pub agents: Vec<String>,
    pub hooks: Vec<String>,
    pub commands: Vec<String>,
    pub mcp: Vec<String>,
    pub from_scope: Option<String>,
    pub origin: Option<String>,
    pub rename: Option<String>,
    pub confirm_license: bool,
    pub license_basis: Option<String>,
    pub json: bool,
}

pub fn import(env: &Env, args: ImportArgs) -> CliResult {
    let style = ui::style();
    if !args.json {
        ui::stderr(&style.header(
            "marketplace import",
            &[Span::Command(&args.target.display().to_string())],
        ));
    }
    let filter = ScopeFilter::resolve(args.from_scope.as_deref(), false, ScopeFilter::All)?;
    let scopes = resolve_scopes(env, filter)?;
    let candidates = author::inventory(env, &scopes)?;
    let wanted: Vec<(ItemKind, &String)> = [
        (ItemKind::Skill, &args.skills),
        (ItemKind::Agent, &args.agents),
        (ItemKind::Hook, &args.hooks),
        (ItemKind::Command, &args.commands),
        (ItemKind::McpServer, &args.mcp),
    ]
    .into_iter()
    .flat_map(|(kind, names)| names.iter().map(move |name| (kind, name)))
    .collect();
    if wanted.is_empty() {
        return list_candidates(&style, &candidates, args.json);
    }
    if args.rename.is_some() && wanted.len() != 1 {
        return Err("--as renames exactly one package — pass one selection with it".into());
    }
    let mut selections = Vec::new();
    for (kind, name) in wanted {
        selections.push(selection(&candidates, kind, name, &args)?);
    }
    let outcome = author::apply(env, &scopes, &args.target, &selections)?;
    ui::stderr(&imported(&style, &outcome));
    // The same check the app shows: findings with files, then the tally.
    super::check_catalog::run(&args.target, false, false)
}

/// What an import copied, and what was already there with the same bytes.
fn imported(style: &Style, outcome: &author::ImportOutcome) -> Vec<String> {
    let written = outcome.written.iter().flat_map(|written| {
        style.report_row(
            Status::Done,
            &[Span::Prose(&format!("imported {written}"))],
            "",
        )
    });
    let present = outcome.already_present.iter().flat_map(|present| {
        style.report_row(
            Status::Notice,
            &[Span::Prose(&format!("already present: {present}"))],
            "",
        )
    });
    written
        .chain(present)
        .chain(
            outcome
                .warnings
                .iter()
                .flat_map(|warning| style.report_warning(warning)),
        )
        .collect()
}

fn selection(
    candidates: &[author::ImportCandidate],
    kind: ItemKind,
    name: &str,
    args: &ImportArgs,
) -> Result<ImportSelection, Box<dyn std::error::Error>> {
    let candidate = candidates
        .iter()
        .find(|candidate| candidate.kind == kind && candidate.name == name)
        .ok_or_else(|| {
            format!(
                "no {} named '{name}' on this computer — run without selections to list candidates",
                kind.name()
            )
        })?;
    let readable: Vec<_> = candidate
        .origins
        .iter()
        .filter(|origin| !origin.hash.is_empty())
        .collect();
    let origin = match (&args.origin, readable.len()) {
        (_, 0) => {
            // Core owns the sentence and the escaping — the same refusal
            // apply gives for the same condition; the layout is this
            // verb's, one origin per line, which is what makes it a
            // message that owns its breaks.
            let places: Vec<(String, Option<String>)> = candidate
                .origins
                .iter()
                .map(|origin| (origin.locations.join(" = "), origin.problem.clone()))
                .collect();
            return Err(Lines(author::import::no_importable_bytes(
                kind,
                name,
                &places,
                author::import::Places::PerLine,
            ))
            .into());
        }
        (None, 1) => readable[0],
        (None, _) => {
            // One origin per line, which makes this a message that owns
            // its breaks: the places are escaped here, because a break in
            // one of them would become a line of its own where it prints.
            let listed: Vec<String> = readable
                .iter()
                .map(|origin| {
                    format!(
                        "{}: {}",
                        &origin.hash[..12],
                        escaped(&origin.locations.join(" = "))
                    )
                })
                .collect();
            return Err(Lines(format!(
                "'{}' exists with different bytes in more than one place — pick one with --origin <hash>:\n{}",
                escaped(name),
                listed.join("\n")
            ))
            .into());
        }
        (Some(prefix), _) => *readable
            .iter()
            .find(|origin| origin.hash.starts_with(prefix.as_str()))
            .ok_or_else(|| format!("no origin of '{name}' matches --origin {prefix}"))?,
    };
    let destination = match &args.rename {
        Some(rename) => rename.clone(),
        None => candidate.name.clone(),
    };
    if let Some(problem) = &candidate.name_problem
        && args.rename.is_none()
    {
        return Err(format!(
            "'{name}' needs a different destination name — {problem}; pass --as <name>"
        )
        .into());
    }
    Ok(ImportSelection {
        kind,
        name: candidate.name.clone(),
        destination,
        hash: origin.hash.clone(),
        license_confirmed: args.confirm_license,
        license_basis: args.license_basis.clone(),
    })
}

fn list_candidates(style: &Style, candidates: &[author::ImportCandidate], json: bool) -> CliResult {
    if json {
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": author::import::IMPORT_SCHEMA,
            "candidates": candidates,
        }))?);
        return Ok(());
    }
    ui::stdout(&candidate_lines(style, candidates));
    Ok(())
}

/// Every place each candidate's bytes live, one row per origin: the hash
/// to select it by, or the word that says it cannot be taken.
fn candidate_lines(style: &Style, candidates: &[author::ImportCandidate]) -> Vec<String> {
    let mut cells = Vec::new();
    for candidate in candidates {
        for origin in &candidate.origins {
            let group = match &origin.group {
                author::import::CandidateGroup::Own => "your own".to_owned(),
                author::import::CandidateGroup::Marketplace {
                    source, license, ..
                } => match license {
                    Some(license) => format!("from marketplace '{source}' ({license})"),
                    None => format!("from marketplace '{source}' (no license found)"),
                },
                author::import::CandidateGroup::Edited {
                    source, license, ..
                } => match license {
                    Some(license) => format!("edited copy from marketplace '{source}' ({license})"),
                    None => format!("edited copy from marketplace '{source}' (no license found)"),
                },
                author::import::CandidateGroup::Unmanaged => "found on disk".to_owned(),
            };
            // An origin with no hash has nothing to select, which is not
            // always a read that failed: a Codex agent reads fine and is
            // merely a format a catalog cannot store. The word says only
            // that it cannot be taken; `problem` says why.
            let hash = match origin.hash.is_empty() {
                true => "unusable".to_owned(),
                false => origin.hash[..12].to_owned(),
            };
            let mut places = Cell::default();
            for (at, location) in origin.locations.iter().enumerate() {
                if at > 0 {
                    places = places.prose(" = ");
                }
                places = places.copy(location.clone());
            }
            if let Some(problem) = &origin.problem {
                places = places.prose(format!(" — {problem}"));
            }
            cells.push(vec![
                candidate.kind.name().to_owned().into(),
                candidate.name.clone().into(),
                format!("[{group}]").into(),
                hash.into(),
                places,
            ]);
        }
    }
    style.report_table(
        "candidates",
        &["kind", "name", "origin", "hash", "places"],
        &cells,
        ui::report::PlainColumns::Joined,
    )
}

/// What a marketplace holds and what its check found, then where its
/// repository stands. Breakage blocks installing it, so it draws as a
/// failure.
fn summarized(style: &Style, row: &author::MineRow) -> Vec<String> {
    use kendex_core::decision::Need;
    let packages: u32 = row.counts.values().sum();
    let status = match row.breakage {
        0 => Status::Done,
        _ => Status::of(Need::Blocked),
    };
    let mut lines = style.report_row(
        status,
        &[Span::Prose(&format!(
            "{}: {packages} package(s), {} bundle(s); check: {} breakage, {} safety finding(s)",
            row.name, row.bundles, row.breakage, row.safety_findings
        ))],
        "",
    );
    let git = match (&row.git.repository, &row.git.candidate) {
        (false, _) => "git: not a repository yet".to_owned(),
        (true, Some(candidate)) => format!("git: remote candidate {candidate}"),
        (true, None) => "git: no GitHub remote yet".to_owned(),
    };
    lines.extend(style.report_row(Status::Notice, &[Span::Prose(&git)], ""));
    lines
}

pub fn submit(env: &Env, dir: Option<PathBuf>, dry_run: bool, status: bool) -> CliResult {
    use kendex_core::registry::credentials::KeyringStore;
    use kendex_core::registry::{CurlFetch, submit};
    let _ = env;
    let fetch = CurlFetch;
    let style = ui::style();
    if status {
        ui::stderr(&style.header("marketplace submit", &[Span::Prose("--status")]));
        let rows = {
            let _asking = ui::spinner("reading your submissions");
            submit::submissions(&fetch, &KeyringStore)?
        };
        ui::stdout(&submissions(&style, &rows));
        return Ok(());
    }
    let dir = match dir {
        Some(dir) => dir,
        None => std::env::current_dir()?,
    };
    ui::stderr(&style.header(
        "marketplace submit",
        &[Span::Command(&dir.display().to_string())],
    ));
    let preflight = {
        let _checking = ui::spinner("checking the marketplace");
        author::submit_preflight(&dir, &fetch)?
    };
    ui::stderr(&preflight_lines(&style, &preflight.checks));
    let Some(candidate) = &preflight.candidate else {
        return Err("nothing to submit yet — push the repository to GitHub first".into());
    };
    if dry_run {
        ui::stderr(&style.summary(
            Status::Notice,
            &format!(
                "would submit {} to {}",
                candidate,
                kendex_core::registry::base_url()
            ),
        ));
        return Ok(());
    }
    if !preflight.ready {
        return Err(
            "not submitted: some checks did not pass — fix the checks marked above, then submit again"
                .into(),
        );
    }
    let outcome = {
        let _sending = ui::spinner("submitting");
        submit::submit(&fetch, &KeyringStore, candidate)?
    };
    ui::stderr(&style.summary(
        Status::Done,
        &format!(
            "submitted {} — status: {}{}",
            outcome.repo,
            outcome.status,
            match outcome.status.as_str() {
                "pending" =>
                    " (waiting for review; run the marketplace submit verb with --status to see when it is listed)",
                "listed" => " (listed in the community directory)",
                _ => "",
            }
        ),
    ));
    Ok(())
}

/// The submission checks: each row's verdict, and the fix under a row
/// that has one. A check that failed or could not be read blocks the
/// submission, so both draw as blocked; plain keeps their own marks.
fn preflight_lines(style: &Style, checks: &[author::PreflightCheck]) -> Vec<String> {
    use kendex_core::decision::Need;
    let mut lines = Vec::new();
    for check in checks {
        let (status, mark) = match check.ok {
            Some(true) => (Status::Done, "ok  "),
            Some(false) => (Status::of(Need::Blocked), " ✗  "),
            None => (Status::of(Need::Blocked), " ?  "),
        };
        lines.extend(style.report_row(status, &[Span::Prose(&check.label)], mark));
        if let Some(fix) = &check.fix {
            lines.extend(style.report_detail(&[Span::Prose(fix)], "      "));
        }
    }
    lines
}

/// Every submission and where it stands.
fn submissions(
    style: &Style,
    rows: &[kendex_core::registry::submit::SubmissionRow],
) -> Vec<String> {
    let cells: Vec<Vec<String>> = rows
        .iter()
        .map(|row| {
            let reason = row
                .status_reason
                .as_ref()
                .map(|reason| format!(" — {reason}"))
                .unwrap_or_default();
            vec![row.repo.clone(), format!("{}{reason}", row.status)]
        })
        .collect();
    style.report_table(
        "submissions",
        &["repository", "status"],
        &cells,
        ui::report::PlainColumns::Joined,
    )
}

fn git_config_name() -> Option<String> {
    let output = Hardened::git(&["config", "user.name"], None)
        .timeout(std::time::Duration::from_secs(5))
        .run()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(test)]
mod tests;
