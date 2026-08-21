use super::*;
use crate::render::skill::{Block, INSTRUCTIONS_END, INSTRUCTIONS_START, Rendered};

const NOTE: &str = "\n> Continued in references/details.md — read it for the remaining sections.\n";

fn skill(body: &str) -> String {
    format!("---\nname: x\n---\n{body}")
}

fn tree(text: &str) -> Vec<(PathBuf, Vec<u8>)> {
    vec![(PathBuf::from(SKILL_FILE), text.as_bytes().to_vec())]
}

/// `count` sections of a fixed size, so a cap can be aimed between them.
fn sections(count: usize) -> String {
    (1..=count)
        .map(|n| format!("\n## S{n}\n\n{}\n", "x".repeat(200)))
        .collect()
}

fn instructions() -> String {
    format!("{INSTRUCTIONS_START}\n## Project Instructions\n\nuse gh\n{INSTRUCTIONS_END}\n")
}

/// The split under the block the renderer would have carried to it. These
/// trees are built here, so where the block sits is known rather than
/// looked for — which is the whole point of passing it in.
fn capped(files: Vec<(PathBuf, Vec<u8>)>, max_bytes: usize) -> SplitOutcome {
    let block = files
        .iter()
        .find(|(path, _)| path == Path::new("SKILL.md"))
        .and_then(|(_, bytes)| {
            let text = std::str::from_utf8(bytes).ok()?;
            let start = text.find(INSTRUCTIONS_START)?;
            let end = text.find(INSTRUCTIONS_END)? + INSTRUCTIONS_END.len() + 1;
            Some(Block {
                file: PathBuf::from("SKILL.md"),
                start,
                end,
            })
        });
    enforce_body_cap(Rendered::split(files, block), max_bytes)
}

fn read(outcome: &SplitOutcome, name: &str) -> String {
    let (_, bytes) = outcome
        .rendered
        .files()
        .iter()
        .find(|(path, _)| path == Path::new(name))
        .unwrap_or_else(|| panic!("{name} is not in the tree"));
    String::from_utf8(bytes.clone()).unwrap()
}

#[test]
fn a_body_under_the_cap_is_left_alone() {
    let files = tree(&skill("\n## One\n\nshort\n"));
    let outcome = capped(files.clone(), 4096);
    assert_eq!(*outcome.rendered.files(), files);
    assert!(outcome.warnings.is_empty());
    assert!(outcome.refusal.is_none());
}

#[test]
fn a_tree_without_a_skill_file_is_left_alone() {
    let files = vec![(PathBuf::from("references/details.md"), vec![b'x'; 900])];
    let outcome = capped(files.clone(), 10);
    assert_eq!(*outcome.rendered.files(), files);
    assert!(outcome.refusal.is_none());
}

#[test]
fn a_split_lands_on_a_heading_and_loses_no_bytes() {
    let text = skill(&sections(6));
    let outcome = capped(tree(&text), 400);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    assert!(head.len() <= 400);
    assert!(head.starts_with("---\nname: x\n---\n"));
    assert!(head.contains("## S1") && !head.contains("## S2"));
    assert!(overflow.starts_with(&format!("{PROVENANCE}## S2")));
    assert_eq!(
        format!(
            "{}{}",
            head.strip_suffix(NOTE).unwrap(),
            overflow.strip_prefix(PROVENANCE).unwrap()
        ),
        text
    );
    assert_eq!(outcome.warnings.len(), 1);
    assert_eq!(outcome.warnings[0].remediation.as_deref(), Some(FIX));
    assert!(outcome.refusal.is_none());
}

#[test]
fn a_heading_inside_a_fence_is_not_a_split_point() {
    let fence = format!("```md\n{}```\n", "## fake\n".repeat(30));
    let text = skill(&format!("{}\n{fence}\n## Last\n\ntail\n", sections(2)));
    // The cap falls inside the fence: a fake heading would win if fences
    // were not tracked.
    let outcome = capped(tree(&text), 640);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    assert!(!head.contains("```"));
    assert!(head.contains("## S1") && !head.contains("## S2"));
    assert!(overflow.contains(&fence));
}

#[test]
fn a_longer_fence_run_is_not_closed_by_a_shorter_one() {
    let body = "````\n```\n## fake\n```\n````\n\n## Real\n";
    let fenced = fenced_ranges(body);
    assert_eq!(fenced, vec![(0, 26)]);
    assert_eq!(headings(body, &fenced), vec![27]);
}

#[test]
fn an_unclosed_fence_swallows_the_rest_of_the_body() {
    let body = "## Real\n\n```\ncode\n\n## fake\n";
    let fenced = fenced_ranges(body);
    assert_eq!(fenced, vec![(9, body.len())]);
    assert_eq!(headings(body, &fenced), vec![0]);
}

/// A block nested inside a list item is indented four spaces. Reading that
/// as prose puts the cut inside it: the head ends on an unclosed fence and
/// the overflow file opens mid-block, with nothing said about either.
#[test]
fn an_indented_fence_is_not_a_split_point() {
    // No headings, so the cut falls where the bytes run out — inside the
    // block unless the block is known to be one.
    let block = format!(
        "1. Run this:\n\n    ```sh\n{}    ```\n",
        "    step\n".repeat(60)
    );
    let text = skill(&format!("{}\n{block}", "Intro line.\n".repeat(20)));
    let outcome = capped(tree(&text), 400);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    assert!(!head.contains("```"), "the head ends mid-block: {head}");
    assert!(head.contains("1. Run this:"));
    assert!(overflow.contains("    ```sh\n") && overflow.ends_with("    ```\n"));
}

