//! A command line as the shell would hand it over.
//!
//! Split out of `fetch.rs`, which is the rule that needs it. Which command
//! runs the payload, which of its arguments is the download, where one
//! command ends and the next begins — every one of those is a question
//! about shell syntax, and every one of them has been answered here with a
//! better search of the raw text and then defeated by the next piece of
//! syntax: case, an address belonging to another command, an option that
//! takes a value, a second fetch, a separator inside quotes. Reading the
//! line once is one answer to all of them.
//!
//! Syntax only. Nothing here expands a variable, runs a substitution or
//! matches a glob, so `curl $URL | sh` names `$URL` — which is what the
//! line says, and what a person reading the finding will see in the file.

/// One word, as the shell would pass it: quotes and escapes taken out.
pub(in crate::quality) struct Word {
    pub(in crate::quality) text: String,
    /// Whether any of it was written inside quotes. A quoted word is an
    /// operand the shell hands over exactly as it stands; a bare one is a
    /// word in prose, and may have picked up punctuation from the sentence
    /// around it.
    pub(in crate::quality) quoted: bool,
    /// Where this word sits in the line it came from, quote marks
    /// included. A reading that knows where a word begins can ask what
    /// else on the line is true there, which is how a word inside a
    /// comment stays a word nothing runs.
    pub(in crate::quality) at: std::ops::Range<usize>,
}

/// How a command was reached from the one before it.
#[derive(PartialEq, Eq)]
pub(in crate::quality) enum Reached {
    /// First on the line.
    First,
    /// `|` — the command before it writes into this one.
    Pipe,
    /// `&&` — this one runs if the command before it succeeded.
    And,
    /// `;`, `&`, `||` — this one runs whatever happened before it.
    Next,
}

/// One command on a line: how it was reached, the words it is given, and
/// where it sits in the line it came from.
pub(in crate::quality) struct Command {
    pub(in crate::quality) reached_by: Reached,
    pub(in crate::quality) at: std::ops::Range<usize>,
    pub(in crate::quality) words: Vec<Word>,
}

impl Command {
    /// Where the program name sits: the first word that is not a variable
    /// assignment. `MODE=x sh` runs `sh` with `MODE` set for it, and
    /// reading the assignment as the program name misses the command
    /// entirely — which for a runner means going quiet on a line that
    /// pipes a download into a shell.
    fn names_program(&self) -> Option<usize> {
        self.words.iter().position(|word| !assigns(word))
    }

    /// The program being run, lowercased and by its own name rather than
    /// the path it was reached through. `None` for a command that is
    /// nothing but assignments, or an empty stretch between separators.
    ///
    /// `/bin/sh` and `./bash` run the same programs `sh` and `bash` do, and
    /// a line piping a download into one of them is the thing this rule
    /// exists to catch — matching the whole word means the rule says
    /// nothing about it. The cut is at the last separator, so `notbash` and
    /// `mybash.txt` are still their own whole names and still match
    /// nothing. An address is not a path to a program, whatever it ends in.
    pub(in crate::quality) fn verb(&self) -> Option<String> {
        Some(named(&self.words.get(self.names_program()?)?.text))
    }

    pub(in crate::quality) fn has_word(&self, word: &str) -> bool {
        self.words.iter().any(|held| held.text == word)
    }

    /// Where the program that actually runs sits, past whatever launcher
    /// prefixes stand in front of it. `env bash -c …` runs bash, and a
    /// reading that stops at `env` is reading the launcher's argument list
    /// as bash's.
    fn runs_program(&self) -> Option<usize> {
        let mut at = self.names_program()?;
        while LAUNCHERS.contains(&named(&self.words.get(at)?.text).as_str()) {
            at = self
                .words
                .iter()
                .enumerate()
                .skip(at + 1)
                .find(|(_, word)| !word.text.starts_with('-') && !assigns(word))
                .map(|(at, _)| at)?;
        }
        Some(at)
    }

