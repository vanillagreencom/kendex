//! The session-start check: classification over the snapshot, stamps, lock
//! and manifest — cheap reads only — rendered inside hard budgets with a
//! closed remedy vocabulary.
//!
//! One state the cheap reads cannot judge: a declaration whose position
//! holds files no record says kendex wrote. Whether those files are the
//! render or something older needs the render, so for that state alone
//! the check plans the scope — once per state and inside the session
//! hook's budget, the verdicts memoized by `drift::copies` — claims a
//! copy the render matches into the record without a word, and reports a
//! copy it does not as stale with the count and, where the pass answered
//! for the whole scope, the take-over as the fix (`scope::blocked_lines`).
//!
//! This report is the one deliberate exception to the no-command-lines
//! rule: it is written for an agent that can act, so each line may carry a
//! remedy built from a fixed template set: apply, replace-unmanaged,
//! refresh, remove, add, fork, drift-hook, move-aside, findings, plan —
//! with validated identifiers or quoted paths in argument positions.
//! Free text from sources or errors renders in quoted informational
//! positions, never in a command position. A remedy that changes something
//! is offered as the fix; the one that only prints is offered as what to
//! see next, because a line an agent runs and meets again next session is
//! worse than no remedy at all.

use serde::Serialize;
use specta::Type;

use crate::env::Env;
use crate::model::{ItemKind, Scope};

/// The check's whole contract: 0 clean, 1 drift, 2 could-not-check. A
/// package awaiting re-evaluation is a state the check determined, so it
/// exits 1 with the drift it sits alongside; only a line the check could
/// not produce exits 2. When both apply, could-not-check wins — an
/// incomplete report must not claim the completeness that exit 1 implies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum CheckStatus {
    Clean,
    Drift,
    Unknown,
}

impl CheckStatus {
    pub fn exit_code(self) -> u8 {
        match self {
            CheckStatus::Clean => 0,
            CheckStatus::Drift => 1,
            CheckStatus::Unknown => 2,
        }
    }
}

/// What a line is: a fact about drift, a package whose verdict is not in
/// yet, or an admission that something could not be checked. The first
/// two are answers and exit 1; the last is the absence of one and exits 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum Class {
    Drift,
    /// The source comparison is missing or outdated, or no deep pass has
    /// run yet. The next background refresh settles it.
    Unevaluated,
    Unknown,
}

impl Class {
    /// What a line of this class makes of the whole check. A verdict still
    /// owed is a state the check determined, so it counts as drift.
    pub fn status(self) -> CheckStatus {
        match self {
            Class::Drift | Class::Unevaluated => CheckStatus::Drift,
            Class::Unknown => CheckStatus::Unknown,
        }
    }
}

/// The closed remedy vocabulary. Nothing else ever renders in a command
/// position; identifiers are validated before rendering and a name that
/// fails validation drops the remedy rather than escaping into it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(
    tag = "verb",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum Remedy {
    /// Restore declared files and remove records no declaration needs.
    Apply {
        global: bool,
    },
    /// Move files kendex never wrote out of a declaration's way and
    /// install the declared render there. Offered only where the plan
    /// measured those files against the render and found them different:
    /// a report that prescribed the take-over from a stat alone would be
    /// prescribing the destructive exit for a state it never judged.
    ReplaceUnmanaged {
        global: bool,
    },
    /// Install or replace Pi packages through their carrier installer.
    UpdatePi {
        global: bool,
    },
    Refresh {
        global: bool,
    },
    /// Compare installed packages with the current source state.
    Updates {
        global: bool,
    },
    /// Replace this scope's old session drift hook with the current copy.
    DriftHook {
        global: bool,
    },
    /// Move an unmanaged Pi copy out of the directory Pi scans. Paths are
    /// shell-quoted when rendered. `windows` selects PowerShell syntax.
    MoveAside {
        from: std::path::PathBuf,
        to: std::path::PathBuf,
        windows: bool,
    },
    Remove {
        name: String,
        global: bool,
    },
    Add {
        kind: ItemKind,
        name: String,
        global: bool,
    },
    Fork {
        kind: ItemKind,
        name: String,
        global: bool,
    },
    /// Show what an apply would do here and why. Where a line names a
    /// state whose right resolution depends on which of two directions the
    /// reader wants, the preview that names both is the remedy: a report
    /// built from stats alone must not prescribe the destructive one.
    Plan {
        global: bool,
    },
}

