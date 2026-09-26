//! Report text with the commands in it marked.
//!
//! A line of the check report is read by a person and pasted by an agent,
//! and some lines carry a command a reader runs: a backup before a
//! reinstall, the editor on a manifest, the refresh to run next. A
//! rendering that wraps text to a terminal may break prose between words,
//! and never a command, which split at a space reads as a shorter one. The
//! line keeps which of its bytes are a command so the rendering can tell.

use std::fmt;
use std::ops::{Deref, Range};

use serde::{Serialize, Serializer};

/// One run of a [`Sentence`]: prose, or a command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Span<'a> {
    Prose(&'a str),
    Command(&'a str),
}

/// Text built from prose and commands, in order. Its plain spelling, what
/// `Display`, `Deref` and the JSON give, is every run joined with nothing
/// between.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Sentence {
    text: String,
    /// The byte ranges of `text` that are commands, in order and apart.
    commands: Vec<Range<usize>>,
}

impl Sentence {
    pub fn prose(mut self, text: &str) -> Sentence {
        self.text.push_str(text);
        self
    }

    pub fn command(mut self, text: &str) -> Sentence {
        let start = self.text.len();
        self.text.push_str(text);
        self.commands.push(start..self.text.len());
        self
    }

    pub fn as_str(&self) -> &str {
        &self.text
    }

    /// The runs in order, empty ones left out.
    pub fn spans(&self) -> Vec<Span<'_>> {
        let mut spans = Vec::new();
        let mut at = 0;
        for command in &self.commands {
            if command.start > at {
                spans.push(Span::Prose(&self.text[at..command.start]));
            }
            if !command.is_empty() {
                spans.push(Span::Command(&self.text[command.clone()]));
            }
            at = command.end;
        }
        if at < self.text.len() {
            spans.push(Span::Prose(&self.text[at..]));
        }
        spans
    }

    /// The same runs, each passed through `each`, so a scrub that changes a
    /// run's length keeps every command where it was.
    pub(super) fn map(&self, each: impl Fn(&str) -> String) -> Sentence {
        self.spans()
            .into_iter()
            .fold(Sentence::default(), |sentence, span| match span {
                Span::Prose(text) => sentence.prose(&each(text)),
                Span::Command(text) => sentence.command(&each(text)),
            })
    }
}

impl Sentence {
    /// Without the whitespace at either end, which a run at that end
    /// carries: prose loses it, and a command keeps its bytes.
    pub(super) fn trimmed(self) -> Sentence {
        let spans = self.spans();
        let last = spans.len().saturating_sub(1);
        spans
            .into_iter()
            .enumerate()
            .fold(Sentence::default(), |sentence, (at, span)| match span {
                Span::Prose(text) => {
                    let text = if at == 0 { text.trim_start() } else { text };
                    let text = if at == last { text.trim_end() } else { text };
                    sentence.prose(text)
                }
                Span::Command(text) => sentence.command(text),
            })
    }
}

impl From<String> for Sentence {
    /// All prose: a line that carries no command.
    fn from(text: String) -> Sentence {
        Sentence {
            text,
            commands: Vec::new(),
        }
    }
}

impl Deref for Sentence {
    type Target = str;

    fn deref(&self) -> &str {
        &self.text
    }
}

impl fmt::Display for Sentence {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        out.write_str(&self.text)
    }
}

impl Serialize for Sentence {
    /// The plain spelling: what reads the JSON reads the line as it always
    /// has.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The runs come back as they were built, the plain spelling is them
    /// joined, and a scrub that changes a run's length keeps the command a
    /// command.
    #[test]
    fn a_sentence_keeps_its_commands_marked() {
        let sentence = Sentence::default()
            .prose("backup first: ")
            .command("cp -i a a.backup")
            .prose("; then reinstall");
        assert_eq!(
            sentence.spans(),
            [
                Span::Prose("backup first: "),
                Span::Command("cp -i a a.backup"),
                Span::Prose("; then reinstall"),
            ]
        );
        assert_eq!(
            sentence.as_str(),
            "backup first: cp -i a a.backup; then reinstall"
        );
        assert_eq!(
            serde_json::to_string(&sentence).ok().as_deref(),
            Some("\"backup first: cp -i a a.backup; then reinstall\"")
        );
        let scrubbed = sentence.map(|run| run.replace('a', "AA"));
        assert_eq!(
            scrubbed.spans(),
            [
                Span::Prose("bAAckup first: "),
                Span::Command("cp -i AA AA.bAAckup"),
                Span::Prose("; then reinstAAll"),
            ]
        );
        assert_eq!(
            Sentence::from("plain".to_owned()).spans(),
            [Span::Prose("plain")]
        );
    }
}
