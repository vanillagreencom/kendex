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

/// A program that execs the command following its own arguments, and the
/// options that program actually defines.
///
/// The options are declared PER PREFIX because they are not a shared
/// vocabulary: `--foreground` and `--preserve-status` belong to `timeout`
/// alone — `nohup` takes no option but `--help`/`--version`, which print and
/// exit, and `setsid` defines neither — so one permissive branch across all of
/// them read `nohup --foreground <script>` as a command that runs the script
/// when it is a nohup that exits 125 having run nothing. An option a prefix
/// does not define means the script is not reached, and that reads as
/// unregistered like every other unprovable command here.
struct ExecPrefix {
    /// Program name, as [`program_name`] reads it.
    name: &'static str,
    /// Its own non-flag operands before the command (`timeout 30 bash …`).
    operands: usize,
    /// Options taking no value of their own.
    flags: &'static [&'static str],
    /// Options taking the next token — or `--name=value` — as their value.
    value_flags: &'static [&'static str],
    /// Whether `NAME=VALUE` assignments may precede the command, as `env`
    /// takes them.
    assignments: bool,
}

impl ExecPrefix {
    /// How many tokens this option consumes, or `None` when the prefix does
    /// not define it — an option a program refuses is a program that never
    /// execs anything.
    fn consume(&self, token: &str) -> Option<usize> {
        if self.assignments && is_env_assignment(token) {
            return Some(1);
        }
        if self.flags.contains(&token) {
            return Some(1);
        }
        if self.value_flags.contains(&token) {
            return Some(2);
        }
        // `--kill-after=30` carries its value in the same token.
        let (long, _) = token.split_once('=')?;
        self.value_flags.contains(&long).then_some(1)
    }
}

/// Every program whose arguments are walked to find the command it execs.
/// `env` is one of them: its `NAME=VALUE` run is the only thing that sets it
/// apart, and that is a field here rather than a branch of its own.
///
/// Each list is the portable set — an option one implementation grew and
/// another rejects would exec nothing there, which is the fail-open again — and
/// options that make the command unknowable are deliberately absent, so they
/// resolve to unregistered: `env -S`/`--split-string` builds the command out
/// of its own value, and `env`'s `--block-signal`-family options take an
/// OPTIONAL value, so nothing can say whether the next token is theirs or the
/// command. `env -0`/`--null` is refused by `env` itself alongside a command.
const EXEC_PREFIXES: &[ExecPrefix] = &[
    ExecPrefix {
        name: "nohup",
        operands: 0,
        flags: &[],
        value_flags: &[],
        assignments: false,
    },
    ExecPrefix {
        name: "setsid",
        operands: 0,
        flags: &["-c", "--ctty", "-f", "--fork", "-w", "--wait"],
        value_flags: &[],
        assignments: false,
    },
    ExecPrefix {
        name: "timeout",
        operands: 1,
        flags: &[
            "-f",
            "--foreground",
            "-p",
            "--preserve-status",
            "-v",
            "--verbose",
        ],
        value_flags: &["-k", "--kill-after", "-s", "--signal"],
        assignments: false,
    },
    ExecPrefix {
        name: "env",
        operands: 0,
        flags: &["-i", "--ignore-environment"],
        value_flags: &["-u", "--unset"],
        assignments: true,
    },
];

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
        if let Some(prefix) = EXEC_PREFIXES.iter().find(|prefix| prefix.name == name) {
            index += 1;
            // Its own options, each judged against what THIS program defines.
            while let Some(token) = tokens.get(index) {
                if token == "--" {
                    index += 1;
                    break;
                }
                let assignment = prefix.assignments && is_env_assignment(token);
                if !token.starts_with('-') && !assignment {
                    break;
                }
                index += prefix.consume(token)?;
            }
            // Past its own operands — a `timeout` duration — sits the command.
            index += prefix.operands;
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
mod tests;
