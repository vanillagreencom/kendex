use clap::Args;

use kendex_core::env::Env;
use kendex_core::package::detail;

use super::pin::parse_kind;
use super::{CliResult, payload, resolve_scopes, say};
use crate::scope::ScopeFilter;

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
    if args.files {
        for file in detail::package_files(env, &scope, kind, &args.name)? {
            say(&format!("{}  {} bytes", file.path, file.size));
        }
        return Ok(());
    }
    if let Some(rel) = &args.file {
        let source = detail::package_file(env, &scope, kind, &args.name, rel)?;
        // The payload the verb exists to print, not a value in a
        // sentence: escaping it would collapse the file onto one line.
        payload(&source.content);
        if source.truncated {
            say("… (truncated at 64 KB)");
        }
        return Ok(());
    }
    if args.readme {
        match detail::package_readme(env, &scope, kind, &args.name)? {
            // A readme is the payload too, printed as its own lines.
            Some(readme) => payload(&readme.content),
            None => say("no readme"),
        }
        return Ok(());
    }
    let meta = detail::package_meta(env, &scope, kind, &args.name)?;
    say(&format!("source: {}", meta.source));
    if let Some(repo) = &meta.repo {
        say(&format!("repository: {}", repo));
    }
    if let Some(current) = &meta.current {
        let label = current
            .label
            .clone()
            .unwrap_or_else(|| current.commit[..7.min(current.commit.len())].to_owned());
        say(&format!("version: {}", label));
    }
    if let Some(rev) = &meta.rev {
        say(&format!("held at: {}", &rev[..7.min(rev.len())]));
    }
    if let Some(installed_at) = &meta.installed_at {
        say(&format!("installed: {}", installed_at));
    }
    if meta.fork.is_some() {
        say("forked: yes — a local package now");
    }
    if let Some(catalog) = &meta.catalog {
        for (label, value) in [
            ("author", &catalog.author),
            ("license", &catalog.license),
            ("homepage", &catalog.homepage),
        ] {
            if let Some(value) = value {
                say(&format!("{}: {}", label, value));
            }
        }
    }
    Ok(())
}
