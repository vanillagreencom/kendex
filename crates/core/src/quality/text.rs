//! Reading content the way a model reads it, not the way a byte comparison
//! does. Three passes: invisible characters come out, compatibility forms
//! collapse (NFKC), and letters that merely look Latin are folded to the
//! Latin letters they imitate. What the rules then match is the text a
//! reader sees, so `ignоre previous instructions` with a Cyrillic о is the
//! same string as the plain one.
//!
//! Nothing here is silent. Every change is counted per document and handed
//! to the `obfuscated-content` rule, because content that needs
//! deobfuscating to look clean has said something about itself.

use std::collections::BTreeSet;

mod normalize;
mod shell;
pub use normalize::deobfuscate;

use super::phrase::find_phrase;
use super::{AuditInput, Content, Doc, Prepared, Severity, TreeFile};

/// What deobfuscation had to do to one document. Only the two counts are
/// reportable: see `changed`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Normalization {
    pub location: String,
    /// Zero-width, bidi and joining characters removed. Variation
    /// selectors are not counted here — see `is_reportable`.
    pub invisible: usize,
    /// Letters folded to the Latin letters they imitate.
    pub homoglyphs: usize,
    /// Bytes that were not valid UTF-8 and had to be replaced to read this
    /// as text at all.
    pub undecodable: usize,
    /// A short name for where those replacements sit in this document's own
    /// text — the readable characters around each hole. The bytes are gone
    /// by the time anything here runs, and a sentence that says only how
    /// many there were is the same sentence in every file with that many:
    /// one decision, settling files the reader never saw. `None` where
    /// nothing had to be replaced.
    pub unreadable: Option<String>,
    /// The distinct characters behind `invisible` and `homoglyphs`, in code
    /// point order. A finding's identity is its rule and its sentence, so a
    /// sentence that says only how many were found is the same sentence for
    /// every file that found that many — and a person shown one would
    /// settle the others unseen. What was found is what tells them apart.
    pub found: BTreeSet<char>,
}

impl Normalization {
    /// Whether this is worth reporting.
    ///
    /// Deliberately not "did anything change". NFKC changes ordinary
    /// typography — an ellipsis, a non-breaking space, an `ﬁ` ligature —
    /// and emoji carry variation selectors by construction (`⚠️` is a
    /// warning sign plus U+FE0F). Both are stripped so that the other
    /// rules read a plain string, and neither says anything about intent.
    /// What is left — zero-width characters, bidirectional overrides,
    /// letters chosen to imitate other letters — has no typographic use.
    pub fn changed(&self) -> bool {
        self.invisible > 0 || self.homoglyphs > 0
    }

    /// Whether anything here is worth handing to a rule at all.
    pub fn reportable(&self) -> bool {
        self.changed() || self.undecodable > 0
    }
}

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
    /// `lines`.
    pub describing: bool,
    /// Byte ranges into `lower` where the file names text rather than
    /// running it, each with which quotation names it. In markdown these
    /// are the inline code spans, read for the whole document at once
    /// because a span may open on one line and close on a later one (see
    /// `lines`); in a shell file they are a full-line comment and the
    /// strings a diagnostic command prints (see [`shell::named_spans`]).
    /// Any other file has none.
    pub spans: Vec<Span>,
}

/// One range of a line that names its text, and the quotation that says
/// so. A rule chooses which quotations it reads as naming: a destructive
/// command in a README's backticks is still the command a reader will
/// paste, while the same words in a guard's own comment are the guard
/// describing what it refuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub by: Quotation,
}

/// What marks a range of a line as named rather than run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quotation {
    /// A markdown inline code span.
    CodeSpan,
    /// A shell comment, or a string a shell script prints to the
    /// terminal.
    ShellText,
}

