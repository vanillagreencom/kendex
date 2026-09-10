//! Where this project keeps its secrets, and whether a secret may be
//! written there.
//!
//! One file per project, named by the project and read by the packages:
//! `.env.local` unless `kendex.settings.toml` `[env]` names another
//! through [`super::ENV_FILE_KEY`], which is the same key the shipped
//! loaders read. A path is never taken on the strength of being
//! configured — the checks below run on every read, so what the app shows
//! before Save is what the write is about to find.
//!
//! Every refusal here is about the same risk: a credential landing
//! somewhere that gets committed, published or read by another project.
//! So the questions are whether the path stays inside this project, and
//! whether git would carry it out. A `.gitignore` line alone does not
//! answer the second — git tracks a file it already tracks whatever the
//! ignore rules say — so both are asked, and a git call that fails to
//! answer refuses rather than passing.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::process::Hardened;

/// The file a project keeps its secrets in when it names none.
pub const DEFAULT_ENV_FILE: &str = ".env.local";

/// The project file that lists what git must not carry.
pub const IGNORE_FILE: &str = ".gitignore";

/// The settings file the shell loaders read AFTER the root one, so its
/// assignment of a key is the one that wins. kendex writes the root file,
/// which is why a selector answered here is honoured but never recorded
/// over.
pub const NESTED_SETTINGS_FILE: &str = ".kendex/settings.toml";

/// Where this project's secrets go, and whether they may.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Destination {
    /// Project-relative, as the person is shown it before Save.
    pub file: String,
    /// Whether the project named this file itself. False means it is the
    /// default, which every project has without choosing it.
    pub chosen: bool,
    pub state: DestinationState,
}

/// Whether a secret may be written to the destination, and what saving
/// has to do first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum DestinationState {
    /// The file is there, git will not carry it, and kendex can write it.
    Ready,
    /// Nothing is there yet. Saving makes it, readable by its owner
    /// alone.
    Missing {
        /// The line saving adds to the project's `.gitignore` first, or
        /// `None` where git already ignores the path.
        ignore: Option<String>,
    },
    /// No secret may be written here, and why.
    Refused { problem: String, fix: String },
}

impl Destination {
    /// The absolute path, given the project root the destination was read
    /// for.
    pub fn path(&self, root: &Path) -> PathBuf {
        root.join(&self.file)
    }

    /// Whether a secret may be written, which is every state but a
    /// refusal.
    pub fn writable(&self) -> bool {
        !matches!(self.state, DestinationState::Refused { .. })
    }
}

/// Where this project's secrets go, given its settings file's text.
///
/// `want` is a file a person is considering instead — the same checks
/// run on it, so what they are shown before choosing is what a save would
/// find. `chosen` then answers whether the project already names that
/// file, which is what tells a save whether it also has to record the
/// choice.
pub fn destination(root: &Path, settings: Option<&str>, want: Option<&str>) -> Destination {
    destination_layered(root, &[settings.map(str::to_owned)], want)
}

