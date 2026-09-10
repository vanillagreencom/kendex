//! The `bookmark` verb family — the same saved marketplace items the
//! window shows, over the same core operations. Nothing about a bookmark
//! is decided here: what one records, whether two spellings of a
//! marketplace are one, and whether a saved item is still offered are
//! core's.

use std::path::PathBuf;

use clap::{Args, Subcommand};
use kendex_core::bookmark::{self, Bookmark, BookmarkItem, Reach, SavedItem};
use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};

use super::add::AddArgs;
use super::{CliResult, note, out, say, warn};

#[derive(Subcommand)]
pub enum BookmarkCommand {
    /// Everything saved, with where each one stands on this machine
    List,
    /// One saved item: what it is, where it came from, and whether its
    /// marketplace still offers it
    Show {
        name: String,
        #[command(flatten)]
        which: Which,
    },
    /// Save a marketplace package or curated set to find again
    Add {
        name: String,
        /// What it is: a package kind, or `bundle` for a curated set
        #[arg(long)]
        kind: String,
        /// The marketplace it comes from — `owner/repo`, a marketplace
        /// link, or a folder
        #[arg(long)]
        source: String,
    },
    /// Forget a saved item. Nothing installed from it is touched
    Remove {
        name: String,
        #[command(flatten)]
        which: Which,
    },
    /// Install a saved item, through the ordinary install
    Install {
        name: String,
        #[command(flatten)]
        which: Which,
        /// The project to install into; without it the personal setup
        #[arg(long)]
        project: Option<PathBuf>,
        /// Skip confirmation prompts
        #[arg(short = 'y', long)]
        yes: bool,
    },
}

/// Which of the saved items wearing one name is meant. Both are optional:
/// a name only one saved item wears needs neither, and a name two wear
/// needs whichever tells them apart.
#[derive(Args, Clone, Default)]
pub struct Which {
    /// What it is, where two saved items share a name
    #[arg(long)]
    pub kind: Option<String>,
    /// The marketplace it comes from, where two saved items share a name
    #[arg(long)]
    pub source: Option<String>,
}

pub fn run(env: &Env, command: BookmarkCommand) -> CliResult {
    match command {
        BookmarkCommand::List => list(env),
        BookmarkCommand::Show { name, which } => show(env, &name, &which),
        BookmarkCommand::Add { name, kind, source } => add(env, name, &kind, source),
        BookmarkCommand::Remove { name, which } => remove(env, &name, &which),
        BookmarkCommand::Install {
            name,
            which,
            project,
            yes,
        } => install(env, &name, &which, project, yes),
    }
}

/// A listing distinguishes unreadable storage from an empty list: an
/// unreadable index leaves through the verb, and nothing saved says so in
/// words.
fn list(env: &Env) -> CliResult {
    let saved = bookmark::resolve(env)?;
    if saved.is_empty() {
        out("nothing saved yet");
        return Ok(());
    }
    for item in &saved {
        out(&line(item));
    }
    Ok(())
}

fn show(env: &Env, name: &str, which: &Which) -> CliResult {
    let item = pick(env, name, which)?;
    out(&line(&item));
    match &item.reach {
        Reach::Offered => {}
        Reach::NotOffered { why } | Reach::Unavailable { why } => warn(why),
        Reach::Unsubscribed => note(NOT_SUBSCRIBED),
    }
    Ok(())
}

fn add(env: &Env, name: String, kind: &str, source: String) -> CliResult {
    let saved = bookmark::add(
        env,
        Bookmark {
            repo: source,
            item: BookmarkItem::parse(kind)?,
            name,
        },
    )?;
    out(&format!(
        "saved {} {} from {}",
        saved.item.name(),
        saved.name,
        saved.repo
    ));
    Ok(())
}

fn remove(env: &Env, name: &str, which: &Which) -> CliResult {
    let item = pick(env, name, which)?;
    bookmark::remove(env, &item.bookmark)?;
    out(&format!(
        "forgot {} {}. Anything installed from it stays installed",
        item.bookmark.item.name(),
        item.bookmark.name
    ));
    Ok(())
}

fn install(env: &Env, name: &str, which: &Which, project: Option<PathBuf>, yes: bool) -> CliResult {
    let item = pick(env, name, which)?;
    // Refused before the destination is settled, because a destination is
    // registered by the install that reaches it: a run that only refused
    // once it had started would leave a project on the list with nothing
    // in it.
    installable(&item)?;
    let destination = match project {
        Some(root) => Scope::Project {
            root: kendex_core::paths::canonical(&root)?,
        },
        None => Scope::Global,
    };
    say(&format!(
        "installing {} {} from {} into {}",
        item.bookmark.item.name(),
        item.bookmark.name,
        item.bookmark.repo,
        super::scope_label(&destination)
    ));
    super::add::run_into(env, &destination, request(&item, yes))
}

