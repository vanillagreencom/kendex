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
        let written = &self.words.get(self.names_program()?)?.text;
        let named = match written.contains("://") {
            true => written.as_str(),
            false => written.rsplit('/').next().unwrap_or(written),
        };
        Some(named.to_ascii_lowercase())
    }

    pub(in crate::quality) fn has_word(&self, word: &str) -> bool {
        self.words.iter().any(|held| held.text == word)
    }

    /// Whether this command reads one of the words it is given as a
    /// command line of its own and runs it. What is written inside that
    /// word is then an instruction, not an operand: the quote marks
    /// around it are the outer shell's and the inner shell never sees
    /// them.
    ///
    /// A shell handed `-c` is the plain case. `eval` is the same thing
    /// with the shell already running, and a remote shell is the same
    /// thing on another machine. Every other program is given operands,
    /// whatever it does with them.
    pub(in crate::quality) fn runs_a_command_string(&self) -> bool {
        self.verb().is_some_and(|verb| {
            verb == "eval" || verb == "ssh" || (interprets(&verb) && self.has_word("-c"))
        })
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