/// A remedy as a reader gets it: the command, and whether it runs where
/// the report was read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fix {
    /// Runnable where the report was read.
    Here(String),
    /// Runnable, but not where it was read: the line is about a project
    /// the command has to name and this verb has no `--project-path`
    /// form, so a session running the catalog's `block-worktree-refresh`
    /// hook is refused it inside that linked git worktree — every such
    /// verb where the project is the main checkout's, and `update-pi`
    /// alone where it is the worktree's own. The command is still the
    /// fix, and the renderer marks it with why it will not run here — a
    /// reader handed no remedy at all is left with the drift and no way
    /// out of it.
    Elsewhere(String),
}

/// The project a project-scope remedy has to name, and whose it is: the
/// two differ in which verbs reach it by being typed in the checked
/// directory. Serialized as the path alone.
///
/// Which one it is follows the one predicate the catalog's
/// `block-worktree-refresh` hook asks of the same place, stated in
/// `crates/core/AGENTS.md`: whether the checked project root, the one
/// `discover::project_root_from` resolves, holds its own manifest file
/// (`manifest::project_manifest_path`) in the linked worktree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(untagged)]
pub enum ProjectTarget {
    /// The checked project in a linked worktree, which holds a manifest of
    /// its own, readable or not, whether it is the worktree's root or a
    /// folder below it. A bare verb typed there writes it and nothing
    /// else, so every remedy but `update-pi` runs there as it is, with no
    /// path in the command: the path reaches no command and is carried
    /// for `kendex check --json`, which prints the target as its path
    /// alone, and for the serialization guard that path shares with the
    /// main checkout's.
    Worktree(std::path::PathBuf),
    /// The project at the same place inside the main checkout, where the
    /// checked worktree carries no manifest and the declarations are the
    /// main checkout's. Only a command naming it reaches it from the
    /// worktree.
    MainCheckout(std::path::PathBuf),
}

impl ProjectTarget {
    pub fn path(&self) -> &std::path::Path {
        match self {
            ProjectTarget::Worktree(path) | ProjectTarget::MainCheckout(path) => path,
        }
    }
}

impl Remedy {
    /// Whether running this changes anything. Every other remedy settles
    /// the line it sits on; the plan prints and returns, so calling it a
    /// fix would promise a person, and an agent acting on this report, a
    /// resolution they will not get.
    pub fn mutates(&self) -> bool {
        !matches!(self, Remedy::Plan { .. })
    }

    /// Whether this remedy is about the personal scope or targets an
    /// absolute path directly. Neither kind needs a project destination.
    pub fn global(&self) -> bool {
        match self {
            Remedy::Apply { global }
            | Remedy::ReplaceUnmanaged { global }
            | Remedy::UpdatePi { global }
            | Remedy::Refresh { global }
            | Remedy::Updates { global }
            | Remedy::DriftHook { global }
            | Remedy::Plan { global }
            | Remedy::Remove { global, .. }
            | Remedy::Add { global, .. }
            | Remedy::Fork { global, .. } => *global,
            Remedy::MoveAside { .. } => true,
        }
    }

    /// Whether this verb takes `--project-path`, the flag that puts the
    /// project a write lands in into the command's own words. The four
    /// whole-scope verbs have it; the rest reach a project only by being
    /// typed inside it.
    pub fn takes_project_path(&self) -> bool {
        matches!(
            self,
            Remedy::Apply { .. }
                | Remedy::ReplaceUnmanaged { .. }
                | Remedy::Refresh { .. }
                | Remedy::Updates { .. }
                | Remedy::Plan { .. }
        )
    }

