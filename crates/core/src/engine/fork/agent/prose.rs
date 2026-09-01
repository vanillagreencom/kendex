//! Taking the generated wrapper off an edited body, and giving every line
//! the person left alone back the words it was written in. A rendering on
//! disk is the person's prose inside everything the renderer wrote around
//! it and said in that harness's own vocabulary; a fork keeps the prose
//! alone, and keeps it in the words the catalog published it in wherever
//! it can still tell which line is which. Whatever the next render writes
//! again out of the manifest this fork carries would otherwise stand
//! twice, and whatever it said in one harness's words would be what every
//! other harness renders.

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
///
/// The publisher's prose, as this harness renders it, is the floor. A
/// generated section may read exactly like one that prose opens or closes
/// with, and where the person deleted the generated copy the publisher's
/// is what stands in its place. Nothing in the text tells the two apart,
/// so the count does: the wrapper may take a section only where the body
/// holds more copies of it than the publisher brought.
///
/// Every line of what is left that the rendering still accounts for is
/// then said back in the words the catalog published it in, because the
/// rendering said those lines in this harness's vocabulary and the fork's
/// source is what every harness renders from next. `Err` is a pairing that
/// cannot be trusted, which is a refusal for the same reason an unreadable
/// wrapper is.
pub(super) fn prose(body: &str, wrapper: Option<&Wrapper>) -> Result<String, String> {
    let lines: Vec<&str> = body.lines().collect();
    let kept: Vec<&str> = match wrapper {
        Some(wrapper) => {
            let rendered: Vec<&str> = wrapper.published.lines().collect();
            let authored: Vec<&str> = wrapper.authored.trim_end().lines().collect();
            let front = &lines[taken(&lines, &rendered, &said(&wrapper.before, false))..];
            let body_back: Vec<&str> = front.iter().rev().copied().collect();
            let rendered_back: Vec<&str> = rendered.iter().rev().copied().collect();
            let back = taken(&body_back, &rendered_back, &said(&wrapper.after, true));
            as_authored(&front[..front.len() - back], &rendered, &authored)?
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
    Ok(format!("{}\n", out.trim_start_matches('\n').trim_end()))
}

/// The kept lines, each one the rendering still accounts for given back
/// the words the catalog published it in. Every harness but Claude says a
/// body's tool references in its own vocabulary, so a line read off the
/// rendering is the publisher's line said in that harness's words, and the
/// fork's source is what every harness renders from next.
///
/// Which line is which is asked of the body's whole order, never of one
/// line's text: [`aligned`] pairs each kept line with the rendered line it
/// stands for, and a pair takes the authored line at that position. A kept
/// line no pair reaches is one the alignment cannot place — a line the
/// person wrote, or one it cannot tell from theirs — and it stays exactly
/// as they wrote it, harness words and all. This reads back what the
/// renderer wrote, and their line is not something it wrote.
///
/// Text alone cannot answer it. Two published lines may render as one and
/// the same line, a fenced sample keeps every byte while the prose above
/// it is reworded into those same words, and a person may type the
/// harness's own name for a tool; matched by text, each of those puts a
/// line into the source that nobody wrote.
///
/// `Err` on either of the two things the pairing needs. The rendering and
/// the published prose have to hold the same number of lines:
/// `rewrite_prose` says each line in the harness's words and gives back
/// one line per line, so a disagreement is that invariant gone and every
/// pair after the slip would carry a neighbour's words. And the two have
/// to be small enough to line up against each other at all, because
/// [`aligned`] holds a cell for every pair of lines and the bodies the
/// catalog door admits reach far past what that affords. Either one is a
/// refusal rather than a guess, the way an unreadable wrapper is.
fn as_authored<'a>(
    kept: &[&'a str],
    rendered: &[&'a str],
    authored: &[&'a str],
) -> Result<Vec<&'a str>, String> {
    if rendered.len() != authored.len() {
        return Err(format!(
            "it renders {} line{} of prose the catalog publishes as {}",
            rendered.len(),
            if rendered.len() == 1 { "" } else { "s" },
            authored.len()
        ));
    }
    let cells = (kept.len() + 1).saturating_mul(rendered.len() + 1);
    if cells > CELLS {
        return Err(format!(
            "lining its {} rendered lines up against the {} kept would take {cells} cells, past the {CELLS} this pairing holds",
            rendered.len(),
            kept.len()
        ));
    }
    let mut words = kept.to_vec();
    for (at, stands_for) in aligned(kept, rendered) {
        words[at] = authored[stands_for];
    }
    Ok(words)
}

/// The most cells [`aligned`] will hold, which is what bounds the body it
/// will line up. A rendering the catalog door admits runs to a hundred
/// thousand lines and more, and a cell for every pair of lines is a table
/// no allocator serves — an abort where this module refuses. The largest
/// agent rendering in circulation is under two hundred lines, so this
/// stands orders of magnitude above any body and still inside what one
/// machine can hold.
const CELLS: usize = 4_000_000;

/// Each kept line paired with the rendered line it stands for, as
/// `(kept, rendered)` indices in order. The pairing is the longest
/// subsequence of lines the two hold in common without reordering either,
/// so a line the person edited, added, deleted or moved drops out of it
/// and every line around it still pairs where it stands. A cell per kept
/// line per rendered line is the cost, which [`CELLS`] bounds.
///
/// The walk back is from the end, so where the rendering says two lines
/// alike the later one is paired. Nothing in the text can tell those two
/// apart — whichever the person deleted, the survivor reads the same — and
/// the choice is only ever right for one of the two deletions. Taking the
/// later one reads the survivor as the copy that stood below the deletion.
///
/// That tie-break is why the alignment is written out here rather than
/// asked of `similar`, which this crate already diffs lines with:
/// `TextDiff` yields these same pairs, and every algorithm it offers picks
/// the other copy.
fn aligned(kept: &[&str], rendered: &[&str]) -> Vec<(usize, usize)> {
    let width = rendered.len() + 1;
    let mut common = vec![0u32; (kept.len() + 1) * width];
    for at in 1..=kept.len() {
        for stands_for in 1..=rendered.len() {
            common[at * width + stands_for] = match kept[at - 1] == rendered[stands_for - 1] {
                true => common[(at - 1) * width + stands_for - 1] + 1,
                false => {
                    common[(at - 1) * width + stands_for].max(common[at * width + stands_for - 1])
                }
            };
        }
    }
    let (mut at, mut stands_for) = (kept.len(), rendered.len());
    let mut pairs = Vec::new();
    while at > 0 && stands_for > 0 {
        if kept[at - 1] == rendered[stands_for - 1] {
            pairs.push((at - 1, stands_for - 1));
            at -= 1;
            stands_for -= 1;
        } else if common[(at - 1) * width + stands_for] >= common[at * width + stands_for - 1] {
            at -= 1;
        } else {
            stands_for -= 1;
        }
    }
    pairs.reverse();
    pairs
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
        let mut said: Vec<Line<'a>> = section
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
/// where the person's own prose starts. A section the published prose
/// brought its own copies of is taken only where the body holds one more
/// than those, which is the copy the wrapper added.
fn taken(body: &[&str], published: &[&str], sections: &[Vec<Line>]) -> usize {
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
fn copies(body: &[&str], section: &[Line]) -> usize {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The pairing is positional, so the rendering and the prose it
    /// publishes have to hold one line for one line. Where they do not,
    /// every pair after the slip would carry a neighbour's words, and the
    /// capture says so rather than writing them.
    #[test]
    fn a_rendering_longer_than_the_prose_it_publishes_is_refused() {
        let problem = as_authored(
            &["Use the read_file tool."],
            &["Use the read_file tool.", "And again."],
            &["Use the Read tool."],
        )
        .unwrap_err();
        assert_eq!(
            problem,
            "it renders 2 lines of prose the catalog publishes as 1"
        );
    }

    /// The pairing holds a cell for every pair of lines, so a body far
    /// past any real agent's is refused before the table is asked for
    /// rather than aborting the process the allocator cannot serve.
    #[test]
    fn a_body_too_large_to_line_up_is_refused_before_the_table() {
        let many = vec!["Use the read_file tool."; 2_001];
        let problem = as_authored(&many, &many, &many).unwrap_err();
        assert_eq!(
            problem,
            "lining its 2001 rendered lines up against the 2001 kept would take 4008004 cells, past the 4000000 this pairing holds"
        );
    }

    /// Both conditions met is the whole of it: a pairing that holds says
    /// the publisher's words back.
    #[test]
    fn a_rendering_the_prose_matches_says_the_published_words_back() {
        let said = as_authored(
            &["Use the read_file tool.", "My body."],
            &["Use the read_file tool.", "Upstream body."],
            &["Use the Read tool.", "Upstream body."],
        )
        .unwrap();
        assert_eq!(said, vec!["Use the Read tool.", "My body."]);
    }
}
