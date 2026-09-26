//! Reading a shell file as far as one question goes: which bytes of a line
//! the script prints or documents, and which it runs.
//!
//! The guard packages this catalog ships exist to refuse a switch, so each
//! one spells that switch in the comment explaining the refusal and in the
//! message it prints when refusing. `--no-verify` in `git commit
//! --no-verify` is a use; the same characters after `#`, or inside the
//! string an `echo` prints, are the script naming it. A rule that cannot
//! tell the two apart rates every guard as the thing it guards against.
//!
//! What is read here is deliberately small. A full-line comment is text. A
//! quoted string is text when it is an argument of `echo`, `printf` or a
//! diagnostic function — one whose body only prints, assigns, tests and
//! steers — and only where that command's output goes to the terminal: a
//! string piped on, redirected into a file, or captured by a command
//! substitution reaches another program, and what that program does with
//! it is not read. Everything else on a line is a command, whichever
//! quotes it stands in: `eval "rm -rf /"` and `bash -c 'rm -rf /'` are
//! commands, and so is the same text inside `$( )`.
//!
//! A test is read one step further. Its shell file hands stubs and
//! assertions the launch lines it checks, so in a file under a test
//! directory a quoted string it assigns or passes to any command but a
//! shell is data, and so is every word it passes to a function the tests
//! define. A switch the test runs, as an argument of a program it does not
//! define or inside a string handed to `eval` or a shell, is still a
//! command.
//!
//! A line ending in a backslash goes on to the next, and the lines are read
//! as the one command the shell reads, so an argument on a continuation
//! line is an argument of the command its first line names.
//!
//! Every reading errs toward the command. Past `MAX_NESTING` the rest of
//! a line is one opaque word, a function judged past that many calls is
//! not diagnostic, and a name defined twice is diagnostic only when every
//! definition is.

use std::collections::{BTreeMap, BTreeSet};

use super::Quotation;

/// Builtins that print what they are handed.
const SPEAKS: &[&str] = &["echo", "printf"];

/// Command words that assign, test or steer and never run what they are
/// handed. A function built from these, `SPEAKS`, and other such functions
/// is a diagnostic function: a formatting helper that pipes through `tr`
/// or `sed` is not one, and the strings it prints stay commands. That is
/// the price of reading no further, and it errs toward the finding.
const HOLDS: &[&str] = &[
    "local", "declare", "typeset", "readonly", "export", "read", "shift", "return", "exit",
    "continue", "break", ":", "true", "false", "[", "[[", "test", "case", "esac", "fi", "done",
    "}",
];

/// Words that open a command and are not its name: the next word is.
const KEYWORDS: &[&str] = &[
    "if", "then", "else", "elif", "while", "until", "do", "!", "{", "time",
];

/// How deep `(`, `$(` and backticks may nest before the rest of the line
/// is read as one opaque word. The same bound `hash::MAX_DEPTH` puts on a
/// document tree: a line built to nest past it is judged as code, never
/// walked.
const MAX_NESTING: usize = 32;

/// One shell token, as byte ranges into the line it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tok {
    Word(usize, usize),
    /// The inside of a quoted string. A double-quoted string holding a
    /// command substitution is several of these around an `Open`/`Close`
    /// pair.
    Str(usize, usize),
    /// `;`, `&`, `&&`, `||`: the next word is a command.
    Break,
    /// A single `|`: the next word is a command, and the last command's
    /// output reaches it.
    Pipe,
    /// `(`, `$(` or an opening backtick: a nested command begins.
    Open,
    Close,
}

/// What ends a nested lexing pass.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Until {
    End,
    Paren,
    Backtick,
}

struct Lexer<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
    toks: Vec<Tok>,
    /// The line ended in a comment, which a trailing backslash does not
    /// continue.
    comment: bool,
}

impl<'a> Lexer<'a> {
    fn at(&self, offset: usize) -> Option<u8> {
        self.s.get(self.i + offset).copied()
    }

    /// A nested command. Past the nesting bound the rest of the line is
    /// one word, so nothing on it reads as text.
    fn open(&mut self, until: Until) {
        if self.depth == MAX_NESTING {
            self.toks.push(Tok::Word(self.i, self.s.len()));
            self.i = self.s.len();
            return;
        }
        self.depth += 1;
        self.toks.push(Tok::Open);
        self.commands(until);
        self.toks.push(Tok::Close);
        self.depth -= 1;
    }