    /// The pasteable spelling, or `None` when the identifier the command
    /// would carry is not one that may reach a command position — the
    /// line then stands without a remedy.
    ///
    /// `target` is the project a project-scope command has to name to
    /// reach the place the line is about, set by [`CheckReport`] where the
    /// checked directory is a linked worktree. Only the main checkout's
    /// project is named: a verb that takes `--project-path` carries it,
    /// and one with no such form renders its bare command as
    /// [`Fix::Elsewhere`]. The worktree's own project is reached by every
    /// bare verb typed there, so the command carries no path and only
    /// `update-pi`, which the catalog's `block-worktree-refresh` hook runs
    /// in a linked worktree at global scope alone, is [`Fix::Elsewhere`] —
    /// the command is still the fix, and the marker the renderer adds
    /// says why it will not run where the report was read.
    pub fn render(&self, target: Option<&ProjectTarget>) -> Option<Fix> {
        self.render_with_scope(target, false)
    }

    fn render_refresh_action(global: bool, target: Option<&ProjectTarget>) -> Option<Fix> {
        Remedy::Refresh { global }.render_with_scope(target, !global)
    }

    fn render_with_scope(
        &self,
        target: Option<&ProjectTarget>,
        explicit_project: bool,
    ) -> Option<Fix> {
        if let Remedy::Remove { name, .. } | Remedy::Add { name, .. } | Remedy::Fork { name, .. } =
            self
            && !crate::names::plain_argument(name)
        {
            return None;
        }
        // Asked once, for every arm below. The global scope is one flag
        // wherever it appears; a project scope is the place the command is
        // typed in, or the main checkout's project it names where this
        // verb can name it. `quoted` because a project path is whatever
        // the filesystem allowed and this is a command position.
        let named = target.filter(|_| !self.global());
        let scope = if !self.global() && explicit_project {
            " --scope project"
        } else {
            ""
        };
        let place = match (self.global(), named) {
            (true, _) => " --global".to_owned(),
            (false, Some(ProjectTarget::MainCheckout(path))) if self.takes_project_path() => {
                format!("{scope} --project-path {}", command_word(path, false)?)
            }
            (false, Some(ProjectTarget::MainCheckout(_) | ProjectTarget::Worktree(_)) | None) => {
                scope.to_owned()
            }
        };
        let command = match self {
            Remedy::Apply { .. } => format!("kendex apply{place}"),
            Remedy::ReplaceUnmanaged { .. } => format!("kendex apply --replace-unmanaged{place}"),
            // Its own scope spelling, so `place` says nothing here.
            Remedy::UpdatePi { global } => format!(
                "kendex update-pi --scope {}",
                match global {
                    true => "global",
                    false => "project",
                }
            ),
            Remedy::Refresh { .. } => format!("kendex refresh{place}"),
            Remedy::Updates { .. } => format!("kendex updates{place}"),
            Remedy::DriftHook { global } => format!(
                "kendex drift-hook --yes --scope {}",
                if *global { "global" } else { "project" }
            ),
            Remedy::MoveAside { from, to, windows } => match *windows {
                true => format!(
                    "Move-Item -LiteralPath {} -Destination {} -Confirm",
                    command_word(from, true)?,
                    command_word(to, true)?
                ),
                false => format!(
                    "mv -i {} {}",
                    command_word(from, false)?,
                    command_word(to, false)?
                ),
            },
            Remedy::Remove { name, .. } => format!("kendex remove {name}{place}"),
            Remedy::Add { kind, name, .. } => {
                format!("kendex add --{} {name}{place}", kind.name())
            }
            Remedy::Fork { kind, name, .. } => {
                format!("kendex fork {} {name}{place}", kind.name())
            }
            Remedy::Plan { .. } => format!("kendex apply --plan{place}"),
        };
        let elsewhere = match named {
            None => false,
            Some(ProjectTarget::Worktree(_)) => matches!(self, Remedy::UpdatePi { .. }),
            Some(ProjectTarget::MainCheckout(_)) => !self.takes_project_path(),
        };
        Some(match elsewhere {
            true => Fix::Elsewhere(command),
            false => Fix::Here(command),
        })
    }
}

/// Quote one path for the shell this environment uses. A non-UTF-8 path,
/// a control byte or a path past the report's fragment bound cannot be
/// printed as the same word, so no command is offered for that path.
fn command_word(path: &std::path::Path, windows: bool) -> Option<String> {
    let word = path.to_str()?;
    let quoted = match windows {
        true => format!("'{}'", word.replace('\'', "''")),
        false => crate::names::quoted(word),
    };
    (text::shown(&quoted) == quoted).then_some(quoted)
}

