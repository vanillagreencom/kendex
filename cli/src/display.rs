//! Everything vstack SHOWS a human or an agent passes through here: the
//! credential redaction, the control-character escape, the length bound, and
//! the POSIX quoting that makes a printed command safe to paste.
//!
//! One home, because the failure these prevent is a value that one renderer
//! scrubbed and another did not — a token in a CI log, an escape sequence
//! driving a terminal, or a copy-paste remedy that executes the substitution
//! it was supposed to name.

use std::path::Path;

/// How much free text (a source string, a parse failure, a name) may reach an
/// agent's context on one report line.
pub(crate) const DISPLAY_LIMIT: usize = 120;

/// [`DISPLAY_LIMIT`] for a diagnostic that IS the remedy — a refusal names the
/// cache entry and the next step, and a cache root is a full path, so the
/// prose bound cut the instruction off. Still bounded by construction, just
/// wide enough to carry a sentence with a path in it.
const REASON_LIMIT: usize = DISPLAY_LIMIT * 4;

/// Remove credentials from a source string. Applied at report construction,
/// so every consumer — human report, quiet hook line, `--json` on stdout, CI
/// logs quoting either — sees credential-free strings.
///
/// One redaction, shared with every source diagnostic vstack prints: a token
/// shape that one implementation handled and another did not is a token in a
/// CI log. Which half of a userinfo is a secret is a question about the
/// transport's grammar, and [`crate::refresh_sources::remote_source_display`]
/// is where that grammar lives.
///
/// Only a REMOTE source is put through that grammar. `?` and `#` are a URL's
/// query and fragment, where a token lives, but ordinary characters in a
/// directory name — redacting them out of a local path corrupted the path
/// instead of protecting anything, and the remedy command built from it named
/// a directory that does not exist. Which of the two a source is, is
/// [`crate::refresh_sources::looks_like_remote_source`]'s answer, the same
/// classifier resolution itself uses: a second notion of remote-looking is how
/// two readers of one fact disagree. A local path still loses everything a
/// terminal would act on, and is still quoted by [`shell_arg`] inside a
/// command — that is what makes it safe.
pub(crate) fn scrub_source_credentials(text: &str) -> String {
    // UNCONDITIONALLY, because the gate that used to stand here asked the
    // wrong question. `looks_like_remote_source` answers whether the parser
    // can USE a spelling, not whether it carries a secret — and a spelling
    // malformed enough to parse as neither URL nor scp-like is exactly the one
    // that carries a secret nothing has refused yet. `https:/TOKEN@host/repo`
    // failed the gate and fell to bare escaping, so the token reached a
    // report header and a paste-ready command in full while the same string
    // rendered redacted two clauses away.
    //
    // Safe for a plain local path: `redact_stray_userinfo` only rewrites a
    // bare `user@` where the spelling says a username cannot appear, and a
    // path has no scheme, so its `@` is left alone.
    crate::refresh_sources::remote_source_display(text)
}

/// Characters a shell passes through untouched, so an argument built only
/// from them needs no quoting at all.
fn is_shell_safe(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '@' | ':' | '=' | '-' | ',' | '+')
}

/// One shell word of a command vstack PRINTS for a human to paste.
///
/// Never truncated — an elided argument is a command that cannot work — and
/// single-quoted whenever it holds anything a shell would interpret, so the
/// pasted command runs on the literal string rather than on whatever `$`,
/// backtick, or quote it happened to contain. Anything a terminal would act
/// on rather than print is escaped first, through the same escape every other
/// displayed string gets.
///
/// This is the ONLY place a displayed command word is built. A renderer that
/// interpolates a raw value into a command string is how
/// `vstack add https://host/team/$(id).git` became a remedy that runs `id`.
///
/// Not for a command vstack EXECUTES: those must carry the value byte for
/// byte, so they quote without escaping or redacting anything
/// ([`crate::installer::hooks`]'s settings.json commands and
/// `refresh_sources`' `GIT_SSH_COMMAND` build their own words).
pub(crate) fn shell_arg(text: &str) -> String {
    let escaped = crate::refresh_sources::escape_unprintable(text);
    if !escaped.is_empty() && escaped.chars().all(is_shell_safe) {
        return escaped;
    }
    // POSIX single-quoting: nothing inside `'…'` is special, and the one
    // character that cannot appear there is spliced back in as `'\''`.
    format!("'{}'", escaped.replace('\'', r"'\''"))
}

/// [`shell_arg`] for a path.
pub(crate) fn shell_arg_path(path: &Path) -> String {
    shell_arg(&path.to_string_lossy())
}

/// A source rendered INSIDE a copy-paste command: credential-scrubbed like
/// prose, then quoted as the shell word it is.
pub(crate) fn command_arg(text: &str) -> String {
    shell_arg(&scrub_source_credentials(text))
}

/// Credential redaction for a string that may be a SENTENCE rather than one
/// source: an error, a refusal, a subprocess's last line, a lock entry's name.
///
/// The source grammar's redactions answer questions about one source string —
/// [`crate::refresh_sources::remote_source_display`] cuts everything after the
/// first `?` because that is a URL's query, where a token lives. In a sentence
/// it is a question mark, and applying the source rule to prose truncated
/// diagnostics mid-word and appended a `<redacted>` that named nothing.
///
/// So the redaction is applied to the words that could carry a credential —
/// the ones spelled with an authority — and the sentence around them is left
/// readable. Escaping runs over the WHOLE string first, so a control character
/// is rendered as its escape rather than splitting a word.
///
/// This is what a REASON gets scrubbed with, at render time and at report
/// construction alike — a sentence handed to the source redaction lost
/// everything after its first question mark.
pub(crate) fn scrub_prose(text: &str) -> String {
    let escaped = crate::refresh_sources::escape_unprintable(text);
    let carries_authority = |word: &str| word.contains('@') || word.contains("://");
    if !carries_authority(&escaped) {
        return escaped;
    }
    escaped
        .split_inclusive(char::is_whitespace)
        .map(|chunk| {
            let (word, tail) = chunk.split_at(chunk.trim_end().len());
            if carries_authority(word) {
                format!("{}{tail}", scrub_source_credentials(word))
            } else {
                chunk.to_string()
            }
        })
        .collect()
}

