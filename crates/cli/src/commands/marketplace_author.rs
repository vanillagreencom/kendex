//! The authoring verbs: `marketplace new|use|import|mine`. Every wizard
//! question the app asks has a flag here, so CI and scripts can do what
//! the dialogs do.

use std::path::PathBuf;

use kendex_core::author::{self, CreateRequest, ImportSelection, License};
use kendex_core::env::Env;
use kendex_core::model::ItemKind;
use kendex_core::process::Hardened;

use super::{CliResult, Lines, answer, escaped, out, resolve_scopes, say};
use crate::scope::ScopeFilter;

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
    say(&format!(
        "created {} — a git repository with kendex.toml, README.md and the check workflow",
        dir.display()
    ));
    summarize(&row);
    Ok(())
}

pub fn use_existing(env: &Env, dir: &std::path::Path) -> CliResult {
    let row = author::use_existing(env, dir)?;
    say(&format!(
        "registered {} under Mine — nothing inside it was changed",
        dir.display()
    ));
    summarize(&row);
    Ok(())
}

pub fn mine(env: &Env, json: bool) -> CliResult {
    let mut rows = Vec::new();
    for path in author::list(env)? {
        match author::status(&path) {
            Ok(row) => rows.push(row),
            Err(error) => say(&format!("{}: {}", path.display(), error)),
        }
    }
    if json {
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": kendex_core::author::status::MINE_SCHEMA,
            "marketplaces": rows,
        }))?);
        return Ok(());
    }
    for row in rows {
        let packages: u32 = row.counts.values().sum();
        out(&format!(
            "{}  {packages} package(s), {} bundle(s), {} problem(s)  {}",
            row.name, row.bundles, row.breakage, row.path,
        ));
    }
    Ok(())
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
        return list_candidates(&candidates, args.json);
    }
    if args.rename.is_some() && wanted.len() != 1 {
        return Err("--as renames exactly one package — pass one selection with it".into());
    }
    let mut selections = Vec::new();
    for (kind, name) in wanted {
        selections.push(selection(&candidates, kind, name, &args)?);
    }
    let outcome = author::apply(env, &scopes, &args.target, &selections)?;
    for written in &outcome.written {
        say(&format!("imported {}", written));
    }
    for present in &outcome.already_present {
        say(&format!("already present: {}", present));
    }
    // The same check the app shows: findings with files, then the tally.
    super::check_catalog::run(&args.target, false, false)
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
                "no {} named '{name}' on this machine — run without selections to list candidates",
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

fn list_candidates(candidates: &[author::ImportCandidate], json: bool) -> CliResult {
    if json {
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": author::import::IMPORT_SCHEMA,
            "candidates": candidates,
        }))?);
        return Ok(());
    }
    for candidate in candidates {
        for origin in &candidate.origins {
            let group = match &origin.group {
                author::import::CandidateGroup::Own => "your own".to_owned(),
                author::import::CandidateGroup::Marketplace {
                    source, license, ..
                } => match license {
                    Some(license) => format!("from '{source}' ({license})"),
                    None => format!("from '{source}' (no licence found)"),
                },
                author::import::CandidateGroup::Edited {
                    source, license, ..
                } => match license {
                    Some(license) => format!("your edited copy from '{source}' ({license})"),
                    None => format!("your edited copy from '{source}' (no licence found)"),
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
            let places = match &origin.problem {
                Some(problem) => format!("{} — {problem}", origin.locations.join(" = ")),
                None => origin.locations.join(" = "),
            };
            out(&format!(
                "{}  {}  [{group}]  {hash}  {places}",
                candidate.kind.name(),
                candidate.name,
            ));
        }
    }
    Ok(())
}

fn summarize(row: &author::MineRow) {
    let packages: u32 = row.counts.values().sum();
    say(&format!(
        "{}: {packages} package(s), {} bundle(s); check: {} breakage, {} safety finding(s)",
        row.name, row.bundles, row.breakage, row.safety_findings
    ));
    match (&row.git.repository, &row.git.candidate) {
        (false, _) => say("git: not a repository yet"),
        (true, Some(candidate)) => say(&format!("git: remote candidate {}", candidate)),
        (true, None) => say("git: no GitHub remote yet"),
    }
}

pub fn submit(env: &Env, dir: Option<PathBuf>, dry_run: bool, status: bool) -> CliResult {
    use kendex_core::registry::credentials::KeyringStore;
    use kendex_core::registry::{CurlFetch, submit};
    let _ = env;
    let fetch = CurlFetch;
    if status {
        for row in submit::submissions(&fetch, &KeyringStore)? {
            let reason = row
                .status_reason
                .map(|reason| format!(" — {reason}"))
                .unwrap_or_default();
            out(&format!("{}  {}{}", row.repo, row.status, reason));
        }
        return Ok(());
    }
    let dir = match dir {
        Some(dir) => dir,
        None => std::env::current_dir()?,
    };
    let preflight = author::submit_preflight(&dir, &fetch)?;
    for check in &preflight.checks {
        let mark = match check.ok {
            Some(true) => "ok",
            Some(false) => " ✗",
            None => " ?",
        };
        say(&format!("{mark}  {}", check.label));
        if let Some(fix) = &check.fix {
            say(&format!("      {}", fix));
        }
    }
    let Some(candidate) = &preflight.candidate else {
        return Err("nothing to submit yet — push the repository to GitHub first".into());
    };
    if dry_run {
        say(&format!(
            "would submit {} to {}",
            candidate,
            kendex_core::registry::base_url()
        ));
        return Ok(());
    }
    if !preflight.ready {
        return Err("fix the rows marked ✗ first — or --dry-run to see what would be sent".into());
    }
    let outcome = submit::submit(&fetch, &KeyringStore, candidate)?;
    say(&format!(
        "submitted {} — status: {}{}",
        outcome.repo,
        outcome.status,
        match outcome.status.as_str() {
            "pending" => " (in the review queue; `kendex marketplace submit --status` follows it)",
            "listed" => " (live in the community directory)",
            _ => "",
        }
    ));
    Ok(())
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