/// The platform editor command for a manifest. Opening the file is an edit
/// step, not a remedy that claims the named table was removed.
pub(super) fn edit_command(env: &Env, path: &std::path::Path) -> Option<String> {
    let path = command_word(path, env.is_windows())?;
    Some(match env.is_windows() {
        true => format!("notepad.exe {path}"),
        false => format!("${{EDITOR:-vi}} {path}"),
    })
}

/// A non-clobbering backup command for an installed file that another
/// remedy replaces. The backup sits beside the file with `.backup` added.
pub(super) fn backup_command(env: &Env, path: &std::path::Path) -> Option<String> {
    let from = command_word(path, env.is_windows())?;
    let mut backup = path.as_os_str().to_owned();
    backup.push(".backup");
    let to = command_word(std::path::Path::new(&backup), env.is_windows())?;
    Some(match env.is_windows() {
        true => format!("Copy-Item -LiteralPath {from} -Destination {to} -Confirm"),
        false => format!("cp -i {from} {to}"),
    })
}

#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub class: Class,
    /// The plain spelling in JSON, with its commands marked for a
    /// rendering that wraps.
    #[specta(type = String)]
    pub text: Sentence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remedy: Option<Remedy>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    pub title: String,
    pub lines: Vec<Line>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CheckReport {
    pub status: CheckStatus,
    pub sections: Vec<Section>,
    /// Seconds since the oldest scope snapshot consulted was derived —
    /// how stale the verdicts might be. Absent when nothing was evaluated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot_age_secs: Option<u64>,
    /// The project a project-scope remedy here has to name to reach the
    /// place its line is about, absent where a command typed in the
    /// checked directory already reaches it.
    ///
    /// Set for a checked project that is a linked git worktree. kendex
    /// refuses no write there; the catalog's `block-worktree-refresh`
    /// hook does, in a session that installed it, where a bare verb would
    /// write the main checkout's project. That project is named in the
    /// command for every worktree reader all the same: it is the one
    /// spelling that is right whether or not the hook is installed, and a
    /// report cannot see which sessions run it. The worktree's own project
    /// is what a bare verb typed there writes, so it is never named.
    ///
    /// It is the worktree itself where the worktree carries a manifest of
    /// its own, readable or not. Where it carries none it is the project
    /// at the same place inside the main checkout — there the worktree
    /// declares nothing and the declarations this report is about are the
    /// main checkout's — and absent again where the main checkout holds
    /// no project root at that place, which leaves every remedy in the
    /// bare spelling a command typed in the checked directory would take.
    #[serde(skip_serializing_if = "project_target_not_serializable")]
    pub project_target: Option<ProjectTarget>,
    /// Whether a scope's plan over unrecorded copies outran the deadline
    /// and is still owed — what sends the caller's background refresh
    /// through it. For the caller that ran the check, never for the
    /// report's readers.
    #[serde(skip)]
    #[specta(skip)]
    pub deep_pass_owed: bool,
}

/// A project target is command data. JSON omits a path the platform cannot
/// represent as the exact UTF-8 argument the command renderer requires.
fn project_target_not_serializable(target: &Option<ProjectTarget>) -> bool {
    target
        .as_ref()
        .is_none_or(|target| target.path().to_str().is_none())
}

impl CheckReport {
    pub fn is_clean(&self) -> bool {
        self.sections.iter().all(|section| section.lines.is_empty())
    }
}

/// Budgets, carried from v1: 10 items per section, 60 lines / 8 KB for the
/// whole report — with every overflow line counted inside its budget.
const SECTION_ITEMS: usize = 10;
const REPORT_LINES: usize = 60;
const REPORT_BYTES: usize = 8 * 1024;

/// What a scope's own manifest file turned out to be, from the one read
/// the check makes of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManifestState {
    /// A manifest is there and parsed: this place declares packages of
    /// its own.
    Declared,
    /// No manifest file at all.
    Absent,
    /// A manifest file that would not load — conflict markers, a schema
    /// this release does not read, a validation finding, a failed read.
    /// The file is still this place's own.
    Unreadable,
}

