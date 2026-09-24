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

use std::collections::{BTreeMap, BTreeSet};

/// Builtins that print what they are handed.
const SPEAKS: &[&str] = &["echo", "printf"];

/// Words that assign, test or steer and never run what they are handed. A
/// function built from these, `SPEAKS`, and other such functions is a
/// diagnostic function: a formatting helper that pipes through `tr` or
/// `sed` is not one, and the strings it prints stay commands. That is the
/// price of reading no further, and it errs toward the finding.
const HOLDS: &[&str] = &[
    "local", "declare", "typeset", "readonly", "export", "read", "shift", "return", "exit",
    "continue", "break", ":", "true", "false", "[", "[[", "test", "while", "until", "if", "then",
    "elif", "else", "fi", "do", "done", "case", "esac", "!", "{", "}",
];

/// Words after which the next word is still the command: the control
/// keywords that open a command, and the `{` of a group. A closing word
/// (`done`, `fi`, `esac`, `}`) is followed by a redirection or nothing.
const KEYWORDS: &[&str] = &[
    "if", "then", "else", "elif", "while", "until", "do", "!", "{", "time",
];

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
    toks: Vec<Tok>,
}

impl<'a> Lexer<'a> {
    fn at(&self, offset: usize) -> Option<u8> {
        self.s.get(self.i + offset).copied()
    }

