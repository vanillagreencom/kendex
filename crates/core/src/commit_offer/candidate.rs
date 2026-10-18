//! The commit a scope would make, built in an index file of its own, and a
//! package's check asked of it.
//!
//! The repository's pre-commit chain judges a commit, not the working tree:
//! `git commit --only` and kendex's region commit both hand their hooks an
//! index holding the last commit with the carried paths over it, and
//! commit-guards runs `bot-instructions check --staged` against that. The
//! candidate is that index, written by the same [`Carrying`] the region
//! commit writes its own with, so what the check is asked about here is
//! what the hook would be asked about there.
//!
//! The repository's own index is never written. The candidate lives in a
//! directory of its own under the git directory, removed when the
//! [`Candidate`] is dropped, whichever way the reading ends.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::engine::GeneratedPaths;
use crate::model::Scope;
use crate::repo_effects::{DeclaredEffects, SetupStatus};

use super::Failed;
use super::regions::{Carrying, index_path};
use super::{Step, git};
use crate::process::Hardened;

/// The prefix of the directory a candidate index is written in.
const PREFIX: &str = "kendex-candidate-";

/// One scope's candidate index, and the directory it is removed with.
pub(super) struct Candidate {
    dir: tempfile::TempDir,
    index: PathBuf,
}

impl Candidate {
    /// Reuse the same proposed commit for configuration reads and package checks.
    pub(super) fn ensure<'a>(
        cached: &'a mut Option<Self>,
        root: &Path,
        generated: &GeneratedPaths,
        carried: &BTreeSet<String>,
    ) -> crate::error::Result<&'a Self> {
        match cached {
            Some(built) => Ok(built),
            None => Ok(cached.insert(Self::build(
                root,
                generated,
                &carried.iter().cloned().collect::<Vec<_>>(),
            )?)),
        }
    }

    /// Write the index the commit of `carried` would hand its hooks.
    fn build(
        root: &Path,
        generated: &GeneratedPaths,
        carried: &[String],
    ) -> crate::error::Result<Candidate> {
        let unbuilt = |failed: Failed| {
            crate::repo_effects::err(format!(
                "the commit could not be built to check: {}",
                failed.said().join("\n")
            ))
        };
        let own = index_path(root).map_err(unbuilt)?;
        let Some(git_dir) = own.parent() else {
            unreachable!(
                "git named {} as its index, a path with no parent",
                own.display()
            );
        };
        let dir = tempfile::Builder::new()
            .prefix(PREFIX)
            .tempdir_in(git_dir)
            .map_err(|error| crate::error::CoreError::io(git_dir, error))?;
        let index = dir.path().join("index");
        Carrying::read(root, generated, carried, super::Step::Read)
            .and_then(|carrying| carrying.candidate(root, &index))
            .map_err(unbuilt)?;
        Ok(Candidate { dir, index })
    }

    /// The package's declared check, asked of this commit.
    pub(super) fn status(&self, scope: &Scope, declared: &DeclaredEffects) -> SetupStatus {
        crate::repo_effects::setup::status_of_index(scope, declared, &self.index)
    }

    /// Read only the manifest bytes this commit would hand its hooks.
    pub(super) fn configured(&self, root: &Path, key: &str) -> crate::error::Result<bool> {
        let primary = self.manifest(root, crate::manifest::MANIFEST_FILE)?;
        let selected = crate::manifest::project_manifest_from(primary.as_ref());
        let table = if selected == crate::manifest::MANIFEST_FILE {
            primary
        } else {
            self.manifest(root, selected)?
        };
        Ok(table.is_some_and(|table| table.contains_key(key)))
    }

    fn manifest(&self, root: &Path, name: &str) -> crate::error::Result<Option<toml::Table>> {
        let command = |args: &[&str]| {
            git::run(
                Hardened::git(args, Some(root))
                    .env("GIT_INDEX_FILE", &self.index.to_string_lossy()),
                Step::Read,
            )
            .map_err(|failed| {
                crate::repo_effects::err(format!(
                    "manifest-read={name}\nthe offered commit's manifest could not be read: {}",
                    failed.said().join("\n")
                ))
            })
        };
        // A missing entry and a failed read both make `show` exit nonzero.
        // Listing first proves absence without hiding a corrupt index or blob.
        let listed = command(&["ls-files", "--", &super::pathspec::literal(name)])?;
        if listed.is_empty() {
            return Ok(None);
        }
        let bytes = command(&["show", &format!(":./{name}")])?;
        let path = root.join(name);
        let text =
            std::str::from_utf8(&bytes).map_err(|error| crate::error::CoreError::TomlParse {
                path: path.clone(),
                message: error.to_string(),
            })?;
        text.parse().map(Some).map_err(|error: toml::de::Error| {
            crate::error::CoreError::TomlParse {
                path,
                message: error.to_string(),
            }
        })
    }

    /// Remove the candidate, reporting a removal that failed rather than
    /// leaving the directory in the git directory unsaid. Dropping it
    /// removes it too, on the paths that end early.
    pub(super) fn close(self) -> crate::error::Result<()> {
        let at = self.dir.path().to_owned();
        self.dir
            .close()
            .map_err(|error| crate::error::CoreError::io(&at, error))
    }
}
