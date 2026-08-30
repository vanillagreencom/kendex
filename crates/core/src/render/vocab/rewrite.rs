//! The prose rewrite: saying a body's tool references in the reader's
//! own words, conservatively enough that a body nobody can translate is
//! left as authored rather than mangled.

use super::super::RenderWarning;
use super::super::fences::{code_spans, fence_marker};
use super::{CLAUDE_TOOLS, SKILL_POINTER, Word, word};
use crate::model::HarnessId;

/// Say the body's tool references in `harness`'s vocabulary. Only two
/// shapes are touched — `the Read tool` and `` `Read` tool `` — because
/// only they can mean a tool and nothing else. Samples the agent is meant
/// to copy (code fences, inline literals), links, and generated skill
/// paths keep every byte, and a name this module does not know is reported
/// rather than guessed at.
///
/// Codex is the exception, because it names actions rather than tools: a
/// phrase can only stand where the whole reference does, so exactly one
/// shape is reworded — `use the Read tool` becomes `open the file`. Every
/// other mention stays in Claude's words, which reads as an unfamiliar name
/// rather than as a broken sentence, and one warning says so.
///
/// Renderers pass the agent's own body and nothing else. Launch and
/// additional instructions are the project's words about this project;
/// rewriting them would put words in the author's mouth, and the author is
/// there to change them.
pub fn rewrite_prose(body: &str, harness: HarnessId) -> (String, Vec<RenderWarning>) {
    if harness == HarnessId::Claude {
        return (body.to_owned(), Vec::new());
    }
    let mut out = String::with_capacity(body.len());
    let mut reworded: Vec<String> = Vec::new();
    let mut kept: Vec<String> = Vec::new();
    let mut fence: Option<(char, usize)> = None;
    for line in body.split_inclusive('\n') {
        match (fence_marker(line), fence) {
            (Some((marker, run, bare)), Some((open, len)))
                if marker == open && run >= len && bare =>
            {
                fence = None;
            }
            (Some((marker, run, _)), None) => fence = Some((marker, run)),
            _ if fence.is_none() && !line.contains(SKILL_POINTER) => {
                out.push_str(&rewrite_line(line, harness, &mut reworded, &mut kept));
                continue;
            }
            _ => {}
        }
        out.push_str(line);
    }

    let mut warnings = Vec::new();
    if !reworded.is_empty() {
        warnings.push(RenderWarning::new(format!(
            "tool references reworded for {}: {}",
            harness.display_name(),
            reworded.join(", ")
        )));
    }
    if !kept.is_empty() {
        warnings.extend(left_as_written(&kept, harness));
    }
    (out, warnings)
}

/// What the rewrite could not say in the harness's own words. Codex has no
/// tool names at all, so listing every mention one by one would bury the
/// body in warnings — one line names them together.
fn left_as_written(kept: &[String], harness: HarnessId) -> Vec<RenderWarning> {
    if harness == HarnessId::Codex {
        return vec![RenderWarning::new(format!(
            "left in Claude's words for Codex: {} — Codex names actions, not tools, so only a whole `use the X tool` is reworded",
            kept.join(", ")
        ))];
    }
    kept.iter()
        .map(|tool| {
            RenderWarning::new(format!(
                "`{tool}` is not {} tool name — the reference passes through as written",
                with_article(harness.display_name())
            ))
        })
        .collect()
}

/// "a Cursor", "an OpenCode" — harness names are proper nouns, and only some
/// of them open with a vowel.
fn with_article(name: &str) -> String {
    match name.starts_with(['A', 'E', 'I', 'O', 'U']) {
        true => format!("an {name}"),
        false => format!("a {name}"),
    }
}

