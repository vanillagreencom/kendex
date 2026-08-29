//! How a path becomes text, and what a canonical root is.
//!
//! Both questions have a per-platform answer from the standard library, and
//! neither of those answers is the one kendex means, so both live here
//! rather than at the sites that ask.
//!
//! **A path a person reads or runs is spelled with `/`.** Windows accepts
//! `/` wherever it accepts `\`, so one spelling costs nothing there, and it
//! is the only spelling that works in the strings kendex writes into a
//! shell: inside `bash "..."` a `\` is an escape character and not a
//! separator at all. It is also what every project-scope hook command and
//! every package-relative path already holds, so a comparison across the
//! two compares the same text. [`slashed`] is that rule, and it is for text
//! only — a path handed back to the operating system stays a [`Path`].
//!
//! **A canonical root carries no extended-length prefix.** Scope identity
//! must not depend on the caller's spelling, so a root is canonicalized;
//! and on Windows [`std::fs::canonicalize`] answers in the verbatim
//! `\\?\C:\...` form, which most programs refuse and which [`slashed`]
//! cannot spell at all, since a verbatim path takes `/` literally instead
//! of as a separator. [`canonical`] is that call with the prefix taken back
//! off wherever the plain spelling names the same file. The length limit
//! the prefix exists to lift is not given up with it: `std`'s Windows file
//! layer puts the prefix back on any path it opens that runs past the
//! legacy limit, and a path too long for the plain spelling is left in the
//! verbatim one.

use std::path::{Path, PathBuf};

/// A path as text, spelled with `/` whatever the platform builds it with.
///
/// The transformation is the platform's own separator, never a blind
/// backslash substitution: on Unix `\` is an ordinary filename character,
/// so a file named `a\b` is one name and stays one name.
pub fn slashed(path: &Path) -> String {
    path.to_string_lossy()
        .replace(std::path::MAIN_SEPARATOR, "/")
}

/// The canonical spelling of `path`: symlinks resolved, and on Windows the
/// extended-length prefix taken back off wherever the plain spelling names
/// the same file.
///
/// A root that cannot be reduced — a volume with no drive letter, a
/// component the Win32 parser would rewrite, a path past the legacy length
/// — keeps the verbatim form, because a spelling that names a different
/// file is worse than an ugly one.
pub fn canonical(path: &Path) -> std::io::Result<PathBuf> {
    dunce::canonicalize(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A path is written down the same way whatever platform joined it:
    /// the separator the join used does not survive into the text.
    #[test]
    fn a_natively_joined_path_is_written_with_slashes() {
        let joined = Path::new("references").join("guides").join("old.md");
        assert_eq!(slashed(&joined), "references/guides/old.md");
    }

    /// The must-fail control for the rule above: replacing `\` rather than
    /// the platform separator would rename a Unix file here.
    #[test]
    #[cfg(unix)]
    fn a_backslash_in_a_unix_name_is_a_name_and_not_a_separator() {
        assert_eq!(slashed(Path::new("dir/a\\b")), "dir/a\\b");
    }

    /// A canonical root does not depend on the spelling it was asked
    /// under, answers the same under a second pass, and is a spelling
    /// other programs read — which on Windows means without the `\\?\`
    /// prefix. `..` rather than `.` for the detour, because two paths
    /// differing only by a `.` component already compare equal and would
    /// let a `canonical` that resolves nothing pass.
    #[test]
    fn a_canonical_root_is_stable_and_plainly_spelled() -> std::io::Result<()> {
        let tmp = tempfile::tempdir()?;
        let root = canonical(tmp.path())?;
        std::fs::create_dir(root.join("sub"))?;
        assert!(root.is_dir());
        assert_eq!(canonical(&root)?, root);
        assert_eq!(canonical(&root.join("sub").join(".."))?, root);
        assert!(!slashed(&root).starts_with("//?/"), "{}", root.display());
        Ok(())
    }
}
