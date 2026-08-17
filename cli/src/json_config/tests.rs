//! The rule both halves of this module answer to: what a harness reads,
//! vstack reads; what a harness refuses, vstack refuses and never rewrites.

use super::*;

/// A file no other test can be holding. Tests run concurrently in one
/// process, and a path keyed on the label and the pid alone was shared by
/// every call — two tests writing their own document to it and reading
/// each other's, which fails on whichever lost the race.
fn tmpfile(label: &str, content: &str) -> std::path::PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let nth = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "vstack-json-config-{label}-{}-{nth}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    std::fs::write(&path, content).unwrap();
    path
}

fn refusal(content: &str) -> String {
    let path = tmpfile("refused", content);
    let err = read(&path, &HOOKS_CONFIG)
        .expect_err("a document that deviates from the schema must be an error");
    let _ = std::fs::remove_file(&path);
    format!("{err:#}")
}

/// Every shape on the read path, refused at the value that deviates —
/// not at the outermost one that happens to be checked first.
#[test]
fn a_deviation_anywhere_on_the_path_names_itself() {
    for (document, expected) in [
        ("[]", "the document is an array, expected an object"),
        (r#"{"hooks": []}"#, "hooks is an array, expected an object"),
        (
            r#"{"hooks": {"SessionStart": {"command": "x"}}}"#,
            "hooks.SessionStart is an object, expected an array",
        ),
        (
            r#"{"hooks": {"SessionStart": ["bash x.sh"]}}"#,
            "hooks.SessionStart[0] is a string, expected an object",
        ),
        (
            r#"{"hooks": {"SessionStart": [{"hooks": {}}]}}"#,
            "hooks.SessionStart[0].hooks is an object, expected an array",
        ),
        (
            r#"{"hooks": {"SessionStart": [{"hooks": ["bash x.sh"]}]}}"#,
            "hooks.SessionStart[0].hooks[0] is a string, expected an object",
        ),
        (
            r#"{"hooks": {"SessionStart": [{"hooks": [{"command": 7}]}]}}"#,
            "hooks.SessionStart[0].hooks[0].command is a number, expected a string",
        ),
        (
            r#"{"hooks": {"PreToolUse:Bash": [1]}}"#,
            "hooks.PreToolUse:Bash[0] is a number, expected an object",
        ),
        // A field the reader INTERPRETS, so a value of the wrong type is a
        // deviation and not a fact: read as "no matcher", this answered for a
        // matcherless hook's registration.
        (
            r#"{"hooks": {"SessionStart": [{"matcher": 42, "hooks": [{"command": "bash x.sh"}]}]}}"#,
            "hooks.SessionStart[0].matcher is a number, expected a string",
        ),
        (
            r#"{"hooks": {"PreToolUse": [{"matcher": ["Bash"], "hooks": []}]}}"#,
            "hooks.PreToolUse[0].matcher is an array, expected a string",
        ),
        (
            r#"{"hooks": {"odd key": 1}}"#,
            r#"hooks["odd key"] is a number, expected an array"#,
        ),
    ] {
        let message = refusal(document);
        assert!(
            message.contains(expected),
            "{document} must report {expected:?}: {message}"
        );
        assert!(
            message.contains("config.json"),
            "…and name the file: {message}"
        );
    }
}

/// The other half of the rule: everything a harness legitimately holds
/// reads, so refusing is never the general case. A key vstack reads that
/// is simply ABSENT is a document fact, not a deviation.
#[test]
fn a_document_off_vstacks_path_reads() {
    for document in [
        "{}",
        r#"{"model": "opus", "env": {"K": "V"}}"#,
        r#"{"hooks": {}}"#,
        r#"{"hooks": {"SessionStart": []}}"#,
        r#"{"hooks": {"SessionStart": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash x.sh", "timeout": 30}]}]}}"#,
        // An entry with no handlers at all, and a handler with no
        // command: neither can be vstack's registration, and no writer
        // replaces either.
        r#"{"hooks": {"Stop": [{"matcher": "*"}]}}"#,
        r#"{"hooks": {"Stop": [{"hooks": [{"type": "future"}]}]}}"#,
        // An absent matcher is what a matcherless hook registers as — a
        // document fact, never a deviation.
        r#"{"hooks": {"SessionStart": [{"hooks": [{"command": "bash x.sh"}]}]}}"#,
        // The `Any` cases, proved by the shapes vstack only PRESERVES: keys
        // no reader here consults, at types no reader here expects. Refusing
        // one would block install and removal over a value vstack never uses.
        r#"{"hooks": {"Stop": [{"hooks": [{"command": "bash x.sh", "type": 7, "timeout": "soon"}], "note": {"mine": true}}]}}"#,
        r#"{"statusLine": 7, "permissions": ["not an object"]}"#,
    ] {
        let path = tmpfile("accepted", document);
        let doc = read(&path, &HOOKS_CONFIG)
            .unwrap_or_else(|err| panic!("{document} must read: {err:#}"));
        assert!(doc.is_some(), "{document} must read as a document");
        let _ = std::fs::remove_file(&path);
    }
}

/// A missing file and an empty one are the same absence, and neither is
/// an error: a writer starts from its own default.
#[test]
fn a_missing_or_empty_file_is_absent_not_unreadable() {
    let path = tmpfile("empty", "   \n");
    assert!(read(&path, &HOOKS_CONFIG).unwrap().is_none());
    std::fs::remove_file(&path).unwrap();
    assert!(read(&path, &HOOKS_CONFIG).unwrap().is_none());
}

/// A key long enough to crowd out the path it sits in is shortened, and
/// the path around it survives.
#[test]
fn a_long_key_is_bounded_in_the_reported_path() {
    let key = "k".repeat(200);
    let message = refusal(&format!(r#"{{"hooks": {{"{key}": 1}}}}"#));
    assert!(message.contains("…"), "the key is elided: {message}");
    assert!(
        message.len() < 200,
        "the reported path stays bounded: {message}"
    );
    assert!(
        message.contains("expected an array"),
        "and still says what was wrong: {message}"
    );
}

/// The control that keeps the fix from becoming a blanket one: claude's
/// `settings.json`, codex's `hooks.json` and Pi's `settings.json` go to
/// strict parsers in their own harnesses, so a comment in one of those IS a
/// broken file and must stay Unreadable.
#[test]
fn a_comment_in_a_strict_harness_config_is_still_unreadable() {
    for (label, config) in [
        ("claude", &CLAUDE_SETTINGS),
        ("codex", &HOOKS_CONFIG),
        ("pi", &PI_SETTINGS),
    ] {
        let path = tmpfile(
            label,
            "{\n  // this harness cannot read this\n  \"hooks\": {}\n}\n",
        );
        let err = read(&path, config)
            .expect_err("a comment in a strictly parsed config is a broken file");
        assert!(
            format!("{err:#}").contains("is not valid JSON"),
            "{label}: {err:#}"
        );
        let _ = std::fs::remove_file(&path);
    }
}
