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
//! Every reading errs toward the command. Past `MAX_NESTING` the rest of
//! a line is one opaque word, a function judged past that many calls is
//! not diagnostic, and a name defined twice is diagnostic only when every
//! definition is.

use std::collections::{BTreeMap, BTreeSet};

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

fn lex(line: &str) -> Vec<Tok> {
    let mut lexer = Lexer {
        s: line.as_bytes(),
        i: 0,
        depth: 0,
        toks: Vec::new(),
    };
    lexer.commands(Until::End);
    lexer.toks
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
                    Some(_) => {
                        if let Some((_, after)) = word.split_once('>') {
                            let after = after.trim_start_matches('>');
                            match after.is_empty() {
                                true => cur.target_pending = true,
                                false => cur.away |= !to_terminal(after),
                            }
                        }
                    }
                }
            }
            Tok::Str(start, end) => match cur.head {
                // The value runs to the next bare word, however many
                // fragments and substitutions it is made of.
                None if cur.value_pending => {}
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
        let shallow = format!(
            "echo {}\"rm -rf /\"{}",
            "$(".repeat(MAX_NESTING),
            ")".repeat(MAX_NESTING)
        );
        assert_eq!(named_spans(&shallow, &BTreeSet::new()), vec![]);
        let chain: String = (0..100_000)
            .map(|n| format!("f{n}() {{ f{}; }}\n", n + 1))
            .collect();
        assert_eq!(diagnostic_functions(&[&chain]), BTreeSet::new());
    }
}