/// Whether a saved item may be installed at all, or the refusal saying why
/// not. Only a marketplace this machine can serve and that still offers the
/// item may be: every other standing would send the engine at content
/// nobody has read.
fn installable(item: &SavedItem) -> Result<(), String> {
    match &item.reach {
        Reach::Offered => Ok(()),
        Reach::NotOffered { why } | Reach::Unavailable { why } => Err(why.clone()),
        Reach::Unsubscribed => Err(format!("{NOT_SUBSCRIBED} — subscribe to it, then install")),
    }
}

/// The install this saved item asks for: its own marketplace, and its own
/// name under its own kind. A curated set installs whole, the way it does
/// from its page.
///
/// The marketplace is sent as the reference the bookmark records rather
/// than as the alias the catalog was resolved through: an alias belongs to
/// the place that declared it, and the destination may be another place
/// entirely. The engine reads the reference against the destination's own
/// declarations and reuses whichever subscription already names that
/// repository, so a place that has it under its own name gains no second
/// one.
fn request(item: &SavedItem, yes: bool) -> AddArgs {
    let name = vec![item.bookmark.name.clone()];
    let mut args = AddArgs {
        source: Some(item.bookmark.repo.clone()),
        yes,
        ..AddArgs::default()
    };
    match item.bookmark.item.kind() {
        None => args.bundle = name,
        Some(ItemKind::Agent) => args.agent = name,
        Some(ItemKind::Skill) => args.skill = name,
        Some(ItemKind::Hook) => args.hook = name,
        Some(ItemKind::Command) => args.command = name,
        Some(ItemKind::McpServer) => args.mcp_server = name,
        // A plugin is its registry's own curated set and installs as one,
        // the same reading every other install path gives it.
        Some(ItemKind::Plugin) => args.bundle = name,
        Some(ItemKind::PiExtension) => args.pi_extension = name,
    }
    args
}

/// One saved item by the name a person typed, and whatever they gave to
/// tell it from the others wearing that name.
///
/// A name nothing wears refuses. A name two saved items wear refuses too,
/// naming the flag that tells them apart and listing what was found —
/// never picking one, which would install or forget something the person
/// did not name.
fn pick(env: &Env, name: &str, which: &Which) -> Result<SavedItem, Box<dyn std::error::Error>> {
    let wanted = which.kind.as_deref().map(BookmarkItem::parse).transpose()?;
    let source = which
        .source
        .as_deref()
        .map(kendex_core::source_ref::repo_identity);
    let mut found: Vec<SavedItem> = bookmark::resolve(env)?
        .into_iter()
        .filter(|item| item.bookmark.name == name)
        .filter(|item| wanted.is_none_or(|kind| item.bookmark.item == kind))
        .filter(|item| {
            source
                .as_deref()
                .is_none_or(|identity| item.repo_identity == identity)
        })
        .collect();
    if found.len() > 1 {
        return Err(ambiguous(name, &found).into());
    }
    found.pop().ok_or_else(|| {
        kendex_core::error::CoreError::NoSuchBookmark {
            name: name.to_owned(),
        }
        .into()
    })
}

/// Said when a name reaches more than one saved item: which flag settles
/// it, and what each candidate is.
fn ambiguous(name: &str, found: &[SavedItem]) -> String {
    let first = found.first().map(|item| item.bookmark.item);
    let flag = match found.iter().any(|item| Some(item.bookmark.item) != first) {
        true => "--kind",
        false => "--source",
    };
    let candidates: Vec<String> = found
        .iter()
        .map(|item| {
            format!(
                "{} {} from {}",
                item.bookmark.item.name(),
                item.bookmark.name,
                item.bookmark.repo
            )
        })
        .collect();
    format!(
        "'{name}' names {} saved items — say which with {flag}: {}",
        found.len(),
        candidates.join("; ")
    )
}

/// One saved item as a line: what it is, what it is called, where it came
/// from, and where it stands.
fn line(item: &SavedItem) -> String {
    let standing = match &item.reach {
        Reach::Offered => "offered",
        Reach::NotOffered { .. } => "no longer offered",
        Reach::Unsubscribed => "not subscribed",
        Reach::Unavailable { .. } => "unavailable",
    };
    format!(
        "{} {}  {}  [{standing}]",
        item.bookmark.item.name(),
        item.bookmark.name,
        item.bookmark.repo
    )
}

const NOT_SUBSCRIBED: &str =
    "nothing on this machine subscribes to this marketplace, so what it offers is unread";