struct Sections {
    stale: Vec<Line>,
    edited: Vec<Line>,
    removed: Vec<Line>,
    mixed: Vec<Line>,
    missing: Vec<Line>,
    record_cleanup: Vec<Line>,
    blocked: Vec<Line>,
    /// A Pi package this project declares that the global manifest
    /// declares too.
    declared_twice: Vec<Line>,
    /// A declared Pi package Pi also loads from a directory under
    /// `extensions/` that kendex does not own.
    shadowed: Vec<Line>,
    references: Vec<Line>,
    unevaluated: Vec<Line>,
    unknown: Vec<Line>,
    deep_pass_owed: bool,
}

impl Sections {
    /// Every line pushed so far, across the sections holding them.
    fn lines(&self) -> impl Iterator<Item = &Line> {
        [
            &self.stale,
            &self.edited,
            &self.removed,
            &self.mixed,
            &self.missing,
            &self.record_cleanup,
            &self.blocked,
            &self.shadowed,
            &self.references,
            &self.unevaluated,
            &self.unknown,
        ]
        .into_iter()
        .flatten()
    }

    /// Whether any line here carries a remedy a project-scope command
    /// would run. Nothing else in the report needs the project such a
    /// command has to name, so nothing else pays for resolving it.
    fn has_project_remedy(&self) -> bool {
        self.lines()
            .filter_map(|line| line.remedy.as_ref())
            .any(|remedy| !remedy.global())
    }

    fn new() -> Sections {
        Sections {
            stale: Vec::new(),
            edited: Vec::new(),
            removed: Vec::new(),
            mixed: Vec::new(),
            missing: Vec::new(),
            record_cleanup: Vec::new(),
            blocked: Vec::new(),
            declared_twice: Vec::new(),
            shadowed: Vec::new(),
            references: Vec::new(),
            unevaluated: Vec::new(),
            unknown: Vec::new(),
            deep_pass_owed: false,
        }
    }

    /// Drift before suggestions: the sections that name broken state come
    /// first, the unknowns after.
    fn into_report(
        self,
        snapshot_age_secs: Option<u64>,
        project_target: Option<ProjectTarget>,
    ) -> CheckReport {
        let sections: Vec<Section> = [
            ("stale", self.stale),
            ("edited by hand", self.edited),
            ("gone from their source", self.removed),
            ("mixed installs", self.mixed),
            ("missing on disk", self.missing),
            ("record cleanup needed", self.record_cleanup),
            ("blocked by files already there", self.blocked),
            ("declared at both scopes", self.declared_twice),
            ("loaded twice by pi", self.shadowed),
            ("broken references", self.references),
            ("source comparison needed", self.unevaluated),
            ("could not check", self.unknown),
        ]
        .into_iter()
        .filter(|(_, lines)| !lines.is_empty())
        .map(|(title, lines)| Section {
            title: title.to_owned(),
            lines,
        })
        .collect();
        let status = sections
            .iter()
            .flat_map(|section| &section.lines)
            .map(|line| line.class.status())
            .max()
            .unwrap_or(CheckStatus::Clean);
        CheckReport {
            status,
            sections,
            snapshot_age_secs,
            project_target,
            deep_pass_owed: self.deep_pass_owed,
        }
    }
}

/// The project a project-scope remedy over `scope` has to name, or `None`
/// where a command typed in the checked directory reaches it on its own.
///
/// One question, asked of the two judges that own its halves:
/// [`crate::guard::Repo`] says whether the project is a linked work tree
/// and which checkout the repository's main one is, and `manifest` is
/// what the check's own read of this place's manifest found.
///
/// The three manifest states are three different answers. A work tree
/// that declares packages is a project in its own right and names itself.
/// One whose manifest would not load is still the place those broken
/// declarations sit in, so it names itself too — pointing a reader at the
/// main checkout there would put the drift lines of one place above the
/// fix for another. Only a work tree with no manifest at all is a
/// checkout of somebody else's declarations, and there the project that
/// holds them is the destination.
///
/// A git that cannot answer leaves the remedies as they are, which is what
/// every release before this one printed. Nothing is written on the
/// strength of the guess: what a reader then runs is the bare verb, which
/// the catalog's `block-worktree-refresh` hook refuses out loud where a
/// session installed it.
fn remedy_target(scope: &Scope, manifest: ManifestState) -> Option<ProjectTarget> {
    let Scope::Project { root } = scope else {
        return None;
    };
    let repo = crate::guard::Repo::probe(root).ok().flatten()?;
    if !repo.is_linked() {
        return None;
    }
    match manifest {
        ManifestState::Declared | ManifestState::Unreadable => {
            Some(ProjectTarget::Worktree(root.clone()))
        }
        ManifestState::Absent => {
            main_checkout_project(&repo, root).map(ProjectTarget::MainCheckout)
        }
    }
}

