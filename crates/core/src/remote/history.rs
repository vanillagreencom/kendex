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
/// A hostile repository can put megabytes in one subject line, and
/// `--name-only` lets it put megabytes in filenames; the cap keeps that its
/// problem. It is applied where the read happens — [`Hardened::max_output`]
/// stops at the bound rather than buffering the whole stream first — so
/// output past it is a refusal, which is what "a history that cannot be
/// read is an error" means here. The truncate below is the backstop.
const MAX_ROWS: usize = 200;
const MAX_OUTPUT: usize = 1_000_000;
/// Display bound for one commit subject.
const MAX_SUMMARY: usize = 200;

fn stdout_capped(git: Hardened) -> Result<String> {
    let git = git.max_output(MAX_OUTPUT);
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

/// A subtree path as a pathspec git will not interpret. Public because a
/// caller composing a set with [`excluding`] has to build every member of
/// it the same way.
pub fn literal(rel: &Path) -> String {
    // Slashed: git matches a pathspec against index paths, and those are
    // `/`-spelled on every platform. A `\` here matches no path at all,
    // and an empty log reads as "nothing changed".
    format!(":(literal){}", crate::paths::slashed(rel))
}

/// A folder left out of a pathspec set. On its own, with no positive
/// pathspec beside it, git reads a set of these as "everything but" — which
/// is how a caller asks for a whole tree minus the folders that are not
/// part of it.
pub fn excluding(folder: &str) -> String {
    format!(":(exclude){folder}")
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
        &["log", "--max-count", "1", "--format=%cI", commit, "--"],
    ))?;
    let date = text.trim().to_owned();
    Ok((!date.is_empty()).then_some(date))
}

/// What one walk of the history said about a set of paths.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Changed {
    /// When each path the walk reached last changed, ISO-8601.
    pub dates: BTreeMap<PathBuf, String>,
}

/// When each of `paths` last changed at-or-before `tip`, walking
/// first-parent history once rather than once per path. Every path is a
/// literal pathspec, so a directory answers for anything under it and a
/// name shaped like git syntax stays a name.
///
/// `max_commits` is this call's own bound and the caller's to choose: it
/// counts commits that touched one of `paths`, not commits walked, because
/// `--max-count` applies after the pathspec filter. A path whose newest
/// commit lies past it has no entry — absent is the honest reading, never
/// a date borrowed from a commit that did not touch it.
///
/// The byte cap does NOT end the walk that way. It refuses the whole read,
/// so every path loses its date at once rather than the oldest losing
/// theirs; the caller keeps `max_commits` low enough that the commit bound
/// is the one that fires. Density is the catalog's to choose, so a wide
/// enough one can still cross the cap — see `browse/updated.rs`.
///
/// Filenames come back NUL-delimited (`-z`), never git's C-quoted default:
/// under `core.quotePath`, which is on unless the host's gitconfig turns it
/// off, a non-ASCII path prints as octal escapes inside quotes and matches
/// nothing this asked for. Pinned in the invocation, so the answer does not
/// depend on whose machine it ran on.
///
/// `-z` also stops git escaping control characters, so the record boundary
/// has to be one a filename cannot hold. It is an EMPTY field: `%x00`
/// opens each record, and with every field NUL-terminated the opening
/// shows up as `\0\0`. No path is empty and none may contain a NUL, so a
/// catalog cannot write a name that opens a record. A printable or
/// control-character delimiter can be: a file named
/// `x<0x1e>2099-01-01T00:00:00+00:00` forged a whole record under the
/// previous `%x1e` framing, dating a sibling package to 2099 and pinning
/// it to the top of a newest-first sort — a freshness signal beside the
/// safety dot in an install decision. The catalog owns its own filenames.
pub fn last_changed(
    mirror: &Path,
    tip: &str,
    paths: &[PathBuf],
    max_commits: usize,
) -> Result<Changed> {
    require_commit(tip)?;
    if paths.is_empty() {
        return Ok(Changed::default());
    }
    let max = max_commits.to_string();
    let specs: Vec<String> = paths.iter().map(|rel| literal(rel)).collect();
    let mut args = vec![
        "log",
        "--first-parent",
        "--max-count",
        &max,
        "--name-only",
        "-z",
        "--format=%x00%cI",
        tip,
        "--",
    ];
    args.extend(specs.iter().map(String::as_str));
    let text = stdout_capped(Hardened::git_bare(mirror, &args))?;
    // Newest first, so the first date a path is seen under is its answer.
    let wanted: BTreeSet<&Path> = paths.iter().map(PathBuf::as_path).collect();
    let mut found = Changed::default();
    // Every field is NUL-terminated. An empty one opens a record: the field
    // after it is that commit's date, and the fields after that are the
    // names it changed, until the next empty field. git writes exactly one
    // separator newline, between the format output and the first name, and
    // that is the only one stripped — a newline inside a filename is part
    // of the filename.
    let mut fields = text.split('\0');
    // Past anything before the first record's opener.
    while fields.next().is_some_and(|field| !field.is_empty()) {}
    while let Some(date) = fields.next().map(str::trim).filter(|d| !d.is_empty()) {
        // The names run to the empty field that opens the next record;
        // consuming it here is what leaves the date of that record next.
        let mut more = false;
        for changed in fields.by_ref() {
            if changed.is_empty() {
                more = true;
                break;
            }
            let changed = changed.strip_prefix('\n').unwrap_or(changed);
            // git names the file that changed; the path asked about may be
            // the directory holding it, so every ancestor is a candidate.
            for candidate in Path::new(changed).ancestors() {
                if wanted.contains(candidate) {
                    found
                        .dates
                        .entry(candidate.to_path_buf())
                        .or_insert_with(|| date.to_owned());
                }
            }
        }
        if !more {
            break;
        }
    }
    Ok(found)
}

/// The newest first-parent commit at-or-before `tip` matching `specs`,
/// ISO-8601. One record of output whatever the history's size, so it
/// cannot approach the byte cap and cannot be forged: `--name-only` is what
/// makes a filename part of the stream, and this asks for none.
///
/// `specs` are git pathspecs, built with [`literal`] and [`excluding`] —
/// not bare paths, because the callers that want a whole tree minus a few
/// folders cannot say that with a path.
///
/// The newest-first ordering is git's, asked for with `--max-count 1`
/// rather than derived here: comparing ISO dates as text would order two
/// commits written in different time zones wrongly.
pub fn newest_touching(mirror: &Path, tip: &str, specs: &[String]) -> Result<Option<String>> {
    require_commit(tip)?;
    if specs.is_empty() {
        return Ok(None);
    }
    let mut args = vec![
        "log",
        "--first-parent",
        "--max-count",
        "1",
        "--format=%cI",
        tip,
        "--",
    ];
    args.extend(specs.iter().map(String::as_str));
    let text = stdout_capped(Hardened::git_bare(mirror, &args))?;
    let date = text.trim().to_owned();
    Ok((!date.is_empty()).then_some(date))
}
