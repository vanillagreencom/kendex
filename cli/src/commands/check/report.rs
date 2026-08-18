//! What a drift report IS: the options that shape it, the per-scope findings,
//! and the one verdict every consumer — the human report, the JSON, the
//! session-start hook — reads the same way.
//!
//! Computing it is [`super`]'s and rendering it is [`super::render`]'s.

use crate::config::ItemKind;
use serde::Serialize;

/// Output and network controls for `vstack check`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CheckOptions {
    /// Print the report as JSON on stdout instead of the human report on stderr.
    pub json: bool,
    /// Print nothing when no drift was found; the human report drops the
    /// per-item listing and keeps only the drift sections.
    pub quiet: bool,
    /// Skip every network call: no CLI version lookup and no remote source
    /// cache fetch. Sources are read exactly as cached.
    pub offline: bool,
    /// Suppress the "available in source but not installed" case.
    pub no_available: bool,
}

/// What the process exit code reports. `Clean` → 0, `Drift` → 1; a check that
/// could not run returns `Err` and exits 2 — see `main.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckOutcome {
    Clean,
    Drift,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Item {
    pub name: String,
    pub kind: ItemKind,
    /// What exactly is wrong with this one, when the section header cannot
    /// say it — a phantom missing in only some harnesses, for instance,
    /// where "run `vstack add`" is the remedy for those harnesses alone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// For a hook, what each harness it is locked at actually does with it —
    /// [`crate::installer::enforcement::summary`]. Human listing only: it
    /// describes an install that is fine, so it is neither drift nor part of
    /// the bounded quiet report, and every drift section already carries the
    /// per-harness gap in `detail`.
    #[serde(skip)]
    pub enforcement: Option<String>,
}

impl Item {
    pub fn new(name: impl Into<String>, kind: ItemKind) -> Self {
        Self {
            name: name.into(),
            kind,
            detail: None,
            enforcement: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AvailableItem {
    pub name: String,
    pub kind: ItemKind,
    /// The lock `source` string the item was found in.
    pub source: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MissingSkillRef {
    pub agent: String,
    pub skill: String,
}

/// Why a source this scope depends on could not be fully read. Serialized
/// with a `problem` tag carrying only that variant's fields, so a new class
/// of problem cannot fall through a string match into the wrong report.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "problem", rename_all = "lowercase")]
pub enum SourceProblem {
    /// The source path does not resolve at all — the cache was never cloned
    /// or the directory is gone. Its `entries` cannot be verified.
    ///
    /// `reason` comes from resolution itself, so `check`, `verify` and
    /// `refresh` name the same cause and the same remedy for the same state.
    Unresolvable {
        entries: Vec<String>,
        reason: String,
    },
    /// The source resolves but cannot be inventoried: its catalog
    /// configuration is unusable, or a whole kind root is missing. `refresh`
    /// fixes neither, so `entries` are reported here instead of as outdated.
    Unreadable {
        entries: Vec<String>,
        reasons: Vec<String>,
    },
    /// Discovery ran, but individual assets failed to parse.
    Discovery { failures: Vec<String> },
    /// A cache for this source exists but cannot be proven to belong to it,
    /// so nothing may be installed or verified from it. Distinct from
    /// `unresolvable`: `reason` is the refusal itself, which already names the
    /// entry and the next step — re-adding a refused source refuses again.
    Unverifiable {
        entries: Vec<String>,
        reason: String,
    },
}

/// One source's problem, tagged with the lock `source` string it came from.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SourceIssue {
    pub source: String,
    #[serde(flatten)]
    pub problem: SourceProblem,
}

/// A source whose cache another vstack process was fetching and resetting
/// while this check ran, so nothing in it was measured.
///
/// Separate from [`SourceIssue`] because it is not a problem and not drift:
/// its `entries` are simply unanswered this run, and the next check answers
/// them. Reporting it as an issue would exit 1 for a background refresh that
/// is working exactly as designed, and reporting its entries as removed or
/// outdated would print a destructive remedy for a tree that is merely
/// mid-rewrite.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BusySource {
    pub source: String,
    /// The entries this scope installed from it, none of which were
    /// classified.
    pub entries: Vec<String>,
    /// Why they were not, in the wording every command uses for this state.
    pub reason: String,
}

/// The growth-guards git-shim verdict for the project repository —
/// `install-git-hooks --check`, relayed. The shims are the one per-repository
/// artifact `refresh` maintains that no lock entry records, so without this
/// row a hook another writer disarmed reads as clean at every session start.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct GitHooksStatus {
    pub state: GitHooksState,
    /// The checker's own summary line: the state and its remedy.
    pub detail: String,
}

/// `Unarmed` covers drifted, absent, and dormant-behind-`core.hooksPath`
/// alike — in each the next commit runs no guard — with `detail` saying
/// which. `Undetermined` is a failed measurement and still drift: failure to
/// measure is not a clean measurement.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GitHooksState {
    Armed,
    Unarmed,
    Undetermined,
}

