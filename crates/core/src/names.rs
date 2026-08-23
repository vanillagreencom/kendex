//! What an item name may be, and when two names are the same name.
//!
//! Every declared name becomes a file or directory somewhere, so a name that
//! cannot be one is refused where it is written down rather than where it
//! fails. Plugin-registry-shaped catalogs add a second rule: a name may carry
//! one `<plugin>/<leaf>` segment pair, and nothing more.

/// Room for the separator a namespaced name expands to, the `.disabled`
/// parking suffix, and Copilot's `.agent.md` — inside the 255-byte
/// component limit every filesystem kendex installs to shares.
const MAX_SEGMENT: usize = 100;

/// Names Windows keeps for devices. A file with one of these stems is not
/// created, it is written to the device, whatever extension it carries.
const DEVICE_NAMES: &[&str] = &[
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];

/// Why this one path segment cannot be a file or directory name.
pub fn segment_problem(segment: &str) -> Option<String> {
    if segment.is_empty() {
        return Some("a name cannot be empty".to_owned());
    }
    if segment == "." || segment == ".." {
        return Some(format!("`{segment}` names a directory, not an item"));
    }
    if segment.starts_with('-') {
        return Some(format!(
            "`{}` starts with `-`, which reads as a flag",
            shown(segment)
        ));
    }
    if let Some(bad) = segment
        .chars()
        .find(|c| c.is_control() || "/\\:*?\"<>|".contains(*c))
    {
        let bad = shown(&bad.to_string());
        return Some(format!(
            "`{}` holds `{bad}`, which no filename may",
            shown(segment)
        ));
    }
    // An invisible or direction-flipping character would let one name read as
    // another on screen while installing under a different one on disk.
    if segment.chars().any(is_deceptive) {
        return Some(format!(
            "`{}` holds an invisible or direction-changing character",
            shown(segment)
        ));
    }
    // Hook names are quoted into the shell command a harness runs; `$` and
    // backticks expand inside double quotes, and one rule for every kind is
    // simpler than one kind exempted.
    if let Some(bad) = segment.chars().find(|c| "$`".contains(*c)) {
        return Some(format!(
            "`{}` holds `{bad}`, which a shell would expand",
            shown(segment)
        ));
    }
    if segment.ends_with('.') || segment.ends_with(' ') {
        return Some(format!(
            "`{}` ends in a dot or a space, which Windows silently drops",
            shown(segment)
        ));
    }
    let stem = segment.split('.').next().unwrap_or(segment);
    if DEVICE_NAMES.contains(&stem.to_ascii_lowercase().as_str()) {
        return Some(format!(
            "`{}` is a reserved device name on Windows",
            shown(segment)
        ));
    }
    if segment.len() > MAX_SEGMENT {
        return Some(format!(
            "`{}` is {} bytes and a name may be {MAX_SEGMENT}",
            shown(segment),
            segment.len()
        ));
    }
    None
}

/// Whether a name can stand as a bare argument in guidance that spells a
/// verb and its parameters. A legal item name may hold spaces, semicolons
/// and ampersands — legal on every filesystem kendex writes to, and a shell
/// would read them as its own — and this product does not carry the cost of
/// quoting for every shell. So a name that is not plain is never printed in
/// an argument position; the guidance says the verb and leaves the name to
/// the row above it.
pub fn plain_argument(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | '@'))
        && !name.starts_with('-')
}

/// A catalog's own text, safe to print. Names travel from a downloaded
/// repository into terminal output and the app, where a control character
/// would move the cursor or colour the line, and an invisible or
/// direction-flipping character would let one marketplace's package read as
/// another's — so those are shown as their escapes, never acted on.
pub fn shown(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c.is_control() || is_deceptive(c) {
            true => out.extend(c.escape_debug()),
            false => out.push(c),
        }
    }
    out
}

/// Characters that render as nothing or reorder what surrounds them: the bidi
/// overrides and isolates, the zero-width spaces and joiners, and the BOM. A
/// name is meant to be the letters a person reads; these would make two
/// different names look like one.
fn is_deceptive(c: char) -> bool {
    matches!(c,
        '\u{200B}'..='\u{200F}'   // zero-width space/joiner, LTR/RTL marks
        | '\u{202A}'..='\u{202E}' // bidi embeddings and overrides
        | '\u{2060}'..='\u{2064}' // word joiner, invisible operators
        | '\u{2066}'..='\u{2069}' // bidi isolates
        | '\u{FEFF}'              // zero-width no-break space (BOM)
    )
}