/// Where a needle stands on a line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    /// At least one occurrence is code: a finding.
    Code,
    /// Every occurrence is inside a span that names it: a mention, kept
    /// for a verbose reading and costing the score nothing.
    Named,
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

    /// Whether what stands at `at` counts as code, or is the file naming
    /// it under one of the quotations `reads`.
    ///
    /// Two quotations exist. A markdown code span: a README writing
    /// `--no-verify` in backticks is naming the switch, and the same
    /// characters standing in the open are the switch. And, in a shell
    /// file, a full-line comment or a string that `echo`, `printf` or a
    /// function that only prints hands to the terminal: a guard that
    /// refuses the switch spells it in exactly those two places, and
    /// nowhere the shell would run it. Everything else counts — a `case`
    /// arm's pattern, a string handed to any other command, a string in a
    /// language this does not parse — because each of those is a switch
    /// written into a file a harness loads, and no reading of what the
    /// file would then do with it holds for every shape a file takes.
    fn counts_at(&self, at: usize, reads: &[Quotation]) -> bool {
        !self
            .spans
            .iter()
            .any(|span| reads.contains(&span.by) && at >= span.start && at < span.end)
    }

    /// Where `needle` stands on this line, if anywhere: one occurrence
    /// that counts makes it code, and a line that only names it under a
    /// quotation in `reads` is a mention. Every rule that reads a switch
    /// off a line reads it through here, so the shapes of naming are told
    /// apart in one place and each rule says which it honours.
    pub fn standing(&self, needle: &str, reads: &[Quotation]) -> Option<Standing> {
        let occurrences = self.occurrences(needle);
        match occurrences.iter().any(|at| self.counts_at(*at, reads)) {
            true => Some(Standing::Code),
            false => (!occurrences.is_empty()).then_some(Standing::Named),
        }
    }
}

/// Which language's quotation marks a document is read with.
#[derive(Debug, Clone, Copy)]
pub enum Reading<'a> {
    /// Markdown: inline code spans name their text.
    Markdown,
    /// A shell script: comments and the strings a diagnostic command
    /// prints name their text. The set is the tree's diagnostic functions
    /// (see [`shell::diagnostic_functions`]).
    Shell(&'a BTreeSet<String>),
    /// Every other file is code from its first byte and quotes nothing.
    Plain,
}

/// Deobfuscate every text this input carries and split it into lines.
pub fn prepare(input: AuditInput) -> Prepared {
    let mut normalized = Vec::new();
    let mut docs = Vec::new();
    let mut clean = |location: String, text: &str| -> String {
        let (out, report) = deobfuscate(&location, text);
        if report.reportable() {
            normalized.push(report);
        }
        out
    };
    let content = match input.content {
        Content::Document { text } => {
            let digest = digest(&text);
            let text = clean(input.location.clone(), &text);
            docs.push(Doc {
                location: input.location.clone(),
                role: super::DocRole::Text,
                lines: lines(
                    &text,
                    language(&input.location, &text).reading(&BTreeSet::new()),
                ),
                digest,
            });
            Content::Document { text }
        }
        Content::SkillTree { files } => Content::SkillTree {
            files: tree_docs(&input.location, files, &mut clean, &mut docs),
        },
        Content::Hook {
            event,
            matcher,
            command,
            values,
            script,
        } => {
            let (command, values, script) = hook_docs(
                &input.location,
                command,
                values,
                script,
                &mut clean,
                &mut docs,
            );
            Content::Hook {
                event,
                matcher,
                command,
                values,
                script,
            }
        }
        Content::Mcp(entry) => Content::Mcp(entry),
        Content::Unread { why } => Content::Unread { why },
        Content::Plugin(sources) => Content::Plugin(super::PluginSources {
            scripts: tree_docs(&input.location, sources.scripts, &mut clean, &mut docs),
            ..sources
        }),
    };
    Prepared {
        input: AuditInput { content, ..input },
        docs,
        normalized,
    }
}

