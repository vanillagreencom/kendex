//! Reading one line into the commands it holds. Quoting, escapes and
//! substitutions are all answered here, in one pass over the characters,
//! because every one of them changes where the next word or command
//! begins.

use super::{Command, Reached, Word};

/// The commands one line holds, in the order they are written.
pub(in crate::quality) fn commands(line: &str) -> Vec<Command> {
    let mut found = Vec::new();
    let mut state = Scan::default();
    let mut chars = line.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        // The escape is read first. Inside single quotes there are none;
        // inside double quotes it covers only what the shell says it
        // covers, and reading it any earlier or later is how a `\"` closed
        // a quote it was written to keep open.
        if c == '\\' && !state.innermost().single {
            let escapes = !state.innermost().double
                || matches!(chars.peek(), Some((_, '"' | '\\' | '$' | '`')));
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
        // A substitution is one word however much shell is written inside
        // it. Where it ends is syntax and the tokenizer owns it; what it
        // produces is expansion, which nothing here does — the operand
        // stays as written, and a line that changes what is inside the
        // substitution is a line that says something else.
        if !state.innermost().single {
            // `$(` is one opening, so the parenthesis is taken with the
            // dollar rather than left for the reading below to reach —
            // which would open the substitution twice and never close it.
            if c == '$' && chars.peek().is_some_and(|(_, next)| *next == '(') {
                state.opened();
                state.push(at, c);
                if let Some((at, opening)) = chars.next() {
                    state.push(at, opening);
                }
                continue;
            }
            if state.substituting(c) {
                state.push(at, c);
                continue;
            }
            if state.substituted() {
                state.push(at, c);
                continue;
            }
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

/// The quoting in force in one line: what a quote mark has opened and not
/// closed again.
#[derive(Clone, Copy, Default)]
struct Quoting {
    single: bool,
    double: bool,
}

/// What has been read so far: the quoting in force, the word being built,
/// and the command it belongs to.
struct Scan {
    /// One frame per line being read: the line itself, then the inside of
    /// every `$( )` still open and of every group written inside one. The
    /// shell does not act on what a substitution holds, it hands it to a
    /// reading of its own — with quoting of its own, which the quoting
    /// around it neither continues nor answers for. A separator inside one
    /// ends nothing.
    quoting: Vec<Quoting>,
    word: String,
    /// Whether a word is being read at all, which a quote mark is enough to
    /// say on its own.
    started: bool,
    /// Whether any of the word being read was written inside quotes.
    quoted: bool,
    start: Option<usize>,
    /// Where the word being read begins, which is not where the command
    /// does: a command keeps its first word's start and every word after
    /// it needs one of its own.
    word_start: Option<usize>,
    end: usize,
    words: Vec<Word>,
    reached_by: Option<Reached>,
}

impl Default for Scan {
    /// The base frame is the line itself, so there is always a quoting to
    /// read and a substitution has somewhere to close back to.
    fn default() -> Self {
        Self {
            quoting: vec![Quoting::default()],
            word: String::new(),
            started: false,
            quoted: false,
            start: None,
            word_start: None,
            end: 0,
            words: Vec::new(),
            reached_by: None,
        }
    }
}

impl Scan {
    /// The quoting that answers for the character being read: the innermost
    /// frame, which is the line that character was written in.
    fn innermost(&self) -> Quoting {
        self.quoting.last().copied().unwrap_or_default()
    }

    /// Whether this character is a quote mark rather than content,
    /// switching the quoting in force as it goes.
    fn delimits(&mut self, c: char) -> bool {
        self.quoting.last_mut().is_some_and(|quoting| match c {
            '\'' if !quoting.double => {
                quoting.single = !quoting.single;
                true
            }
            '"' if !quoting.single => {
                quoting.double = !quoting.double;
                true
            }
            _ => false,
        })
    }

    fn inside(&self) -> bool {
        let quoting = self.innermost();
        quoting.single || quoting.double
    }

    /// Whether this character opens or closes a substitution, keeping a
    /// frame for the quoting each one is read with.
    ///
    /// A group written inside a substitution — `$( (true); printf … )` — is
    /// a line of its own in the same way, so it opens a frame of its own and
    /// the parenthesis that closes it closes the group rather than the
    /// substitution around it. The separator after it is still inside, where
    /// it cuts nothing off the command that fetches the payload.
    ///
    /// A parenthesis inside quotes is a character in a word, opening and
    /// closing nothing. The quoting that says so is the frame's own: read
    /// against a quote mark written outside the substitution, a `)` closes
    /// nothing, the substitution never ends, and every separator after it —
    /// the pipe that hands a download to a shell among them — stops being
    /// one.
    ///
    /// A parenthesis outside a substitution is left alone. A subshell at the
    /// top level holds its separators the same way, but prose is full of
    /// brackets and reading those as a group would swallow every separator
    /// on the line — which is a rule that says nothing, where this is a rule
    /// that could have said something sharper.
    ///
    /// `$( )` and not the backtick spelling of the same thing. What these
    /// rules read is markdown with commands written into it, where a
    /// backtick is a code span far more often than it is a substitution —
    /// and reading `` `curl … | sh` `` as one substituted word takes the
    /// pipe with it, so the rule says nothing about the most ordinary way
    /// anybody writes that line down. An identity that could have been
    /// sharper is the smaller cost.
    fn substituting(&mut self, c: char) -> bool {
        if self.inside() || !self.substituted() {
            return false;
        }
        match c {
            '(' => {
                self.opened();
                true
            }
            ')' => {
                self.quoting.pop();
                true
            }
            _ => false,
        }
    }

    /// A substitution begins here, and what is written inside it is a line
    /// of its own.
    fn opened(&mut self) {
        self.quoting.push(Quoting::default());
    }

    /// Whether the reading is inside a substitution, where a separator is a
    /// character in a word rather than the end of a command.
    fn substituted(&self) -> bool {
        self.quoting.len() > 1
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
        self.word_start.get_or_insert(at);
        self.started = true;
        self.quoted = true;
        self.end = at + c.len_utf8();
    }

    fn push(&mut self, at: usize, c: char) {
        if self.start.is_none() {
            self.start = Some(at);
        }
        self.word_start.get_or_insert(at);
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
        let at = std::mem::take(&mut self.word_start).unwrap_or(self.end)..self.end;
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
        self.words.push(Word { text, quoted, at });
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
