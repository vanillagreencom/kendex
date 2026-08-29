//! Taking the generated wrapper off an edited body. A rendering on disk is
//! the person's prose inside everything the renderer wrote around it, and
//! a fork keeps the prose alone: whatever the next render writes again out
//! of the manifest this fork carries would otherwise stand twice.

use crate::render::agent::GENERATED_BANNER;

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
///
/// The publisher's prose, as this harness renders it, is the floor. A
/// generated section may read exactly like one that prose opens or closes
/// with, and where the person deleted the generated copy the publisher's
/// is what stands in its place. Nothing in the text tells the two apart,
/// so the count does: the wrapper may take a section only where the body
/// holds more copies of it than the publisher brought.
pub(super) fn prose(body: &str, wrapper: Option<&Wrapper>) -> String {
    let lines: Vec<&str> = body.lines().collect();
    let mut kept = lines.as_slice();
    if let Some(wrapper) = wrapper {
        let publisher: Vec<&str> = wrapper.published.lines().collect();
        kept = &kept[taken(kept, &publisher, &said(&wrapper.before, false))..];
        let body_back: Vec<&str> = kept.iter().rev().copied().collect();
        let publisher_back: Vec<&str> = publisher.iter().rev().copied().collect();
        kept =
            &kept[..kept.len() - taken(&body_back, &publisher_back, &said(&wrapper.after, true))];
    }
    let mut out = String::new();
    // The banner is a section like any other and comes off with them.
    // Filtered again here for the body no wrapper could be read for,
    // where nothing was taken off at all.
    for line in kept.iter().filter(|line| line.trim() != GENERATED_BANNER) {
        out.push_str(line);
        out.push('\n');
    }
    // Only the blank separators go. A first line indented into a code
    // block is the person's own content, and trimming it would render
    // their block as ordinary prose.
    format!("{}\n", out.trim_start_matches('\n').trim_end())
}

/// The lines that identify each section, in the order a walk from this
/// end meets them. Blank lines are left out: they separate sections
/// rather than say which one this is, and a person who closed a gap up
/// has not deleted a section.
fn said<'a>(sections: &'a [String], from_the_end: bool) -> Vec<Vec<&'a str>> {
    let lines = |section: &'a String| -> Vec<&'a str> {
        let said = section.lines().filter(|line| !line.trim().is_empty());
        match from_the_end {
            true => said.rev().collect(),
            false => said.collect(),
        }
    };
    match from_the_end {
        true => sections.iter().rev().map(lines).collect(),
        false => sections.iter().map(lines).collect(),
    }
}

/// How many lines at the front of `body` the wrapper wrote. Each section
/// is tried where the one before it stopped and nothing is searched for,
/// so the count is the run of lines the wrapper accounts for and stops
/// where the person's own prose starts. A section the published prose
/// brought its own copies of is taken only where the body holds one more
/// than those, which is the copy the wrapper added.
fn taken(body: &[&str], published: &[&str], sections: &[Vec<&str>]) -> usize {
    let mut at = 0;
    for section in sections {
        if copies(&body[at..], section) > copies(published, section)
            && let Some(more) = held(&body[at..], section)
        {
            at += more;
        }
    }
    at
}

/// How many copies of this section stand one after another at the front of
/// `body`.
fn copies(body: &[&str], section: &[&str]) -> usize {
    let mut at = 0;
    let mut seen = 0;
    while let Some(more) = held(&body[at..], section) {
        at += more;
        seen += 1;
    }
    seen
}

/// How many lines at the front of `body` hold this whole section, or
/// `None` where they do not. Whole means every line the section is
/// identified by, in its order, with nothing but blank lines among them.
/// A body holding some of a section holds none of it: half a section is
/// as likely to be the person writing what the renderer would have
/// written as it is the remains of what it wrote.
fn held(body: &[&str], section: &[&str]) -> Option<usize> {
    if section.is_empty() {
        return None;
    }
    let mut matched = 0;
    let mut through = 0;
    for (at, line) in body.iter().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        if line != section.get(matched)? {
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