fn tree_docs(
    root: &str,
    files: Vec<TreeFile>,
    clean: &mut impl FnMut(String, &str) -> String,
    docs: &mut Vec<Doc>,
) -> Vec<TreeFile> {
    // The location a deobfuscation report is filed under is the one every
    // line rule cites, spelled once here for both.
    let placed: Vec<(TreeFile, String, Option<Cleaned>)> = files
        .into_iter()
        .map(|file| {
            let location = format!("{root}/{}", crate::paths::slashed(&file.path));
            let cleaned = file.text.map(|text| Cleaned {
                digest: digest(&text),
                text: clean(location.clone(), &text),
            });
            (TreeFile { text: None, ..file }, location, cleaned)
        })
        .collect();
    // A script calls the message helpers its tree's library files define,
    // so the diagnostic functions are read off every shell file of the
    // tree before any one of them is split into lines. Each file's
    // language is decided once, here, for both passes.
    let languages: Vec<Option<Language>> = placed
        .iter()
        .map(|(_, location, cleaned)| {
            cleaned
                .as_ref()
                .map(|cleaned| language(location, &cleaned.text))
        })
        .collect();
    let shell: Vec<&str> = placed
        .iter()
        .zip(&languages)
        .filter(|(_, language)| **language == Some(Language::Shell))
        .filter_map(|((_, _, cleaned), _)| cleaned.as_ref().map(|cleaned| cleaned.text.as_str()))
        .collect();
    let diagnostic = shell::diagnostic_functions(&shell);
    placed
        .into_iter()
        .zip(languages)
        .map(|((file, location, cleaned), language)| {
            let Some(cleaned) = cleaned else {
                return file;
            };
            if let Some(language) = language {
                let split = lines(&cleaned.text, language.reading(&diagnostic));
                docs.push(Doc {
                    lines: match is_supporting(&file.path) {
                        true => split.into_iter().map(Line::as_description).collect(),
                        false => split,
                    },
                    role: super::DocRole::Text,
                    location,
                    digest: cleaned.digest,
                });
            }
            TreeFile {
                text: Some(cleaned.text),
                ..file
            }
        })
        .collect()
}

/// A file that comes along with a skill rather than being what a harness
/// loads. Its findings weigh one severity less: a test asserting that a
/// command line is passed through is describing that command line, not
/// issuing it, and a reference page is background reading the model pulls in
/// only when it needs the detail.
///
/// This was settled by a real catalog. The kendex `orch` skill ships tests
/// that assert `--dangerously-skip-permissions` reaches the launcher, and
/// the `review-gate` skill has a test that base64-encodes a fixture. Both
/// are exactly what those rules look for, and neither is the skill telling
/// a model to do anything. A key in one of these files still counts in
/// full, because `plaintext-secrets` never downgrades.
///
/// The primary file — SKILL.md, an agent or command body, a hook's script —
/// is never supporting, whatever it puts inside a fence.
fn is_supporting(path: &std::path::Path) -> bool {
    path.components().any(|component| {
        matches!(
            component.as_os_str().to_str(),
            Some(
                "tests"
                    | "test"
                    | "__tests__"
                    | "fixtures"
                    | "testdata"
                    | "references"
                    | "reference"
            )
        )
    })
}

/// A hook's documents — its command, the values it stores, and its script
/// — each cleaned and pushed under its own label, handed back in that
/// order.
fn hook_docs(
    root: &str,
    command: String,
    values: Option<String>,
    script: Option<String>,
    clean: &mut impl FnMut(String, &str) -> String,
    docs: &mut Vec<Doc>,
) -> (String, Option<String>, Option<String>) {
    // The command line is run by a shell, and its script defines nothing
    // the command line can call.
    let command_digest = digest(&command);
    let command = clean(format!("{root} (command)"), &command);
    docs.push(Doc {
        location: format!("{root} (command)"),
        role: super::DocRole::Text,
        lines: lines(&command, Reading::Shell(&BTreeSet::new())),
        digest: command_digest,
    });
    // What the harness stores beside the command, not what it runs: one
    // value per line, one document, for the rules about values.
    let values = values.map(|values| {
        let digest = digest(&values);
        let values = clean(format!("{root} (entry)"), &values);
        docs.push(Doc {
            location: format!("{root} (entry)"),
            role: super::DocRole::Values,
            lines: lines(&values, Reading::Plain),
            digest,
        });
        values
    });
    let script = script.map(|body| {
        let digest = digest(&body);
        let body = clean(root.to_owned(), &body);
        let language = language(root, &body);
        let diagnostic = match language {
            Language::Shell => shell::diagnostic_functions(&[&body]),
            Language::Markdown | Language::Plain => BTreeSet::new(),
        };
        docs.push(Doc {
            location: root.to_owned(),
            role: super::DocRole::Text,
            lines: lines(&body, language.reading(&diagnostic)),
            digest,
        });
        body
    });
    (command, values, script)
}

/// One tree file's text as the rules read it, beside the name of the text
/// it was read from: the digest is taken before deobfuscation, so it is
/// the hash a file of exactly the author's text has on disk.
struct Cleaned {
    text: String,
    digest: String,
}

/// What names a document's text wherever a reading has to say which text
/// it read: the hash a file of exactly this text has on disk.
fn digest(text: &str) -> String {
    crate::hash::hash_bytes(text.as_bytes())
}

