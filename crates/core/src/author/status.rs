//! Local readiness of one authored folder: what kendex found in it, what
//! the check says, and what git says about it — from this machine only.
//!
//! "Ready to submit" is deliberately not pronounced here. That verdict
//! needs an authenticated GitHub lookup (visibility, push authority, the
//! repository id) and belongs to the submit preflight; this row reports
//! what can be known without asking anyone.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::check_catalog::{self, CheckFinding};
use crate::error::{CoreError, Result};
use crate::process::Hardened;
use crate::source_read::SealedSource;

/// One Mine row, computed fresh from the folder on every ask.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MineRow {
    pub path: String,
    /// The catalog's own name, or the folder leaf where it says nothing.
    pub name: String,
    pub description: Option<String>,
    pub license: Option<String>,
    /// Discovered packages per kind name.
    pub counts: BTreeMap<String, u32>,
    pub bundles: u32,
    /// Whether a control file (`kendex.toml`) declares the layout — the
    /// offers surface reads this to know what to offer.
    pub declared: bool,
    pub breakage: u32,
    pub advisory: u32,
    /// Safety findings across every package — advisory, never a refusal.
    pub safety_findings: u32,
    /// Every check finding, file-first, so the app can open each one.
    pub findings: Vec<StatusFinding>,
    pub git: GitReadiness,
}

/// The versioned envelope `marketplace mine --json` wraps its rows in.
/// Schema 3 counts safety findings as `safetyFindings` per marketplace,
/// with no verdict beside them, and carries a finding's line in `line`
/// rather than spelled into `file` — the same split schema 3 of the check
/// envelope makes, and for the same reason: `file` is a path to open.
pub const MINE_SCHEMA: u32 = 3;

/// One check finding shaped for a screen with an Open button.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct StatusFinding {
    pub file: String,
    /// The 1-based line within `file`, where the finding has one. Kept
    /// apart from the path so the row can offer to open the file.
    pub line: Option<u32>,
    pub kind: String,
    pub name: String,
    pub pass: String,
    pub severity: String,
    pub message: String,
    pub fix: String,
}

/// What git says about the folder, locally. Nothing here asks the network.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct GitReadiness {
    pub repository: bool,
    /// `Some(false)` when uncommitted changes exist; `None` outside a repo.
    pub clean: Option<bool>,
    /// The `origin` remote URL, verbatim.
    pub remote: Option<String>,
    /// `owner/repo` parsed out of a GitHub remote — the candidate the
    /// submit preflight will verify, never a verdict by itself.
    pub candidate: Option<String>,
    /// Commits ahead of the tracked upstream, when one is configured. What
    /// this machine knows — the remote may have moved since the last fetch.
    pub ahead: Option<u32>,
}

/// Compute the row. Zero writes: everything is read through the sealed
/// source or asked of git read-only.
pub fn status(path: &Path) -> Result<MineRow> {
    let sealed = SealedSource::open(path)?;
    let leaf = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "marketplace".to_owned());
    let config = crate::source::source_config(&sealed, &leaf)?;
    let report = check_catalog::check_with(&sealed, &config, &leaf)?;

    let mut counts: BTreeMap<String, u32> = BTreeMap::new();
    for item in &report.items {
        *counts.entry(item.kind.name().to_owned()).or_default() += 1;
    }
    // A folder whose sets cannot be read is unreadable, not a folder with no
    // sets: both callers of this row report why one is missing, and `0
    // bundle(s)` would say the author declared none.
    let bundles = crate::source::bundles::offered(&sealed, &config)?.len() as u32;
    let tally = report.tally();
    let meta = config.marketplace.clone().unwrap_or_default();
    Ok(MineRow {
        path: crate::paths::slashed(path),
        name: meta.name.unwrap_or(leaf),
        description: meta.description,
        license: meta.license,
        counts,
        bundles,
        declared: config.mode == crate::source::CatalogMode::Explicit
            || config.mode == crate::source::CatalogMode::PluginRegistry,
        breakage: tally.breakage as u32,
        advisory: tally.advisory as u32,
        safety_findings: tally.findings as u32,
        findings: report.findings().map(shape).collect(),
        git: git_readiness(path),
    })
}

fn shape(finding: CheckFinding) -> StatusFinding {
    StatusFinding {
        file: finding.file,
        line: finding.line,
        kind: finding.kind.to_owned(),
        name: finding.name,
        pass: finding.pass,
        severity: finding.severity.to_owned(),
        message: finding.message,
        fix: finding.fix,
    }
}

/// Ask git, read-only, tolerating its absence: a folder without git — or a
/// machine without git — is an honest `repository: false`, never an error.
fn git_readiness(path: &Path) -> GitReadiness {
    let Some(inside) = git_line(path, &["rev-parse", "--is-inside-work-tree"]) else {
        return GitReadiness::default();
    };
    if inside != "true" {
        return GitReadiness::default();
    }
    let porcelain = git_line(path, &["status", "--porcelain"]);
    let remote = git_line(path, &["remote", "get-url", "origin"]).filter(|url| !url.is_empty());
    // Submission sends `origin`, so "ahead" must measure against origin's
    // copy of this branch — not `@{upstream}`, which on a fork tracks the
    // upstream and would call a branch pushed to origin's fork clean while
    // origin has none of its commits.
    let ahead = git_line(path, &["symbolic-ref", "--short", "HEAD"])
        .and_then(|branch| {
            git_line(
                path,
                &["rev-list", "--count", &format!("origin/{branch}..HEAD")],
            )
        })
        .and_then(|count| count.parse::<u32>().ok());
    GitReadiness {
        repository: true,
        clean: porcelain.map(|changes| changes.is_empty()),
        // A remote is a URL, so the bare `owner/repo` shorthand
        // `owner_repo` also folds is not one: a relative path remote like
        // `../bare.git` is that shape too, and would read as a GitHub
        // repository the folder could be submitted as.
        candidate: remote
            .as_deref()
            .filter(|url| url.contains("://") || url.contains('@'))
            .and_then(crate::source_ref::owner_repo),
        remote,
        ahead,
    }
}

/// One git question, one trimmed answer; `None` on any failure. Multi-line
/// output collapses to the whole trimmed text, which is empty exactly when
/// `git status --porcelain` has nothing to say. `--no-optional-locks`
/// keeps even `status` from refreshing `.git/index` — reading a folder
/// must not change a byte inside it.
fn git_line(path: &Path, args: &[&str]) -> Option<String> {
    let mut no_locks: Vec<&str> = vec!["--no-optional-locks"];
    no_locks.extend_from_slice(args);
    let output = Hardened::git_in(path, &no_locks)
        .timeout(std::time::Duration::from_secs(10))
        .run()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Register an existing folder under Mine, reading it as-is: zero bytes
/// change inside the folder, no git operation mutates it, and the row is
/// whatever the folder already offers.
pub fn use_existing(env: &crate::env::Env, path: &Path) -> Result<MineRow> {
    let row = status(path)?;
    if row.counts.is_empty() && !row.declared {
        return Err(CoreError::Authoring {
            message: format!(
                "{} holds nothing kendex can offer — add a skill (skills/<name>/SKILL.md) or an agent (agents/<name>.md) first, or create a new marketplace instead",
                path.display()
            ),
        });
    }
    super::registry::register(env, path)?;
    Ok(row)
}
