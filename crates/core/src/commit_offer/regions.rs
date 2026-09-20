//! A generated part of a file that kendex does not own as a whole.
//!
//! The renderer names the file and the Markdown heading that bounds its
//! section. This module is the only reader of that ownership description.
//! Commit and restore use its splice operation, so neither can accidentally
//! treat the surrounding user text as generated content.

use std::ops::Range;
use std::path::{Path, PathBuf};

use crate::process::Hardened;

use super::pathspec::Spec;
use super::{Failed, Refusal, Step, git};

/// One Markdown section a renderer owns inside a user-owned file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct OwnedRegion {
    path: PathBuf,
    heading: String,
}

impl OwnedRegion {
    /// Build the ownership description reported by a renderer.
    pub fn new(path: PathBuf, heading: String) -> Result<Self, String> {
        if heading.contains(['\n', '\r', '\t']) || heading_level(&heading).is_none() {
            return Err("a rendered region heading must be one Markdown heading line".to_owned());
        }
        Ok(Self { path, heading })
    }

    /// The file that contains this region.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The heading carried through the renderer protocol.
    pub fn heading(&self) -> &str {
        &self.heading
    }

    /// Replace this region's body in `base` with its body from `source`.
    /// Text before the heading and after the section stays from `base`.
    pub(crate) fn splice(&self, base: &str, source: &str) -> Result<String, String> {
        let base_body = self.body(base)?;
        let source_body = self.body(source)?;
        let mut merged = String::with_capacity(base.len() - base_body.len() + source_body.len());
        merged.push_str(&base[..base_body.start]);
        merged.push_str(&source[source_body]);
        merged.push_str(&base[base_body.end..]);
        Ok(merged)
    }

    /// The bytes after the owned heading and before the next heading at the
    /// same or a higher level.
    pub(crate) fn body(&self, text: &str) -> Result<Range<usize>, String> {
        let wanted = self.heading.as_str();
        let Some(level) = heading_level(wanted) else {
            return Err("the owned region carries an invalid Markdown heading".to_owned());
        };
        let mut matches = text
            .split_inclusive('\n')
            .scan(0usize, |offset, line| {
                let start = *offset;
                *offset += line.len();
                Some((start, line.trim_end_matches(['\n', '\r'])))
            })
            .filter(|(_, line)| *line == wanted);
        let Some((heading_start, _)) = matches.next() else {
            return Err(format!(
                "{}: the owned heading is absent",
                self.path.display()
            ));
        };
        if matches.next().is_some() {
            return Err(format!(
                "{}: the owned heading occurs more than once",
                self.path.display()
            ));
        }
        let heading_end = text[heading_start..]
            .find('\n')
            .map_or(text.len(), |newline| heading_start + newline + 1);
        let mut end = text.len();
        let mut prior: Option<(usize, &str)> = None;
        for (offset, line) in
            text[heading_end..]
                .split_inclusive('\n')
                .scan(heading_end, |cursor, line| {
                    let start = *cursor;
                    *cursor += line.len();
                    Some((start, line.trim_end_matches(['\n', '\r'])))
                })
        {
            if heading_level(line).is_some_and(|found| found <= level) {
                end = offset;
                break;
            }
            if setext_level(line).is_some_and(|found| found <= level)
                && let Some((prior_offset, prior_line)) = prior
                && !prior_line.trim().is_empty()
            {
                end = prior_offset;
                break;
            }
            prior = Some((offset, line));
        }
        Ok(heading_end..end)
    }
}

/// Restore only this region from `HEAD`, preserving every surrounding byte
/// from the working tree.
pub(super) fn restore(root: &Path, region: &OwnedRegion) -> Result<(), Failed> {
    let relative = region
        .path()
        .strip_prefix(root)
        .map(crate::paths::slashed)
        .map_err(|_| {
            refused(format!(
                "{} is outside the project",
                region.path().display()
            ))
        })?;
    let committed = git::read_required(root, &["show", &format!("HEAD:./{relative}")])?;
    let committed = String::from_utf8(committed)
        .map_err(|_| refused(format!("{relative}: the committed file is not UTF-8 text")))?;
    let working = std::fs::read_to_string(region.path())
        .map_err(|error| refused(format!("{}: {error}", region.path().display())))?;
    let restored = region.splice(&working, &committed).map_err(refused)?;
    crate::fs::atomic_write(region.path(), &restored).map_err(|error| refused(error.to_string()))
}

/// Whether the generated region differs between `HEAD` and the working
/// tree. Changes outside the region do not make the path kendex-owned.
pub(super) fn changed(root: &Path, region: &OwnedRegion) -> Result<bool, Failed> {
    let relative = relative(root, region)?;
    if !git::born(root)? || !committed(root, &relative)? {
        return Ok(false);
    }
    let before = git::read_required(root, &["show", &format!("HEAD:./{relative}")])?;
    let before = text(&relative, before, Step::Read)?;
    let after = canonical_working(root, &relative, Step::Read)?;
    let before_body = region.body(&before).map_err(read_refused)?;
    let after_body = region.body(&after).map_err(read_refused)?;
    Ok(before[before_body] != after[after_body])
}

