//! The second armed shape: a hand-wired hook that runs the installed script
//! directly.
//!
//! A repository whose `core.hooksPath` points somewhere else cannot get the
//! installer's shims — it writes into `.git/hooks`, which git is not
//! reading — so the stand-down message tells people to wire that directory's
//! hooks at these scripts themselves. Those hooks gate commits perfectly
//! well and carry no delegating line, so a check that knew only the first
//! shape would call every one of them unarmed.
//!
//! The grammar is closed and whole-file: a shebang, comments, and exactly
//! ONE command, and that command is this install's entry point for the hook
//! with an argument list that still lets it fail the commit. Anything else
//! is cannot-tell.
//!
//! Every clause below is load-bearing, and the shell's own comments say why
//! — a scan that accepted the entry point anywhere executable-looking kept
//! finding new ways to report `armed` for a repository git does not gate.

use std::path::{Path, PathBuf};

use super::shims::Shape;

/// Whether one hook file is a hand-wired call to `scripts_dir/hook`.
pub(super) fn shape(path: &Path, hook: &str, scripts_dir: &Path, worktree: &Path) -> Shape {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Shape::Unknown;
    };
    let Ok(own_dir) = std::fs::canonicalize(scripts_dir) else {
        return Shape::Unknown;
    };
    let (mut seen, mut matched, mut named, mut opaque) = (0usize, false, false, false);

    // Split on newlines alone, never `lines()`: that strips a carriage
    // return, and the shell does not. A CR is part of the word, so
    // `exec\r` is a command named `exec\r` and `#!/bin/sh\r` names an
    // interpreter that is not there — both have to stay visible to the
    // checks below or a CRLF hook reads as one this understands.
    for line in text.split('\n') {
        // Blanks, not all whitespace: the shell separates tokens on blanks,
        // so a line starting with CR runs a command named `\rexec`.
        let body = line.trim_start_matches([' ', '\t']);
        if body.is_empty() || body.starts_with('#') {
            continue;
        }
        // Counted before any classification: a line this cannot read still
        // runs, and skipping it uncounted would leave a later entry point
        // looking like the only command in the file.
        seen += 1;
        // Tabs are ordinary separators; only control characters the shell
        // keeps inside a word make a line unreadable.
        if body.replace('\t', " ").chars().any(char::is_control) {
            opaque = true;
            continue;
        }
        let mut rest = body;
        if let Some(after) = rest.strip_prefix("exec")
            && after.starts_with([' ', '\t'])
        {
            rest = after.trim_start_matches([' ', '\t']);
            // `exec -a NAME cmd` runs cmd under another argv[0], so the
            // command word is two tokens further along.
            if rest.starts_with('-') {
                opaque = true;
                continue;
            }
        }
        // `NAME=value cmd` runs cmd with an env prefix; the command word is
        // further along, and reading the assignment as the command reported
        // a hook that gates as not gated.
        if let Some((name, _)) = rest.split_once('=')
            && !name.is_empty()
            && name.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            opaque = true;
            continue;
        }
        let Some((cmd, tail, quoting)) = split_command(rest) else {
            continue;
        };
        // The word the SHELL runs, not the one written down. Single quotes
        // make everything literal; double quotes still expand `$` and
        // backticks and honour backslashes; an unquoted word additionally
        // globs and expands `~`. A checkout path containing `$slot` passed
        // every file test while /bin/sh ran whatever `slot` pointed at.
        let unstable = match quoting {
            Quoting::Single => false,
            Quoting::Double => cmd.contains(['$', '`', '\\']),
            Quoting::None => cmd.contains(['$', '`', '\\', '*', '?', '[', ']', '{', '}', '~']),
        };
        if unstable {
            opaque = true;
            continue;
        }
        // A tail has to be separated from the command by a real blank: the
        // shell concatenates `"…/commit-msg""$1"` into one word.
        if !(tail.is_empty() || tail.starts_with([' ', '\t'])) {
            continue;
        }
        if Path::new(cmd).file_name().is_none_or(|name| name != hook) {
            continue;
        }
        // git runs a hook from the work tree's top level, so a relative
        // command word resolves against THAT — never against wherever this
        // check happens to be running. Judging it from the process's own
        // directory answers a question about a different file, and in a
        // nested project it is reliably the wrong one.
        let candidate = match Path::new(cmd).is_absolute() {
            true => PathBuf::from(cmd),
            false => worktree.join(cmd),
        };
        let candidate = candidate.as_path();
        if !candidate.is_file() || !super::shims::is_executable(candidate) {
            continue;
        }
        // A path is not an identity: an executable copy of /bin/true can
        // wear this name and pass every file test while gating nothing. Only
        // which file it resolves to settles it.
        if candidate.is_symlink() {
            named = true;
            continue;
        }
        let Some(parent) = candidate.parent() else {
            continue;
        };
        let Ok(dir) = std::fs::canonicalize(parent) else {
            named = true;
            continue;
        };
        if dir != own_dir {
            continue;
        }
        named = true;
        // The command word is the entry point; the tail decides whether
        // running it can still fail the commit. The accepted arguments
        // differ per hook, and swapping them breaks the gate rather than
        // weakening it: `pre-commit` takes none and exits 2 on any, while
        // `commit-msg` needs git's message path or it reads inherited stdin
        // and rejects every commit as an empty message.
        let tail = tail.trim_matches([' ', '\t']);
        let tail = tail.strip_suffix(" || exit $?").unwrap_or(tail);
        matched = match hook {
            "pre-commit" => tail.is_empty() || tail == "\"$@\"",
            _ => tail == "\"$1\"" || tail == "\"$@\"",
        };
    }

    // The verdict waits for the whole file: deciding on the first command
    // would call a hook that runs `set -e` before the entry point ungated.
    if seen == 1 && matched && !opaque {
        return Shape::Armed;
    }
    // The entry point IS the command and only its argument list is outside
    // the allowlist — a trailing comment, an extra argument. That may gate;
    // this cannot say, so it says so rather than calling it ungated.
    if named || opaque {
        return Shape::Unknown;
    }
    // Exactly one command and it is not the entry point at all: recognisable,
    // and recognisably not a guard. Everything else is a shape whose
    // reachability this does not get to guess at.
    match seen <= 1 {
        true => Shape::Unarmed,
        false => Shape::Unknown,
    }
}

enum Quoting {
    None,
    Single,
    Double,
}

/// The command word and what follows it, honouring one layer of quoting so
/// a path containing a space stays one word.
fn split_command(rest: &str) -> Option<(&str, &str, Quoting)> {
    for (mark, quoting) in [('"', Quoting::Double), ('\'', Quoting::Single)] {
        if let Some(after) = rest.strip_prefix(mark) {
            let end = after.find(mark)?;
            return Some((&after[..end], &after[end + 1..], quoting));
        }
    }
    let end = rest.find([' ', '\t']).unwrap_or(rest.len());
    Some((&rest[..end], &rest[end..], Quoting::None))
}