/// Defensive rendering of text that did not pass through
/// `is_safe_item_name` (source strings, parse failures, agent-declared
/// skill references): credentials are removed, anything a terminal would act
/// on rather than print is escaped so nothing can start a new line or drive a
/// terminal, and anything long is truncated — an item is never classified on
/// its length, only shortened when shown.
pub(crate) fn display_text(text: &str) -> String {
    display_bounded(text, DISPLAY_LIMIT)
}

/// [`display_text`] for a cause-and-remedy sentence; see [`REASON_LIMIT`].
pub(crate) fn display_reason(text: &str) -> String {
    display_bounded(text, REASON_LIMIT)
}

fn display_bounded(text: &str, limit: usize) -> String {
    let scrubbed = scrub_prose(text);
    if scrubbed.chars().count() <= limit {
        return scrubbed;
    }
    let kept: String = scrubbed.chars().take(limit).collect();
    format!("{kept}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shell_word_quotes_every_metacharacter() {
        assert_eq!(shell_arg("owner/repo"), "owner/repo");
        assert_eq!(shell_arg("/src/$VAR/repo"), "'/src/$VAR/repo'");
        assert_eq!(shell_arg("/src/`id`/repo"), "'/src/`id`/repo'");
        assert_eq!(shell_arg("/src/a;rm -rf b"), "'/src/a;rm -rf b'");
        assert_eq!(shell_arg("/src/it's/repo"), r"'/src/it'\''s/repo'");
        assert_eq!(shell_arg(""), "''");
    }

    #[test]
    fn a_shell_word_escapes_what_a_terminal_would_act_on() {
        let quoted = shell_arg("/src/a\u{1b}[2Kb");
        assert!(
            !quoted.contains('\u{1b}'),
            "escape survived into a printed command: {quoted}"
        );
        assert!(quoted.starts_with('\''), "an escaped word is quoted");
    }

    #[test]
    fn a_shell_word_is_never_truncated() {
        let long = format!("/sources/{}", "a".repeat(4 * DISPLAY_LIMIT));
        assert_eq!(shell_arg(&long), long, "commands never truncate");
    }

    #[test]
    fn prose_keeps_its_punctuation_and_still_loses_its_credentials() {
        // The source rule reads `?` and `#` as a URL's query and cuts there.
        // A diagnostic is a sentence: it keeps them.
        assert_eq!(
            display_text("could not read the cache: is it there?"),
            "could not read the cache: is it there?"
        );
        assert_eq!(
            display_text("error #42 while parsing"),
            "error #42 while parsing"
        );
        assert_eq!(
            display_text("clone of file:foo failed"),
            "clone of file:foo failed"
        );

        // A URL quoted inside a sentence is still scrubbed as a URL, query
        // and userinfo alike.
        assert_eq!(
            display_text("cloning https://user:ghp_secret@github.com/o/r failed"),
            "cloning https://user:<redacted>@github.com/o/r failed"
        );
        assert_eq!(
            display_text("fetch https://github.com/o/r?access_token=ghp_secret timed out"),
            "fetch https://github.com/o/r?<redacted> timed out"
        );
        // Control: ssh keeps the account that picks the key.
        assert_eq!(
            display_text("cloning ssh://git@example.com/o/r failed"),
            "cloning ssh://git@example.com/o/r failed"
        );
    }

    #[test]
    fn prose_escapes_what_a_terminal_would_act_on_without_splitting_words() {
        assert_eq!(display_text("a\x1bb\nc"), r"a\u{1b}b\u{a}c");
    }

    /// A local source is a PATH, not a URL. `?` and `#` are a query and a
    /// fragment in one and ordinary characters in the other, so redacting them
    /// out of a local path corrupted the path rather than protecting anything
    /// — the remedy command then named a directory that does not exist.
    #[test]
    fn a_local_source_path_keeps_the_punctuation_a_url_would_lose() {
        for local in [
            "/sources/what?why#now/vstack",
            "/sources/team#2/vstack",
            "~/sources/is-it-here?/vstack",
        ] {
            assert_eq!(scrub_source_credentials(local), local, "{local}");
        }
        assert_eq!(
            command_arg("/sources/what?why#now/vstack"),
            "'/sources/what?why#now/vstack'"
        );

        // Control: a remote URL's query and userinfo are still where a token
        // lives, and both still go.
        assert_eq!(
            scrub_source_credentials("https://github.com/o/r?access_token=ghp_secret"),
            "https://github.com/o/r?<redacted>"
        );
        assert_eq!(
            command_arg("https://user:ghp_secret@github.com/o/r?k=v"),
            "'https://user:<redacted>@github.com/o/r?<redacted>'"
        );
        // Control: an ssh account is the spelling, not a secret.
        assert_eq!(
            command_arg("ssh://git@example.com/o/r"),
            "ssh://git@example.com/o/r"
        );
        // Control: a local path still loses what a terminal would act on, and
        // is still quoted as one inert shell word.
        assert!(!scrub_source_credentials("/sources/a\u{1b}[2Kb").contains('\u{1b}'));
        assert_eq!(
            command_arg("/sources/$(id)?x/repo"),
            "'/sources/$(id)?x/repo'"
        );
    }
}
