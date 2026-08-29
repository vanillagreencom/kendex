//! How a path becomes text, and what a canonical root is.
//!
//! Both questions have a per-platform answer from the standard library, and
//! neither of those answers is the one kendex means, so both live here
//! rather than at the sites that ask. Both rules are written as functions
//! over a string with the platform's part passed in, so a Windows-shaped
//! path can be spelled and reduced on any host — and proven there.
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
//! **A canonical root drops the extended-length prefix wherever the plain
//! spelling names the same file.** Scope identity must not depend on the
//! caller's spelling, so a root is canonicalized; and on Windows
//! [`std::fs::canonicalize`] answers in the verbatim `\\?\C:\...` form,
//! which most programs refuse and which [`slashed`] cannot spell at all,
//! since a verbatim path takes `/` literally instead of as a separator.
//! [`canonical`] takes that prefix back off. **It is not a categorical
//! never**: a root whose plain spelling would reach a different file, or no
//! file, keeps the verbatim form, and [`plain`] names those shapes. So a
//! caller may still meet a `\\?\` root, and one that must hand a root to
//! another program or to [`slashed`] has to expect it.
//!
//! The length limit the prefix exists to lift is not given up with it:
//! `std`'s Windows file layer puts the prefix back on any path it opens
//! that runs past the legacy limit, so kendex's own reads and writes are
//! unaffected by which spelling it holds.

use std::path::{Path, PathBuf};

/// The prefix Windows canonicalization answers in.
const VERBATIM: &str = r"\\?\";

/// The legacy path limit, in bytes rather than the UTF-16 units Windows
/// counts: over-counting a non-ASCII path only keeps the verbatim spelling
/// that already worked, where under-counting would hand out a plain one
/// the Win32 parser refuses.
const LEGACY_MAX_PATH: usize = 248;

/// A path as text, spelled with `/` whatever the platform builds it with.
pub fn slashed(path: &Path) -> String {
    spelled(&path.to_string_lossy(), std::path::MAIN_SEPARATOR)
}

/// The rule [`slashed`] applies, with the platform's separator passed in.
///
/// Only that separator moves, never `\` blindly: on Unix a backslash is an
/// ordinary filename character, so a file named `a\b` is one name and has
/// to stay one name.
fn spelled(text: &str, separator: char) -> String {
    text.replace(separator, "/")
}

/// The canonical spelling of `path`: symlinks resolved, and on Windows the
/// extended-length prefix taken back off wherever [`plain`] can.
pub fn canonical(path: &Path) -> std::io::Result<PathBuf> {
    let resolved = path.canonicalize()?;
    // A path whose bytes are not UTF-8 cannot be reduced without inventing
    // some, and no canonicalized Unix path can carry the prefix anyway —
    // it is absolute and begins with `/` — so this is a Windows rule that
    // costs the other platforms one comparison.
    match resolved.to_str() {
        Some(text) => Ok(PathBuf::from(plain(text))),
        None => Ok(resolved),
    }
}

