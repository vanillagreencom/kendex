//! Taking the generated wrapper off an edited body. A rendering on disk is
//! the person's prose inside everything the renderer wrote around it, and
//! a fork keeps the prose alone: whatever the next render writes again out
//! of the manifest this fork carries would otherwise stand twice.

use crate::render::agent::GENERATED_BANNER;
use crate::render::inside_a_block;

use super::wrapper::Wrapper;

/// The person's own prose: the edited body with the generated wrapper
/// taken off. Everything in that wrapper is written again by the next
/// render, out of the manifest entries this fork carries, so prose keeping
/// a copy of it would render twice — the banner duplication one layer out.
///
/// The wrapper comes off section by section, each tried where the one
/// before it stopped. A section the body does not hold whole is one the
/// person deleted — the banner is the one they reach for — and it is
/// passed over without taking anything, so the sections after it still
/// come off and a line of the person's own is never taken for a line of
/// the wrapper.
pub(super) fn prose(body: &str, wrapper: Option<&Wrapper>) -> String {
    let lines: Vec<&str> = body.lines().collect();
    let kept: Vec<&str> = match wrapper {
        Some(wrapper) => {
            let front = &lines[taken(&lines, &said(&wrapper.before, false))..];
            let body_back: Vec<&str> = front.iter().rev().copied().collect();
            let back = taken(&body_back, &said(&wrapper.after, true));
            front[..front.len() - back].to_vec()
        }
        // Nothing was subtracted, so the banner the renderer wrote is
        // still standing in the body — the one line the next render is
        // certain to write again. Where a wrapper was read the banner is
        // a section like any other and the walk has already had it, so
        // filtering here would take a line the walk deliberately kept.
        None => lines
            .iter()
            .filter(|line| line.trim() != GENERATED_BANNER)
            .copied()
            .collect(),
    };
    let mut out = String::new();
    for line in kept {
        out.push_str(line);
        out.push('\n');
    }
    // Only the blank separators go. A first line indented into a code
    // block is the person's own content, and trimming it would render
    // their block as ordinary prose.
    format!("{}\n", out.trim_start_matches('\n').trim_end())
}

/// One line a section is identified by. `inside` is a line standing
/// inside a code block, where whitespace is content the person can edit
/// rather than separation between sections.
struct Line<'a> {
    text: &'a str,
    inside: bool,
}

/// The lines that identify each section, in the order a walk from this
/// end meets them. A blank line outside a code block is left out: it
/// separates sections rather than says which one this is, and a person
/// who closed a gap up has not deleted a section. Inside one it is kept,
/// because there it is a line of the block's own text.
fn said<'a>(sections: &'a [String], from_the_end: bool) -> Vec<Vec<Line<'a>>> {
    let lines = |section: &'a String| -> Vec<Line<'a>> {
        let mut said: Vec<Line> = section
            .lines()
            .zip(inside_a_block(section))
            .filter(|(text, inside)| *inside || !text.trim().is_empty())
            .map(|(text, inside)| Line { text, inside })
            .collect();
        if from_the_end {
            said.reverse();
        }
        said
    };
    match from_the_end {
        true => sections.iter().rev().map(lines).collect(),
        false => sections.iter().map(lines).collect(),
    }
}

/// How many lines at the front of `body` the wrapper wrote. Each section
/// is tried where the one before it stopped and nothing is searched for,
/// so the count is the run of lines the wrapper accounts for and stops
/// where the person's own prose starts.
fn taken(body: &[&str], sections: &[Vec<Line>]) -> usize {
    let mut at = 0;
    for section in sections {
        if let Some(more) = held(&body[at..], section) {
            at += more;
        }
    }
    at
}

/// How many lines at the front of `body` hold this whole section, or
/// `None` where they do not. Whole means every line the section is
/// identified by, in its order, with nothing but separating blank lines
/// among them. A body holding some of a section holds none of it: half a
/// section is as likely to be the person writing what the renderer would
/// have written as it is the remains of what it wrote.
fn held(body: &[&str], section: &[Line]) -> Option<usize> {
    if section.is_empty() {
        return None;
    }
    let mut matched = 0;
    let mut through = 0;
    for (at, line) in body.iter().enumerate() {
        let want = section.get(matched)?;
        // A blank line the section is not standing on is separation, and
        // a person may open or close a gap without touching the section.
        // One the section does stand on is a line of a code block, where
        // their whitespace is content: it has to match byte for byte, and
        // one they added stands against the block's next line and refuses.
        if line.trim().is_empty() && !want.inside {
            continue;
        }
        if *line != want.text {
            return None;
        }
        matched += 1;
        through = at + 1;
        if matched == section.len() {
            break;
        }
    }
    if matched < section.len() {
        return None;
    }
    // The blank lines behind it separated it from what came next, and
    // are the wrapper's too.
    let trailing = body[through..]
        .iter()
        .take_while(|line| line.trim().is_empty())
        .count();
    Some(through + trailing)
}