/// The destination, given every settings layer in the order the shell
/// loaders read them — lowest precedence first.
///
/// The loaders read `kendex.settings.toml`, then `.kendex/settings.toml`,
/// and the later assignment wins. Reading only the first would show and
/// write one private file while the installed packages source another, so
/// the layers are read here the way they are read there.
pub fn destination_layered(
    root: &Path,
    layers: &[Option<String>],
    want: Option<&str>,
) -> Destination {
    // The last layer that ASSIGNS the key is the one the loaders honour,
    // so the walk runs from the top down and stops at the first
    // assignment — not at the first non-empty one. An empty assignment is
    // an answer there: the shell reads `${KENDEX_ENV_FILE:-}` off it and
    // resolves the default, and a walk that read past it would take a
    // filename from a layer the loaders have already overwritten.
    let answered = layers.iter().enumerate().rev().find_map(|(at, text)| {
        match text.as_deref().map(configured_file) {
            None | Some(Ok(Assigned::Absent)) => None,
            Some(answer) => Some((at, answer)),
        }
    });
    let (from, named) = match answered {
        // Empty resolves to the default here exactly as it does in the
        // shell, and it still stops the walk.
        Some((at, Ok(Assigned::Empty))) => (at, Some(DEFAULT_ENV_FILE.to_owned())),
        Some((at, Ok(Assigned::Named(named)))) => (at, Some(named)),
        Some((_, Ok(Assigned::Absent))) => (0, None),
        Some((_, Err(problem))) => return refused_selector(problem),
        None => (0, None),
    };
    // A file the higher-precedence layer names is honoured and never
    // recorded over: kendex writes the root settings file, and a choice
    // written there would be overridden by the layer above it the moment
    // a package read it. `chosen` therefore stays false for such a file,
    // and a save that would record one is refused rather than written.
    let above = from > 0;
    // What the loaders will read. A file the higher layer names is that
    // answer whatever anyone picks here, because that layer is read last;
    // otherwise the pick decides, then the root file, then the default.
    let file = match (above, &named) {
        (true, Some(named)) => named.clone(),
        _ => want
            .map(str::to_owned)
            .or_else(|| named.clone())
            .unwrap_or_else(|| DEFAULT_ENV_FILE.to_owned()),
    };
    let chosen = !above && named.as_deref() == Some(file.as_str());
    if above && want.is_some_and(|want| want != file) {
        return Destination {
            chosen,
            state: refused(
                format!(
                    "{NESTED_SETTINGS_FILE} names {file} as this project's private file, and it is read after the file kendex writes"
                ),
                format!(
                    "settle {} in {NESTED_SETTINGS_FILE}, then open this page again",
                    super::ENV_FILE_KEY
                ),
            ),
            file,
        };
    }
    let state = match relative(&file) {
        Err(refusal) => refusal,
        Ok(()) => protection(root, &file),
    };
    Destination {
        file,
        chosen,
        state,
    }
}

/// A selector nothing can read is not a selector the default stands in
/// for: the shell loaders refuse the whole file over one.
fn refused_selector(problem: String) -> Destination {
    Destination {
        file: DEFAULT_ENV_FILE.to_owned(),
        chosen: false,
        state: refused(
            problem,
            format!(
                "settle {} in the settings file that assigns it, then open this page again",
                super::ENV_FILE_KEY
            ),
        ),
    }
}

/// What one settings layer says about the key.
///
/// Absent and empty are held apart because the loaders hold them apart: a
/// layer that assigns nothing leaves the layer below it deciding, while
/// one that assigns the empty string has decided — on the default.
enum Assigned {
    Absent,
    Empty,
    Named(String),
}

/// The file this settings layer names for its secrets: nothing, the empty
/// assignment, a name, or why nothing can read the one that is there.
///
/// Read through the same view of the settings file the settings rows come
/// from, so kendex and the shipped loaders resolve one key one way.
fn configured_file(settings: &str) -> std::result::Result<Assigned, String> {
    let sites = crate::settings_file::sites(settings);
    match crate::settings_file::current_of(&sites, super::ENV_FILE_KEY) {
        crate::settings_file::Current::Absent => Ok(Assigned::Absent),
        crate::settings_file::Current::Value { value, .. } => Ok(match value.trim().is_empty() {
            true => Assigned::Empty,
            false => Assigned::Named(value),
        }),
        crate::settings_file::Current::Ambiguous { problem, lines } => Err(format!(
            "kendex.settings.toml assigns {} in a shape no script reads — {problem}: {}",
            super::ENV_FILE_KEY,
            crate::settings_file::lines_phrase(&lines)
        )),
    }
}

/// Whether the named path is one inside this project at all, judged as
/// text before anything is touched. A path that leaves the project by
/// spelling is refused here; one that leaves it through a link is refused
/// by [`protection`].
fn relative(file: &str) -> std::result::Result<(), DestinationState> {
    let refuse = |problem: &str| {
        Err(DestinationState::Refused {
            problem: problem.to_owned(),
            fix: format!(
                "set {} in kendex.settings.toml to a path inside this project, or remove it to use {DEFAULT_ENV_FILE}",
                super::ENV_FILE_KEY
            ),
        })
    };
    if file.trim().is_empty() {
        return refuse("the project names no file for its secrets");
    }
    let path = Path::new(file);
    if path.is_absolute() || file.starts_with('/') || file.starts_with('\\') {
        return refuse(&format!(
            "{file} is an absolute path, not one inside this project"
        ));
    }
    // Windows spells a path with backslashes and a volume prefix, and
    // neither is a relative path this reads. Judged as characters rather
    // than by component, so the answer does not depend on the host.
    if file.contains('\\') || file.contains(':') {
        return refuse(&format!(
            "{file} is not a plain relative path — write it with forward slashes and no drive"
        ));
    }
    if path
        .components()
        .any(|part| part == std::path::Component::ParentDir)
    {
        return refuse(&format!("{file} climbs out of this project with .."));
    }
    if path.file_name().is_none() {
        return refuse(&format!("{file} names no file"));
    }
    Ok(())
}