    /// Lex commands up to `until` (consumed) or the end of the line.
    fn commands(&mut self, until: Until) {
        let mut word_start = true;
        while let Some(c) = self.at(0) {
            match c {
                b' ' => {
                    self.i += 1;
                    word_start = true;
                    continue;
                }
                b')' if until == Until::Paren => {
                    self.i += 1;
                    return;
                }
                b'`' if until == Until::Backtick => {
                    self.i += 1;
                    return;
                }
                b'#' if word_start => {
                    self.i = self.s.len();
                    self.comment = true;
                    return;
                }
                b'(' => {
                    self.i += 1;
                    self.open(Until::Paren);
                }
                b'`' => {
                    self.i += 1;
                    self.open(Until::Backtick);
                }
                b';' => {
                    self.i += 1;
                    self.toks.push(Tok::Break);
                }
                b'&' => {
                    self.i += 1 + usize::from(self.at(1) == Some(b'&'));
                    self.toks.push(Tok::Break);
                }
                b'|' if self.at(1) == Some(b'|') => {
                    self.i += 2;
                    self.toks.push(Tok::Break);
                }
                b'|' => {
                    self.i += 1;
                    self.toks.push(Tok::Pipe);
                }
                b'\'' => {
                    let start = self.i + 1;
                    let end = self.s[start..]
                        .iter()
                        .position(|&b| b == b'\'')
                        .map_or(self.s.len(), |n| start + n);
                    self.toks.push(Tok::Str(start, end));
                    self.i = (end + 1).min(self.s.len());
                }
                b'"' => {
                    self.i += 1;
                    self.quoted();
                }
                b'$' if self.at(1) == Some(b'(') && self.at(2) == Some(b'(') => {
                    self.arithmetic();
                }
                b'$' if self.at(1) == Some(b'(') => {
                    self.i += 2;
                    self.open(Until::Paren);
                }
                _ => self.word(until),
            }
            word_start = false;
        }
    }

    /// A bare word: everything up to a space, a quote, an operator or the
    /// start of a substitution. Arithmetic inside it is part of it.
    fn word(&mut self, until: Until) {
        let start = self.i;
        while let Some(c) = self.at(0) {
            let stops = match c {
                b' ' | b';' | b'|' | b'(' | b'\'' | b'"' | b'`' => true,
                // `>&2` and `2>&1` are one redirection word, not a command
                // ending in `&`.
                b'&' => !matches!(self.s.get(self.i.wrapping_sub(1)), Some(b'>' | b'<')),
                b')' => until == Until::Paren,
                b'$' if self.at(1) == Some(b'(') && self.at(2) == Some(b'(') => {
                    self.arithmetic();
                    continue;
                }
                b'$' => self.at(1) == Some(b'('),
                _ => false,
            };
            if stops {
                break;
            }
            self.i += 1;
        }
        if self.i > start {
            self.toks.push(Tok::Word(start, self.i));
        } else {
            // An operator character the caller did not take, e.g. a `)`
            // outside any substitution: skip it rather than loop on it.
            self.i += 1;
        }
    }

    /// `$(( ... ))`, skipped whole: an arithmetic expansion runs nothing.
    fn arithmetic(&mut self) {
        self.i += 3;
        let mut depth = 2;
        while let Some(c) = self.at(0) {
            self.i += 1;
            match c {
                b'(' => depth += 1,
                b')' => {
                    depth -= 1;
                    if depth == 0 {
                        return;
                    }
                }
                _ => {}
            }
        }
    }

    /// Inside double quotes: string fragments around any substitution.
    fn quoted(&mut self) {
        let mut start = self.i;
        while let Some(c) = self.at(0) {
            match c {
                b'\\' => self.i += 2,
                b'"' => {
                    self.toks.push(Tok::Str(start, self.i));
                    self.i += 1;
                    return;
                }
                b'`' => {
                    self.toks.push(Tok::Str(start, self.i));
                    self.i += 1;
                    self.open(Until::Backtick);
                    start = self.i;
                }
                b'$' if self.at(1) == Some(b'(') && self.at(2) == Some(b'(') => self.arithmetic(),
                b'$' if self.at(1) == Some(b'(') => {
                    self.toks.push(Tok::Str(start, self.i));
                    self.i += 2;
                    self.open(Until::Paren);
                    start = self.i;
                }
                _ => self.i += 1,
            }
        }
        self.toks.push(Tok::Str(start, self.s.len().min(self.i)));
    }
}

