//! kendex's own record that it armed one package's effect in one
//! repository.
//!
//! The record is the licence to run that package's declared check, and it
//! exists because nothing else on disk can be one. A checker is a script
//! out of a checkout, and a checkout arrives with a fetch: opening a
//! package's page must not run it. What separates a repository somebody
//! armed from one that merely carries the package's files has to be a fact
//! kendex holds itself.
//!
//! Two properties make this one. It sits in the repository's COMMON GIT
//! DIRECTORY, which git clones for nobody, so a record can only have been
//! made on this machine. And [`super::arm`] is its only writer, so nothing
//! a declaration says can produce one.
//!
//! Both are load-bearing, and the second is the reason a path the
//! DECLARATION names cannot serve. `writes` accepts any repo-relative
//! path, so `.git/config` and `.git/HEAD` are legal members and exist in
//! every repository ever cloned; a package naming one would be checked
//! everywhere. A careful author reaches the same place without malice by
//! naming `.git/hooks/pre-commit`, which husky and pre-commit also write.
//!
//! Absence is an answer and not an error: kendex did not arm this effect
//! here. It is not a claim that the effect is not in force — somebody may
//! have run the package's installer themselves — which is why the surface
//! that reports it also offers the person a way to ask the package
//! directly.

use std::path::{Path, PathBuf};

use crate::error::Result;

/// The directory the records live in, under the common git directory.
///
/// Namespaced under `kendex` rather than dropped beside git's own files:
/// this is kendex's state in somebody else's directory, and it has to be
/// recognisable as such by a person looking at it.
const DIR: &str = "kendex/armed";

/// Where one package's record sits, or `None` where its name could not be
/// one.
///
/// `names::item_problem` is the one rule for what an item may be called,
/// and every legal name is one path segment or a `<plugin>/<leaf>` pair of
/// them — so a legal name is a legal relative path and an illegal one gets
/// no record rather than a path built out of it. Refused rather than
/// sanitised: a name kendex would not install is not a name it writes a
/// licence under.
fn record(common_dir: &Path, name: &str) -> Option<PathBuf> {
    crate::names::item_problem(name)
        .is_none()
        .then(|| common_dir.join(DIR).join(name))
}

/// Write the record that kendex armed this package's effect here.
///
/// Called after the installer has exited clean, so a failed arming leaves
/// no licence: the direction to fail in is the one where kendex runs less
/// of the checkout's code, not more.
pub fn arm(common_dir: &Path, name: &str) -> Result<()> {
    let Some(path) = record(common_dir, name) else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| crate::error::CoreError::io(parent, error))?;
    }
    // The file's content is not read by anything and is not evidence of
    // anything; its presence is the whole record. A line saying so is for
    // the person who finds it in their git directory and wants to know
    // what wrote it.
    crate::fs::atomic_write(
        &path,
        "kendex recorded arming this package's repository effect here\n",
    )
}

/// Drop the record, because the package's uninstaller has run.
///
/// A record left behind after a disarm would licence a check of an effect
/// nothing here armed — the same fail-open in slower motion.
pub fn disarm(common_dir: &Path, name: &str) -> Result<()> {
    let Some(path) = record(common_dir, name) else {
        return Ok(());
    };
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(crate::error::CoreError::io(&path, error)),
    }
}

/// Whether kendex armed this package's effect in this repository.
///
/// Three answers and not two, through [`crate::fs::exists`]: a directory
/// that would not open is a question nobody asked, and folding it into
/// "no record" would turn it into a positive claim about a repository
/// nothing looked at.
pub fn recorded(common_dir: &Path, name: &str) -> Result<bool> {
    match record(common_dir, name) {
        Some(path) => crate::fs::exists(&path),
        None => Ok(false),
    }
}