/// The project files kendex writes itself, none of which is a place a
/// credential may go.
///
/// `kendex.settings.toml` is the public settings file this very save
/// records the destination choice in, and `.kendex/settings.toml` is the
/// layer read after it; both are configuration a project commits, and
/// neither is env-file syntax to begin with. `.kendex-generated.json` is
/// rewritten wholesale by every apply.
const KENDEX_FILES: [&str; 3] = [
    crate::settings_seed::SETTINGS_FILE,
    NESTED_SETTINGS_FILE,
    crate::engine::generated_paths::INVENTORY,
];

/// Whether a credential may be written at this path: not a file kendex
/// writes itself, inside the project through every link on the way, a
/// regular file or nothing at all, and out of git's reach.
fn protection(root: &Path, file: &str) -> DestinationState {
    let path = root.join(file);
    // Asked before git, because it is not a question about git. A project
    // with no repository, or one that ignores its settings file, would
    // otherwise take `kendex.settings.toml` as ready and append a
    // credential to the configuration kendex publishes — and a project
    // that becomes a repository later commits it.
    if let Some(owned) = KENDEX_FILES.iter().find(|owned| same_file(file, owned)) {
        return refused(
            format!(
                "{owned} is kendex's own configuration, not a private file — a secret written there would be published with the project's settings"
            ),
            format!(
                "name another file for this project's secrets, or leave it on {DEFAULT_ENV_FILE}"
            ),
        );
    }
    if let Err(refusal) = inside(root, &path, file) {
        return refusal;
    }
    match std::fs::symlink_metadata(&path) {
        // A link is refused whatever it points at: the target is where
        // the bytes land, and it is outside every check made here.
        Ok(meta) if meta.is_symlink() => {
            return refused(
                format!(
                    "{file} is a symbolic link, and a secret written through it lands somewhere these checks never saw"
                ),
                format!(
                    "replace {file} with a regular file, or name another file for this project's secrets"
                ),
            );
        }
        Ok(meta) if !meta.is_file() => {
            return refused(
                format!("{file} is not a regular file"),
                "move it aside, or name another file for this project's secrets".to_owned(),
            );
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return refused(
                format!("{file} could not be read ({error})"),
                "fix its permissions, then open this page again".to_owned(),
            );
        }
    }
    let exists = path.is_file();
    match git_standing(root, file) {
        Err(problem) => refused(
            problem,
            "fix the repository, then open this page again — until git can answer, kendex cannot say a secret written here would stay out of it"
                .to_owned(),
        ),
        // No repository, so nothing here can carry the file anywhere.
        Ok(None) => ready(exists, None),
        Ok(Some(standing)) if standing.tracked => refused(
            format!("git already tracks {file}, so a secret written there would be committed — an ignore rule does not untrack a file"),
            format!("run git rm --cached -- {file} and commit that, then open this page again"),
        ),
        Ok(Some(standing)) if standing.ignored => ready(exists, None),
        // Not ignored. A file that is not there yet can be made safe in
        // the same save; one that is already there is the person's, and
        // kendex does not quietly start ignoring a file they can see.
        Ok(Some(_)) if exists => refused(
            format!("git does not ignore {file}, so a secret written there would show up as a change to commit"),
            format!("add /{file} to {IGNORE_FILE}, then open this page again"),
        ),
        Ok(Some(_)) => ready(false, Some(format!("/{file}"))),
    }
}