/// Why this item name cannot be installed. A name from a plugin-registry-shaped
/// catalog carries its plugin — `<plugin>/<leaf>` — and that is the only
/// `/` any name may hold.
pub fn item_problem(name: &str) -> Option<String> {
    let mut segments = name.split('/');
    let first = segments.next().unwrap_or_default();
    if let Some(problem) = segment_problem(first) {
        return Some(problem);
    }
    // No second segment is a plain name, which is legal.
    let leaf = segments.next()?;
    if segments.next().is_some() {
        return Some(format!(
            "`{name}` has more than one `/` — a name is either a plain name or `<plugin>/<item>`"
        ));
    }
    segment_problem(leaf)
}

/// The plugin and item halves of a namespaced name, or `None` for a plain
/// one. Callers that resolve paths use this rather than splitting again:
/// the split and the legality rule above must never disagree.
pub fn split(name: &str) -> Option<(&str, &str)> {
    let (plugin, leaf) = name.split_once('/')?;
    (item_problem(name).is_none()).then_some((plugin, leaf))
}

/// The spelling two names collide under. Case is folded because macOS and
/// Windows hand the same file to both spellings, accents are composed
/// because macOS hands `café` written as one character and as `e` plus an
/// accent to the same file, and trailing dots are dropped because Windows
/// drops them — on those systems the second install silently overwrites the
/// first.
pub fn fold(name: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    name.to_lowercase()
        .nfc()
        .collect::<String>()
        .split('/')
        .map(|segment| segment.trim_end_matches(['.', ' ']).to_owned())
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_names_and_one_plugin_segment_are_legal() {
        assert!(item_problem("gh").is_none());
        assert!(item_problem("data-science/eda").is_none());
        assert_eq!(split("data-science/eda"), Some(("data-science", "eda")));
        assert_eq!(split("gh"), None);
    }

    #[test]
    fn path_hostile_shapes_are_named_with_the_reason() {
        for name in [
            "..",
            "../etc",
            "a/../b",
            "a/b/c",
            "",
            "a/",
            "/b",
            "nul",
            "com1.md",
            "trailing.",
            "-flag",
            "back\\slash",
            "x$(id)",
            "a`id`b",
        ] {
            assert!(item_problem(name).is_some(), "{name} should be refused");
        }
        assert!(item_problem(&"x".repeat(MAX_SEGMENT + 1)).is_some());
        assert!(item_problem(&"x".repeat(MAX_SEGMENT)).is_none());
    }

    /// A right-to-left override or a zero-width space would let one
    /// marketplace's package read on screen as another's while installing
    /// under a different name — refused as a name, and escaped when shown.
    #[test]
    fn deceptive_characters_are_refused_and_escaped() {
        assert!(segment_problem("pay\u{202e}gnp.exe").is_some());
        assert!(segment_problem("gh\u{200b}").is_some());
        assert!(segment_problem("a\u{2066}b").is_some());
        assert!(item_problem("clean\u{200e}").is_some());
        // shown() renders them visible rather than letting them act.
        assert!(!shown("pay\u{202e}gnp").contains('\u{202e}'));
        assert!(!shown("a\u{200b}b").contains('\u{200b}'));
    }

    #[test]
    fn folding_catches_the_collisions_a_filesystem_would_make() {
        assert_eq!(fold("Data-Science/EDA"), "data-science/eda");
        assert_eq!(fold("gh."), "gh");
        assert_ne!(fold("a/b"), fold("a-b"));
        // Composed and decomposed accents are one file on macOS.
        assert_eq!(fold("caf\u{e9}"), fold("cafe\u{301}"));
        assert_ne!(fold("cafe"), fold("caf\u{e9}"));
    }

    /// One path segment holds no separator: only the kinds a plugin-registry
    /// catalog offers are namespaced, and those are split before they get
    /// here.
    #[test]
    fn a_single_segment_may_not_hold_a_separator() {
        assert!(segment_problem("tools/guard").is_some());
        assert!(item_problem("tools/guard").is_none());
    }

    /// A catalog's text reaches a terminal. Control characters are shown as
    /// what they are rather than acted on.
    #[test]
    fn a_refusal_never_carries_the_control_characters_it_refuses() {
        let said = segment_problem("gh\u{1b}[31m\0").unwrap_or_default();
        assert!(!said.contains('\u{1b}'), "{said:?}");
        assert!(!said.contains('\0'), "{said:?}");
        assert!(said.contains("\\u{1b}") && said.contains("\\0"), "{said:?}");
    }
}