/// The project inside the repository's main work tree that answers for
/// `root`, or `None` where there is none.
///
/// A kendex project can sit below the git top level, so the main work
/// tree's top level is not the destination: the same path under it is,
/// and it is only a destination if it is a project root there. A folder
/// that is not one names nothing a write could use — `--project-path`
/// would refuse it, or it would land in a project nobody asked about.
fn main_checkout_project(
    repo: &crate::guard::Repo,
    root: &std::path::Path,
) -> Option<std::path::PathBuf> {
    let below = root.strip_prefix(&repo.worktree).ok()?;
    let mapped = repo.main_checkout().ok()?.join(below);
    crate::discover::is_project(&mapped).then_some(mapped)
}

fn drift(text: impl Into<Sentence>, remedy: Option<Remedy>) -> Line {
    Line {
        class: Class::Drift,
        text: text.into(),
        remedy,
    }
}

fn unevaluated(text: impl Into<Sentence>, remedy: Remedy) -> Line {
    Line {
        class: Class::Unevaluated,
        text: text.into(),
        remedy: Some(remedy),
    }
}

fn unknown(text: impl Into<Sentence>) -> Line {
    Line {
        class: Class::Unknown,
        text: text.into(),
        remedy: None,
    }
}

/// The check itself: reads the manifest, the lock, the drift snapshot and
/// the fetch stamps, stats what the lock says should be on disk, and for
/// a scope declaring Pi packages lists the `extensions/` of the two roots
/// Pi loads together with the `package.json` of what sits there and of
/// each managed copy under `packages/`, and nothing else — no source
/// trees, no module files, no hashing, no per-package subprocesses —
/// until a declaration sits on files no record accounts for, which is
/// the one state it plans the scope to judge, inside the session hook's
/// budget.
pub fn check(env: &Env, scopes: &[Scope]) -> CheckReport {
    check_within(env, scopes, crate::drift::hook::DEEP_PASS_BUDGET)
}

/// [`check`] with the deep read's budget stated: what a caller that has to
/// see the budget run out asks for. One deadline is set from it before
/// the first scope, so the budget bounds the check as a whole and not
/// each of the scopes it covers.
pub fn check_within(env: &Env, scopes: &[Scope], budget: std::time::Duration) -> CheckReport {
    let now = crate::clock::unix_now();
    let deadline = std::time::Instant::now() + budget;
    let mut sections = Sections::new();
    // The global manifest, read once for the whole report: every project
    // scope judges its own Pi declarations against it, and a read per
    // scope would report one unreadable file once per scope and count it
    // as that many items. A global-only check asks for none, its own
    // manifest read being that same file.
    let global_manifest = scopes
        .iter()
        .any(|scope| scope.canonical() != Scope::Global)
        .then(|| crate::manifest::load(&crate::manifest::manifest_path(env, &Scope::Global)));
    // A global manifest that will not parse leaves unjudged only the
    // scopes that reach the duplicate check, so the line is pushed from
    // that check and not from here. Once for the whole report: every
    // project scope reads the same file, and a line per scope would count
    // one file as that many items. Already reported where the run covers
    // the global scope, because that scope's own manifest read names the
    // same file with the same error.
    let global_manifest_named = std::cell::Cell::new(
        scopes
            .iter()
            .any(|scope| scope.canonical() == Scope::Global),
    );
    let mut oldest_age: Option<u64> = None;
    // The one project scope a check covers, and what its own manifest
    // file turned out to be. Held rather than acted on: which project a
    // remedy names is asked once, after the lines are in, and only if a
    // line will carry the answer.
    let mut project_scope: Option<(Scope, ManifestState)> = None;
    let many = scopes.len() > 1;
    // Every scope reads the same two Pi roots, so the scans are folded
    // across scopes before their lines land: one copy, one failure, once
    // per report (`ShadowScan::fold`, the owner both verbs use).
    let mut scans = Vec::new();

    for scope in scopes {
        let scope = scope.canonical();
        let global = scope == Scope::Global;
        let prefix = match many {
            true => format!("{}: ", scope_word(&scope)),
            false => String::new(),
        };
        let ctx = scope::ScopeCheck {
            env,
            scope: &scope,
            global,
            prefix: &prefix,
            now,
            deadline,
            budget,
            pi_roots: crate::settings::load(env)
                .map(|settings| crate::pi_ext::session_roots(env, &settings, &scope)),
            global_manifest: global_manifest.as_ref(),
            global_manifest_named: &global_manifest_named,
        };
        let outcome = check_scope(&ctx, &mut sections, &mut oldest_age);
        // A check covers at most one project scope, so one target answers
        // for every project remedy in the report.
        if !global {
            project_scope = Some((scope.clone(), outcome.manifest));
        }
        scans.push((prefix, outcome.scan));
    }
    crate::pi_ext::ShadowScan::fold(scans.iter_mut().map(|(_, scan)| scan));
    for (prefix, scan) in scans {
        scope::shadow_lines(env, &prefix, scan, &mut sections);
    }
    // Asked last, and only where an answer would be printed: resolving it
    // spawns git children, and the session-start check runs on every
    // session — a clean report has no project remedy to point anywhere,
    // so it pays for none of them.
    let project_target = project_scope
        .filter(|_| sections.has_project_remedy())
        .and_then(|(scope, manifest)| remedy_target(&scope, manifest));
    sections.into_report(oldest_age, project_target)
}

