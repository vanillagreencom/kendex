//! What a mirror's history says about its directories: the commits that
//! changed one (with the tags that name them), the newest such commit
//! at-or-before a given one, and when each of many last changed.
//! Everything here reads the bare mirror through
//! [`Hardened`], with full commit ids only, a `--` separator, and literal
//! pathspecs — a catalog chooses its own directory names, and a name
//! shaped like git syntax must stay a name.
//!
//! A history that cannot be read is an error, never an empty timeline: a
//! corrupt mirror answering "no commits" would read as "nothing changed",
//! which is exactly the fail-open a drift report cannot be built on.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::process::Hardened;

/// One commit that changed the subtree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitRow {
    /// Full commit id.
    pub commit: String,
    /// ISO-8601 committer date.
    pub date: String,
    /// Commit subject, bounded and control-stripped for display.
    pub summary: String,
    /// Tag names pointing at exactly this commit.
    pub tags: Vec<String>,
}

/// The timeline is bounded twice: rows, and the bytes read before parsing.
/// A hostile repository can put megabytes in one subject line; the cap
/// keeps that its problem.
const MAX_ROWS: usize = 200;
const MAX_OUTPUT: usize = 1_000_000;
/// Display bound for one commit subject.
const MAX_SUMMARY: usize = 200;

fn stdout_capped(git: Hardened) -> Result<String> {
    let command = git.label().to_owned();
    let output = git.run()?;
    if !output.status.success() {
        return Err(CoreError::GitFailed {
            command,
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    let mut bytes = output.stdout;
    bytes.truncate(MAX_OUTPUT);
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// A subtree path as a pathspec git will not interpret.
fn literal(rel: &Path) -> String {
    // Slashed: git matches a pathspec against index paths, and those are
    // `/`-spelled on every platform. A `\` here matches no path at all,
    // and an empty log reads as "nothing changed".
    format!(":(literal){}", crate::paths::slashed(rel))
}

/// A commit subject as something safe to show: control characters become
/// spaces (the same posture every displayed foreign string takes) and the
/// length is bounded.
fn shown_summary(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .take(MAX_SUMMARY)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    cleaned.trim().to_owned()
}

/// A value that is not a full commit id never reaches git as a positional:
/// it could be read as an option. Commit values arrive from lock files,
/// which travel inside project repositories and are not trusted — so the
/// refusal is an error naming the value's shape, not a silent empty answer.
fn require_commit(value: &str) -> Result<()> {
    match crate::remote::store::is_pin(value) {
        true => Ok(()),
        false => Err(CoreError::GitFailed {
            command: "reading history".to_owned(),
            stderr: "not a full commit id".to_owned(),
        }),
    }
}

/// The commits that changed `rel`, newest first, walking first-parent
/// history from `tip`. Tag names arrive through `%D` decorations so one
/// invocation answers both "what changed" and "what is it called".
pub fn subtree_log(mirror: &Path, tip: &str, rel: &Path) -> Result<Vec<CommitRow>> {
    require_commit(tip)?;
    let max = MAX_ROWS.to_string();
    let text = stdout_capped(Hardened::git_bare(
        mirror,
        &[
            "log",
            "--first-parent",
            "--max-count",
            &max,
            "--decorate=full",
            "--format=%H%x00%cI%x00%s%x00%D%x1e",
            tip,
            "--",
            &literal(rel),
        ],
    ))?;
    Ok(text
        .split('\u{1e}')
        .filter_map(|record| {
            let mut fields = record.trim_start_matches(['\n', ' ']).split('\0');
            let commit = fields.next()?.trim().to_owned();
            if commit.len() != 40 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
                return None;
            }
            let date = fields.next()?.to_owned();
            let summary = shown_summary(fields.next()?);
            let tags = fields
                .next()
                .map(|decorations| {
                    decorations
                        .split(", ")
                        .filter_map(|d| d.trim().strip_prefix("tag: refs/tags/"))
                        .map(shown_summary)
                        .collect()
                })
                .unwrap_or_default();
            Some(CommitRow {
                commit,
                date,
                summary,
                tags,
            })
        })
        .collect())
}

/// The newest commit at-or-before `from` that changed `rel` — the content
/// revision an installation at `from` actually holds. An installed commit
/// that merely sat near the package (it changed other files) is not itself
/// on the package's timeline; this maps it onto the row that is. `None`
/// means the history genuinely holds no such commit; a history that could
/// not be read is an error.
pub fn last_content_commit(mirror: &Path, from: &str, rel: &Path) -> Result<Option<String>> {
    require_commit(from)?;
    let text = stdout_capped(Hardened::git_bare(
        mirror,
        &[
            "log",
            "--first-parent",
            "--max-count",
            "1",
            "--format=%H",
            from,
            "--",
            &literal(rel),
        ],
    ))?;
    let commit = text.trim().to_owned();
    Ok((commit.len() == 40).then_some(commit))
}

/// The committer date of one commit, ISO-8601. A mirror that has no such
/// commit answers `None`; a mirror that cannot be read is an error, on the
/// same footing as every other read here.
pub fn commit_date(mirror: &Path, commit: &str) -> Result<Option<String>> {
    require_commit(commit)?;
    let text = stdout_capped(Hardened::git_bare(
        mirror,
        &["log", "--max-count", "1", "--format=%cI", commit],
    ))?;
    let date = text.trim().to_owned();
    Ok((!date.is_empty()).then_some(date))
}

/// When each of `paths` last changed at-or-before `tip`, walking
/// first-parent history once rather than once per path. Every path is a
/// literal pathspec, so a directory answers for anything under it and a
/// name shaped like git syntax stays a name.
///
/// A path missing from the answer is a path this walk did not reach: the
/// row bound and the byte bound both cut the history short, and an older
/// package falls off the end. Absent is the honest reading, never a date
/// borrowed from a commit that did not touch it.
pub fn last_changed(
    mirror: &Path,
    tip: &str,
    paths: &[PathBuf],
) -> Result<BTreeMap<PathBuf, String>> {
    require_commit(tip)?;
    if paths.is_empty() {
        return Ok(BTreeMap::new());
    }
    let max = MAX_ROWS.to_string();
    let specs: Vec<String> = paths.iter().map(|rel| literal(rel)).collect();
    let mut args = vec![
        "log",
        "--first-parent",
        "--max-count",
        &max,
        "--name-only",
        "--format=%x1e%cI",
        tip,
        "--",
    ];
    args.extend(specs.iter().map(String::as_str));
    let text = stdout_capped(Hardened::git_bare(mirror, &args))?;
    // Newest first, so the first date a path is seen under is its answer.
    let wanted: BTreeSet<&Path> = paths.iter().map(PathBuf::as_path).collect();
    let mut out = BTreeMap::new();
    for record in text.split('\u{1e}') {
        let mut lines = record.lines();
        let Some(date) = lines.next().map(str::trim).filter(|d| !d.is_empty()) else {
            continue;
        };
        for changed in lines.filter(|line| !line.is_empty()) {
            // git names the file that changed; the path asked about may be
            // the directory holding it, so every ancestor is a candidate.
            let changed = Path::new(changed);
            for candidate in changed.ancestors() {
                if wanted.contains(candidate) {
                    out.entry(candidate.to_path_buf())
                        .or_insert_with(|| date.to_owned());
                }
            }
        }
    }
    Ok(out)
}
