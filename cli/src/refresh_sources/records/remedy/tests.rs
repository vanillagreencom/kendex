//! What a caller is TOLD about a source that produced nothing: the cause, the
//! command, and the shapes that get no command at all.
//!
//! Every string here reaches a terminal, a log or a paste buffer, so the two
//! properties under test are that a credential never survives into one and
//! that whatever IS offered as a command can actually be run.

use super::*;
use crate::refresh_sources::looks_like_remote_source;

/// A credential URL malformed enough to evade `parse_remote_url` is
/// classified as a local path, and that fallback used to print it
/// verbatim — so `check`, `verify` and `refresh` leaked legacy lock-file
/// secrets to their logs.
#[test]
fn a_malformed_credential_source_is_redacted_when_reported_missing() {
    for source in [
        "https:/user:ghp_SECRET@github.com/owner/repo",
        "user:ghp_SECRET@github.com/owner/repo",
        "/srv/user:ghp_SECRET@host/repo",
    ] {
        let cause = absent_source_reason(source);
        let note = absent_source_note(source, None, false);
        for text in [&cause, &note] {
            assert!(!text.contains("ghp_SECRET"), "{source}: {text}");
        }
        // A pasteable argument is the RAW string, so a source whose display
        // has to hide part of itself is never handed back as one — the remedy
        // would print exactly what the cause took care not to.
        assert!(
            !note.contains("vstack add"),
            "{source}: no command may carry a credential: {note}"
        );
        // Where the source is named at all it is through the redacting
        // display, so nothing is silently dropped either.
        if cause.contains(source.trim_start_matches("https:/")) {
            panic!("{source}: named verbatim: {cause}");
        }
    }
    // Control: a source with nothing to hide is named in full AND handed back
    // as a command, so the rule above is about the credential and not about
    // withholding commands generally.
    assert!(absent_source_note("/srv/vstack", None, false).contains("vstack add"));
    // A lock that recorded no source at all has nothing to re-add, so it is
    // offered no command either — `vstack add \'\'` is not one.
    assert_eq!(
        absent_source_note("   ", None, false),
        "source not found (none recorded)"
    );
    // A plain missing path is still named in full.
    assert_eq!(
        absent_source_reason("/srv/vstack"),
        "source not found: /srv/vstack"
    );
    assert_eq!(
        absent_source_note("/srv/vstack", None, false),
        "source not found: /srv/vstack — run `vstack add /srv/vstack`"
    );
}

/// The restoration command is meant to be PASTED, so the source arrives in it
/// as a shell word. `RemoteSource` accepts a URL whose path carries shell
/// syntax, and interpolating its display form handed the reader a command that
/// ran the substitution instead of naming the repository.
#[test]
fn a_restoration_command_passes_its_source_literally() {
    let hostile = "https://host.example/team/$(id).git";
    let reason = absent_source_note(hostile, None, false);
    assert!(
        looks_like_remote_source(hostile),
        "the fixture must take the remote branch"
    );
    assert!(
        reason.contains(&format!("`vstack add '{hostile}'`")),
        "the argument must be single-quoted and inert: {reason}"
    );
    // And it really is one inert argument to a real shell.
    let arg = crate::display::command_arg(hostile);
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("printf '%s' {arg}"))
        .output()
        .expect("sh runs");
    assert_eq!(String::from_utf8_lossy(&out.stdout), hostile);

    // Control: the same source's PROSE mention is still scrubbed, and long
    // prose still truncates while the command never does.
    let long = format!("https://host.example/team/{}.git", "a".repeat(400));
    assert!(
        crate::display::display_text(&long).ends_with('…'),
        "prose truncates"
    );
    assert!(
        absent_source_note(&long, None, false).contains(&long),
        "a command argument is never elided"
    );

    // Control: an ordinary source renders unquoted, exactly as before.
    assert_eq!(
        absent_source_note("https://github.com/owner/repo", None, false),
        "remote cache not present — run `vstack add https://github.com/owner/repo`"
    );
    // Control: the CAUSE alone names no command, so the surface that builds a
    // report out of it does not print one twice.
    assert_eq!(
        absent_source_reason("https://github.com/owner/repo"),
        "remote cache not present"
    );
}

/// No surface may hand back a spelling whose display has to hide part of
/// itself. The gate this replaced asked whether the PARSER could use a
/// spelling, not whether it carried a secret — and the spelling malformed
/// enough that no parser accepts it is exactly the one carrying a secret
/// nothing has refused yet.
#[test]
fn a_token_no_parser_recognises_never_becomes_a_pasteable_argument() {
    let hostile = "https:/s3cr3ttoken@example.invalid/team/repo";
    assert!(
        !looks_like_remote_source(hostile),
        "the fixture must be the shape the old gate let through"
    );
    assert_eq!(restore_source_argument(hostile, None), None);
    for text in [
        absent_source_reason(hostile),
        absent_source_note(hostile, None, false),
        crate::display::scrub_source_credentials(hostile),
        crate::display::command_arg(hostile),
    ] {
        assert!(!text.contains("s3cr3ttoken"), "{text}");
    }
    // Control: the same shape with nothing to hide is still handed back, so
    // the rule is about the secret and not about the spelling being odd.
    let plain = "https:/example.invalid/team/repo";
    assert_eq!(
        restore_source_argument(plain, None).as_deref(),
        Some(plain),
        "a malformed spelling with no secret is still restorable"
    );
}

/// The command has to work where it is printed. A global entry's remedy needs
/// `-g`; without it the paste installs into the PROJECT scope, exits 0, and
/// leaves the global entry exactly as broken.
#[test]
fn the_printed_command_carries_the_scope_it_repairs() {
    assert_eq!(
        absent_source_note("/srv/vstack", None, true),
        "source not found: /srv/vstack — run `vstack add -g /srv/vstack`"
    );
    assert_eq!(
        absent_source_note("/srv/vstack", None, false),
        "source not found: /srv/vstack — run `vstack add /srv/vstack`"
    );
    // One place decides the flag, so `check`'s report and the printed lines
    // cannot drift apart.
    assert_eq!(scope_flag(true), " -g");
    assert_eq!(scope_flag(false), "");
}