fn lexed(line: &str) -> Lexer<'_> {
    let mut lexer = Lexer {
        s: line.as_bytes(),
        i: 0,
        depth: 0,
        toks: Vec::new(),
        comment: false,
    };
    lexer.commands(Until::End);
    lexer
}

fn lex(line: &str) -> Vec<Tok> {
    lexed(line).toks
}

/// Whether the shell reads the next line as more of this one: an odd run
/// of backslashes ends it, and it does not end in a comment.
fn continues(line: &str) -> bool {
    let trailing = line.bytes().rev().take_while(|b| *b == b'\\').count();
    trailing % 2 == 1 && !lexed(line).comment
}

/// Whether this word is `name=` or `name+=`, with or without a value.
fn is_assignment(word: &str) -> bool {
    let name = word
        .split_once('=')
        .map(|(name, _)| name.strip_suffix('+').unwrap_or(name));
    name.is_some_and(|name| {
        !name.is_empty()
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            && !name.as_bytes()[0].is_ascii_digit()
    })
}

/// What stands where a command's name goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Head {
    /// A bare word, as a byte range into the line.
    Named(usize, usize),
    /// A quoted string, a substitution or text past the nesting bound:
    /// something no command is named by.
    Opaque,
}

/// One simple command, split off a line by the one pass that knows the
/// keyword, assignment-prefix and assignment-value rules.
#[derive(Debug, Default)]
struct Simple {
    depth: usize,
    head: Option<Head>,
    /// The quoted strings among its arguments.
    strings: Vec<(usize, usize)>,
    /// Its bare arguments, redirections left out.
    words: Vec<(usize, usize)>,
    /// The quoted strings an assignment before its name takes as a value.
    values: Vec<(usize, usize)>,
    /// Its output reaches the next command.
    piped: bool,
    /// Its output is redirected somewhere that is not the terminal.
    away: bool,
    /// An assignment word opened a value: what follows up to the next
    /// bare word is the value, not the head.
    value_pending: bool,
    /// The word after a bare `>` is the redirection's target.
    target_pending: bool,
}

/// Whether a redirection target is still the terminal, or nowhere:
/// `&2`, `&1`, `/dev/null`. A file is a program's input later.
fn to_terminal(target: &str) -> bool {
    target.starts_with('&') || target.starts_with("/dev/")
}

/// The simple commands on a line, at every nesting, in the order they end.
fn commands(line: &str) -> Vec<Simple> {
    let mut done = Vec::new();
    let mut open = vec![Simple::default()];
    for tok in lex(line) {
        let Some(cur) = open.last_mut() else {
            unreachable!("the lexer closes only what it opened");
        };
        match tok {
            Tok::Word(start, end) => {
                let word = &line[start..end];
                if cur.target_pending {
                    cur.target_pending = false;
                    cur.away |= !to_terminal(word);
                    continue;
                }
                cur.value_pending = false;
                match cur.head {
                    None if KEYWORDS.contains(&word) => {}
                    None if is_assignment(word) => cur.value_pending = true,
                    None => cur.head = Some(Head::Named(start, end)),
                    Some(_) => match word.split_once('>') {
                        Some((_, after)) => {
                            let after = after.trim_start_matches('>');
                            match after.is_empty() {
                                true => cur.target_pending = true,
                                false => cur.away |= !to_terminal(after),
                            }
                        }
                        None if word.contains('<') => {}
                        None => cur.words.push((start, end)),
                    },
                }
            }
            // A quoted target is the ordinary way to name a file to write:
            // it is the redirection's, never one of the strings printed.
            Tok::Str(start, end) if cur.target_pending => {
                cur.target_pending = false;
                cur.away |= !to_terminal(&line[start..end]);
            }
            Tok::Str(start, end) => match cur.head {
                // The value runs to the next bare word, however many
                // fragments and substitutions it is made of.
                None if cur.value_pending => {
                    if start < end {
                        cur.values.push((start, end));
                    }
                }
                None => cur.head = Some(Head::Opaque),
                Some(_) => {
                    if start < end {
                        cur.strings.push((start, end));
                    }
                }
            },
            Tok::Break | Tok::Pipe => {
                let depth = cur.depth;
                cur.piped = tok == Tok::Pipe;
                done.push(std::mem::replace(
                    cur,
                    Simple {
                        depth,
                        ..Simple::default()
                    },
                ));
            }
            Tok::Open => {
                // A target a substitution names, `> "$(mktemp)"`, is a
                // file whatever it turns out to be.
                if cur.target_pending {
                    cur.target_pending = false;
                    cur.away = true;
                }
                if cur.head.is_none() && !cur.value_pending {
                    cur.head = Some(Head::Opaque);
                }
                let depth = cur.depth + 1;
                open.push(Simple {
                    depth,
                    ..Simple::default()
                });
            }
            Tok::Close => {
                if let Some(closed) = open.pop() {
                    done.push(closed);
                }
            }
        }
    }
    done.extend(open);
    done
}