/// A scope's short spelling in a report line: "global", or the project
/// directory's name — enough to tell the two apart without a path per line.
fn scope_word(scope: &Scope) -> String {
    match scope {
        Scope::Global => "global".to_owned(),
        Scope::Project { root } => root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "project".to_owned()),
    }
}

/// A disabled installation keeps its bytes under a `.disabled` sibling —
/// either spelling on disk means the files are not missing.
fn toggled_sibling(path: &std::path::Path) -> std::path::PathBuf {
    let text = path.display().to_string();
    match text.strip_suffix(".disabled") {
        Some(base) => std::path::PathBuf::from(base),
        None => std::path::PathBuf::from(format!("{text}.disabled")),
    }
}

fn stamp_for(env: &Env, repo: &str) -> Option<super::stamps::FetchStamp> {
    if repo.is_empty() {
        return None;
    }
    let key = crate::remote::cache_key(env, repo);
    Some(super::stamps::load(env, &key))
}

/// Whether the check should spawn the detached background refresh: a
/// stale mirror needs fetching, a scope with remote sources has no
/// snapshot (a mutation just invalidated it, or nothing ever evaluated),
/// or the report it just produced says a plan over unrecorded copies
/// outran the deadline and is still owed — either way the deep pass is
/// what turns "maybe" back into verdicts.
pub fn wants_background_refresh(env: &Env, scopes: &[Scope], checked: &CheckReport) -> bool {
    if checked.deep_pass_owed {
        return true;
    }
    let now = crate::clock::unix_now();
    scopes.iter().any(|scope| {
        let Ok(crate::manifest::ManifestFile::Current(manifest)) =
            crate::manifest::load(&crate::manifest::manifest_path(env, scope))
        else {
            return false;
        };
        let remotes = manifest
            .sources
            .values()
            .any(|decl| decl.enabled && decl.repo.is_some());
        if !remotes {
            return false;
        }
        if !matches!(
            super::snapshot::load(env, scope),
            super::snapshot::SnapshotFile::Current(_)
        ) {
            return true;
        }
        manifest.sources.values().any(|decl| {
            decl.enabled
                && decl
                    .repo
                    .as_deref()
                    .and_then(|repo| stamp_for(env, repo))
                    .is_some_and(|stamp| stamp.is_stale(now))
        })
    })
}

mod render;
mod scope;
mod sentence;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_evidence;
#[cfg(test)]
mod tests_render;
mod text;

pub use render::{Page, PageFix, PageItem, PageSection, page, render_plain};
use scope::check_scope;
pub use sentence::{Sentence, Span};
pub use text::{Text, fold};
