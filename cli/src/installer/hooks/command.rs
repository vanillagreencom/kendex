//! The command a harness config registers, read the way the shell that runs
//! it would.
//!
//! The harness stores one string; whether that string RUNS vstack's script is
//! a shell question, and only splitting it into the words a shell would pass
//! to `execve` can answer it. Everything else here — which word is the one
//! executed, and whether its path is ours — builds on that split.

use std::path::{Path, PathBuf};

/// Path identity for comparison: the canonical path when it exists, so a
/// symlinked or `..`-spelled command still names the same script, and the
/// path exactly as written when it does not.
fn resolved_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Shells that RUN their first operand. `bash <script>` executes the script;
/// the same path in some other program's argument list is data.
const SCRIPT_INTERPRETERS: &[&str] = &["sh", "bash", "dash", "ksh", "zsh", "ash"];

/// Programs that exec the command following their own arguments, with the
/// count of their own non-flag operands first (`timeout 30 bash …`). `env` is
/// not here: it also takes `NAME=VALUE` assignments, so it is walked
/// separately.
const EXEC_PREFIXES: &[(&str, usize)] = &[("nohup", 0), ("setsid", 0), ("timeout", 1)];

/// The program a token names, ignoring the directory it lives in, so
/// `/bin/bash` and `bash` read alike.
fn program_name(token: &str) -> Option<&str> {
    Path::new(token).file_name()?.to_str()
}

/// A `NAME=VALUE` token — what the shell and `env` both read as an
/// environment assignment rather than as the program to run.
fn is_env_assignment(token: &str) -> bool {
    token.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && !name.starts_with(|c: char| c.is_ascii_digit())
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// A shell flag that leaves the first operand as the script the shell runs.
/// `-c` makes that operand a command STRING, `-s` reads the script from
/// stdin, and `-o`/`-O` swallow the next token — after any of those we cannot
/// say what runs, so they are not here. Unknown long flags are refused for
/// the same reason.
fn shell_flag_keeps_operand(flag: &str) -> bool {
    match flag.strip_prefix("--") {
        Some(long) => matches!(
            long,
            "norc" | "noprofile" | "posix" | "login" | "restricted"
        ),
        None => flag.strip_prefix('-').is_some_and(|short| {
            !short.is_empty()
                && short
                    .chars()
                    .all(|c| c.is_ascii_lowercase() && !matches!(c, 'c' | 'o' | 's'))
        }),
    }
}

/// The token the shell would EXECUTE, walking past the prefixes that exec
/// what follows them. `None` when nothing in the command can be proven to run.
///
/// Only an executable position counts. `echo <script>` names our path in an
/// argument list, and reading that as a registration is exactly the fail-open
/// the registration check exists to close.
fn executed_token(tokens: &[String]) -> Option<&str> {
    let mut index = 0;
    // A leading `VAR=value` run is the shell's own environment prefix.
    while tokens
        .get(index)
        .is_some_and(|token| is_env_assignment(token))
    {
        index += 1;
    }
    loop {
        let word = tokens.get(index)?.as_str();
        let name = program_name(word)?;
        if name == "env" {
            index += 1;
            // `env` execs the first operand that is neither an assignment nor
            // one of the flags that take no argument of their own.
            while let Some(token) = tokens.get(index) {
                if token == "--" {
                    index += 1;
                    break;
                }
                if is_env_assignment(token)
                    || matches!(token.as_str(), "-i" | "--ignore-environment")
                {
                    index += 1;
                    continue;
                }
                if token.starts_with('-') {
                    return None;
                }
                break;
            }
            continue;
        }
        if let Some((_, operands)) = EXEC_PREFIXES.iter().find(|(prefix, _)| *prefix == name) {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if token == "--" {
                    index += 1;
                    break;
                }
                if matches!(token.as_str(), "--foreground" | "--preserve-status") {
                    index += 1;
                    continue;
                }
                if token.starts_with('-') {
                    return None;
                }
                break;
            }
            // Past its own operands — a `timeout` duration — sits the command.
            index += operands;
            continue;
        }
        if SCRIPT_INTERPRETERS.contains(&name) {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if token == "--" {
                    index += 1;
                    break;
                }
                if !token.starts_with('-') {
                    break;
                }
                if !shell_flag_keeps_operand(token) {
                    return None;
                }
                index += 1;
            }
            return tokens.get(index).map(String::as_str);
        }
        // Some other program: our path can only be its data.
        return Some(word);
    }
}

