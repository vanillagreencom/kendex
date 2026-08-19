//! How a source is shown to a human. Display only — selection and installation
//! carry the raw source, and everything printed here is credential-scrubbed,
//! because a lock or registry written by an earlier vstack can still hold a
//! `https://user:token@host/…` remote that would otherwise reach terminal
//! scrollback and captured logs.

use super::*;

/// How a source is shown to a human — the scope summary and the TUI source
/// selector both print this. Display only: selection and installation carry
/// the raw source, and this string is credential-scrubbed because a
/// `https://user:token@host/…` remote would otherwise print its token into
/// terminal scrollback and captured logs.
pub(in crate::commands::add) fn source_label(source: &str) -> String {
    if Path::new(source).exists() {
        // A lock-recorded local path is untrusted text like any other: a
        // matching directory whose name carries an escape would put it on the
        // picker row. Through the same redacting display as every other source
        // diagnostic — a credential-looking string can name a real path.
        return format!(
            "local: {}",
            crate::refresh_sources::remote_source_display(source)
        );
    }

    // The repository a GitHub remote NAMES, through the one parser that
    // answers that question. The prefix trimming this replaces knew three
    // spellings and left every other one long, so an `ssh://` remote and an
    // `https://` one for the same repository sat on two differently labelled
    // rows. A slug is charset-gated where it is minted, so nothing a
    // credential or a terminal acts on can reach a picker row through it.
    if let Some(slug) = crate::config::parse_github_slug(source) {
        return slug;
    }

    // Not GitHub, so there is no identity to render — the recorded spelling,
    // minus what names no part of the repository. A registry or lock written
    // by an earlier vstack can still hold a credential URL; a picker row is
    // one of the places that would print it.
    let display = crate::refresh_sources::remote_source_display(source);
    let trimmed = display.trim_end_matches('/');
    trimmed.strip_suffix(".git").unwrap_or(trimmed).to_string()
}