/// Every command's name on this line, at any nesting. A head no command
/// is named by is reported as `"`.
fn command_words(line: &str) -> Vec<&str> {
    commands(line)
        .into_iter()
        .filter_map(|command| match command.head? {
            Head::Named(start, end) => Some(&line[start..end]),
            Head::Opaque => Some("\""),
        })
        .collect()
}

/// The name a line defines a function under and the text after its `{`,
/// where it defines one: `name() {`, `function name {` or
/// `function name() {`.
fn defined(line: &str) -> Option<(&str, &str)> {
    let line = line.trim();
    let line = line.strip_prefix("function ").map_or(line, str::trim_start);
    let (name, rest) = line.split_once(['(', ' '])?;
    let rest = rest.trim_start_matches(')').trim();
    let named = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    let body = rest.strip_prefix('{')?;
    named.then_some((name, body))
}

/// The functions these shell sources define whose every body only prints,
/// assigns, tests and steers — so a string handed to one is printed,
/// never run. A body on the definition's own line is the text between
/// its braces; any other body is the lines down to the first unindented
/// `}`, and one closed any other way is judged on what was read, which
/// errs toward the command. A name defined more than once, in one file
/// or across the tree, is diagnostic only when every definition is.
pub fn diagnostic_functions(sources: &[&str]) -> BTreeSet<String> {
    let mut bodies: BTreeMap<&str, Vec<Vec<&str>>> = BTreeMap::new();
    for source in sources {
        let mut lines = source.lines();
        while let Some(line) = lines.next() {
            let Some((name, rest)) = defined(line) else {
                continue;
            };
            let inner = rest.trim();
            let body = match inner.rsplit_once('}') {
                Some((body, _)) if !inner.starts_with('#') => vec![body],
                _ => {
                    let mut body = Vec::new();
                    if !inner.is_empty() && !inner.starts_with('#') {
                        body.push(inner);
                    }
                    body.extend(lines.by_ref().take_while(|line| *line != "}"));
                    body
                }
            };
            bodies.entry(name).or_default().push(body);
        }
    }
    let mut judged: BTreeMap<&str, Option<bool>> = BTreeMap::new();
    for name in bodies.keys() {
        judge(name, &bodies, &mut judged, 0);
    }
    judged
        .into_iter()
        .filter(|(_, verdict)| *verdict == Some(true))
        .map(|(name, _)| name.to_owned())
        .collect()
}

/// Whether `name` is diagnostic, memoized. A function in the middle of
/// being judged (a cycle), or reached past `MAX_NESTING` calls, is not.
fn judge<'a>(
    name: &'a str,
    bodies: &BTreeMap<&'a str, Vec<Vec<&'a str>>>,
    judged: &mut BTreeMap<&'a str, Option<bool>>,
    depth: usize,
) -> bool {
    match judged.get(name) {
        Some(Some(verdict)) => return *verdict,
        Some(None) => return false,
        None => {}
    }
    if depth > MAX_NESTING {
        return false;
    }
    judged.insert(name, None);
    let verdict = bodies[name].iter().flatten().all(|line| {
        command_words(line).into_iter().all(|word| {
            SPEAKS.contains(&word)
                || HOLDS.contains(&word)
                || (bodies.contains_key(word) && judge(word, bodies, judged, depth + 1))
        })
    });
    judged.insert(name, Some(verdict));
    verdict
}

