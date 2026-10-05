use clap::Args;

use kendex_core::env::Env;
use kendex_core::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME};
use kendex_core::model::HarnessId;
use kendex_core::package::detail;
use kendex_core::package::support::{FallbackTool, RecordSupport, UnsupportedTool};

use super::pin::{kind_choices, parse_kind};
use super::{CliResult, payload, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui::report::PlainColumns;
use crate::ui::{self, Span, Status, Style, Target};

#[derive(Args)]
pub struct ShowArgs {
    #[arg(help = kind_choices())]
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

/// How the supported-tools line collapses core's unsupported list.
#[derive(Debug, PartialEq)]
enum Coverage<'a> {
    /// No tool is unsupported.
    All,
    /// Some tools are unsupported, each named with its own reason.
    Except(&'a [UnsupportedTool]),
    /// Every tool is unsupported: each distinct reason once, in the order
    /// the tools first give it, rather than once per tool.
    None(Vec<&'a str>),
}

fn coverage(unsupported: &[UnsupportedTool]) -> Coverage<'_> {
    if unsupported.is_empty() {
        return Coverage::All;
    }
    if unsupported.len() != HarnessId::ALL.len() {
        return Coverage::Except(unsupported);
    }
    let mut reasons: Vec<&str> = Vec::new();
    for reason in unsupported.iter().filter_map(|gap| gap.reason.as_deref()) {
        if !reasons.contains(&reason) {
            reasons.push(reason);
        }
    }
    Coverage::None(reasons)
}

/// One `; `-separated part of the supported-tools line, in line order.
#[derive(Debug, PartialEq)]
enum Segment<'a> {
    /// Core could not read the record; the cause says why. The whole line.
    Unknown(&'a str),
    /// Which tools run the package, less the unsupported ones.
    Coverage(Coverage<'a>),
    /// Tools that take the package only as advice.
    Advisory(&'a [HarnessId]),
    /// Tools where a fallback does the package's job.
    Fallback(&'a [FallbackTool]),
}

/// What the supported-tools line says about a record: its coverage, then
/// the advisory tools and the fallback tools where there are any. A record
/// core could not read says only that, with why.
fn segments(support: &RecordSupport) -> Vec<Segment<'_>> {
    let (unsupported, advisory, fallback) = match support {
        RecordSupport::Read {
            unsupported,
            advisory,
            fallback,
        } => (unsupported, advisory, fallback),
        RecordSupport::Unread { cause } => return vec![Segment::Unknown(cause)],
    };
    let mut line = vec![Segment::Coverage(coverage(unsupported))];
    if !advisory.is_empty() {
        line.push(Segment::Advisory(advisory));
    }
    if !fallback.is_empty() {
        line.push(Segment::Fallback(fallback));
    }
    line
}

/// The package's supported tools in one value, each segment worded: an
/// unsupported tool with its reason where the package states one.
fn supported_tools(support: &RecordSupport) -> String {
    let named = |gap: &UnsupportedTool| match &gap.reason {
        Some(reason) => format!("{} ({reason})", gap.tool.display_name()),
        None => gap.tool.display_name().to_owned(),
    };
    let worded: Vec<String> = segments(support)
        .into_iter()
        .map(|segment| match segment {
            Segment::Unknown(cause) => format!("unknown ({cause})"),
            Segment::Coverage(Coverage::All) => "all".to_owned(),
            Segment::Coverage(Coverage::Except(gaps)) => {
                let gaps: Vec<String> = gaps.iter().map(named).collect();
                format!("all except {}", gaps.join(", "))
            }
            Segment::Coverage(Coverage::None(reasons)) if reasons.is_empty() => "none".to_owned(),
            Segment::Coverage(Coverage::None(reasons)) => format!("none ({})", reasons.join("; ")),
            Segment::Advisory(tools) => {
                let tools: Vec<&str> = tools.iter().map(|tool| tool.display_name()).collect();
                format!("advisory on {}", tools.join(", "))
            }
            Segment::Fallback(notes) => {
                let tools: Vec<String> = notes
                    .iter()
                    .map(|note| format!("{} ({})", note.tool.display_name(), note.reason))
                    .collect();
                format!("fallback on {}", tools.join(", "))
            }
        })
        .collect();
    worded.join("; ")
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
    field(
        "supported tools",
        &supported_tools(&meta.support),
        Status::Notice,
        None,
    );
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