/// Real skills section themselves with `###` under one `##`. Counting only
/// `##` leaves those with a title and a pointer — every byte reachable, and
/// nothing useful in the file the tool actually reads.
#[test]
fn deeper_headings_are_split_points_too() {
    let body: String = (1..=6)
        .map(|n| format!("\n### S{n}\n\n{}\n", "x".repeat(200)))
        .collect();
    let text = skill(&format!("\n## Only\n\nintro\n{body}"));
    let outcome = capped(tree(&text), 700);
    let head = read(&outcome, "SKILL.md");

    assert!(head.len() <= 700);
    assert!(
        head.contains("### S2"),
        "the head kept almost nothing: {head}"
    );
    assert!(read(&outcome, "references/details.md").starts_with(&format!("{PROVENANCE}### ")));
}

#[test]
fn a_multibyte_character_is_never_cut_in_half() {
    let text = skill(&"é".repeat(400));
    let outcome = capped(tree(&text), 201);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    // The budget lands mid-character; the cut walks back one byte.
    assert_eq!(head.len(), 200);
    assert_eq!(head.matches('é').count(), 53);
    assert_eq!(
        format!(
            "{}{}",
            head.strip_suffix(NOTE).unwrap(),
            overflow.strip_prefix(PROVENANCE).unwrap()
        ),
        text
    );
}

#[test]
fn a_fenced_block_larger_than_the_cap_is_refused() {
    let files = tree(&skill(&format!("```\n{}```\n", "line\n".repeat(200))));
    let outcome = capped(files.clone(), 300);

    assert_eq!(*outcome.rendered.files(), files);
    assert!(outcome.warnings.is_empty());
    assert!(outcome.refusal.unwrap().contains("fenced code block"));
}

#[test]
fn the_instructions_block_stays_in_the_head_when_it_comes_late() {
    let text = skill(&format!(
        "{}\n{}\n## Tail\n\nz\n",
        sections(3),
        instructions()
    ));
    let outcome = capped(tree(&text), 700);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    assert!(head.len() <= 700);
    assert!(head.contains(&instructions()));
    assert!(!overflow.contains(INSTRUCTIONS_START));
    // Content that preceded the block moved out so the block could stay.
    assert!(overflow.contains("## S3") && overflow.contains("## Tail"));
    assert_eq!(
        head.len() - NOTE.len() + overflow.len() - PROVENANCE.len(),
        text.len()
    );
}

#[test]
fn a_heading_inside_the_instructions_block_is_not_a_split_point() {
    // The block's own `## Project Instructions` is the last heading under
    // the cap; taking it would leave the markers in different files.
    let text = skill(&format!(
        "{}\n{}{}\n## Later\n\nz\n",
        sections(2),
        instructions(),
        "y".repeat(300)
    ));
    let outcome = capped(tree(&text), 694);
    let head = read(&outcome, "SKILL.md");
    let overflow = read(&outcome, "references/details.md");

    assert!(head.contains(&instructions()));
    assert!(!overflow.contains(INSTRUCTIONS_START) && !overflow.contains(INSTRUCTIONS_END));
    assert!(overflow.contains("## S2") && overflow.contains("## Later"));
}

#[test]
fn a_cap_below_the_instructions_block_is_refused() {
    let text = skill(&format!("{}{}", instructions(), sections(2)));
    let outcome = capped(tree(&text), 100);
    assert!(
        outcome
            .refusal
            .unwrap()
            .contains("frontmatter and project instructions")
    );
}

#[test]
fn an_existing_details_file_pushes_the_overflow_to_a_free_name() {
    let mut files = tree(&skill(&sections(6)));
    files.push((PathBuf::from("references/details.md"), b"prior\n".to_vec()));
    let outcome = capped(files.clone(), 400);

    assert_eq!(read(&outcome, "references/details.md"), "prior\n");
    assert!(read(&outcome, "references/details_overflow.md").starts_with(PROVENANCE));
    assert!(read(&outcome, "SKILL.md").contains("references/details_overflow.md"));

    files.push((
        PathBuf::from("references/details_overflow.md"),
        b"prior\n".to_vec(),
    ));
    let outcome = capped(files, 400);
    assert!(read(&outcome, "references/details_overflow-2.md").starts_with(PROVENANCE));
}

#[test]
fn the_returned_tree_stays_sorted() {
    let mut files = tree(&skill(&sections(6)));
    files.push((PathBuf::from("assets/logo.svg"), b"<svg/>".to_vec()));
    let outcome = capped(files, 400);

    let paths: Vec<&PathBuf> = outcome
        .rendered
        .files()
        .iter()
        .map(|(path, _)| path)
        .collect();
    let mut sorted = paths.clone();
    sorted.sort();
    assert_eq!(paths, sorted);
    assert_eq!(paths.len(), 3);
}