/// Commit a set that contains at least one owned region. A temporary index
/// holds the commit candidate. The real index is prepared as it must stand
/// after that commit, preserving staged bytes outside every owned region.
pub(super) fn commit(
    root: &Path,
    generated: &crate::engine::GeneratedPaths,
    all: &[String],
    message: &str,
) -> Result<(), super::CommitFailure> {
    let regions: Vec<(&str, &OwnedRegion)> = all
        .iter()
        .filter_map(|path| {
            generated
                .region(root, path)
                .map(|region| (path.as_str(), region))
        })
        .collect();
    if regions.is_empty() {
        unreachable!("the regional commit route needs an owned region");
    }
    let whole: Vec<String> = all
        .iter()
        .filter(|path| generated.region(root, path).is_none())
        .cloned()
        .collect();
    let index = index_path(root).map_err(super::CommitFailure::from)?;
    let parent = index.parent().unwrap_or(root);
    let temp = tempfile::Builder::new()
        .prefix("kendex-region-commit-")
        .tempdir_in(parent)
        .map_err(|error| super::CommitFailure::from(commit_refused(error.to_string())))?;
    let backup = temp.path().join("original-index");
    let had_index = index.exists();
    if had_index {
        std::fs::copy(&index, &backup)
            .map_err(|error| super::CommitFailure::from(commit_refused(error.to_string())))?;
    }
    let alternate = temp.path().join("candidate-index");
    let source: Vec<(&str, &OwnedRegion, String)> = regions
        .iter()
        .map(|(path, region)| {
            canonical_working(root, path, Step::Commit).map(|text| (*path, *region, text))
        })
        .collect::<Result<_, _>>()
        .map_err(super::CommitFailure::from)?;

    let prepare = (|| -> Result<(), Failed> {
        stage(root, &index, &whole)?;
        for (path, region, source) in &source {
            write_region_to_index(root, &index, path, region, source)?;
        }
        initialize_candidate(root, &alternate)?;
        stage(root, &alternate, &whole)?;
        for (path, region, source) in &source {
            write_region_to_index(root, &alternate, path, region, source)?;
        }
        Ok(())
    })();
    if let Err(failed) = prepare {
        let still_staged = restore_index(&index, &backup, had_index)
            .err()
            .map(|_| all.len());
        return Err(super::CommitFailure {
            failed,
            still_staged,
        });
    }

    let result = git::run(
        Hardened::git(&["commit", "-m", message], Some(root))
            .env("GIT_INDEX_FILE", &alternate.to_string_lossy()),
        Step::Commit,
    );
    match result {
        Ok(_) => Ok(()),
        Err(failed) => Err(super::CommitFailure {
            still_staged: restore_index(&index, &backup, had_index)
                .err()
                .map(|_| all.len()),
            failed,
        }),
    }
}

fn initialize_candidate(root: &Path, index: &Path) -> Result<(), Failed> {
    let args = match git::born(root)? {
        true => ["read-tree", "HEAD"].as_slice(),
        false => ["read-tree", "--empty"].as_slice(),
    };
    git::run(
        Hardened::git(args, Some(root)).env("GIT_INDEX_FILE", &index.to_string_lossy()),
        Step::Stage,
    )?;
    Ok(())
}

fn stage(root: &Path, index: &Path, paths: &[String]) -> Result<(), Failed> {
    if paths.is_empty() {
        return Ok(());
    }
    let spec = Spec::write(paths, Step::Stage)?;
    let mut args = vec!["add".to_owned(), "-A".to_owned()];
    args.extend(spec.args());
    let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
    git::run(
        Hardened::git(&borrowed, Some(root)).env("GIT_INDEX_FILE", &index.to_string_lossy()),
        Step::Stage,
    )?;
    Ok(())
}

fn write_region_to_index(
    root: &Path,
    index: &Path,
    path: &str,
    region: &OwnedRegion,
    source: &str,
) -> Result<(), Failed> {
    let command = |args: &[&str]| {
        git::run(
            Hardened::git(args, Some(root)).env("GIT_INDEX_FILE", &index.to_string_lossy()),
            Step::Stage,
        )
    };
    let base = command(&["show", &format!(":./{path}")])?;
    let base = text(path, base, Step::Stage)?;
    let merged = region.splice(&base, source).map_err(stage_refused)?;
    let content = index.with_extension("region-content");
    std::fs::write(&content, merged.as_bytes())
        .map_err(|error| stage_refused(error.to_string()))?;
    let oid = git::run(
        Hardened::git(
            &["hash-object", "-w", "--", &content.to_string_lossy()],
            Some(root),
        ),
        Step::Stage,
    )?;
    let oid = String::from_utf8_lossy(&oid).trim().to_owned();
    let row = command(&["ls-files", "--stage", "--", &super::pathspec::literal(path)])?;
    let mode = String::from_utf8_lossy(&row)
        .split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| stage_refused(format!("{path}: the owned region has no index entry")))?;
    command(&[
        "update-index",
        "--add",
        "--cacheinfo",
        &format!("{mode},{oid},{path}"),
    ])?;
    let _ = std::fs::remove_file(content);
    Ok(())
}

