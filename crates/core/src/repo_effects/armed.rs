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
//! Two properties make this one. It sits in one of the repository's GIT
//! DIRECTORIES, which git clones for nobody, so a record can only have been
//! made on this machine. And [`super::arm`] is its only writer, so nothing
//! a declaration says can produce one.
//!
//! Which of them is [`record_dir`]'s answer, and it is the effect's reach:
//! an effect inside `.git` belongs to every linked work tree and an effect
//! in the checkout belongs to the one it was armed in.
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

/// The directory the records live in, under whichever git directory
/// [`record_dir`] names.
///
/// Namespaced under `kendex` rather than dropped beside git's own files:
/// this is kendex's state in somebody else's directory, and it has to be
/// recognisable as such by a person looking at it.
const DIR: &str = "kendex/armed";

/// The file inside a package's record directory whose presence is the
/// record.
///
/// A leaf and not the directory itself, because a name is a path of one or
/// two segments: with the record AT `armed/<name>`, arming `foo/bar` makes
/// `armed/foo` a directory and a plain package called `foo` reads as
/// armed. One name's record path is never another's once every record is a
/// file at a fixed leaf below its own name.
///
/// Starting with `-` so no package can be called this: `names::segment_problem`
/// refuses a leading dash, which is what keeps `armed/<name>/-record` from
/// ever being the record directory of a package named `<name>/-record`.
const LEAF: &str = "-record";

/// Where this repository's records live for an effect of this reach.
///
/// A shared effect lands in the common git directory, which every linked
/// work tree of the repository reads: the effect is theirs too, so one
/// arming licenses the check in all of them. An effect that writes a work
/// tree path is that work tree's alone — arming it in one says nothing
/// about the checkout beside it — so its record goes in the work tree's own
/// git directory. Git clones neither.
pub fn record_dir(repo: &crate::guard::Repo, shared: bool) -> &std::path::Path {
    match shared {
        true => &repo.common_dir,
        false => &repo.git_dir,
    }
}

/// Where one package's record sits, or `None` where its name could not be
/// one.
///
/// `names::item_problem` is the one rule for what an item may be called,
/// and every legal name is one path segment or a `<plugin>/<leaf>` pair of
/// them — so a legal name is a legal relative path and an illegal one gets
/// no record rather than a path built out of it. Refused rather than
/// sanitised: a name kendex would not install is not a name it writes a
/// licence under.
fn record(record_dir: &Path, name: &str) -> Option<PathBuf> {
    crate::names::item_problem(name)
        .is_none()
        .then(|| record_dir.join(DIR).join(name).join(LEAF))
}

/// Write the record that kendex armed this package's effect here.
///
/// Called after the installer has exited clean, so a failed arming leaves
/// no licence: the direction to fail in is the one where kendex runs less
/// of the checkout's code, not more.
pub fn arm(record_dir: &Path, name: &str) -> Result<()> {
    let Some(path) = record(record_dir, name) else {
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
pub fn disarm(record_dir: &Path, name: &str) -> Result<()> {
    let Some(path) = record(record_dir, name) else {
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
pub fn recorded(record_dir: &Path, name: &str) -> Result<bool> {
    match record(record_dir, name) {
        Some(path) => crate::fs::exists(&path),
        None => Ok(false),
    }
}

#[cfg(test)]
mod tests;
