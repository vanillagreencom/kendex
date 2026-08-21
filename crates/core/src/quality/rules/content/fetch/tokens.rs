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
pub(super) struct Word {
    pub(super) text: String,
    /// Whether any of it was written inside quotes. A quoted word is an
    /// operand the shell hands over exactly as it stands; a bare one is a
    /// word in prose, and may have picked up punctuation from the sentence
    /// around it.
    pub(super) quoted: bool,
}

/// How a command was reached from the one before it.
#[derive(PartialEq, Eq)]
pub(super) enum Reached {
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
pub(super) struct Command {
    pub(super) reached_by: Reached,
    pub(super) at: std::ops::Range<usize>,
    pub(super) words: Vec<Word>,
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

    /// The program being run, lowercased. `None` for a command that is
    /// nothing but assignments, or an empty stretch between separators.
    pub(super) fn verb(&self) -> Option<String> {
        Some(
            self.words
                .get(self.names_program()?)?
                .text
                .to_ascii_lowercase(),
        )
    }

    pub(super) fn has_word(&self, word: &str) -> bool {
        self.words.iter().any(|held| held.text == word)
    }

    /// Everything after the program name, as the shell would pass it —
    /// counted from the program and not from the start of the command, or
    /// an assignment before it shifts every argument by one.
    pub(super) fn arguments(&self) -> &[Word] {
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

/// The commands one line holds, in the order they are written.
pub(super) fn commands(line: &str) -> Vec<Command> {
    let mut found = Vec::new();
    let mut state = Scan::default();
    let mut chars = line.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        // The escape is read first. Inside single quotes there are none;
        // inside double quotes it covers only what the shell says it
        // covers, and reading it any earlier or later is how a `\"` closed
        // a quote it was written to keep open.
        if c == '\\' && !state.single {
            let escapes =
                !state.double || matches!(chars.peek(), Some((_, '"' | '\\' | '$' | '`')));
            match (escapes, chars.next_if(|_| escapes)) {
                (true, Some((at, escaped))) => state.push(at, escaped),
                _ => state.push(at, c),
            }
            continue;
        }
        // A quote mark is syntax the shell takes out, so it is consumed
        // here rather than falling through to be pushed: a word that keeps
        // its quotes is a program nothing has heard of, and the rule goes
        // quiet on the line.
        if state.delimits(c) {
            state.opens(at, c);
            continue;
        }
        if state.inside() {
            state.push(at, c);
            continue;
        }
        match c {
            c if c.is_whitespace() => state.end_word(),
            '|' | '&' => {
                let doubled = chars.peek().is_some_and(|(_, next)| *next == c);
                if doubled {
                    chars.next();
                }
                let reached = match (c, doubled) {
                    ('|', false) => Reached::Pipe,
                    ('&', true) => Reached::And,
                    _ => Reached::Next,
                };
                state.end_command(reached, &mut found);
            }
            ';' => state.end_command(Reached::Next, &mut found),
            c => state.push(at, c),
        }
    }
    state.finish(&mut found);
    found
}

/// What has been read so far: the quoting in force, the word being built,
/// and the command it belongs to.
#[derive(Default)]
struct Scan {
    single: bool,
    double: bool,
    word: String,
    /// Whether a word is being read at all, which a quote mark is enough to
    /// say on its own.
    started: bool,
    /// Whether any of the word being read was written inside quotes.
    quoted: bool,
    start: Option<usize>,
    end: usize,
    words: Vec<Word>,
    reached_by: Option<Reached>,
}

impl Scan {
    /// Whether this character is a quote mark rather than content,
    /// switching the quoting in force as it goes.
    fn delimits(&mut self, c: char) -> bool {
        match c {
            '\'' if !self.double => {
                self.single = !self.single;
                true
            }
            '"' if !self.single => {
                self.double = !self.double;
                true
            }
            _ => false,
        }
    }

    fn inside(&self) -> bool {
        self.single || self.double
    }

    /// A quote mark begins a word even where the word is empty: the shell
    /// passes `""` as an argument, and one that vanished would shift every
    /// argument after it. It stakes out the same ground a character does,
    /// so a command that is nothing but an empty argument is still a
    /// command with somewhere to be.
    fn opens(&mut self, at: usize, c: char) {
        if self.start.is_none() {
            self.start = Some(at);
        }
        self.started = true;
        self.quoted = true;
        self.end = at + c.len_utf8();
    }

    fn push(&mut self, at: usize, c: char) {
        if self.start.is_none() {
            self.start = Some(at);
        }
        self.started = true;
        self.quoted |= self.inside();
        self.word.push(c);
        self.end = at + c.len_utf8();
    }

    /// Close the word being read, with the backticks a markdown document
    /// wraps a command in taken off its edges.
    ///
    /// What these rules read is prose with commands written into it, and a
    /// command inside a code span is the same command: leaving the backtick
    /// on makes `` `curl `` a program nothing has heard of, and the line
    /// that fired the rule gets named by nothing.
    fn end_word(&mut self) {
        let word = std::mem::take(&mut self.word);
        let quoted = std::mem::take(&mut self.quoted);
        if !std::mem::take(&mut self.started) {
            return;
        }
        // A bare word keeps the backticks off its edges: these rules read
        // markdown with commands written into it, and `` `curl `` inside a
        // code span is `curl`. A quoted word is an operand the shell hands
        // over as it stands, and nothing in prose put those there.
        let text = match quoted {
            true => word,
            false => word.trim_matches('`').to_owned(),
        };
        // A bare word that was nothing but backticks was punctuation in a
        // sentence, never an argument, and printing it as one leaves a gap
        // in the middle of the sentence the finding says. A quoted empty
        // word is an argument: the shell passes it.
        if !quoted && text.is_empty() {
            return;
        }
        self.words.push(Word { text, quoted });
    }

    fn end_command(&mut self, reached: Reached, found: &mut Vec<Command>) {
        self.finish(found);
        self.reached_by = Some(reached);
    }

    /// Close whatever has been read. A stretch with no words in it is not a
    /// command — `foo || bar` is two, not three — but the operator that
    /// ended it still says how the next one was reached.
    fn finish(&mut self, found: &mut Vec<Command>) {
        self.end_word();
        let reached = self.reached_by.take().unwrap_or(Reached::First);
        let Some(start) = self.start.take() else {
            self.reached_by = Some(reached);
            return;
        };
        found.push(Command {
            reached_by: reached,
            at: start..self.end,
            words: std::mem::take(&mut self.words),
        });
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests;
