//! How a path becomes text, what a canonical root is, and how a typed `~`
//! is expanded.
//!
//! The first two have a per-platform answer from the standard library, and
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
//!
//! **A leading `~` a shell would have expanded is expanded here**, because
//! the GUI has no shell in front of it. [`expand_tilde`] is that rule.

use std::borrow::Cow;
use std::path::{Path, PathBuf};

/// The prefix Windows canonicalization answers in.
const VERBATIM: &str = r"\\?\";

/// The legacy path limit, in bytes rather than the UTF-16 units Windows
/// counts: over-counting a non-ASCII path only keeps the verbatim spelling
/// that already worked, where under-counting would hand out a plain one
/// the Win32 parser refuses.
const LEGACY_MAX_PATH: usize = 248;

/// Expands a leading `~/` or a lone `~` against `home`. A `~user` prefix is
/// left untouched because it names another account, not `home`.
pub fn expand_tilde(home: &Path, input: &str) -> PathBuf {
    if input == "~" {
        return home.to_path_buf();
    }
    match input.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => PathBuf::from(input),
    }
}

/// A path as text, spelled with `/` whatever the platform builds it with.
///
/// A verbatim path is reduced by [`plain`] first, since `\\?\C:\x` with
/// its separators swapped is `//?/C:/x`, which names nothing: extended
/// syntax reads `/` as an ordinary character rather than a separator. One
/// [`plain`] cannot reduce has no `/` spelling at all and comes back as it
/// went in, still `\`-spelled — a caller writing it into a shell string
/// gets a path that shell cannot read, which is the honest answer where
/// the alternative names a different file or none. A root reaches here
/// that way only from a harness root somebody set to the verbatim form.
///
/// **Routing a producer here routes its readers too.** A test that builds
/// both sides of a comparison carries one spelling whichever it is, and
/// that is why fixture paths are left raw — but the moment one side is a
/// value from here, the expectation has to be spelled here as well, or the
/// two agree only on the host where the separator already matches.
pub fn slashed(path: &Path) -> String {
    let text = path.to_string_lossy();
    let reduced = plain(&text);
    match reduced.starts_with(VERBATIM) {
        true => reduced.into_owned(),
        false => spelled(&reduced, std::path::MAIN_SEPARATOR),
    }
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
    Ok(reduced(&path.canonicalize()?))
}

/// An already-resolved `path` in the spelling kendex hands out —
/// [`canonical`] without the resolving step.
///
/// The prefix is kept or dropped per path, on that path's own length and
/// components, so two paths reduced apart are two spellings and can no
/// longer be compared: an ancestor short enough to lose it does not prefix
/// a descendant long enough to keep it. A walk or a containment test
/// therefore resolves in [`std::fs::canonicalize`]'s one spelling and
/// reduces the answer it settles on, here.
pub fn reduced(path: &Path) -> PathBuf {
    // A path whose bytes are not UTF-8 cannot be reduced without inventing
    // some, and no canonicalized Unix path can carry the prefix anyway —
    // it is absolute and begins with `/` — so this is a Windows rule that
    // costs the other platforms one comparison.
    match path.to_str() {
        Some(text) => PathBuf::from(plain(text).as_ref()),
        None => path.to_path_buf(),
    }
}

/// `text` without the extended-length prefix where the plain spelling
/// names the same file, and `text` unchanged where it would not.
///
/// Two verbatim roots have a plain spelling at all: a drive-lettered one is
/// the same path with the prefix gone, and a share is `\\server\share`,
/// which is the prefix's own `UNC` swapped back for one separator. A root
/// with neither — a volume with no mount point above all — has no plain
/// equivalent to fall back to, so it is not a candidate however clean its
/// components read. That distinction is the whole rule: what follows only
/// decides whether an equivalent that exists is also safe.
///
/// An equivalent is safe only where it is *proven* to be the same path, and
/// the proof is `names::win32_preserves` over every component plus the
/// legacy length. That direction is the point: a verbatim path reaches the
/// object manager as written, a plain one is parsed by Win32 first, and the
/// parser has more rewriting rules than are worth listing. Asking each
/// component to prove itself means a shape nobody anticipated keeps the
/// prefix — ugly, and still naming what it named — where asking it to match
/// a list of known-bad shapes means an unlisted one is silently respelled
/// into something else. The checks are the same for both roots: a share's
/// host and share name go through them too, which can only ever keep a
/// verbatim spelling that already worked.
fn plain(text: &str) -> Cow<'_, str> {
    let Some(rest) = text.strip_prefix(VERBATIM) else {
        return Cow::Borrowed(text);
    };
    // The root itself is not a component — a drive letter holds the `:`
    // every component is refused for — so each form hands back what sits
    // below it, and only that is asked to prove itself.
    let (plain, below) = if let Some(below) = drive_rooted(rest) {
        (Cow::Borrowed(rest), below)
    } else if let Some(share) = rest.strip_prefix(r"UNC\") {
        (Cow::Owned(format!(r"\\{share}")), share)
    } else {
        return Cow::Borrowed(text);
    };
    // A root's own trailing separator closes the root rather than opening
    // an empty component; anywhere else an empty one is unproven like the
    // rest, because Win32 collapses it and verbatim does not.
    let below = below.trim_end_matches('\\');
    if plain.len() > LEGACY_MAX_PATH
        || (!below.is_empty() && !below.split('\\').all(crate::names::win32_preserves))
    {
        return Cow::Borrowed(text);
    }
    plain
}

