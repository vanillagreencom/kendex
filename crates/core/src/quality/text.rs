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

mod line;
mod normalize;
pub(in crate::quality) mod tokens;

pub use line::{Line, Reading};
pub use normalize::deobfuscate;

use super::{AuditInput, Content, Doc, Prepared, TreeFile};

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
                lines: lines(&text, reading(&input.location, &text)),
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
            let split = lines(&text, reading(&location, &text));
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
        lines: lines(&command, Reading::Shell),
    });
    // What the harness stores beside the command, not what it runs: one
    // value per line, one document, for the rules about values.
    let values = values.map(|values| {
        let values = clean(format!("{root} (entry)"), &values);
        docs.push(Doc {
            location: format!("{root} (entry)"),
            role: super::DocRole::Values,
            lines: lines(&values, Reading::Shell),
        });
        values
    });
    let script = script.map(|body| {
        let body = clean(root.to_owned(), &body);
        docs.push(Doc {
            location: root.to_owned(),
            role: super::DocRole::Text,
            lines: lines(&body, reading(root, &body)),
        });
        body
    });
    (command, values, script)
}

/// Split into lines, marking the ones that are quoting somebody else and
/// the ones that are prose.
///
/// A code fence is deliberately *not* one of the quoting marks. A fenced
/// `sh` block in a SKILL.md is not an illustration of the instruction, it
/// is the instruction — it is the shape every real skill writes its
/// commands in, and exempting it would mean the gate blocks the unnatural
/// spelling of an attack and waves the natural one through. A blockquote is
/// different: it is markdown's way of saying "these are someone else's
/// words".
///
/// What a fence does decide is which marks quote *inside* the line, which
/// is [`Line::reading`]. A markdown document has prose to tell from blocks
/// at all; a script is a command line from its first byte.
///
/// The code spans come from here too, and for the same reason: a run of
/// backticks may close on a later line, so only something holding the
/// whole document can say which of them ever meet a match.
pub fn lines(text: &str, reading: Reading) -> Vec<Line> {
    let raw: Vec<&str> = text.lines().collect();
    let lower: Vec<String> = raw.iter().map(|line| flatten(line)).collect();
    let prose = match reading {
        Reading::Prose => crate::render::prose_lines(text),
        Reading::Shell | Reading::Opaque => vec![false; raw.len()],
    };
    let spans = crate::render::code_spans_by_line(&lower, &prose);
    raw.iter()
        .zip(lower)
        .zip(spans)
        .enumerate()
        .map(|(index, ((raw, lower), spans))| Line {
            number: index + 1,
            lower,
            describing: raw.trim_start().starts_with('>'),
            // A markdown document is prose outside its blocks and a
            // command line inside them; every other document is one
            // reading throughout.
            reading: match prose[index] {
                true => Reading::Prose,
                false => match reading {
                    Reading::Prose => Reading::Shell,
                    other => other,
                },
            },
            spans,
            text: (*raw).to_owned(),
        })
        .collect()
}

/// Shells whose scripts are the command lines this rule reads.
const SHELLS: &[&str] = &["sh", "bash", "zsh", "dash", "ksh", "ash"];

/// Suffixes that name one of those scripts.
const SHELL_SUFFIXES: &[&str] = &[".sh", ".bash", ".zsh", ".ksh", ".bats"];

/// Which syntax reads this document.
///
/// Markdown by its suffix, with the parked suffix taken off first:
/// `SKILL.md.disabled` is the same markdown as `SKILL.md` and the audit
/// reads it as one, so judging it by the trailing extension would make
/// switching an item off turn its code spans back into findings.
///
/// Otherwise a shebang settles it, because that line is the file saying
/// what runs it. Failing that, a shell suffix, and then a name carrying no
/// suffix at all — a script in a skill's `scripts/` directory is written
/// without one, and every such file this repository ships is a shell
/// script.
///
/// Everything left is a program in some other language, and this rule does
/// not read those. A `.rs`, `.py` or `.js` file hands a program its
/// arguments through a call, not a command line, and a `.json` or `.toml`
/// file holds strings some other reader gives meaning to. None of that
/// makes what is written there any less handed over, so none of it is read
/// as quoted: see [`Reading::Opaque`].
fn reading(location: &str, text: &str) -> Reading {
    let lower = location.to_ascii_lowercase();
    let base = lower.strip_suffix(".disabled").unwrap_or(&lower);
    if base.ends_with(".md") || base.ends_with(".markdown") {
        return Reading::Prose;
    }
    if let Some(interpreter) = shebang(text) {
        return match SHELLS.contains(&interpreter.as_str()) {
            true => Reading::Shell,
            false => Reading::Opaque,
        };
    }
    let name = base.rsplit('/').next().unwrap_or(base);
    let shell = SHELL_SUFFIXES.iter().any(|suffix| name.ends_with(suffix)) || !name.contains('.');
    match shell {
        true => Reading::Shell,
        false => Reading::Opaque,
    }
}

/// The interpreter a first line names, by its own name rather than the
/// path it was reached through. `#!/usr/bin/env bash` names it in the word
/// after `env`, which is how nearly every script this reads is written.
fn shebang(text: &str) -> Option<String> {
    let mut words = text
        .lines()
        .next()?
        .strip_prefix("#!")?
        .split_whitespace()
        .filter(|word| !word.starts_with('-'));
    let program = words.next()?;
    let named = program.rsplit('/').next().unwrap_or(program);
    let named = match named == "env" {
        true => words.next().unwrap_or(named),
        false => named,
    };
    Some(named.to_ascii_lowercase())
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