/// `text` without the extended-length prefix where the plain spelling
/// names the same file, and `text` unchanged where it would not.
///
/// A verbatim path reaches the object manager as written. A plain one goes
/// through the Win32 parser first, which trims a trailing dot or space off
/// each component, reads a reserved device stem as the device, and refuses
/// the whole path past the legacy limit — so a path carrying any of those
/// keeps the prefix, because a spelling that names a different file is
/// worse than an ugly one. `\\?\UNC\` shares and volume-GUID roots have no
/// drive letter to fall back to and are left whole for the same reason.
fn plain(text: &str) -> &str {
    let Some(rest) = text.strip_prefix(VERBATIM) else {
        return text;
    };
    let mut head = rest.chars();
    let drive_rooted = matches!(
        (head.next(), head.next(), head.next()),
        (Some(letter), Some(':'), Some('\\')) if letter.is_ascii_alphabetic()
    );
    if !drive_rooted
        || rest.len() > LEGACY_MAX_PATH
        || rest.split('\\').any(crate::names::win32_rewrites)
    {
        return text;
    }
    rest
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The spelling rule, driven with a Windows-shaped path on whatever
    /// host runs the suite. Against `to_string_lossy` — the call every one
    /// of these sites used to make — this is red.
    #[test]
    fn a_windows_path_is_spelled_with_slashes_on_any_host() {
        assert_eq!(
            spelled(r"C:\Users\me\.claude\hooks\guard.sh", '\\'),
            "C:/Users/me/.claude/hooks/guard.sh"
        );
        assert_eq!(
            spelled("/h/.claude/hooks/guard.sh", '/'),
            "/h/.claude/hooks/guard.sh"
        );
    }

    /// The must-fail control for taking the platform's separator rather
    /// than `\`: where `/` separates, a backslash is part of a name.
    #[test]
    fn a_backslash_is_a_name_where_the_slash_is_the_separator() {
        assert_eq!(spelled(r"dir/a\b", '/'), r"dir/a\b");
    }

    /// And `slashed` is that rule over this platform's separator, so the
    /// two above pin the entry point the rest of the crate calls.
    #[test]
    fn slashed_is_spelled_over_the_platform_separator() {
        let joined = Path::new("references").join("guides").join("old.md");
        assert_eq!(slashed(&joined), "references/guides/old.md");
    }

    /// The reduction, driven with verbatim input on any host. Against a
    /// `canonical` that returns std's answer whole, this is red.
    #[test]
    fn a_verbatim_drive_root_loses_the_prefix_on_any_host() {
        assert_eq!(plain(r"\\?\C:\Users\me\dev\app"), r"C:\Users\me\dev\app");
        assert_eq!(plain(r"\\?\C:\"), r"C:\");
        // Nothing to take off: already plain, or not Windows at all.
        assert_eq!(plain(r"C:\Users\me\dev\app"), r"C:\Users\me\dev\app");
        assert_eq!(plain("/home/me/dev/app"), "/home/me/dev/app");
    }

    /// The must-fail control for the exception the doc now states: a
    /// blanket strip would hand back a path naming something else, or
    /// nothing. Each of these keeps the prefix.
    #[test]
    fn the_prefix_stays_where_the_plain_spelling_names_something_else() {
        for verbatim in [
            // No drive letter to fall back to: a share, and a volume with
            // no mount point.
            r"\\?\UNC\server\share\app",
            r"\\?\Volume{b75e2c83-0000-0000-0000-602f00000000}\app",
            // The Win32 parser trims these away, naming another directory.
            r"\\?\C:\dev\app ",
            r"\\?\C:\dev.\app",
            // And reads this component as the console device.
            r"\\?\C:\dev\CON\app",
            r"\\?\C:\dev\con.txt",
        ] {
            assert_eq!(plain(verbatim), verbatim, "{verbatim}");
        }
        // Past the legacy limit the plain spelling is refused outright.
        let long = format!(r"\\?\C:\{}", "d".repeat(LEGACY_MAX_PATH));
        assert_eq!(plain(&long), long);
    }

    /// A canonical root names the directory it was asked about and does
    /// not depend on the spelling it was asked under. `..` rather than
    /// `.` for the detour, because two paths differing only by a `.`
    /// component already compare equal and would let a `canonical` that
    /// resolves nothing pass.
    #[test]
    fn a_canonical_root_does_not_depend_on_the_spelling_it_was_asked_under() -> std::io::Result<()>
    {
        let tmp = tempfile::tempdir()?;
        let root = canonical(tmp.path())?;
        std::fs::create_dir(root.join("sub"))?;
        assert!(root.is_dir());
        assert_eq!(canonical(&root)?, root);
        assert_eq!(canonical(&root.join("sub").join(".."))?, root);
        Ok(())
    }
}
