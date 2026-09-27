use clap::Args;

use kendex_core::env::Env;
use kendex_core::package::diff::{FileStatus, LineKind, PackageDiff, VersionSel};

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::{self, Look, Span, Status, Style};

#[derive(Args)]
pub struct DiffArgs {
    /// agent | skill | hook | command | mcp-server | pi-extension
    kind: String,
    name: String,
    /// A version (tag, branch, commit) or `installed`
    #[arg(long)]
    from: String,
    /// A version (tag, branch, commit) or `installed` (the default)
    #[arg(long, default_value = "installed")]
    to: String,
    /// Which harness's installed files to compare (default claude)
    #[arg(long)]
    harness: Option<String>,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: DiffArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    let harness = match &args.harness {
        Some(value) => Some(
            kendex_core::model::HarnessId::parse(value)
                .ok_or_else(|| format!("unknown harness '{value}'"))?,
        ),
        None => None,
    };
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let side = |selector: &str| -> Result<VersionSel, Box<dyn std::error::Error>> {
        if selector == "installed" {
            return Ok(VersionSel::Installed);
        }
        Ok(VersionSel::Commit(kendex_core::package::resolve_version(
            env, &scope, kind, &args.name, selector,
        )?))
    };
    let from = side(&args.from)?;
    let to = side(&args.to)?;
    let diff = kendex_core::package::diff::package_diff(
        env, &scope, kind, &args.name, &from, &to, harness,
    )?;
    let style = ui::style();
    ui::stderr(&style.header("diff", &args.name));
    ui::stderr(&screen(&style, &diff));
    Ok(())
}

fn screen(style: &Style, diff: &PackageDiff) -> Vec<String> {
    if diff.files.is_empty() {
        return style.summary(Status::Done, "no changes");
    }
    let summary = format!(
        "+{} -{}{}",
        diff.total_additions,
        diff.total_deletions,
        if diff.truncated { "  (truncated)" } else { "" }
    );
    let mut lines = match style.look {
        Look::Plain => style.note(&[Span::Prose(&summary)]),
        Look::Rich { .. } => style.section("changes", diff.files.len(), Status::Notice),
    };
    for file in &diff.files {
        let status = match file.status {
            FileStatus::Added => " (added)",
            FileStatus::Removed => " (removed)",
            FileStatus::Modified => "",
            FileStatus::Binary => " (binary)",
            FileStatus::TooLarge => " (too large to show)",
        };
        let label = format!(
            "{}{status}  +{} -{}",
            file.path, file.additions, file.deletions
        );
        // The plain grammar sets each file off with a blank line; a rich
        // row is its own boundary.
        if matches!(style.look, Look::Plain) {
            lines.push(String::new());
        }
        lines.extend(style.report_row(Status::Notice, &[Span::Prose(&label)], ""));
        for hunk in &file.hunks {
            lines.extend(style.report_detail(&[Span::Prose(&hunk.header)], ""));
            for line in &hunk.lines {
                let marker = match line.kind {
                    LineKind::Context => ' ',
                    LineKind::Add => '+',
                    LineKind::Remove => '-',
                };
                let text = format!("{marker}{}", line.text);
                lines.extend(match style.look {
                    Look::Plain => style.note(&[Span::Prose(&text)]),
                    Look::Rich { .. } => style.detail(
                        match line.kind {
                            LineKind::Context => None,
                            LineKind::Add => Some(Status::Done),
                            LineKind::Remove => Some(Status::Decision),
                        },
                        &[Span::Prose(&text)],
                    ),
                });
            }
        }
    }
    if matches!(style.look, Look::Rich { .. }) {
        lines.extend(style.summary(
            if diff.truncated {
                Status::Notice
            } else {
                Status::Done
            },
            &summary,
        ));
    }
    lines
}

#[cfg(test)]
mod tests;