/// Byte ranges of this line that a shell reads as text rather than as a
/// command: the whole of a full-line comment, and each string literal
/// handed to `echo`, `printf` or one of `diagnostic` whose output goes to
/// the terminal. Ranges index the line as given; the caller passes the
/// flattened lowercase copy, whose offsets are the original's.
pub fn named_spans(line: &str, diagnostic: &BTreeSet<String>) -> Vec<(usize, usize)> {
    if line.trim_start().starts_with('#') {
        return vec![(0, line.len())];
    }
    commands(line)
        .into_iter()
        .filter(|command| command.depth == 0 && !command.piped && !command.away)
        .filter(|command| match command.head {
            Some(Head::Named(start, end)) => {
                let word = &line[start..end];
                SPEAKS.contains(&word) || diagnostic.contains(word)
            }
            Some(Head::Opaque) | None => false,
        })
        .flat_map(|command| command.strings)
        .collect()
}

/// Whether this program runs the program text it is handed, piped in or
/// as an argument.
///
/// A version on the end of the name is the same interpreter: `python3` is
/// what anybody actually writes, and a whole-word match on `python` alone
/// misses it. Nothing else is stretched — a name that is not one of these
/// runs whatever it runs, and saying otherwise would hold back lines
/// nothing interprets.
pub fn interprets(program: &str) -> bool {
    const SHELLS: &[&str] = &["sh", "bash", "zsh", "python"];
    SHELLS.contains(&program)
        || program.strip_prefix("python").is_some_and(|version| {
            !version.is_empty() && version.chars().all(|c| c.is_ascii_digit() || c == '.')
        })
}

/// The functions a shell file's lines are read against.
#[derive(Debug, Clone, Copy)]
pub struct Context<'a> {
    /// The tree's diagnostic functions (see [`diagnostic_functions`]).
    pub diagnostic: &'a BTreeSet<String>,
    /// In a file under a test directory, the functions the tree's tests
    /// define (see [`fixture_spans`]); `None` in every other file.
    pub helpers: Option<&'a BTreeSet<String>>,
}

impl Context<'static> {
    /// A file read against no function at all: a hook's command line, or a
    /// document that is not part of a tree.
    pub fn none() -> Self {
        static NONE: BTreeSet<String> = BTreeSet::new();
        Context {
            diagnostic: &NONE,
            helpers: None,
        }
    }
}

/// Every function name these shell sources define.
pub fn defined_functions(sources: &[&str]) -> BTreeSet<String> {
    sources
        .iter()
        .flat_map(|source| source.lines())
        .filter_map(defined)
        .map(|(name, _)| name.to_owned())
        .collect()
}

/// Byte ranges of this line a test hands over as data: each quoted string
/// that is an argument of a command other than `eval` or an interpreter,
/// or an assignment's value, and each bare argument of one of `helpers`,
/// the functions the tests define. What such a function then does with
/// its argument is not read: a stub records it, an assertion compares it,
/// and a helper that launches the script under test hands it to that
/// script's stubbed programs. A command's name is never data, and neither
/// is a bare argument of a program the tests do not define.
pub fn fixture_spans(line: &str, helpers: &BTreeSet<String>) -> Vec<(usize, usize)> {
    commands(line)
        .into_iter()
        .flat_map(|command| {
            let (strings, words) = match command.head {
                Some(Head::Named(start, end)) => {
                    let word = &line[start..end];
                    let program = word.rsplit('/').next().unwrap_or(word);
                    let runs = word == "eval" || interprets(program);
                    (!runs, helpers.contains(word))
                }
                Some(Head::Opaque) => (true, false),
                None => (false, false),
            };
            let mut spans = command.values;
            if strings {
                spans.extend(command.strings);
            }
            if words {
                spans.extend(command.words);
            }
            spans
        })
        .collect()
}