/// Split into lines, marking the ones that are quoting somebody else and
/// reading the code spans of the ones that are prose.
///
/// A code fence is deliberately *not* one of the quoting marks. A fenced
/// `sh` block in a SKILL.md is not an illustration of the instruction, it
/// is the instruction — it is the shape every real skill writes its
/// commands in, and exempting it would mean the gate blocks the unnatural
/// spelling of an attack and waves the natural one through. A blockquote is
/// different: it is markdown's way of saying "these are someone else's
/// words".
///
/// What a fence does decide is which marks quote *inside* the line. A
/// markdown document has prose to tell from its blocks at all; a shell
/// file has comments and the strings it prints; every other file is code
/// from its first byte, and `reading` says which this is.
///
/// The code spans come from here rather than from a line: a run of
/// backticks may close on a later line, so only something holding the
/// whole document can say which of them ever meet a match.
pub fn lines(text: &str, reading: Reading<'_>) -> Vec<Line> {
    let raw: Vec<&str> = text.lines().collect();
    let lower: Vec<String> = raw.iter().map(|line| flatten(line)).collect();
    // The spans come off the document's own bytes, and index the flattened
    // copy just as well: flattening rewrites whitespace and case one byte
    // for one, and touches neither a backtick nor the backslash escaping it.
    let marked = |by: Quotation| {
        move |ranges: Vec<(usize, usize)>| -> Vec<Span> {
            ranges
                .into_iter()
                .map(|(start, end)| Span { start, end, by })
                .collect()
        }
    };
    let spans: Vec<Vec<Span>> = match reading {
        Reading::Markdown => crate::render::code_by_line(text)
            .spans
            .into_iter()
            .map(marked(Quotation::CodeSpan))
            .collect(),
        Reading::Shell(diagnostic) => lower
            .iter()
            .map(|line| marked(Quotation::ShellText)(shell::named_spans(line, diagnostic)))
            .collect(),
        Reading::Plain => vec![Vec::new(); raw.len()],
    };
    raw.iter()
        .zip(lower)
        .zip(spans)
        .enumerate()
        .map(|(index, ((raw, lower), spans))| Line {
            number: index + 1,
            lower,
            describing: raw.trim_start().starts_with('>'),
            spans,
            text: (*raw).to_owned(),
        })
        .collect()
}

/// Whether this document is markdown, the one language whose quotation
/// these rules read.
///
/// The parked suffix comes off first. `SKILL.md.disabled` is the same
/// markdown as `SKILL.md` and the audit reads it as one, so judging it by
/// the trailing extension would make switching an item off turn its code
/// spans back into findings.
fn is_markdown(location: &str) -> bool {
    let lower = location.to_ascii_lowercase();
    let base = lower.strip_suffix(".disabled").unwrap_or(&lower);
    base.ends_with(".md") || base.ends_with(".markdown")
}

/// Whether this document is a shell script: by its extension, or by the
/// interpreter line a script with no extension carries — every guard
/// script in the catalog is `#!/usr/bin/env bash` under a bare name.
fn is_shell(location: &str, text: &str) -> bool {
    let lower = location.to_ascii_lowercase();
    lower.ends_with(".sh")
        || lower.ends_with(".bash")
        || text
            .lines()
            .next()
            .is_some_and(|first| first.starts_with("#!") && first.contains("sh"))
}

/// The language a document is read in, decided once per document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Language {
    Markdown,
    Shell,
    Plain,
}

impl Language {
    /// How to read a document of this language, given the tree's
    /// diagnostic functions.
    fn reading(self, diagnostic: &BTreeSet<String>) -> Reading<'_> {
        match self {
            Language::Markdown => Reading::Markdown,
            Language::Shell => Reading::Shell(diagnostic),
            Language::Plain => Reading::Plain,
        }
    }
}

fn language(location: &str, text: &str) -> Language {
    if is_markdown(location) {
        Language::Markdown
    } else if is_shell(location, text) {
        Language::Shell
    } else {
        Language::Plain
    }
}

/// ASCII-lowercase with every whitespace byte turned into a space. Both
/// operations are byte-for-byte, so offsets still index the original line.
fn flatten(raw: &str) -> String {
    raw.chars()
        .map(|c| match c.is_ascii() {
            true if c.is_ascii_whitespace() => ' ',
            true => c.to_ascii_lowercase(),
            false => c,
        })
        .collect()
}