    /// Which of the words this command is given the program reads as a
    /// command line of its own and runs. What is written inside one of
    /// them is an instruction, not an operand: the quote marks around it
    /// are the outer shell's and the inner shell never sees them.
    ///
    /// This is a position and not a property of the command. `eval` joins
    /// every operand it is given into one command line, and a remote shell
    /// does the same on another machine. An interpreter handed `-c` reads
    /// exactly one: the first operand after that option, because the ones
    /// after it are the `$0`, `$1`, `$2` the command line is run with —
    /// `sh -c 'true' marker 'git commit --no-verify'` never runs the third
    /// operand, and reading it as code reports a switch nothing hands over.
    ///
    /// The option is found the way the shell finds it. A bundle is a `-`
    /// and a run of option letters; `c` takes the command line as its
    /// value, which is the rest of the bundle where letters follow it and
    /// the next word where none do. So `-lc` reaches the next word and
    /// `-cl` does not, which is what the shell does with each. Option
    /// parsing stops at the first operand, so the `-c` in `python
    /// script.py -c x` belongs to the script.
    fn command_strings(&self) -> Vec<usize> {
        let Some(program) = self.runs_program() else {
            return Vec::new();
        };
        let Some(verb) = self.words.get(program).map(|word| named(&word.text)) else {
            return Vec::new();
        };
        if verb == "eval" || verb == "ssh" {
            return (program + 1..self.words.len()).collect();
        }
        if !interprets(&verb) {
            return Vec::new();
        }
        for (at, word) in self.words.iter().enumerate().skip(program + 1) {
            let Some(letters) = word.text.strip_prefix('-') else {
                break;
            };
            if !letters.chars().all(|c| c.is_ascii_alphanumeric()) {
                continue;
            }
            let Some(taken) = letters.find('c') else {
                continue;
            };
            return match taken + 1 == letters.len() {
                true => vec![at + 1],
                false => vec![at],
            };
        }
        Vec::new()
    }

    /// Every argument this command is given, each with whether the program
    /// reads it as a command line rather than as an operand.
    pub(in crate::quality) fn operands(&self) -> Vec<(&Word, bool)> {
        let Some(program) = self.names_program() else {
            return Vec::new();
        };
        let strings = self.command_strings();
        self.words
            .iter()
            .enumerate()
            .skip(program + 1)
            .map(|(at, word)| (word, strings.contains(&at)))
            .collect()
    }

    /// Everything after the program name, as the shell would pass it —
    /// counted from the program and not from the start of the command, or
    /// an assignment before it shifts every argument by one.
    pub(in crate::quality) fn arguments(&self) -> &[Word] {
        let Some(at) = self.names_program() else {
            return &[];
        };
        self.words.get(at + 1..).unwrap_or_default()
    }
}

/// A program by its own name rather than the path it was reached through,
/// lowercased.
///
/// `/bin/sh` and `./bash` run the same programs `sh` and `bash` do, and a
/// line piping a download into one of them is the thing these rules exist
/// to catch — matching the whole word means they say nothing about it. The
/// cut is at the last separator, so `notbash` and `mybash.txt` are still
/// their own whole names and still match nothing. An address is not a path
/// to a program, whatever it ends in.
fn named(written: &str) -> String {
    let named = match written.contains("://") {
        true => written,
        false => written.rsplit('/').next().unwrap_or(written),
    };
    named.to_ascii_lowercase()
}

/// Programs that run one of their own operands as a program and hand it
/// the rest of the line. Each takes its options first and then the
/// program, so the program it runs is the first operand that is neither an
/// option nor an assignment.
///
/// Only that shape is listed. `timeout 5 bash -c …` and `nice -n 5 bash …`
/// put an operand of their own before the program, so the first non-option
/// word names `5` rather than an interpreter — and a launcher option that
/// takes a separate value, `env -u NAME bash`, lands on the value the same
/// way. Both leave the words after them read as the operands they are
/// written as, which is what an unrecognised program gets anyway.
const LAUNCHERS: &[&str] = &["env", "command", "exec", "nohup", "setsid"];

/// Whether this word sets a variable for the command rather than being one:
/// a name the shell would accept, then `=`. `--referer=https://x` is not
/// one — the name has to be a name.
fn assigns(word: &Word) -> bool {
    let Some((name, _)) = word.text.split_once('=') else {
        return false;
    };
    let mut letters = name.chars();
    letters
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && letters.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Interpreters a download can be handed straight to.
const SHELLS: &[&str] = &["sh", "bash", "zsh", "python"];

/// Whether this program reads what is piped into it and runs it.
///
/// A version on the end of the name is the same interpreter: `python3` is
/// what anybody actually writes, and it is the spelling a substring search
/// used to catch and a whole-word one stopped catching. Nothing else is
/// stretched — a name that is not one of these runs whatever it runs, and
/// saying otherwise would hold back lines nothing interprets.
pub(in crate::quality) fn interprets(program: &str) -> bool {
    SHELLS.contains(&program)
        || program.strip_prefix("python").is_some_and(|version| {
            !version.is_empty() && version.chars().all(|c| c.is_ascii_digit() || c == '.')
        })
}

/// The line read into the commands it holds.
mod scan;
pub(in crate::quality) use scan::commands;

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests;
