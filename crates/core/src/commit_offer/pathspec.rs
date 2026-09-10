//! How the set reaches git.
//!
//! The set runs to a thousand paths in a large project, tens of kilobytes
//! of path text. Windows caps a command line at 32,767 characters and
//! kendex supports Windows, so no step passes the set as arguments: it is
//! written to a file in the system temp directory, NUL-separated, and
//! passed with `--pathspec-from-file` and `--pathspec-file-nul`. `git add`,
//! `git commit` and `git reset` all take it.
//!
//! The file is outside the checkout, so it is never a path the offer could
//! then find, and it is removed when the step ends.
//!
//! Each entry carries its own [`Spec::LITERAL`] magic prefix rather than
//! the step passing git's `--literal-pathspecs`. The two select the same
//! files, but the git-wide option is one git re-exports as
//! `GIT_LITERAL_PATHSPECS=1` to everything it starts, and `git commit`
//! starts the repository's hooks. A hook is other people's code reading
//! their own repository: under that variable a hook's `git ls-files --
//! ':(glob)docs/**/*.md'` matches nothing and its `git check-ignore`
//! exits 128 on magic it never wrote. The prefix keeps the selection
//! inside the file, where only the step that wrote it reads it.

use std::io::Write;
use std::path::PathBuf;

use super::{Failed, Refusal, Step};

/// A NUL-separated pathspec file, removed when it goes out of scope.
pub struct Spec {
    path: PathBuf,
}

impl Spec {
    /// Write the paths for one step.
    pub fn write(paths: &[String], step: Step) -> Result<Spec, Failed> {
        let mut file = tempfile::Builder::new()
            .prefix("kendex-paths-")
            .tempfile()
            .map_err(|error| failure(step, &error))?;
        for path in paths {
            file.write_all(Spec::LITERAL.as_bytes())
                .and_then(|()| file.write_all(path.as_bytes()))
                .and_then(|()| file.write_all(&[0]))
                .map_err(|error| failure(step, &error))?;
        }
        file.flush().map_err(|error| failure(step, &error))?;
        // Kept by path rather than by handle: git opens the file itself,
        // and Windows will not open a second handle to a file this process
        // still holds exclusively.
        let (_, path) = file.keep().map_err(|error| failure(step, &error.error))?;
        Ok(Spec { path })
    }

    /// The two arguments git reads the file through.
    pub fn args(&self) -> [String; 2] {
        [
            format!("--pathspec-from-file={}", self.path.display()),
            "--pathspec-file-nul".to_owned(),
        ]
    }

    /// The magic prefix every pathspec this module hands git is written
    /// behind, whether it goes in the file or in argv.
    ///
    /// `--pathspec-file-nul` fixes the separator, not the matching: git
    /// still reads each entry as a pathspec, so a rendered path holding
    /// `[`, `*` or `?` would match a different file and put a path in the
    /// commit that was never in the set. Behind this prefix git takes the
    /// rest of the entry as the path it is, and it is read only at the
    /// start of an entry, so a `:` inside a path is a character like any
    /// other rather than the opening of a second prefix.
    const LITERAL: &'static str = ":(literal)";
}

/// One path as a pathspec on a command line, for a read that names a
/// single path in argv rather than through the file above.
///
/// The same prefix and the same guarantee as an entry in that file, so the
/// crate has one spelling of "this text is a path" rather than a file-only
/// one and an argv-only one that could drift apart.
pub fn literal(path: &str) -> String {
    format!("{}{path}", Spec::LITERAL)
}

impl Drop for Spec {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// A pathspec file that could not be written is that step failing before
/// it ran: nothing was staged, nothing was committed.
fn failure(step: Step, error: &std::io::Error) -> Failed {
    Failed {
        step,
        refusal: Refusal::Said(vec![format!(
            "the list of paths for this step could not be written: {error}"
        )]),
    }
}