/// What sits below a `C:\`-shaped root, or `None` where this is not one —
/// the one form that needs nothing but the prefix taken off.
fn drive_rooted(text: &str) -> Option<&str> {
    let mut head = text.chars();
    matches!(
        (head.next(), head.next(), head.next()),
        (Some(letter), Some(':'), Some('\\')) if letter.is_ascii_alphabetic()
    )
    .then(|| &text[3..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tilde_expands_against_home_without_rewriting_other_paths() {
        let home = Path::new("/home/pat");
        for (input, want) in [
            ("~", "/home/pat"),
            ("~/dev/hyprtrade", "/home/pat/dev/hyprtrade"),
            // `~user` names another account, so it is left alone.
            ("~alex/dev", "~alex/dev"),
            ("dev/hyprtrade", "dev/hyprtrade"),
            ("/opt/dev/hyprtrade", "/opt/dev/hyprtrade"),
        ] {
            assert_eq!(expand_tilde(home, input), PathBuf::from(want), "{input}");
        }
    }

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
        // Ordinary components the parser carries through untouched, so
        // proving each one cannot become a rule that proves nothing: a
        // dot inside a name, a space inside one, a name that merely
        // starts with a device's letters, and one that is not ASCII.
        assert_eq!(
            plain(r"\\?\C:\Users\my dev\v1.2\console\café\app"),
            r"C:\Users\my dev\v1.2\console\café\app"
        );
        // Nothing to take off: already plain, or not Windows at all.
        assert_eq!(plain(r"C:\Users\me\dev\app"), r"C:\Users\me\dev\app");
        assert_eq!(plain("/home/me/dev/app"), "/home/me/dev/app");
    }

    /// A share has a plain spelling too, and the rule holds for it: the
    /// prefix's own `UNC` becomes the separator that starts `\\server`.
    /// Against a `plain` that only knows drive letters, this is red.
    #[test]
    fn a_verbatim_share_becomes_its_plain_double_separator_spelling() {
        assert_eq!(plain(r"\\?\UNC\server\share\app"), r"\\server\share\app");
        assert_eq!(plain(r"\\?\UNC\server\share"), r"\\server\share");
        // And the same component checks decide it, so a share carrying a
        // shape the Win32 parser rewrites keeps the prefix like any other.
        assert_eq!(
            plain(r"\\?\UNC\server\share\app "),
            r"\\?\UNC\server\share\app "
        );
    }

    /// The must-fail control for the exception the doc now states: a
    /// blanket strip would hand back a path naming something else, or
    /// nothing. Each of these keeps the prefix.
    #[test]
    fn the_prefix_stays_where_the_plain_spelling_names_something_else() {
        for verbatim in [
            // A volume with no mount point has no plain spelling at all —
            // the distinction the UNC case above turns on.
            r"\\?\Volume{b75e2c83-0000-0000-0000-602f00000000}\app",
            // The Win32 parser trims these away, naming another directory.
            r"\\?\C:\dev\app ",
            r"\\?\C:\dev.\app",
            // And reads these components as devices — the superscript
            // serial and parallel ports as surely as the ASCII-digit ones,
            // and a stem whose trailing spaces Win32 takes off before it
            // tests the name at all.
            r"\\?\C:\dev\CON\app",
            r"\\?\C:\dev\con.txt",
            r"\\?\C:\dev\COM1\app",
            "\\\\?\\C:\\dev\\COM\u{b9}\\app",
            "\\\\?\\C:\\dev\\LPT\u{b3}\\app",
            r"\\?\C:\dev\NUL .txt",
            // A component holding a character the Win32 grammar keeps for
            // itself was made through the extended namespace and has no
            // plain spelling at all — the parser would reject it or read
            // it as syntax.
            r"\\?\C:\dev\what?\app",
            r"\\?\C:\dev\a*b\app",
            r"\\?\C:\dev\a:b\app",
            "\\\\?\\C:\\dev\\a\u{1}b\\app",
            // Win32 resolves these where verbatim takes them literally, so
            // the two spellings name different places.
            r"\\?\C:\dev\..\app",
            r"\\?\C:\dev\.\app",
        ] {
            assert_eq!(plain(verbatim), verbatim, "{verbatim}");
        }
        // Past the legacy limit the plain spelling is refused outright.
        let long = format!(r"\\?\C:\{}", "d".repeat(LEGACY_MAX_PATH));
        assert_eq!(plain(&long), long);
    }

    /// The verbatim form has no `/` spelling, so the prefix comes off
    /// before the separators move, and stays on where it cannot come off.
    /// Against a `slashed` that spells whatever it is handed, the first
    /// of these is red and the second passes for the wrong reason.
    #[test]
    fn a_verbatim_path_is_reduced_before_it_is_spelled_or_left_whole() {
        let out = slashed(Path::new(r"\\?\C:\Users\me"));
        assert!(!out.starts_with(VERBATIM), "{out}");
        assert!(!out.starts_with("//?/"), "{out}");
        assert!(out.ends_with("me"), "{out}");
        // Nothing to reduce to, so nothing to spell: `/` inside extended
        // syntax is a character in a name, not a separator.
        assert_eq!(slashed(Path::new(r"\\?\C:\dev\app ")), r"\\?\C:\dev\app ");
    }

    /// And `reduced` is that rule over a path, so a caller that resolved
    /// in std's own spelling settles on the same answer `canonical` would
    /// have handed it. Against a `reduced` that gives the path back whole,
    /// this is red.
    #[test]
    fn a_resolved_path_is_reduced_to_the_spelling_canonical_hands_out() {
        assert_eq!(
            reduced(Path::new(r"\\?\C:\Users\me\dev\app")),
            Path::new(r"C:\Users\me\dev\app")
        );
        // And keeps the prefix on exactly the shapes `plain` keeps it on,
        // so the two cannot drift apart.
        assert_eq!(
            reduced(Path::new(r"\\?\C:\dev\app ")),
            Path::new(r"\\?\C:\dev\app ")
        );
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