/// A remote source cache that is not up to date; the report was computed
/// against whatever the cache already held.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CacheRefreshFailure {
    pub source: String,
    /// Seconds since the FIRST failure of the current run of failures — not
    /// since the last attempt, which every TTL retry would reset. 0 for a
    /// cache that cannot be written at all.
    pub age_secs: u64,
    /// What went wrong, for the human line.
    pub reason: String,
    /// The failure has outlived two TTL windows of retries, or cannot resolve
    /// itself at all. Counts as drift: a permanently broken remote must not
    /// read as clean at every session start.
    pub persistent: bool,
}

/// One scope's findings. Every list is sorted by name so the human, JSON, and
/// hook renderings are stable across runs.
#[derive(Debug, Clone, Serialize, Default)]
pub struct ScopeReport {
    pub scope: &'static str,
    /// Lock entries in this scope.
    pub installed: usize,
    /// Lock entries whose source content changed since install — `vstack refresh`.
    pub outdated: Vec<Item>,
    /// Lock entries whose source resolves but no longer ships the item —
    /// `vstack remove <name>`.
    pub removed: Vec<Item>,
    /// Skills present on disk but absent from the lock — `vstack add`
    /// recovers. Skills only: they are the one kind with a canonical on-disk
    /// root to scan.
    pub orphaned: Vec<Item>,
    /// Lock entries whose installed files are gone, for every kind that
    /// records an install path (extras do not).
    pub phantom: Vec<Item>,
    /// Lock entries whose install could not be DETERMINED — the evidence a
    /// presence check reads is itself unreadable. Deliberately not phantom:
    /// telling a user to reinstall a Pi package whose registration merely
    /// could not be read points them at the wrong fault, so each detail names
    /// the file to fix instead.
    pub unverifiable: Vec<Item>,
    /// Lock entries whose install is complete and whose harness is configured
    /// not to run it — Claude's `disableAllHooks`, Codex's `[features] hooks`.
    /// Its own list because its own remedy: nothing is missing to reinstall
    /// and nothing is broken to repair, so each detail names the switch and
    /// the file holding it.
    pub disabled: Vec<Item>,
    /// Installed agents referencing skills that are not installed.
    pub missing_skill_refs: Vec<MissingSkillRef>,
    /// Sources that could not be resolved or fully discovered.
    pub source_issues: Vec<SourceIssue>,
    /// Sources whose caches were being rewritten while this check ran. Their
    /// entries appear in no other list — not outdated, not removed, not
    /// current. A transient, not drift: see [`Self::has_drift`].
    pub busy_sources: Vec<BusySource>,
    /// Lock entries whose names fail [`is_safe_item_name`]; they are excluded
    /// from every other list and rendered as `<invalid name>`.
    pub invalid_names: Vec<Item>,
    /// Whether the growth-guards git shims are armed in this repository.
    /// `None` when the skill is not installed here, the project is not a git
    /// work tree, or the scope is global — states with no verdict to give,
    /// as opposed to a verdict that could not be measured.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_hooks: Option<GitHooksStatus>,
    /// Items a declared source ships that this scope never installed —
    /// `vstack add --<kind> <name>`, pending user approval. A suggestion, not
    /// drift: it never affects [`has_drift`](Self::has_drift).
    pub available: Vec<AvailableItem>,
    /// Entries neither outdated nor removed, in lock order (human listing only).
    #[serde(skip)]
    pub current: Vec<Item>,
}

impl ScopeReport {
    /// True when something in this scope needs attention.
    ///
    /// Two lists are deliberately excluded. `available` is a suggestion: a
    /// scope that installs a deliberate subset of a source is not drifting.
    /// `busy_sources` is a transient: a cache being refreshed by another
    /// process is the design working, nothing about it can be repaired, and
    /// exiting 1 for it would make every session start that happens to
    /// overlap a background refresh report drift that no command can clear —
    /// the same false alarm this report avoids everywhere else. The entries
    /// behind it are not called clean either; they are simply not classified,
    /// and the next check classifies them.
    pub fn has_drift(&self) -> bool {
        !(self.outdated.is_empty()
            && self.removed.is_empty()
            && self.orphaned.is_empty()
            && self.phantom.is_empty()
            && self.unverifiable.is_empty()
            && self.disabled.is_empty()
            && self.missing_skill_refs.is_empty()
            && self.source_issues.is_empty()
            && self.invalid_names.is_empty()
            && self
                .git_hooks
                .as_ref()
                .is_none_or(|hooks| hooks.state == GitHooksState::Armed))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CheckReport {
    /// JSON shape version; bump on any incompatible field change.
    pub version: u32,
    pub cli_version: &'static str,
    pub cli_hash: &'static str,
    /// Any scope has drift, or a cache failure has become persistent.
    /// Independent of `available`.
    pub drift: bool,
    /// Remote caches that are not up to date.
    pub cache_refresh_failures: Vec<CacheRefreshFailure>,
    /// Why the background cache refresh could not even be started, if it
    /// could not. A refresh that never runs would otherwise be invisible:
    /// nothing writes a stamp, so nothing else on the read path notices.
    /// Reported, never drift — an environment where spawning cannot succeed
    /// must not exit 1 at every session start forever.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background_refresh_error: Option<String>,
    pub scopes: Vec<ScopeReport>,
}

impl CheckReport {
    pub fn outcome(&self) -> CheckOutcome {
        if self.drift {
            CheckOutcome::Drift
        } else {
            CheckOutcome::Clean
        }
    }
}
