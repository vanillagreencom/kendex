//! One line of a document, and the two questions a rule asks about a
//! position in it: where the line's command starts, and whether what sits
//! there is something the line would run.

use super::super::Severity;
use super::super::phrase::find_phrase;
use super::tokens;

/// One line of a document, classified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub number: usize,
    pub text: String,
    /// ASCII-lowercased with whitespace flattened to spaces. Byte offsets
    /// match `text` exactly, so a match found here locates in the original.
    pub lower: String,
    /// This line is quoting something rather than instructing it, so its
    /// findings cost one severity less — a blockquote, or any line of a
    /// skill's supporting files. A code fence is not one of these: see
    /// [`super::lines`].
    pub describing: bool,
    /// This line is prose: markdown, outside its code blocks. It decides
    /// one thing and nothing else — which marks quote, which
    /// [`Line::runs_at`] reads. Prose names a switch inside a code span and
    /// an apostrophe in it is punctuation; a command line is the other way
    /// round. Weight is a separate question: see `describing`.
    pub prose: bool,
    /// This line's inline code spans, as byte ranges into `lower`. Read
    /// only where `prose` says the marks are markdown's. A span may open
    /// on one line and close on a later one, so these are read for the
    /// whole document at once: see [`super::lines`].
    pub spans: Vec<(usize, usize)>,
}

impl Line {
    /// Where `needle` sits in this line, allowing any run of whitespace
    /// where the needle has one space.
    pub fn find(&self, needle: &str) -> Option<usize> {
        find_phrase(&self.lower, needle)
    }

    pub fn has(&self, needle: &str) -> bool {
        self.find(needle).is_some()
    }

    /// Every offset where `needle` sits in this line. A line that mentions
    /// a path twice is two chances to match, and taking only the first lets
    /// one innocent mention hide a guilty one behind it.
    pub fn occurrences(&self, needle: &str) -> Vec<usize> {
        let mut found = Vec::new();
        let mut from = 0;
        while let Some(at) = find_phrase(&self.lower[from..], needle) {
            found.push(from + at);
            from += at + 1;
        }
        found
    }

    /// The character just before `at`, or `None` at the start of the line.
    pub fn before(&self, at: usize) -> Option<char> {
        self.lower[..at].chars().next_back()
    }

    /// The character just after a match of `len` bytes at `at`.
    pub fn after(&self, at: usize, len: usize) -> Option<char> {
        self.lower[at + len..].chars().next()
    }

    /// Mark this line as description rather than instruction.
    pub fn as_description(self) -> Line {
        Line {
            describing: true,
            ..self
        }
    }

    /// What a hit weighs here: one severity less on a line that is
    /// describing, full weight otherwise.
    pub fn weigh(&self, base: Severity) -> Severity {
        match self.describing {
            true => base.lowered(),
            false => base,
        }
    }

    /// Where this line's command starts: past a shell `case` arm's pattern
    /// list — alternatives separated by `|`, ending at the `)` that opens
    /// the arm — or at the first byte when the line carries no such list.
    ///
    /// Naming `sudo` or `--no-verify` as one of the tokens a parser should
    /// catch is not running it, and reading it as a command is the rule
    /// mistaking a list of words for an instruction.
    ///
    /// This is a deliberate narrowing of what the rules catch, and the
    /// price is stated: a line that is a bare list of single words ending
    /// in `)` is not read as a command, so a command written in exactly
    /// that shape is missed. Every such word is a pattern to match, not a
    /// program to run — `sudo)` runs nothing — and the content that pays
    /// for the narrowing is the class of skills and hooks that parse
    /// command lines, which name the dangerous verbs and switches
    /// precisely because they exist to catch them.
    ///
    /// Only the pattern half is exempt, so only the pattern half is cut. A
    /// `case` arm whose body follows on the same line still has that body
    /// read: everything from the `)` on is a command like any other.
    pub fn command_at(&self) -> usize {
        let Some((head, _)) = self.lower.split_once(')') else {
            return 0;
        };
        let pattern = head.trim();
        let is_pattern = !pattern.is_empty()
            && pattern
                .split('|')
                .map(str::trim)
                .all(|token| !token.is_empty() && token.split_whitespace().count() == 1);
        match is_pattern {
            true => head.len() + 1,
            false => 0,
        }
    }