/// Whether the configured name and one of kendex's own are the same file
/// as written. Compared by component so `./kendex.settings.toml` and
/// `.kendex//settings.toml` are the file they name, and not by resolving
/// anything: a name kendex will not write is refused before the disk is
/// touched, and a link pointing at one is refused as a link.
fn same_file(file: &str, owned: &str) -> bool {
    fn parts(name: &str) -> Vec<std::path::Component<'_>> {
        Path::new(name)
            .components()
            .filter(|part| !matches!(part, std::path::Component::CurDir))
            .collect()
    }
    parts(file) == parts(owned)
}

fn ready(exists: bool, ignore: Option<String>) -> DestinationState {
    match exists {
        true => DestinationState::Ready,
        false => DestinationState::Missing { ignore },
    }
}

fn refused(problem: String, fix: String) -> DestinationState {
    DestinationState::Refused { problem, fix }
}

/// Whether the path stays inside the project once every link on the way
/// is followed. The file itself may not exist yet, so the deepest
/// existing ancestor is what is resolved and the rest is spelling, which
/// [`relative`] has already judged.
fn inside(root: &Path, path: &Path, file: &str) -> std::result::Result<(), DestinationState> {
    let Ok(root) = crate::paths::canonical(root) else {
        return Err(refused(
            format!(
                "this project's folder could not be resolved, so nothing can say whether {file} is inside it"
            ),
            "check that the project folder is still there, then open this page again".to_owned(),
        ));
    };
    let mut ancestor = path.parent();
    while let Some(dir) = ancestor {
        if !dir.exists() {
            ancestor = dir.parent();
            continue;
        }
        let Ok(resolved) = crate::paths::canonical(dir) else {
            return Err(refused(
                format!(
                    "{} could not be resolved, so nothing can say whether {file} is inside this project",
                    dir.display()
                ),
                "check that the folder is still there, then open this page again".to_owned(),
            ));
        };
        if !resolved.starts_with(&root) {
            return Err(refused(
                format!("{file} resolves outside this project, through a link on the way to it"),
                "name a file inside this project for its secrets".to_owned(),
            ));
        }
        return Ok(());
    }
    Ok(())
}

/// What git says about one path.
struct GitStanding {
    /// In the index: committed, or staged for the next commit. Either way
    /// git carries the file.
    tracked: bool,
    /// Matched by an ignore rule.
    ignored: bool,
}

/// What git says about the path, or `None` where there is no repository
/// to say anything. An answer git refuses to give is an error rather than
/// a pass: "kendex could not check" and "git will not carry this" are not
/// the same fact, and a secret must not be written on the second when
/// only the first is known.
fn git_standing(root: &Path, file: &str) -> std::result::Result<Option<GitStanding>, String> {
    let inside = run(root, &["rev-parse", "--is-inside-work-tree"])?;
    if !inside.status.success() {
        let said = String::from_utf8_lossy(&inside.stderr);
        if said.contains("not a git repository") || said.contains("not a working tree") {
            return Ok(None);
        }
        return Err(format!("git could not read this project ({})", said.trim()));
    }
    let listed = run(root, &["ls-files", "-z", "--", file])?;
    if !listed.status.success() {
        return Err(format!(
            "git ls-files could not read {file} ({})",
            String::from_utf8_lossy(&listed.stderr).trim()
        ));
    }
    let checked = run(root, &["check-ignore", "-q", "--", file])?;
    // `git check-ignore -q` answers with its exit status: 0 ignored, 1
    // not, anything else a failure to answer.
    let ignored = match checked.status.code() {
        Some(0) => true,
        Some(1) => false,
        _ => {
            return Err(format!(
                "git check-ignore could not answer for {file} ({})",
                String::from_utf8_lossy(&checked.stderr).trim()
            ));
        }
    };
    Ok(Some(GitStanding {
        tracked: !listed.stdout.is_empty(),
        ignored,
    }))
}

/// One git read of the project, under English diagnostics — the phrases
/// above are matched, and git translates its own.
fn run(root: &Path, args: &[&str]) -> std::result::Result<std::process::Output, String> {
    crate::guard::english(Hardened::git(args, Some(root)))
        .run()
        .map_err(|error| error.to_string())
}
