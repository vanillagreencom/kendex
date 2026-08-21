//! The session-start check: classification over the snapshot, stamps, lock
//! and manifest — cheap reads only — rendered inside hard budgets with a
//! closed remedy vocabulary.
//!
//! This report is the one deliberate exception to the no-command-lines
//! rule: it is written for an agent that can act, so each line may carry a
//! remedy built from a fixed template set — refresh, remove, add, fork,
//! findings — with only validated identifiers in argument positions. Free
//! text from sources or errors renders in quoted informational positions,
//! never in a command position.

use serde::Serialize;
use specta::Type;

use crate::env::Env;
use crate::model::{ItemKind, Scope};

/// The check's whole contract: 0 clean, 1 drift, 2 could-not-check. When
/// both apply, could-not-check wins — an incomplete report must not claim
/// the completeness that exit 1 implies.
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

/// A line is either a fact about drift or an admission that something
/// could not be checked. The distinction is the exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum Class {
    Drift,
    Unknown,
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
    Refresh {
        global: bool,
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
    Findings {
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

/// Only characters every declared name already passed validation for. A
/// name is data; this is the belt-and-braces check at the one place data
/// enters a command position.
fn safe_ident(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | '@'))
        && !name.starts_with('-')
}

impl Remedy {
    /// Whether running this changes anything. Every other remedy settles
    /// the line it sits on; the plan prints and returns, so calling it a
    /// fix would promise a person, and an agent acting on this report, a
    /// resolution they will not get.
    pub fn mutates(&self) -> bool {
        !matches!(self, Remedy::Plan { .. })
    }

    /// The pasteable spelling, or `None` when an identifier fails
    /// validation — the line then stands without a remedy.
    pub fn render(&self) -> Option<String> {
        let flag = |global: &bool| if *global { " --global" } else { "" };
        if let Remedy::Remove { name, .. } | Remedy::Add { name, .. } | Remedy::Fork { name, .. } =
            self
            && !safe_ident(name)
        {
            return None;
        }
        Some(match self {
            Remedy::Refresh { global } => format!("kendex refresh{}", flag(global)),
            Remedy::Remove { name, global } => format!("kendex remove {name}{}", flag(global)),
            Remedy::Add { kind, name, global } => {
                format!("kendex add --{} {name}{}", kind.name(), flag(global))
            }
            Remedy::Fork { kind, name, global } => {
                format!("kendex fork {} {name}{}", kind.name(), flag(global))
            }
            Remedy::Findings { global } => format!("kendex findings{}", flag(global)),
            Remedy::Plan { global } => format!("kendex apply --plan{}", flag(global)),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub class: Class,
    pub text: String,
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

struct Sections {
    stale: Vec<Line>,
    edited: Vec<Line>,
    removed: Vec<Line>,
    mixed: Vec<Line>,
    missing: Vec<Line>,
    blocked: Vec<Line>,
    references: Vec<Line>,
    findings: Vec<Line>,
    unevaluated: Vec<Line>,
    unknown: Vec<Line>,
}

impl Sections {
    fn new() -> Sections {
        Sections {
            stale: Vec::new(),
            edited: Vec::new(),
            removed: Vec::new(),
            mixed: Vec::new(),
            missing: Vec::new(),
            blocked: Vec::new(),
            references: Vec::new(),
            findings: Vec::new(),
            unevaluated: Vec::new(),
            unknown: Vec::new(),
        }
    }

    /// Drift before suggestions: the sections that name broken state come
    /// first, findings and the unknowns after.
    fn into_report(self, snapshot_age_secs: Option<u64>) -> CheckReport {
        let sections: Vec<Section> = [
            ("stale", self.stale),
            ("edited by hand", self.edited),
            ("gone from their source", self.removed),
            ("mixed installs", self.mixed),
            ("missing on disk", self.missing),
            ("asked for but not installed", self.blocked),
            ("broken references", self.references),
            ("safety findings", self.findings),
            ("not yet evaluated", self.unevaluated),
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
            .map(|line| match line.class {
                Class::Drift => CheckStatus::Drift,
                Class::Unknown => CheckStatus::Unknown,
            })
            .max()
            .unwrap_or(CheckStatus::Clean);
        CheckReport {
            status,
            sections,
            snapshot_age_secs,
        }
    }
}

/// Foreign text on its way into the report: control characters become
/// spaces, credentials become fingerprints, length is bounded.
fn shown(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .take(300)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    crate::quality::redact(cleaned.trim())
}

fn drift(text: String, remedy: Option<Remedy>) -> Line {
    Line {
        class: Class::Drift,
        text,
        remedy,
    }
}

fn unknown(text: String) -> Line {
    Line {
        class: Class::Unknown,
        text,
        remedy: None,
    }
}

/// The check itself: reads the manifest, the lock, the drift snapshot and
/// the fetch stamps, stats what the lock says should be on disk, and
/// nothing else. No source trees, no hashing, no per-package subprocesses.
pub fn check(env: &Env, scopes: &[Scope]) -> CheckReport {
    let now = crate::clock::unix_now();
    let mut sections = Sections::new();
    let mut oldest_age: Option<u64> = None;
    let many = scopes.len() > 1;

    for scope in scopes {
        let scope = scope.canonical();
        let global = scope == Scope::Global;
        let prefix = match many {
            true => format!("{}: ", scope_word(&scope)),
            false => String::new(),
        };
        check_scope(
            env,
            &scope,
            global,
            &prefix,
            now,
            &mut sections,
            &mut oldest_age,
        );
    }
    sections.into_report(oldest_age)
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
/// stale mirror needs fetching, or a scope with remote sources has no
/// snapshot (a mutation just invalidated it, or nothing ever evaluated) —
/// either way the deep pass is what turns "maybe" back into verdicts.
pub fn wants_background_refresh(env: &Env, scopes: &[Scope]) -> bool {
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
        if super::snapshot::load(env, scope).is_none() {
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
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_render;

pub use render::render_plain;
use scope::check_scope;
