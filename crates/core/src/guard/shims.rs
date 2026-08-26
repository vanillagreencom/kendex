//! Whether commits are gated, read off the hook files and nothing else.
//!
//! The grammar is closed, and the verdict has three values, not two.
//! Anything the grammar does not describe is **cannot tell** — never armed,
//! never unarmed. Four review rounds of substring searches and reachability
//! guesses each found a new way to report armed for a repository whose
//! commits git does not gate: a comment quoting the marker, a helper git
//! cannot execute, a line that gates but sits somewhere this cannot confirm
//! it runs. Deciding reachability needs a shell parser, and a verifier that
//! guesses fails open — the one direction this answer must never fail in.
//!
//! So a lane is armed when the file is a regular file git can exec, its
//! first line is a POSIX-shell shebang, and its *second* line is byte-equal
//! to the delegating line the installer writes. The helper is armed when its
//! bytes equal the ones the installer generates. Every other shape is
//! reported as itself.
//!
//! This mirrors the shell installer's `--check`, whose grammar
//! `DEVELOPMENT.md` documents; [`super::grammar`] holds the shapes and the
//! test that keeps the two from drifting apart.

use std::path::Path;

use crate::error::Result;

use super::grammar::{HELPER, call_line, helper_body};
use super::{LANES, SKILL};

/// What one artifact is, in the closed grammar's terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Shape {
    /// Exactly what the installer writes. Commits here are gated.
    Armed,
    /// Provably not gating: absent, not a file, no shebang git can run, no
    /// delegating line, or not executable.
    Unarmed,
    /// Outside the grammar. It may gate perfectly well; this cannot tell,
    /// and guessing is what every false "armed" was made of.
    Unknown,
}

/// One artifact's shape and the sentence explaining it.
pub(super) struct Finding {
    pub(super) shape: Shape,
    pub(super) reason: String,
}

fn finding(shape: Shape, reason: impl Into<String>) -> Finding {
    Finding {
        shape,
        reason: reason.into(),
    }
}

/// Whether line 1 is a shell script's shebang at all — the installer's own
/// first gate, and deliberately the permissive one: a dir prefix, an
/// optional `env`, a shell name, then whitespace or end of line. Failing it
/// means git runs something that is not a shell, so the guard line cannot
/// run whatever else is true.
fn is_shell_shebang(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("#!") else {
        return false;
    };
    let mut words = rest.split_whitespace();
    let program = |word: &str| word.rsplit('/').next().unwrap_or(word).to_owned();
    let named = match words.next().map(program).as_deref() {
        Some("env") => words.next().map(program),
        other => other.map(str::to_owned),
    };
    matches!(
        named.as_deref(),
        Some("sh" | "bash" | "dash" | "ksh" | "zsh")
    )
}

/// The interpreters this check will vouch for: a full path, exactly, and
/// nothing after it.
const TRUSTED_INTERPRETERS: [&str; 10] = [
    "/bin/sh",
    "/bin/bash",
    "/bin/dash",
    "/bin/ksh",
    "/bin/zsh",
    "/usr/bin/sh",
    "/usr/bin/bash",
    "/usr/bin/dash",
    "/usr/bin/ksh",
    "/usr/bin/zsh",
];

