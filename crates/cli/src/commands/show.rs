use clap::Args;

use kendex_core::env::Env;
use kendex_core::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME};
use kendex_core::package::detail;

use super::pin::parse_kind;
use super::{CliResult, payload, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::report::PlainColumns;
use crate::ui::{self, Span, Status, Style, Target};

#[derive(Args)]
pub struct ShowArgs {
    /// agent | skill | hook | command | mcp-server | pi-extension
    kind: String,
    name: String,
    /// List the package's files
    #[arg(long)]
    files: bool,
    /// Print one file's content
    #[arg(long, conflicts_with = "files")]
    file: Option<String>,
    /// Print the package's readme
    #[arg(long, conflicts_with_all = ["files", "file"])]
    readme: bool,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: ShowArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let style = ui::style();
    if args.files {
        let files = detail::package_files(env, &scope, kind, &args.name)?;
        ui::stderr(&style.header("show", &args.name));
        ui::stderr(&file_list(&style, &files));
        return Ok(());
    }
    if let Some(rel) = &args.file {
        let source = detail::package_file(env, &scope, kind, &args.name, rel)?;
        // The payload the verb exists to print, not a value in a
        // sentence: escaping it would collapse the file onto one line.
        payload(&source.content);
        if source.truncated {
            ui::report::notice("… (truncated at 64 KB)");
        }
        return Ok(());
    }
    if args.readme {
        match detail::package_readme(env, &scope, kind, &args.name)? {
            // A readme is the payload too, printed as its own lines.
            Some(readme) => payload(&readme.content),
            None => ui::stderr(&style.summary(Status::Notice, "no readme")),
        }
        return Ok(());
    }
    let meta = detail::package_meta(env, &scope, kind, &args.name)?;
    ui::stderr(&style.header("show", &args.name));
    ui::stderr(&metadata(&style, &meta));
    Ok(())
}

fn file_list(style: &Style, files: &[detail::PackageFile]) -> Vec<String> {
    style.report_table(
        "files",
        &["path", "size"],
        &files
            .iter()
            .map(|file| vec![file.path.clone(), format!("{} bytes", file.size)])
            .collect::<Vec<_>>(),
        PlainColumns::Joined,
    )
}

fn metadata(style: &Style, meta: &detail::PackageMeta) -> Vec<String> {
    let mut lines = Vec::new();
    let mut field = |label: &str, value: &str, status, url: Option<&str>| {
        let text = format!("{label}: {value}");
        lines.extend(match url {
            Some(url) => style.report_link(&text, Target::Url(url)),
            None => style.report_row(status, &[Span::Prose(&text)], ""),
        });
    };
    match meta.source.as_str() {
        LOCAL_SOURCE_NAME | INPLACE_SOURCE_NAME => field(
            "marketplace",
            "none — your own package",
            Status::Notice,
            None,
        ),
        source => field("marketplace", source, Status::Notice, None),
    }
    if let Some(repo) = &meta.repo {
        field("repository", repo, Status::Notice, meta.repo_url.as_deref());
    }
    if let Some(current) = &meta.current {
        let label = current
            .label
            .clone()
            .unwrap_or_else(|| current.commit[..7.min(current.commit.len())].to_owned());
        field("version", &label, Status::Done, None);
    }
    if let Some(rev) = &meta.rev {
        field("held at", &rev[..7.min(rev.len())], Status::Decision, None);
    }
    if let Some(installed_at) = &meta.installed_at {
        field("installed", installed_at, Status::Done, None);
    }
    if meta.fork.is_some() {
        field(
            "own copy",
            "yes — updates from its marketplace are paused",
            Status::Decision,
            None,
        );
    }
    if let Some(catalog) = &meta.catalog {
        for (label, value) in [
            ("author", &catalog.author),
            ("license", &catalog.license),
            ("homepage", &catalog.homepage),
        ] {
            if let Some(value) = value {
                field(
                    label,
                    value,
                    Status::Notice,
                    (label == "homepage").then_some(value.as_str()),
                );
            }
        }
    }
    lines
}

#[cfg(test)]
mod tests;
