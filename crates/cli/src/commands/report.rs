use std::path::PathBuf;

use kendex_core::env::Env;
use kendex_core::model::ItemKind;
use kendex_core::process::Hardened;
use kendex_core::report::DEFAULT_UPSTREAM;

use super::{CliResult, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::{self, Span, Status, Style};

pub struct ReportArgs {
    pub skill: Option<String>,
    pub agent: Option<String>,
    pub hook: Option<String>,
    pub asset: Option<String>,
    pub title: String,
    pub body: Option<String>,
    pub body_file: Option<PathBuf>,
    pub global: bool,
    pub scope: Option<String>,
    pub upstream: Option<String>,
    pub area: Option<String>,
    pub dry_run: bool,
}

/// What the marker says where the lock recorded no commit or no rendering
/// for the reported asset.
const UNLOCKED: &str = "unlocked";

/// `--area` names accepted on the CLI, mapped to routing labels.
fn parse_area(raw: &str) -> Result<&'static str, String> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "cli" => Ok("cli"),
        "skills" => Ok("skills"),
        "harness" => Ok("harness"),
        "review-gate" | "ci-infra" => Ok("ci-infra"),
        "docs" => Ok("docs"),
        "tech-debt" | "chore" => Ok("chore"),
        other => Err(format!(
            "unknown --area '{other}'; expected one of: cli, skills, harness, review-gate, docs, tech-debt"
        )),
    }
}

struct Inputs {
    selector: Option<(String, Option<ItemKind>)>,
    body: String,
    filter: ScopeFilter,
    area_override: Option<&'static str>,
    upstream: String,
}

fn parse_inputs(args: &ReportArgs) -> Result<Inputs, Box<dyn std::error::Error>> {
    let selectors = [
        (&args.skill, Some(ItemKind::Skill)),
        (&args.agent, Some(ItemKind::Agent)),
        (&args.hook, Some(ItemKind::Hook)),
        (&args.asset, None),
    ];
    let mut chosen: Vec<(String, Option<ItemKind>)> = selectors
        .iter()
        .filter_map(|(name, kind)| name.as_ref().map(|n| (n.clone(), *kind)))
        .collect();
    if chosen.len() > 1 {
        return Err("pass at most one of --skill, --agent, --hook, --asset".into());
    }
    let body = match (&args.body, &args.body_file) {
        (Some(_), Some(_)) => return Err("--body and --body-file are mutually exclusive".into()),
        (None, None) => return Err("provide --body or --body-file".into()),
        (Some(text), None) => text.clone(),
        (None, Some(path)) => std::fs::read_to_string(path)?,
    };
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    if filter == ScopeFilter::All {
        return Err(
            "report reads one install record; pass --scope project or --scope global".into(),
        );
    }
    Ok(Inputs {
        selector: chosen.pop(),
        body,
        filter,
        area_override: args.area.as_deref().map(parse_area).transpose()?,
        upstream: args
            .upstream
            .clone()
            .unwrap_or_else(|| DEFAULT_UPSTREAM.to_owned()),
    })
}

fn resolve_route(
    style: &Style,
    env: &Env,
    scope: &kendex_core::model::Scope,
    selector: &Option<(String, Option<ItemKind>)>,
    upstream: &str,
) -> Option<kendex_core::report::ResolvedRoute> {
    let resolved = selector
        .as_ref()
        .map(|(name, kind)| kendex_core::report::resolve(env, scope, name, *kind, upstream));
    if let Some(resolved) = &resolved {
        for warning in &resolved.warnings {
            ui::stderr(&style.note(&[Span::Prose("warning: "), Span::Prose(warning)]));
        }
    }
    resolved
}

fn append_routing_warnings(body: &mut String, resolved: &kendex_core::report::ResolvedRoute) {
    if resolved.warnings.is_empty() {
        return;
    }
    body.push_str("\n\nkendex routing warnings:\n");
    for warning in &resolved.warnings {
        body.push_str(&format!("- {warning}\n"));
    }
}