fn rewrite_line(
    line: &str,
    harness: HarnessId,
    reworded: &mut Vec<String>,
    kept: &mut Vec<String>,
) -> String {
    let spans = code_spans(line);
    let links = link_ranges(line);
    let mut out = String::with_capacity(line.len());
    let mut copied = 0;
    for (at, _) in line.match_indices("tool") {
        let Some(reference) = reference_before(line, at) else {
            continue;
        };
        let (from, to) = reference.name;
        let name = &line[from..to];
        // A link is a target, and a code span holding more than the name
        // itself is a sample to copy — neither is prose about a tool.
        let quoted_reference =
            |(open, close): &(usize, usize)| line[*open..*close].trim_matches('`').trim() == name;
        if reference.start < copied
            || links
                .iter()
                .any(|(open, close)| from >= *open && from < *close)
            || spans
                .iter()
                .any(|span| from > span.0 && to < span.1 && !quoted_reference(span))
        {
            continue;
        }
        let (from, to, said) = match (CLAUDE_TOOLS.contains(&name), word(name, harness)) {
            (true, Some(Word::Name(said))) => (from, to, said.to_owned()),
            // A phrase names an action, so it can only stand where a whole
            // `use the X tool` stood. Anywhere else — as a subject, after
            // another verb, in backticks — it would put a verb phrase in a
            // noun's place and the sentence would stop making sense.
            (true, Some(Word::Phrase(said))) => match reference.verb {
                Some(capital) if !reference.quoted => match capital {
                    true => (reference.start, at + 4, capitalize(said)),
                    false => (reference.start, at + 4, said.to_owned()),
                },
                _ => {
                    remember(kept, name);
                    continue;
                }
            },
            // A tool this harness has no word for, and any name that is not
            // ours to translate — an MCP id, a plugin's own tool.
            (true, None) | (false, _) if tool_shaped(name) => {
                remember(kept, name);
                continue;
            }
            _ => continue,
        };
        remember(reworded, name);
        out.push_str(&line[copied..from]);
        out.push_str(&said);
        copied = to;
    }
    out.push_str(&line[copied..]);
    out
}

/// The tool reference ending at the word `tool` that starts at `at`: where
/// the whole reference starts (verb, article and backticks included), the
/// name's own range, whether the name was quoted, and — when the reference
/// reads `use the X tool` — whether that verb opened a sentence.
struct Reference {
    start: usize,
    name: (usize, usize),
    quoted: bool,
    verb: Option<bool>,
}

fn reference_before(line: &str, at: usize) -> Option<Reference> {
    // `tools` and `toolkit` are prose about tools, not a reference to one.
    if line[at + 4..]
        .chars()
        .next()
        .is_some_and(char::is_alphanumeric)
    {
        return None;
    }
    let head = line[..at].strip_suffix(' ')?.trim_end();
    let quoted = head.ends_with('`');
    let (name, outer) = match head.strip_suffix('`') {
        Some(quoted) => {
            let open = quoted.rfind('`')?;
            ((open + 1, head.len() - 1), open)
        }
        None => {
            let start = head
                .char_indices()
                .rev()
                .take_while(|(_, ch)| word_char(*ch))
                .last()
                .map_or(head.len(), |(start, _)| start);
            ((start, head.len()), start)
        }
    };
    if name.0 >= name.1 {
        return None;
    }
    let before = line[..outer].trim_end();
    let article = ["the", "The"]
        .iter()
        .find(|article| {
            before.ends_with(**article) && !line[..before.len() - 3].ends_with(word_char)
        })
        .map(|article| before.len() - article.len());
    let verb = article.and_then(|start| verb_before(line, start));
    Some(Reference {
        start: match (verb, article) {
            (Some((start, _)), _) => start,
            (None, Some(start)) => start,
            (None, None) => outer,
        },
        name,
        quoted,
        verb: verb.map(|(_, capital)| capital),
    })
}

/// The `use` or `Use` immediately before the article, as its offset and
/// whether it opened a sentence.
fn verb_before(line: &str, article: usize) -> Option<(usize, bool)> {
    let head = line[..article].trim_end();
    ["use", "Use"].iter().find_map(|verb| {
        let start = head.strip_suffix(*verb)?;
        (!start.ends_with(word_char)).then_some((head.len() - verb.len(), verb.starts_with('U')))
    })
}

fn word_char(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

/// Worth naming in a warning: an MCP id or a PascalCase identifier — the
/// shapes a tool name takes. "the right tool for the job" is prose.
fn tool_shaped(name: &str) -> bool {
    name.starts_with("mcp__") || name.chars().any(|ch| ch.is_ascii_uppercase())
}

fn remember(list: &mut Vec<String>, name: &str) {
    if !list.iter().any(|kept| kept == name) {
        list.push(name.to_owned());
    }
}

/// Codex's phrase swallows the article, so a reference that opened a
/// sentence must not leave it lowercase.
fn capitalize(phrase: &str) -> String {
    let mut chars = phrase.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Markdown links as outer byte ranges — link text and target both.
fn link_ranges(line: &str) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    for (at, _) in line.match_indices("](") {
        let (Some(open), Some(close)) = (line[..at].rfind('['), line[at + 2..].find(')')) else {
            continue;
        };
        ranges.push((open, at + 3 + close));
    }
    ranges
}