/// Does this command RUN the managed script? The script has to sit where the
/// shell would execute it — the command word, or the operand of an
/// interpreter or exec prefix — and the path there has to be ours, so neither
/// `notfoo.sh` nor an unrelated `foo.sh` elsewhere on disk answers for
/// `<root>/hooks/foo.sh`. A command whose target cannot be proven reads as
/// unregistered: a spurious drift line is inspectable, a false clean is not.
///
/// `deferred_root` is the placeholder a project-scope command leaves for run
/// time and what the harness expands it to — `$(git rev-parse
/// --show-toplevel)` for codex, `$CLAUDE_PROJECT_DIR` for claude — so a
/// command a user reshaped by hand is read the way the shell running it will.
pub(super) fn command_targets_hook_script(
    command: &str,
    script_path: &Path,
    deferred_root: Option<(&str, &Path)>,
) -> bool {
    let expanded = match deferred_root {
        Some((placeholder, root)) => command.replace(placeholder, &root.to_string_lossy()),
        None => command.to_string(),
    };
    let Some(words) = shell_words(&expanded) else {
        return false;
    };
    executed_token(&words)
        .is_some_and(|token| resolved_path(Path::new(token)) == resolved_path(script_path))
}

/// A line more than one simple command, or one expanding to text this cannot
/// know. Unquoted, any of these ends the read.
const UNRESOLVABLE_BARE: &[char] = &[
    '$', '`', '|', '&', ';', '<', '>', '(', ')', '\n', '*', '?', '[',
];
/// Inside double quotes only expansion survives — every operator above is
/// ordinary text there, and a path is free to contain it.
const UNRESOLVABLE_QUOTED: &[char] = &['$', '`'];

/// The words a POSIX shell would hand `execve`.
///
/// `None` for a line whose words this cannot settle: an unterminated quote, an
/// expansion, a glob, or an operator that makes the line more than one simple
/// command. The caller asks whether the line runs OUR script, and "nobody
/// parsed it" has to answer no — a spurious drift line is inspectable, a false
/// clean is not.
///
/// The whitespace split this replaces cut `bash '/home/my user/guard.sh'` into
/// three words and then stripped the quote characters off each, so the command
/// vstack ITSELF writes for any install path containing a space read as
/// running something else. That was permanent drift no remedy could clear: the
/// reinstall the report prescribed wrote the very same command back.
fn shell_words(command: &str) -> Option<Vec<String>> {
    let mut words: Vec<String> = Vec::new();
    let mut word = String::new();
    let mut started = false;
    let mut chars = command.chars();
    while let Some(ch) = chars.next() {
        match ch {
            ' ' | '\t' => {
                if started {
                    words.push(std::mem::take(&mut word));
                    started = false;
                }
            }
            // A literal string: every character stands for itself, and only
            // the closing quote ends it.
            '\'' => {
                started = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        c => word.push(c),
                    }
                }
            }
            '"' => {
                started = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        // Inside double quotes a backslash escapes only these;
                        // before anything else it is itself a character.
                        '\\' => match chars.next()? {
                            c @ ('$' | '`' | '"' | '\\') => word.push(c),
                            // A quoted line continuation produces nothing.
                            '\n' => {}
                            c => {
                                word.push('\\');
                                word.push(c);
                            }
                        },
                        c if UNRESOLVABLE_QUOTED.contains(&c) => return None,
                        c => word.push(c),
                    }
                }
            }
            '\\' => {
                started = true;
                match chars.next()? {
                    '\n' => {}
                    c => word.push(c),
                }
            }
            c if UNRESOLVABLE_BARE.contains(&c) => return None,
            c => {
                started = true;
                word.push(c);
            }
        }
    }
    if started {
        words.push(word);
    }
    Some(words)
}