    fn open(&mut self, until: Until) {
        self.toks.push(Tok::Open);
        self.commands(until);
        self.toks.push(Tok::Close);
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

/// Every word in command position on this line, at any nesting: the first
/// word of each command and of each substitution. A quoted string standing
/// where a command goes — `"$@"` — is reported as `"`, a word no command
/// is named by.
fn command_words(line: &str) -> Vec<&str> {
    let toks = lex(line);
    let mut words = Vec::new();
    let mut expecting = true;
    // The string an assignment word opens is its value, not a command.
    let mut value = false;
    for tok in toks {
        match tok {
            Tok::Word(start, end) => {
                let word = &line[start..end];
                value = false;
                if expecting {
                    words.push(word);
                    value = is_assignment(word);
                    expecting = KEYWORDS.contains(&word) || value;
                }
            }
            Tok::Str(..) => {
                if expecting && !value {
                    words.push("\"");
                    expecting = false;
                }
            }
            Tok::Break | Tok::Pipe | Tok::Open => expecting = true,
            Tok::Close => expecting = false,
        }
    }
    words
}

/// The name a line defines a function under, where it does:
/// `name() {`, `function name {` or `function name() {`.
fn defined(line: &str) -> Option<&str> {
    let line = line.trim();
    let line = line.strip_prefix("function ").map_or(line, str::trim_start);
    let (name, rest) = line.split_once(['(', ' '])?;
    let rest = rest.trim_start_matches(')').trim();
    let named = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    (named && rest.starts_with('{')).then_some(name)
}

/// The functions these shell sources define whose bodies only print,
/// assign, test and steer — so a string handed to one is printed, never
/// run. A body is the lines down to the first unindented `}`; a function
/// closed any other way is read as far as that and judged on what was
/// read, which errs toward the command.
pub fn diagnostic_functions(sources: &[&str]) -> BTreeSet<String> {
    let mut bodies: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for source in sources {
        let mut lines = source.lines();
        while let Some(line) = lines.next() {
            let Some(name) = defined(line) else {
                continue;
            };
            let body = lines.by_ref().take_while(|line| *line != "}").collect();
            bodies.insert(name, body);
        }
    }
    let mut judged: BTreeMap<&str, Option<bool>> = BTreeMap::new();
    for name in bodies.keys() {
        judge(name, &bodies, &mut judged);
    }
    judged
        .into_iter()
        .filter(|(_, verdict)| *verdict == Some(true))
        .map(|(name, _)| name.to_owned())
        .collect()
}

/// Whether `name` is diagnostic, memoized; a function in the middle of
/// being judged (a cycle) is not.
fn judge<'a>(
    name: &'a str,
    bodies: &BTreeMap<&'a str, Vec<&'a str>>,
    judged: &mut BTreeMap<&'a str, Option<bool>>,
) -> bool {
    match judged.get(name) {
        Some(Some(verdict)) => return *verdict,
        Some(None) => return false,
        None => {}
    }
    judged.insert(name, None);
    let verdict = bodies[name].iter().all(|line| {
        command_words(line).into_iter().all(|word| {
            SPEAKS.contains(&word)
                || HOLDS.contains(&word)
                || is_assignment(word)
                || (bodies.contains_key(word) && judge(word, bodies, judged))
        })
    });
    judged.insert(name, Some(verdict));
    verdict
}

/// Whether a redirection word sends output somewhere that is still the
/// terminal or nowhere: `>&2`, `2>&1`, `>/dev/null`. A file is a program's
/// input later.
fn redirects_to_terminal(word: &str, target: Option<&str>) -> bool {
    let after = word
        .split_once('>')
        .map(|(_, after)| after.trim_start_matches('>'));
    let target = match after {
        Some("") => target.unwrap_or(""),
        Some(after) => after,
        None => return true,
    };
    target.starts_with('&') || target.starts_with("/dev/")
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
    let toks = lex(line);
    let mut spans = Vec::new();
    let mut depth = 0usize;
    let mut expecting = true;
    // Strings under the current command, kept until the command ends
    // without piping or redirecting them elsewhere.
    let mut pending: Vec<(usize, usize)> = Vec::new();
    let mut speaks = false;
    let mut settle = |pending: &mut Vec<(usize, usize)>, keep: bool| {
        if keep {
            spans.append(pending);
        }
        pending.clear();
    };
    let mut keep = true;
    for (index, tok) in toks.iter().enumerate() {
        match *tok {
            Tok::Word(start, end) if depth == 0 => {
                let word = &line[start..end];
                if expecting {
                    if !(KEYWORDS.contains(&word) || is_assignment(word)) {
                        speaks = SPEAKS.contains(&word) || diagnostic.contains(word);
                        expecting = false;
                    }
                } else if word.contains('>') {
                    let next = toks[index + 1..].iter().find_map(|tok| match tok {
                        Tok::Word(s, e) => Some(&line[*s..*e]),
                        _ => None,
                    });
                    keep &= redirects_to_terminal(word, next);
                }
            }
            Tok::Str(start, end) if depth == 0 => {
                if expecting {
                    expecting = false;
                } else if speaks && start < end {
                    pending.push((start, end));
                }
            }
            Tok::Word(..) | Tok::Str(..) => {}
            Tok::Break | Tok::Pipe if depth > 0 => expecting = true,
            Tok::Break => {
                settle(&mut pending, keep);
                keep = true;
                expecting = true;
                speaks = false;
            }
            Tok::Pipe => {
                settle(&mut pending, false);
                keep = true;
                expecting = true;
                speaks = false;
            }
            Tok::Open => {
                depth += 1;
                expecting = true;
            }
            Tok::Close => {
                depth = depth.saturating_sub(1);
                expecting = false;
            }
        }
    }
    settle(&mut pending, keep);
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_words_are_read_at_every_nesting() {
        assert_eq!(command_words("echo hi"), vec!["echo"]);
        assert_eq!(
            command_words("value=\"$(gg_scrubbed \"$2\")\" || return 2"),
            vec!["value=", "gg_scrubbed", "return"]
        );
        assert_eq!(
            command_words("while IFS= read -r line || [ -n \"$line\" ]; do"),
            vec!["while", "IFS=", "read", "[", "do"]
        );
        assert_eq!(command_words("  \"$@\""), vec!["\""]);
        assert_eq!(
            command_words("x=$((n + 1)); eval \"$x\""),
            vec!["x=$((n + 1))", "eval"]
        );
        assert_eq!(
            command_words("echo `rm -rf /` # comment"),
            vec!["echo", "rm"]
        );
        assert_eq!(command_words("# only a comment"), Vec::<&str>::new());
    }

    #[test]
    fn a_function_is_diagnostic_only_when_its_body_only_prints() {
        let lib = "say() {\n  printf '%s\\n' \"$1\" >&2\n}\nfail() {\n  say \"$@\"\n  exit 2\n}\nrun() {\n  local c=\"$1\"\n  eval \"$c\"\n}\nloop() {\n  loop \"$@\"\n}\n";
        assert_eq!(
            diagnostic_functions(&[lib]),
            ["say", "fail"].into_iter().map(str::to_owned).collect()
        );
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
            ("echo \"a\"; echo 'b'", &["a", "b"]),
            ("echo \"rm -rf /\" | sh", &[]),
            ("echo \"rm -rf /\" > run.sh", &[]),
            ("echo \"rm -rf /\" >> run.sh", &[]),
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
}