/// Whether the shebang names an interpreter whose behaviour this check can
/// vouch for. The package's checker applies exactly this rule, and the
/// strictness is the point three times over.
///
/// The whole remainder of the line has to be one of those paths, so **any**
/// option disqualifies it: `#!/bin/sh -n` reads the guard line and executes
/// nothing, which would make an armed-looking hook gate no commit at all.
/// No basename matching, because `#!/usr/bin/env bash` resolves through
/// PATH and what runs is whatever PATH says today. And on the list is not
/// on the disk — `/bin/dash` and `/bin/ksh` are absent from plenty of
/// hosts, and git answers "cannot exec" for every commit rather than
/// running the hook — so the file has to be there and be executable.
///
/// Failing this is *cannot tell*, never unarmed: the hook may gate
/// perfectly well under an interpreter this does not know.
fn is_trusted_interpreter(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("#!") else {
        return false;
    };
    let path = rest.trim();
    if !TRUSTED_INTERPRETERS.contains(&path) {
        return false;
    }
    let path = Path::new(path);
    path.is_file() && is_executable(path)
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// One hook lane, judged against the grammar.
pub(super) fn lane_shape(hooks: &Path, lane: &str) -> Finding {
    let path = hooks.join(lane);
    // A symlink is followed on purpose: git runs whatever the path resolves
    // to, so a link to a well-formed shim is armed and a dangling one is not.
    if !path.exists() {
        return finding(Shape::Unarmed, format!("{lane} is missing"));
    }
    if !path.is_file() {
        return finding(Shape::Unarmed, format!("{lane} is not a file git can run"));
    }
    let Ok(text) = std::fs::read_to_string(&path) else {
        return finding(Shape::Unknown, format!("{lane} could not be read"));
    };
    let mut lines = text.lines();
    let shebang = lines.next().unwrap_or_default();
    if shebang.chars().any(char::is_control) {
        return finding(
            Shape::Unarmed,
            format!("{lane} has a control character in its shebang, so git cannot exec it"),
        );
    }
    if !is_shell_shebang(shebang) {
        return finding(
            Shape::Unarmed,
            format!("{lane} is not a POSIX-shell script, so the guard line cannot run"),
        );
    }
    // The interpreter decides whether the body runs at all, so it is judged
    // before anything in the body is read.
    if !is_trusted_interpreter(shebang) {
        return finding(
            Shape::Unknown,
            format!("{lane} runs under an interpreter this cannot vouch for ({shebang})"),
        );
    }
    let expected = call_line(lane);
    if lines.next().unwrap_or_default() != expected {
        // The line may be further down and gating perfectly well. Where
        // exactly is beyond what a data-only read establishes, so this is
        // unverifiable rather than a "not gated" verdict about a repository
        // that is gated.
        return match text.lines().any(|line| line == expected) {
            true => finding(
                Shape::Unknown,
                format!(
                    "{lane} carries the guard line, but not at line 2 where this can confirm it runs"
                ),
            ),
            false => finding(
                Shape::Unarmed,
                format!("{lane} does not carry the guard line at line 2"),
            ),
        };
    }
    match is_executable(&path) {
        true => finding(Shape::Armed, format!("{lane} is armed")),
        false => finding(
            Shape::Unarmed,
            format!("{lane} is not executable, so git ignores it"),
        ),
    }
}

/// The helper, judged by its bytes.
///
/// The marker is a comment and anything can carry one: an executable file
/// holding that comment and `exit 0` would pass every cheaper test while
/// gating nothing. Only the bytes settle what the helper does.
pub(super) fn helper_shape(hooks: &Path, scripts_dir: &Path) -> Finding {
    let path = hooks.join(HELPER);
    if !path.exists() {
        return finding(Shape::Unarmed, format!("helper {HELPER} is missing"));
    }
    if path.is_symlink() || !path.is_file() {
        return finding(
            Shape::Unarmed,
            format!("helper {HELPER} is not a regular file"),
        );
    }
    if !is_executable(&path) {
        return finding(
            Shape::Unarmed,
            format!(
                "helper {HELPER} is not executable, so every commit is blocked rather than guarded"
            ),
        );
    }
    let Ok(text) = std::fs::read_to_string(&path) else {
        return finding(Shape::Unknown, format!("helper {HELPER} could not be read"));
    };
    match text == helper_body(&scripts_dir.to_string_lossy()) {
        true => finding(
            Shape::Armed,
            format!("helper {HELPER} is the installed one"),
        ),
        false => finding(
            Shape::Unknown,
            format!(
                "helper {HELPER} is not the one this install generates, so what it runs cannot be verified"
            ),
        ),
    }
}

/// Every artifact's shape in one hooks directory, folded.
///
/// Definitive drift outranks something unmeasured: "a shim is provably
/// gone" already answers the question, while unmeasured-only stays cannot
/// tell.
pub(super) fn directory_shape(hooks: &Path, scripts_dir: &Path) -> (Shape, String) {
    let mut findings = vec![helper_shape(hooks, scripts_dir)];
    findings.extend(LANES.iter().map(|lane| lane_shape(hooks, lane)));
    let reasons: Vec<&str> = findings
        .iter()
        .filter(|f| f.shape != Shape::Armed)
        .map(|f| f.reason.as_str())
        .collect();
    let shape = if findings.iter().any(|f| f.shape == Shape::Unarmed) {
        Shape::Unarmed
    } else if findings.iter().any(|f| f.shape == Shape::Unknown) {
        Shape::Unknown
    } else {
        Shape::Armed
    };
    (shape, reasons.join("; "))
}

/// Shims left in a hooks directory with no package to run them, or `None`
/// where the directory holds none of ours.
///
/// Read without a package to compare the helper's bytes against, so the
/// helper is judged only by its marker being absent or present — the one
/// case where that is all there is. What matters here is the lanes: a hook
/// carrying the delegating line at line 2 fails every commit closed once
/// the scripts it delegates to are gone.
pub(super) fn orphaned_shims(hooks: &Path) -> Result<Option<String>> {
    let mut found = Vec::new();
    for lane in LANES {
        if lane_shape(hooks, lane).shape != Shape::Unarmed {
            found.push(lane.to_owned());
        }
    }
    if found.is_empty() {
        return Ok(None);
    }
    if hooks.join(HELPER).exists() {
        found.push(HELPER.to_owned());
    }
    Ok(Some(format!(
        "{} carries the package's shims ({}) with no {SKILL} package to run them — commits are blocked until they go",
        hooks.display(),
        found.join(", ")
    )))
}