/// One word of a command a HARNESS will execute, written into its settings.
///
/// Deliberately not [`crate::display::shell_arg`]: that one is for commands
/// vstack prints, so it escapes what a terminal would act on. A hook path
/// carrying such a byte still has to be handed to the harness verbatim, or the
/// hook it registers never runs.
pub(super) fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'))
    {
        s.to_string()
    } else {
        let escaped = s.replace('\'', "'\\''");
        format!("'{escaped}'")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn targets(command: &str, script: &str) -> bool {
        command_targets_hook_script(command, Path::new(script), None)
    }

    /// The command vstack WRITES has to read back as the command vstack wrote.
    /// `shell_quote` quotes any path that is not plain, and the whitespace
    /// split that used to read it back cut a quoted path with a space into
    /// three words — so every claude and codex hook on a machine whose install
    /// path contains a space reported "script present but not registered",
    /// forever, because the reinstall the report prescribed wrote the same
    /// command back.
    #[test]
    fn a_quoted_path_round_trips_through_the_command_vstack_writes() {
        for script in [
            "/home/my user/.claude/hooks/guard.sh",
            "/home/o'brien/.claude/hooks/guard.sh",
            "/srv/a b/c d/hooks/guard.sh",
            // Control: the plain path `shell_quote` leaves unquoted.
            "/home/user/.claude/hooks/guard.sh",
        ] {
            let command = format!("bash {}", shell_quote(script));
            assert!(targets(&command, script), "{command}");
            // …and it is still THIS script, not any other.
            assert!(
                !targets(&command, "/home/user/.claude/hooks/other.sh"),
                "{command}"
            );
        }
    }

    /// Quoting decides word boundaries, so the same characters mean different
    /// things in and out of quotes.
    #[test]
    fn words_are_split_the_way_a_shell_splits_them() {
        for (command, expected) in [
            ("bash /a/b.sh", vec!["bash", "/a/b.sh"]),
            ("  bash   /a/b.sh  ", vec!["bash", "/a/b.sh"]),
            ("bash '/a b/c.sh'", vec!["bash", "/a b/c.sh"]),
            ("bash \"/a b/c.sh\"", vec!["bash", "/a b/c.sh"]),
            ("bash /a\\ b/c.sh", vec!["bash", "/a b/c.sh"]),
            // Adjacent quoted and bare runs are ONE word.
            ("bash /a' b'/c.sh", vec!["bash", "/a b/c.sh"]),
            // An empty quoted word is a word.
            ("bash ''", vec!["bash", ""]),
            // Operators are ordinary characters inside quotes.
            ("bash '/a;b|c/d.sh'", vec!["bash", "/a;b|c/d.sh"]),
            ("bash \"/a*b/c.sh\"", vec!["bash", "/a*b/c.sh"]),
            // A backslash escapes only the four characters that need it
            // inside double quotes, and stands for itself before the rest.
            ("bash \"/a\\\"b/c.sh\"", vec!["bash", "/a\"b/c.sh"]),
            ("bash \"/a\\nb/c.sh\"", vec!["bash", "/a\\nb/c.sh"]),
        ] {
            assert_eq!(
                shell_words(command),
                Some(expected.iter().map(|s| s.to_string()).collect::<Vec<_>>()),
                "{command}"
            );
        }
    }

    /// A line whose words cannot be settled is refused outright, so no caller
    /// can read a half-parsed command as a registration.
    #[test]
    fn a_command_that_cannot_be_settled_is_refused_not_guessed() {
        for command in [
            // Unterminated quoting.
            "bash '/a/b.sh",
            "bash \"/a/b.sh",
            "bash /a/b.sh\\",
            // Expansions and substitutions.
            "bash $HOOK/guard.sh",
            "bash \"$HOOK/guard.sh\"",
            "bash `which guard.sh`",
            "bash \"$(dirname x)/guard.sh\"",
            // More than one simple command, or output going elsewhere.
            "bash /a/b.sh; rm -rf /",
            "bash /a/b.sh | tee log",
            "bash /a/b.sh && other",
            "bash /a/b.sh > out",
            "(bash /a/b.sh)",
            // Pathname expansion this cannot resolve without the filesystem.
            "bash /a/*/guard.sh",
            "bash /a/guard?.sh",
        ] {
            assert_eq!(shell_words(command), None, "{command}");
            assert!(!targets(command, "/a/b.sh"), "{command}");
        }
    }

    /// The deferred placeholder is expanded BEFORE the split, so the one
    /// substitution vstack itself writes is the only one that survives.
    #[test]
    fn the_deferred_root_placeholder_is_expanded_before_the_split() {
        let root = Path::new("/srv/my project");
        let script = root.join(".claude/hooks/guard.sh");
        let command = "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"";
        assert!(command_targets_hook_script(
            command,
            &script,
            Some(("$CLAUDE_PROJECT_DIR", root))
        ));
        // Without the expansion the `$` is an expansion like any other.
        assert!(!command_targets_hook_script(command, &script, None));
    }
}
