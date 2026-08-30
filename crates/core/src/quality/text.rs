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
    /// This line's inline code spans, as byte ranges into `lower`. Only a
    /// prose line has any — inside a code block, and in a file that is not
    /// markdown at all, a backtick is the code's own character. A span may
    /// open on one line and close on a later one, so these are read for the
    /// whole document at once: see `lines`.
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

    /// Whether what stands at `at` counts as code, or is a document naming
    /// it.
    ///
    /// A markdown code span is the one quotation read here. A README
    /// writing `--no-verify` in backticks is naming the switch; the same
    /// characters standing in the open are the switch. Everything else
    /// counts — a `#` comment, a `case` arm's pattern, a string in a
    /// language this does not parse — because each of those is a switch
    /// written into a file a harness loads, and no reading of what the
    /// file would then do with it holds for every shape a file takes.
    ///
    /// The spans are markdown's own, already read into `spans`: a run of
    /// backticks closes only on a run of its own length, one that never
    /// meets its match quotes nothing, and a run reaches no further than
    /// the block it opened in.
    pub fn counts_at(&self, at: usize) -> bool {
        !self
            .spans
            .iter()
            .any(|(start, end)| at >= *start && at < *end)
    }
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
            let text = clean(input.location.clone(), &text);
            docs.push(Doc {
                location: input.location.clone(),
                role: super::DocRole::Text,
                lines: lines(&text, is_markdown(&input.location)),
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
    files
        .into_iter()
        .map(|file| {
            let Some(text) = file.text else {
                return TreeFile { text: None, ..file };
            };
            let location = format!("{root}/{}", crate::paths::slashed(&file.path));
            let supporting = is_supporting(&file.path);
            let text = clean(location.clone(), &text);
            let split = lines(&text, is_markdown(&location));
            docs.push(Doc {
                lines: match supporting {
                    true => split.into_iter().map(Line::as_description).collect(),
                    false => split,
                },
                role: super::DocRole::Text,
                location,
            });
            TreeFile {
                text: Some(text),
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
    let command = clean(format!("{root} (command)"), &command);
    docs.push(Doc {
        location: format!("{root} (command)"),
        role: super::DocRole::Text,
        lines: lines(&command, false),
    });
    // What the harness stores beside the command, not what it runs: one
    // value per line, one document, for the rules about values.
    let values = values.map(|values| {
        let values = clean(format!("{root} (entry)"), &values);
        docs.push(Doc {
            location: format!("{root} (entry)"),
            role: super::DocRole::Values,
            lines: lines(&values, false),
        });
        values
    });
    let script = script.map(|body| {
        let body = clean(root.to_owned(), &body);
        docs.push(Doc {
            location: root.to_owned(),
            role: super::DocRole::Text,
            lines: lines(&body, false),
        });
        body
    });
    (command, values, script)
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
/// markdown document has prose to tell from its blocks at all; every other
/// file is code from its first byte, and `markdown` says which this is.
///
/// The code spans come from here rather than from a line: a run of
/// backticks may close on a later line, so only something holding the
/// whole document can say which of them ever meet a match.
pub fn lines(text: &str, markdown: bool) -> Vec<Line> {
    let raw: Vec<&str> = text.lines().collect();
    let lower: Vec<String> = raw.iter().map(|line| flatten(line)).collect();
    // The spans come off the document's own bytes, and index the flattened
    // copy just as well: flattening rewrites whitespace and case one byte
    // for one, and touches neither a backtick nor the backslash escaping it.
    let spans = match markdown {
        true => crate::render::code_spans_by_line(text),
        false => vec![Vec::new(); raw.len()],
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