pub fn run(env: &Env, args: ReportArgs) -> CliResult {
    let style = ui::style();
    ui::stderr(&style.header("report", &args.title));
    let Inputs {
        selector,
        body,
        filter,
        area_override,
        upstream,
    } = parse_inputs(&args)?;

    let scope = resolve_scopes(env, filter)?.remove(0);
    if selector.is_none() {
        ui::stderr(&style.note(&[Span::Prose(
            "warning: no asset selector — routing to this project's own repo",
        )]));
    }
    let resolved = resolve_route(&style, env, &scope, &selector, &upstream);
    let route = resolved.as_ref().map(|resolved| &resolved.route);
    // The judge names the destination as well as the decision: `gh --repo`
    // takes `owner/repo`, not the URL `--upstream` may be spelled with.
    let target = route
        .as_ref()
        .filter(|r| r.kendex_owned)
        .and_then(|r| r.repo.clone());
    let kendex_owned = target.is_some();

    let mut gh_args = vec!["issue".to_owned(), "create".to_owned()];
    let mut sent_body = body.clone();
    let mut area = None;
    if let Some(resolved) = &resolved {
        append_routing_warnings(&mut sent_body, resolved);
    }
    if let Some(target) = &target {
        let name = selector.as_ref().map_or("unknown", |(n, _)| n.as_str());
        // The kind the route resolved, so `--asset` on a skill stamps the
        // same marker `--skill` would.
        let kind_label = route
            .as_ref()
            .and_then(|r| r.kind)
            .map_or("asset", ItemKind::name);
        // What the lock recorded about this installation, so triage can
        // compare the report to the fix before investigating it. An
        // installation the lock never dated says so and files anyway.
        let recorded = route.as_ref();
        let source = recorded
            .and_then(|r| r.source.as_deref())
            .unwrap_or(UNLOCKED);
        let rendered = recorded
            .and_then(|r| r.rendered.as_deref())
            .unwrap_or(UNLOCKED);
        sent_body.push_str(&format!(
            "\n\n<!-- kendex-report:v1 asset={name} kind={kind_label} ownership=kendex source={source} rendered={rendered} -->"
        ));
        gh_args.extend(["--repo".to_owned(), target.clone()]);
        // Routing labels exist only on the canonical repo; a fork override
        // must not carry one or gh fails with "label not found".
        if let Some(derived) =
            area_override.or_else(|| route.as_ref().and_then(|r| r.label.as_deref()))
        {
            gh_args.extend(["--label".to_owned(), derived.to_owned()]);
            area = Some(derived);
        }
    }
    gh_args.extend(["--title".to_owned(), args.title.clone()]);
    gh_args.extend(["--body".to_owned(), sent_body.clone()]);

    let ownership = if kendex_owned {
        "kendex"
    } else {
        "project-local"
    };
    if args.dry_run {
        ui::stderr(&preview(
            &style,
            ownership,
            target.as_deref(),
            area,
            &gh_args,
        ));
        return Ok(());
    }

    submit(&style, &gh_args, &args.title, &sent_body)
}

fn submit(style: &Style, gh_args: &[String], title: &str, body: &str) -> CliResult {
    let gh_args: Vec<&str> = gh_args.iter().map(String::as_str).collect();
    let output = Hardened::gh(&gh_args).run();
    match output {
        Ok(result) if result.status.success() => {
            let url = String::from_utf8_lossy(&result.stdout).trim().to_owned();
            if url.is_empty() {
                ui::stdout(&style.summary(Status::Done, "Issue filed"));
            } else {
                ui::stdout(&style.summary(Status::Done, &format!("Issue filed: {url}")));
            }
            Ok(())
        }
        other => {
            let detail = match other {
                Ok(result) => String::from_utf8_lossy(&result.stderr).trim().to_owned(),
                Err(error) => error.to_string(),
            };
            let saved = save_body(title, body);
            if let Some(path) = &saved {
                ui::stderr(&style.note(&[
                    Span::Prose("report body saved to "),
                    Span::Command(&path.display().to_string()),
                ]));
            }
            ui::stderr(&style.note(&[
                Span::Prose("file it manually with the gh command above, or check `"),
                Span::Command("gh auth status"),
                Span::Prose("`"),
            ]));
            Err(format!("failed to file the report via gh: {detail}").into())
        }
    }
}

/// The dry-run fields are a script protocol. Keep their names, order and
/// gh argument spelling identical in plain mode.
fn preview(
    style: &Style,
    ownership: &str,
    target: Option<&str>,
    area: Option<&str>,
    gh_args: &[String],
) -> Vec<String> {
    let mut lines = style.note(&[Span::Prose("ownership: "), Span::Prose(ownership)]);
    lines.extend(style.note(&[
        Span::Prose("target: "),
        Span::Command(target.unwrap_or("current repo origin")),
    ]));
    if let Some(area) = area {
        lines.extend(style.note(&[Span::Prose("label: "), Span::Prose(area)]));
    }
    lines.extend(style.note(&[
        Span::Prose("would run: "),
        Span::Command(&format!("gh {}", shell_join(gh_args))),
    ]));
    lines
}

fn save_body(title: &str, body: &str) -> Option<PathBuf> {
    let slug: String = title
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .take(40)
        .collect();
    let path = std::env::temp_dir().join(format!("kendex-report-{slug}-{}.md", std::process::id()));
    std::fs::write(&path, body).ok()?;
    Some(path)
}

fn shell_join(args: &[String]) -> String {
    args.iter()
        .map(|a| {
            if a.chars().any(|c| c.is_whitespace() || c == '"') {
                format!("{a:?}")
            } else {
                a.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests;
