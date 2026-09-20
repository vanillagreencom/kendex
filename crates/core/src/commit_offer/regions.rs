use std::ffi::OsString;
use std::io::Write;
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
    package_root: PathBuf,
    launcher: String,
}

impl OwnedRegion {
    pub fn new(
        path: PathBuf,
        heading: String,
        package_root: PathBuf,
        launcher: String,
    ) -> Result<Self, String> {
        if heading.is_empty() || heading.contains(['\n', '\r', '\t']) {
            return Err("a rendered region heading must be one non-empty line".to_owned());
        }
        Ok(Self {
            path,
            heading,
            package_root,
            launcher,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn heading(&self) -> &str {
        &self.heading
    }

    pub(crate) fn splice(
        &self,
        root: &Path,
        base: &str,
        source: &str,
        step: Step,
    ) -> Result<String, Failed> {
        let base_body = self.body(root, base, step)?;
        let source_body = self.body(root, source, step)?;
        let mut merged = String::with_capacity(base.len() - base_body.len() + source_body.len());
        merged.push_str(&base[..base_body.start]);
        merged.push_str(&source[source_body]);
        merged.push_str(&base[base_body.end..]);
        Ok(merged)
    }

    fn body(&self, root: &Path, text: &str, step: Step) -> Result<Range<usize>, Failed> {
        let mut input = tempfile::Builder::new()
            .prefix("kendex-region-source-")
            .tempfile()
            .map_err(|error| failed(step, error.to_string()))?;
        input
            .write_all(text.as_bytes())
            .map_err(|error| failed(step, error.to_string()))?;
        let report = crate::repo_effects::run_script_program(
            &crate::model::Scope::Project {
                root: root.to_owned(),
            },
            &self.package_root,
            &self.launcher,
            vec![
                OsString::from("region-bounds"),
                OsString::from("--input"),
                input.path().as_os_str().to_owned(),
            ],
        )
        .map_err(|error| failed(step, error.to_string()))?;
        if report.code != 0 {
            return Err(failed(
                step,
                crate::bot_instructions::said(&report.stdout, &report.stderr),
            ));
        }
        let range = report
            .stdout
            .as_slice()
            .first()
            .filter(|_| report.stdout.len() == 1)
            .and_then(|line| line.strip_prefix("region bounds\t"))
            .and_then(|bounds| bounds.split_once('\t'))
            .and_then(|(start, end)| Some(start.parse().ok()?..end.parse().ok()?))
            .filter(|range| {
                range.start <= range.end
                    && range.end <= text.len()
                    && text.is_char_boundary(range.start)
                    && text.is_char_boundary(range.end)
            });
        range.ok_or_else(|| {
            failed(
                step,
                format!(
                    "invalid region bounds: {}",
                    crate::bot_instructions::said(&report.stdout, &report.stderr)
                ),
            )
        })
    }
}

/// Restore this region from `HEAD` and preserve surrounding working bytes.
pub(super) fn restore(root: &Path, region: &OwnedRegion) -> Result<(), Failed> {
    let relative = region
        .path()
        .strip_prefix(root)
        .map(crate::paths::slashed)
        .map_err(|_| {
            failed(
                Step::Restore,
                format!("{} is outside the project", region.path().display()),
            )
        })?;
    let committed = git::read_required(root, &["show", &format!("HEAD:./{relative}")])?;
    let committed = String::from_utf8(committed).map_err(|_| {
        failed(
            Step::Restore,
            format!("{relative}: the committed file is not UTF-8 text"),
        )
    })?;
    let working = std::fs::read_to_string(region.path()).map_err(|error| {
        failed(
            Step::Restore,
            format!("{}: {error}", region.path().display()),
        )
    })?;
    let restored = region.splice(root, &working, &committed, Step::Restore)?;
    crate::fs::atomic_write(region.path(), &restored)
        .map_err(|error| failed(Step::Restore, error.to_string()))
}

/// Whether this region differs between `HEAD` and the working tree.
pub(super) fn changed(root: &Path, region: &OwnedRegion) -> Result<bool, Failed> {
    let relative = relative(root, region)?;
    if !git::born(root)? || !committed(root, &relative)? {
        return Ok(false);
    }
    let before = git::read_required(root, &["show", &format!("HEAD:./{relative}")])?;
    let before = text(&relative, before, Step::Read)?;
    let after = canonical_working(root, &relative, Step::Read)?;
    let before_body = region.body(root, &before, Step::Read)?;
    let after_body = region.body(root, &after, Step::Read)?;
    Ok(before[before_body] != after[after_body])
}

/// Commit whole paths and owned regions while preserving other staged bytes.
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
        .map_err(|error| super::CommitFailure::from(failed(Step::Commit, error.to_string())))?;
    let backup = temp.path().join("original-index");
    let had_index = index.exists();
    if had_index {
        std::fs::copy(&index, &backup)
            .map_err(|error| super::CommitFailure::from(failed(Step::Commit, error.to_string())))?;
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
    let merged = region.splice(root, &base, source, Step::Stage)?;
    let content = index.with_extension("region-content");
    std::fs::write(&content, merged.as_bytes())
        .map_err(|error| failed(Step::Stage, error.to_string()))?;
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
        .ok_or_else(|| {
            failed(
                Step::Stage,
                format!("{path}: the owned region has no index entry"),
            )
        })?;
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
    let text = String::from_utf8(bytes).map_err(|_| {
        failed(
            Step::Commit,
            "git returned a non-text index path".to_owned(),
        )
    })?;
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
            failed(
                Step::Read,
                format!("{} is outside the project", region.path().display()),
            )
        })
}

fn text(path: &str, bytes: Vec<u8>, step: Step) -> Result<String, Failed> {
    String::from_utf8(bytes).map_err(|_| Failed {
        step,
        refusal: Refusal::Said(vec![format!("{path}: the owned region is not UTF-8 text")]),
    })
}

fn failed(step: Step, message: String) -> Failed {
    Failed {
        step,
        refusal: Refusal::Said(vec![message]),
    }
}