/// Each line's quoted ranges, one list per line of `lines`, with the
/// quotation that names each. A run of lines joined by trailing
/// backslashes is read as the one line the shell reads, and each range is
/// handed back to the lines it covers.
pub fn quoted(lines: &[String], context: Context<'_>) -> Vec<Vec<(usize, usize, Quotation)>> {
    let mut found = vec![Vec::new(); lines.len()];
    let mut first = 0;
    while first < lines.len() {
        let mut last = first;
        while last + 1 < lines.len() && continues(&lines[last]) {
            last += 1;
        }
        // The backslash that joins two lines becomes a space, and one more
        // space stands for the newline, so each line keeps its own offsets
        // from where it starts in the joined text.
        let mut joined = String::new();
        let mut starts = Vec::new();
        for (at, line) in lines[first..=last].iter().enumerate() {
            starts.push(joined.len());
            match first + at < last {
                true => {
                    joined.push_str(&line[..line.len() - 1]);
                    joined.push_str("  ");
                }
                false => joined.push_str(line),
            }
        }
        let mut spans: Vec<(usize, usize, Quotation)> = named_spans(&joined, context.diagnostic)
            .into_iter()
            .map(|(start, end)| (start, end, Quotation::ShellText))
            .collect();
        if let Some(helpers) = context.helpers {
            spans.extend(
                fixture_spans(&joined, helpers)
                    .into_iter()
                    .map(|(start, end)| (start, end, Quotation::Fixture)),
            );
        }
        for (at, line) in lines[first..=last].iter().enumerate() {
            let (from, to) = (starts[at], starts[at] + line.len());
            found[first + at].extend(spans.iter().filter_map(|(start, end, by)| {
                let (start, end) = ((*start).max(from), (*end).min(to));
                (start < end).then(|| (start - from, end - from, *by))
            }));
        }
        first = last + 1;
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_words_are_read_at_every_nesting() {
        assert_eq!(command_words("echo hi"), vec!["echo"]);
        assert_eq!(
            command_words("value=\"$(gg_scrubbed \"$2\")\" || return 2"),
            vec!["gg_scrubbed", "return"]
        );
        assert_eq!(
            command_words("while IFS= read -r line || [ -n \"$line\" ]; do"),
            vec!["read", "["]
        );
        assert_eq!(command_words("  \"$@\""), vec!["\""]);
        assert_eq!(command_words("x=$((n + 1)); eval \"$x\""), vec!["eval"]);
        assert_eq!(
            command_words("echo `rm -rf /` # comment"),
            vec!["rm", "echo"]
        );
        assert_eq!(command_words("$(get) arg"), vec!["get", "\""]);
        assert_eq!(command_words("# only a comment"), Vec::<&str>::new());
    }

    /// One row per definition shape: the source, and the names that come
    /// out diagnostic.
    #[test]
    fn a_function_is_diagnostic_only_when_its_every_body_only_prints() {
        let rows: &[(&[&str], &[&str])] = &[
            (
                &[
                    "say() {\n  printf '%s\\n' \"$1\" >&2\n}\nfail() {\n  say \"$@\"\n  exit 2\n}\nrun() {\n  local c=\"$1\"\n  eval \"$c\"\n}\nloop() {\n  loop \"$@\"\n}\n",
                ],
                &["say", "fail"],
            ),
            // A one-line body is judged on its own line, and the line after
            // it is the next definition, not part of it.
            (
                &["run() { eval \"$1\"; }\nsay() { echo \"$1\"; }\n"],
                &["say"],
            ),
            (&["run() { eval \"$1\"; }\necho hi\n}\n"], &[]),
            (&["function say { # KEY\n  echo \"$1\"\n}\n"], &["say"]),
            // The same name defined twice is diagnostic only when both are.
            (&["say() { echo \"$1\"; }\nsay() { eval \"$1\"; }\n"], &[]),
            (
                &["say() { eval \"$1\"; }\n", "say() { echo \"$1\"; }\n"],
                &[],
            ),
            (
                &["say() { echo \"$1\"; }\n", "say() { eval \"$1\"; }\n"],
                &[],
            ),
            (
                &[
                    "say() { echo \"$1\"; }\n",
                    "say() { printf '%s' \"$1\"; }\n",
                ],
                &["say"],
            ),
        ];
        for (sources, want) in rows {
            assert_eq!(
                diagnostic_functions(sources),
                want.iter().map(|name| (*name).to_owned()).collect(),
                "{sources:?}"
            );
        }
    }

    /// One row per shape: the line, and the text that must be named.
    #[test]
    fn strings_are_named_only_under_a_command_that_prints_to_the_terminal() {
        let diagnostic: BTreeSet<String> = ["say".to_owned()].into();
        fn named<'a>(line: &'a str, diagnostic: &BTreeSet<String>) -> Vec<&'a str> {
            named_spans(line, diagnostic)
                .into_iter()
                .map(|(s, e)| &line[s..e])
                .collect()
        }
        let rows: &[(&str, &[&str])] = &[
            ("# rm -rf / is refused", &["# rm -rf / is refused"]),
            ("echo \"rm -rf /\" >&2", &["rm -rf /"]),
            (
                "  printf '%s\\n' 'use --no-verify'",
                &["%s\\n", "use --no-verify"],
            ),
            (
                "say result 2 \"bypass with --no-verify\"",
                &["bypass with --no-verify"],
            ),
            ("FOO=\"x\" echo \"--no-verify\"", &["--no-verify"]),
            ("echo \"a\"; echo 'b'", &["a", "b"]),
            ("echo \"rm -rf /\" | sh", &[]),
            ("echo \"rm -rf /\" > run.sh", &[]),
            ("echo \"rm -rf /\" >> run.sh", &[]),
            ("echo \"rm -rf /\" > \"$out\"", &[]),
            ("echo \"rm -rf /\" >\"run.sh\"", &[]),
            ("echo \"rm -rf /\" > \"$(mktemp)\"", &[]),
            ("echo \"rm -rf /\" > \"/dev/null\"", &["rm -rf /"]),
            ("echo \"rm -rf /\" 2>/dev/null", &["rm -rf /"]),
            ("x=$(echo \"rm -rf /\")", &[]),
            ("echo \"$(rm -rf /)\"", &[]),
            ("eval \"rm -rf /\"", &[]),
            ("bash -c 'rm -rf /'", &[]),
            ("run \"rm -rf /\"", &[]),
            ("rm -rf /", &[]),
            ("echo done && rm -rf /", &[]),
        ];
        for (line, want) in rows {
            assert_eq!(named(line, &diagnostic), *want, "{line:?}");
        }
    }

    /// Lines joined by a trailing backslash are read as one command, and
    /// each named range is handed back to the line it sits on. One row per
    /// shape: the lines, and the text named on each.
    #[test]
    fn a_continued_line_is_read_with_the_command_it_continues() {
        let rows: &[(&[&str], &[&[&str]])] = &[
            (
                &["echo \"a\" \\", "  \"--no-verify\""],
                &[&["a"], &["--no-verify"]],
            ),
            (&["echo \"rm -rf /\" \\", "  | sh"], &[&[], &[]]),
            (&["say \\", "  \"--no-verify\""], &[&[], &[]]),
            (&["echo \"a\" \\\\", "  \"--no-verify\""], &[&["a"], &[]]),
            (
                &["# refuses rm -rf / \\", "rm -rf /"],
                &[&["# refuses rm -rf / \\"], &[]],
            ),
        ];
        for (lines, want) in rows {
            let lines: Vec<String> = lines.iter().map(|line| (*line).to_owned()).collect();
            let named: Vec<Vec<&str>> = quoted(&lines, Context::none())
                .iter()
                .zip(&lines)
                .map(|(spans, line)| spans.iter().map(|(s, e, _)| &line[*s..*e]).collect())
                .collect();
            assert_eq!(named, *want, "{lines:?}");
        }
    }

    /// Past the nesting bound the rest of the line is code: a line built to
    /// nest a million deep is judged, never walked.
    #[test]
    fn nesting_past_the_bound_is_read_as_code() {
        let deep = format!(
            "echo {}\"rm -rf /\"{}",
            "$(".repeat(100_000),
            ")".repeat(100_000)
        );
        assert_eq!(named_spans(&deep, &BTreeSet::new()), vec![]);
        // At the bound the innermost command is still read; one deeper,
        // the rest of the line is one opaque word and no command in it is.
        // The bound is the one a document tree gets, so a line is never
        // read deeper than the tree it sits in.
        assert_eq!(MAX_NESTING, crate::hash::MAX_DEPTH);
        let nested = |depth: usize| format!("{}eval x{}", "$(".repeat(depth), ")".repeat(depth));
        assert!(command_words(&nested(MAX_NESTING)).contains(&"eval"));
        assert!(!command_words(&nested(MAX_NESTING + 1)).contains(&"eval"));
        let chain: String = (0..100_000)
            .map(|n| format!("f{n}() {{ f{}; }}\n", n + 1))
            .collect();
        assert_eq!(diagnostic_functions(&[&chain]), BTreeSet::new());
    }
}
