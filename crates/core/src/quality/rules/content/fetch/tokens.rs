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
    /// The program being run, lowercased. `None` for a command that is
    /// nothing but an assignment or an empty stretch between separators.
    pub(super) fn verb(&self) -> Option<String> {
        Some(self.words.first()?.text.to_ascii_lowercase())
    }

    pub(super) fn has_word(&self, word: &str) -> bool {
        self.words.iter().any(|held| held.text == word)
    }

    /// Everything after the program name, as the shell would pass it.
    pub(super) fn arguments(&self) -> &[Word] {
        self.words.get(1..).unwrap_or_default()
    }
}

/// The commands one line holds, in the order they are written.
pub(super) fn commands(line: &str) -> Vec<Command> {
    let mut found = Vec::new();
    let mut state = Scan::default();
    let mut chars = line.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        if state.quoted(c) {
            state.push(at, c);
            continue;
        }
        match c {
            '\\' => match chars.next() {
                Some((at, escaped)) => state.push(at, escaped),
                None => state.push(at, c),
            },
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
    start: Option<usize>,
    end: usize,
    words: Vec<Word>,
    reached_by: Option<Reached>,
}

impl Scan {
    /// Whether this character is inside quotes, taking the quote marks
    /// themselves out as it goes. A quote is a word boundary the shell
    /// removes, never part of what the command is handed.
    fn quoted(&mut self, c: char) -> bool {
        match c {
            '\'' if !self.double => {
                self.single = !self.single;
                false
            }
            '"' if !self.single => {
                self.double = !self.double;
                false
            }
            _ => self.single || self.double,
        }
    }

    fn push(&mut self, at: usize, c: char) {
        if self.start.is_none() {
            self.start = Some(at);
        }
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
        let trimmed = word.trim_matches('`');
        if !trimmed.is_empty() {
            self.words.push(Word {
                text: trimmed.to_owned(),
            });
        }
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
