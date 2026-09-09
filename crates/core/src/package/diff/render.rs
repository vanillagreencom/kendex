//! Shaping two loaded trees into a display diff: statuses, per-file line
//! counts, unified hunks, and the budgets that keep hostile or huge
//! content a label instead of a hang.

use similar::TextDiff;

use super::{FileDiff, FileStatus, Hunk, Line, LineKind, PackageDiff, Tree};

/// Budgets, checked before the expensive work: a 256 KB file of one-byte
/// lines can cost more to diff than to download.
const MAX_FILE_BYTES: usize = 256 * 1024;
const MAX_FILE_LINES: usize = 10_000;
const MAX_FILES: usize = 400;
const MAX_TOTAL_LINES: usize = 20_000;
const CONTEXT_LINES: usize = 3;

/// Shape two loaded trees into a display diff.
pub fn diff_trees(from: &Tree, to: &Tree) -> PackageDiff {
    let mut files = Vec::new();
    let mut total_additions = 0;
    let mut total_deletions = 0;
    let mut total_lines = 0usize;
    let mut truncated = false;
    let paths: Vec<&String> = {
        let mut all: Vec<&String> = from.keys().chain(to.keys()).collect();
        all.sort();
        all.dedup();
        all
    };
    for path in paths {
        if files.len() >= MAX_FILES {
            truncated = true;
            break;
        }
        let old = from.get(path);
        let new = to.get(path);
        if old == new {
            continue;
        }
        let file = diff_file(path, old, new, MAX_TOTAL_LINES.saturating_sub(total_lines));
        total_additions += file.additions;
        total_deletions += file.deletions;
        total_lines += file
            .hunks
            .iter()
            .map(|hunk| hunk.lines.len())
            .sum::<usize>();
        if total_lines >= MAX_TOTAL_LINES {
            truncated = true;
        }
        files.push(file);
    }
    PackageDiff {
        files,
        total_additions,
        total_deletions,
        truncated,
    }
}

fn diff_file(
    path: &str,
    old: Option<&Vec<u8>>,
    new: Option<&Vec<u8>>,
    line_budget: usize,
) -> FileDiff {
    let status = match (old, new) {
        (None, Some(_)) => FileStatus::Added,
        (Some(_), None) => FileStatus::Removed,
        _ => FileStatus::Modified,
    };
    let empty = Vec::new();
    let old = old.unwrap_or(&empty);
    let new = new.unwrap_or(&empty);
    if old.contains(&0) || new.contains(&0) {
        return FileDiff {
            path: path.to_owned(),
            status: FileStatus::Binary,
            additions: 0,
            deletions: 0,
            lossy: false,
            hunks: Vec::new(),
        };
    }
    let old_text = String::from_utf8_lossy(old);
    let new_text = String::from_utf8_lossy(new);
    let lossy = matches!(old_text, std::borrow::Cow::Owned(_))
        || matches!(new_text, std::borrow::Cow::Owned(_));
    if old.len() > MAX_FILE_BYTES
        || new.len() > MAX_FILE_BYTES
        || old_text.lines().count() > MAX_FILE_LINES
        || new_text.lines().count() > MAX_FILE_LINES
    {
        return FileDiff {
            path: path.to_owned(),
            status: FileStatus::TooLarge,
            additions: 0,
            deletions: 0,
            lossy,
            hunks: Vec::new(),
        };
    }
    let text_diff = TextDiff::from_lines(old_text.as_ref(), new_text.as_ref());
    let mut additions = 0;
    let mut deletions = 0;
    let mut hunks = Vec::new();
    let mut emitted = 0usize;
    for group in text_diff.grouped_ops(CONTEXT_LINES) {
        let (Some(first), Some(last)) = (group.first(), group.last()) else {
            continue;
        };
        let header = format!(
            "@@ -{},{} +{},{} @@",
            first.old_range().start + 1,
            last.old_range().end - first.old_range().start,
            first.new_range().start + 1,
            last.new_range().end - first.new_range().start,
        );
        let mut lines = Vec::new();
        for op in &group {
            for change in text_diff.iter_changes(op) {
                if emitted >= line_budget {
                    break;
                }
                emitted += 1;
                let kind = match change.tag() {
                    similar::ChangeTag::Equal => LineKind::Context,
                    similar::ChangeTag::Insert => LineKind::Add,
                    similar::ChangeTag::Delete => LineKind::Remove,
                };
                match kind {
                    LineKind::Add => additions += 1,
                    LineKind::Remove => deletions += 1,
                    LineKind::Context => {}
                }
                lines.push(Line {
                    kind,
                    text: change.value().trim_end_matches('\n').to_owned(),
                    old_no: change.old_index().map(|i| i as u32 + 1),
                    new_no: change.new_index().map(|i| i as u32 + 1),
                });
            }
        }
        if !lines.is_empty() {
            hunks.push(Hunk { header, lines });
        }
        if emitted >= line_budget {
            break;
        }
    }
    FileDiff {
        path: path.to_owned(),
        status,
        additions,
        deletions,
        lossy,
        hunks,
    }
}