fn canonical_working(root: &Path, path: &str, step: Step) -> Result<String, Failed> {
    let oid = git::run(
        Hardened::git(
            &["hash-object", "-w", "--path", path, "--", path],
            Some(root),
        ),
        step,
    )?;
    let oid = String::from_utf8_lossy(&oid).trim().to_owned();
    let bytes = git::run(Hardened::git(&["cat-file", "blob", &oid], Some(root)), step)?;
    text(path, bytes, step)
}

fn committed(root: &Path, path: &str) -> Result<bool, Failed> {
    let listed = git::read_required(
        root,
        &["ls-tree", "HEAD", "--", &super::pathspec::literal(path)],
    )?;
    Ok(String::from_utf8_lossy(&listed)
        .lines()
        .next()
        .and_then(|entry| entry.split_whitespace().nth(1))
        .is_some_and(|kind| kind == "blob"))
}

fn index_path(root: &Path) -> Result<PathBuf, Failed> {
    let bytes = git::read_required(root, &["rev-parse", "--git-path", "index"])?;
    let text = String::from_utf8(bytes)
        .map_err(|_| commit_refused("git returned a non-text index path".to_owned()))?;
    let path = PathBuf::from(text.trim_end());
    Ok(if path.is_absolute() {
        path
    } else {
        root.join(path)
    })
}

fn restore_index(index: &Path, backup: &Path, had_index: bool) -> std::io::Result<()> {
    if had_index {
        std::fs::copy(backup, index).map(|_| ())
    } else {
        match std::fs::remove_file(index) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }
}

fn relative(root: &Path, region: &OwnedRegion) -> Result<String, Failed> {
    region
        .path()
        .strip_prefix(root)
        .map(crate::paths::slashed)
        .map_err(|_| {
            read_refused(format!(
                "{} is outside the project",
                region.path().display()
            ))
        })
}

fn text(path: &str, bytes: Vec<u8>, step: Step) -> Result<String, Failed> {
    String::from_utf8(bytes).map_err(|_| Failed {
        step,
        refusal: Refusal::Said(vec![format!("{path}: the owned region is not UTF-8 text")]),
    })
}

fn read_refused(message: String) -> Failed {
    Failed {
        step: Step::Read,
        refusal: Refusal::Said(vec![message]),
    }
}

fn stage_refused(message: String) -> Failed {
    Failed {
        step: Step::Stage,
        refusal: Refusal::Said(vec![message]),
    }
}

fn commit_refused(message: String) -> Failed {
    Failed {
        step: Step::Commit,
        refusal: Refusal::Said(vec![message]),
    }
}

fn refused(message: String) -> Failed {
    Failed {
        step: Step::Restore,
        refusal: Refusal::Said(vec![message]),
    }
}

fn heading_level(line: &str) -> Option<usize> {
    let trimmed = line
        .strip_prefix("   ")
        .or_else(|| line.strip_prefix("  "))
        .or_else(|| line.strip_prefix(' '))
        .unwrap_or(line);
    let hashes = trimmed.bytes().take_while(|byte| *byte == b'#').count();
    if !(1..=6).contains(&hashes) || trimmed.as_bytes().get(hashes) != Some(&b' ') {
        return None;
    }
    Some(hashes)
}

fn setext_level(line: &str) -> Option<usize> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    match trimmed.bytes().next()? {
        b'=' if trimmed.bytes().all(|byte| byte == b'=') => Some(1),
        b'-' if trimmed.bytes().all(|byte| byte == b'-') => Some(2),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn region() -> OwnedRegion {
        OwnedRegion::new(
            PathBuf::from("AGENTS.md"),
            "## Code Review Rules".to_owned(),
        )
        .expect("the fixture heading is valid")
    }

    #[test]
    fn splice_changes_only_the_owned_section_body() {
        let base =
            "# App\n\nuser before\n\n## Code Review Rules\n\nold\n\n## User notes\n\nbase note\n";
        let source =
            "# App changed\n\n## Code Review Rules\n\nnew\n\n## User notes\n\nworking note\n";
        assert_eq!(
            region().splice(base, source).expect("the section splices"),
            "# App\n\nuser before\n\n## Code Review Rules\n\nnew\n\n## User notes\n\nbase note\n"
        );
    }

    #[test]
    fn a_setext_heading_ends_the_owned_section() {
        let base = "## Code Review Rules\n\nold\n\nUser notes\n----------\nbase\n";
        let source = "## Code Review Rules\n\nnew\n\nUser notes\n----------\nworking\n";
        assert_eq!(
            region().splice(base, source).expect("the section splices"),
            "## Code Review Rules\n\nnew\n\nUser notes\n----------\nbase\n"
        );
    }
}
