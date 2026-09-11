//! The `bookmark` verb family — the same saved marketplace items the
//! window shows, over the same core operations. Nothing about a bookmark
//! is decided here: what one records, whether two spellings of a
//! marketplace are one, and whether a saved item is still offered are
//! core's.

use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use kendex_core::bookmark::{self, Bookmark, BookmarkItem, Reach, SavedItem};
use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::Catalog;
use kendex_core::source_ref::SourceRef;

use super::add::{AddArgs, Declared};
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
            repo: marketplace(env, &source)?,
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

/// The marketplace a person typed, as a bookmark records it. A repository
/// is kept as typed, for core to fold. A folder is recorded where it
/// resolves from the folder this runs in, the join `source::path_root`
/// gives a declaration made here, because its relative spelling names
/// another directory from every place that reads it.
fn marketplace(env: &Env, typed: &str) -> Result<String, Box<dyn std::error::Error>> {
    match kendex_core::source_ref::parse_typed(typed)? {
        SourceRef::Path { path } => {
            let here = std::env::current_dir()
                .and_then(|cwd| kendex_core::paths::canonical(&cwd))
                .map_err(|e| format!("the current folder could not be read: {e}"))?;
            Ok(kendex_core::paths::slashed(
                &kendex_core::source::path_root(env, &Scope::Project { root: here }, &path),
            ))
        }
        SourceRef::Remote { .. }
        | SourceRef::Tree { .. }
        | SourceRef::SkillsSh { .. }
        | SourceRef::Collection { .. } => Ok(typed.to_owned()),
    }
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
    let subscription = installable(&item)?;
    let destination = match project {
        Some(root) => project_named(env, &root)?,
        None => Scope::Global,
    };
    say(&format!(
        "installing {} {} from {} into {}",
        item.bookmark.item.name(),
        item.bookmark.name,
        item.bookmark.repo,
        super::scope_label(&destination)
    ));
    super::add::run_into(env, &destination, request(&item, subscription, yes))
}

/// The project `--project` names, or the refusal where it is the home
/// directory. `discover::may_be_a_project_root` is the rule, the one
/// `kendex add` settles its destination by: a home made into a project
/// would take every install below it.
///
/// The rule compares in `std::fs::canonicalize`'s spelling, and the root
/// handed back is `paths::reduced` of it, the split `kendex add` makes.
fn project_named(env: &Env, named: &Path) -> Result<Scope, Box<dyn std::error::Error>> {
    let here = named
        .canonicalize()
        .map_err(|e| format!("{} could not be read: {e}", named.display()))?;
    let root = kendex_core::paths::reduced(&here);
    if !kendex_core::discover::may_be_a_project_root(&here, env.real_home()) {
        return Err(format!(
            "{} is your home directory, and kendex does not make it a project — everything below it would install into it; leave out --project for your personal setup, or name the project you mean",
            root.display()
        )
        .into());
    }
    Ok(Scope::Project { root })
}

/// The subscription a saved item installs from, or the refusal saying why
/// it may not be installed. Only a marketplace this machine can serve and
/// that still offers the item may be: every other standing would send the
/// engine at content nobody has read.
fn installable(item: &SavedItem) -> Result<Declared, String> {
    match (&item.reach, &item.catalog) {
        (Reach::Offered, Some(Catalog::Subscription { scope, source })) => Ok(Declared {
            scope: scope.clone(),
            name: source.clone(),
        }),
        (Reach::Offered, None | Some(Catalog::Repo { .. })) => Err(format!(
            "internal: saved {} '{}' reads as offered through no subscription",
            item.bookmark.item.name(),
            item.bookmark.name
        )),
        (Reach::NotOffered { why } | Reach::Unavailable { why }, _) => Err(why.clone()),
        (Reach::Unsubscribed, _) => {
            Err(format!("{NOT_SUBSCRIBED} — subscribe to it, then install"))
        }
    }
}

/// The install this saved item asks for: its own name under its own kind,
/// from the subscription its standing was read through. A curated set
/// installs whole, the way it does from its page.
///
/// The subscription travels as the place declaring it and its alias there,
/// never as the reference the bookmark records. A reference read against
/// the destination's own declarations is whatever that place makes of it —
/// an alias that happens to share its name, or a folder spelled against
/// another root — and the install would read content the standing never
/// read.
fn request(item: &SavedItem, subscription: Declared, yes: bool) -> AddArgs {
    let name = vec![item.bookmark.name.clone()];
    let mut args = AddArgs {
        subscription: Some(subscription),
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
        .map(|typed| marketplace(env, typed))
        .transpose()?
        .map(|repo| kendex_core::source_ref::repo_identity(&repo));
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