    /// Whether this line hands `needle` to a program even though a quote
    /// mark stands in front of it.
    ///
    /// The shell takes its quote marks out before it builds the argument
    /// list, so `git commit "--no-verify"` gives git exactly what the
    /// unquoted spelling does. [`Line::runs_at`] cannot see that: it
    /// reads a position, and every position inside a quotation looks the
    /// same from there. This reads the line as the shell does and asks
    /// what each program is actually given.
    ///
    /// Two shapes count. A word that *is* the needle is that program's
    /// own argument, whatever the program turns out to be — a name
    /// nobody listed is not evidence that it ignores what it is handed,
    /// so an unrecognised program counts. A word a program will run as a
    /// command line counts by what is written inside it, which is how a
    /// switch reaches git through an `eval`, a `sh -c` or an `ssh`.
    ///
    /// What does not count is a needle standing inside a longer word that
    /// nothing will read as a command. `echo "use --no-verify"` hands one
    /// argument to `echo` and that argument is a sentence; the switch in
    /// it turns off no check, here or anywhere the sentence is printed.
    ///
    /// Each word is weighed at its own first character through
    /// `runs_at`, so a comment and a `case` arm's pattern list are still
    /// the dead text they were: this widens what a live word can be, not
    /// where a word is live.
    pub fn hands_over(&self, needle: &str) -> bool {
        if self.prose {
            return false;
        }
        tokens::commands(&self.lower).iter().any(|command| {
            let interpreted = command.runs_a_command_string();
            command
                .arguments()
                .iter()
                .filter(|word| self.runs_at(word.at.start))
                .any(|word| match interpreted {
                    true => tokens::commands(&word.text)
                        .iter()
                        .flat_map(|inner| inner.words.iter())
                        .any(|inner| inner.text == needle),
                    false => word.text == needle,
                })
        })
    }

    /// Whether this line would hand what sits at `at` to a program, or
    /// only holds the characters.
    ///
    /// A switch turns nothing off until something runs it. `echo "commit
    /// with git commit --no-verify"` prints a sentence, a guard's `case`
    /// arm names the switch to catch it, a `#` comment explains it, and a
    /// README writes it in backticks to warn about it — none of them
    /// passes it to git. What does is the same characters standing in the
    /// open, and that is the only thing this answers yes to.
    ///
    /// The marks that quote are the line's own. In prose the code spans
    /// are markdown's, already read into `spans`: a run of backticks
    /// closes only on a run of its own length, one that never meets its
    /// match quotes nothing, and `'` and `"` are punctuation throughout.
    /// On a command line `'` and `"` hold a string, a backtick runs what
    /// it holds rather than quoting it, and a `#` opens a comment that
    /// reaches the end of the line wherever a word could start.
    pub fn runs_at(&self, at: usize) -> bool {
        if at < self.command_at() {
            return false;
        }
        if self.prose {
            return !self
                .spans
                .iter()
                .any(|(start, end)| at >= *start && at < *end);
        }
        let mut open: Option<char> = None;
        let mut at_a_break = true;
        let mut chars = self.lower.char_indices();
        while let Some((offset, c)) = chars.next() {
            if offset >= at {
                return open.is_none();
            }
            if open == Some('\'') {
                // Nothing inside a single-quoted string escapes.
                open = (c != '\'').then_some('\'');
            } else if c == '\\' {
                chars.next();
            } else if open == Some('"') {
                open = (c != '"').then_some('"');
            } else if c == '\'' || c == '"' {
                open = Some(c);
            } else if c == '#' && at_a_break {
                return false;
            }
            at_a_break = c.is_whitespace() || ends_a_token(c);
        }
        open.is_none()
    }
}

/// Where a shell word can start again: after one of the operator
/// characters, the same as after a space. `true;# never use --no-verify`
/// runs the switch no more than `true # never use --no-verify` does.
///
/// Every longer operator — `&&`, `||`, `;;`, `2>`, `&>` — ends in one of
/// these, so the character before the `#` is the whole question. Nothing
/// else ends a word: after `{`, `}`, `!`, `=` or a closing quote the `#`
/// is another byte of the word already being built, and a literal `#` is
/// not a comment.
fn ends_a_token(c: char) -> bool {
    matches!(c, ';' | '&' | '|' | '<' | '>' | '(' | ')')
}
