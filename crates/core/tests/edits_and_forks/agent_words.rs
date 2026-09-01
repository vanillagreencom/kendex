//! The words a capture keeps. Every harness but Claude says an agent's
//! tool references in its own vocabulary, so the prose read back off a
//! rendering is the publisher's prose said in that harness's words. What
//! the fork writes into the local source is what every other harness
//! renders from next, so each line the rendering still accounts for has to
//! come back in the words the catalog published it in, and each line the
//! person wrote has to stay as they wrote it.

use std::fs;

use super::*;

/// Every harness but Claude says an agent's tool references in its own
/// words, so a body captured off a Gemini rendering is Gemini's vocabulary
/// rather than the person's. Kept as source it renders in Gemini's words
/// everywhere, and the harnesses that never had those names read a tool
/// they do not have.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_gemini_agent_captures_the_words_its_prose_was_written_in() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUse the Read tool.\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    assert!(
        fs::read_to_string(&file)
            .unwrap()
            .contains("Use the read_file tool."),
        "the fixture must render Gemini's own word for the tool"
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("Use the Read tool.") && !source.contains("read_file"),
        "the capture kept Gemini's vocabulary as the fork's source: {source}"
    );
    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(
        claude.contains("Use the Read tool.") && !claude.contains("read_file"),
        "Claude renders the fork in Gemini's words: {claude}"
    );
    let gemini = fs::read_to_string(&file).unwrap();
    assert!(
        gemini.contains("Use the read_file tool.") && gemini.contains("My body."),
        "the Gemini rendering must still read in Gemini's words: {gemini}"
    );
    assert_eq!(banners(&gemini), 1, "{gemini}");
}

/// The same class through Pi, whose word for the tool is a third spelling
/// again: a fork taken from one harness must not teach every other harness
/// that harness's names. The sections the renderer appends travel into the
/// manifest with it, so each of them stands once in each rendering.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_pi_agent_captures_the_words_its_prose_was_written_in() {
    let w = agent_world(
        "\"claude\", \"pi\"",
        "---\nname: rev\ndescription: agent rev\n---\nUse the WebFetch tool.\n\nUpstream body.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n",
    );
    let file = rendered(&w, HarnessId::Pi, "rev");
    assert!(
        fs::read_to_string(&file)
            .unwrap()
            .contains("Use the webfetch tool."),
        "the fixture must render Pi's own word for the tool"
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Pi).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("Use the WebFetch tool.") && !source.contains("webfetch"),
        "the capture kept Pi's vocabulary as the fork's source: {source}"
    );
    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(
        claude.contains("Use the WebFetch tool."),
        "Claude renders the fork in Pi's words: {claude}"
    );
    let pi = fs::read_to_string(&file).unwrap();
    assert!(
        pi.contains("Use the webfetch tool.") && pi.contains("My body."),
        "the Pi rendering must still read in Pi's words: {pi}"
    );
    for text in [&claude, &pi] {
        for section in ["## Launch Instructions", "## Additional Instructions"] {
            assert_eq!(times(text, section), 1, "{section} count wrong: {text}");
        }
        assert_eq!(banners(text), 1, "{text}");
    }
}

/// A harness may render two published lines as one and the same line.
/// Gemini says `glob` for the Glob tool, which is also the ordinary word
/// somebody writes in lowercase prose. Read by text the two are one line
/// with two answers; read by position each is its own.
#[test]
#[allow(clippy::unwrap_used)]
fn two_published_lines_a_harness_renders_alike_each_keep_their_own_words() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUse the glob tool.\n\nUse the Glob tool.\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    assert_eq!(
        times(&fs::read_to_string(&file).unwrap(), "Use the glob tool."),
        2,
        "the fixture must render both lines alike"
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in ["Use the glob tool.", "Use the Glob tool."] {
        assert_eq!(
            times(&source, line),
            1,
            "{line} is one of two lines the rendering says alike: {source}"
        );
    }
}

/// A fenced sample keeps every byte through the rewrite, so a sample
/// written in Gemini's own words stands in the rendering beside prose the
/// rewrite turned into those same words. The sample is the publisher's
/// bytes and must come back as they wrote it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fenced_sample_written_in_the_harnesss_words_keeps_every_byte() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUse the Read tool.\n\n```\nUse the read_file tool.\n```\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    assert_eq!(
        times(
            &fs::read_to_string(&file).unwrap(),
            "Use the read_file tool."
        ),
        2,
        "the fixture must render the prose into the sample's own words"
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(
        times(&source, "Use the read_file tool."),
        1,
        "the fenced sample lost the bytes the rewrite keeps: {source}"
    );
    assert_eq!(
        times(&source, "Use the Read tool."),
        1,
        "the prose above it did not come back in the published words: {source}"
    );
}

/// A line the person typed into the rendering is theirs, in whatever words
/// they reached for. Reading the rendering back says what the renderer
/// wrote, and their line is not something it wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn a_line_the_person_typed_in_the_harnesss_words_stays_as_they_wrote_it() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUse the Read tool.\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("Upstream body.", "My body.\n\nUse the read_file tool."),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(
        prose(&source),
        ["Use the Read tool.", "My body.", "Use the read_file tool."],
        "each line has to hold its own words where it stands: the publisher's opening said back, and the one they typed left alone: {source}"
    );
}

/// The ordinary way a person edits an installed agent is to tweak the
/// opening and tweak the close. Both ends moving leaves no run of
/// untouched lines at either end, and everything the publisher wrote
/// between them still has to come back in their words.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_at_both_ends_still_says_the_lines_between_them_back() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nIntro line.\n\nUse the Read tool.\n\nUse the WebFetch tool.\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    edit_line(&file, "Intro line.", "My intro.");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in ["Use the Read tool.", "Use the WebFetch tool."] {
        assert_eq!(
            times(&source, line),
            1,
            "an edit at each end left {line} in Gemini's words: {source}"
        );
    }
    for word in ["read_file", "web_fetch"] {
        assert!(!source.contains(word), "{word} survived into {source}");
    }
    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(
        claude.contains("My intro.") && claude.contains("My body."),
        "both edits must survive the fork: {claude}"
    );
}

/// The mirror of it: the person edits the opening alone, so the run of
/// untouched lines is at the back and every line before it still pairs
/// where it stands.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_at_the_front_still_says_the_lines_after_it_back() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nIntro line.\n\nUse the Read tool.\n\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    edit_line(&file, "Intro line.", "My intro.");

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(times(&source, "Use the Read tool."), 1, "{source}");
    assert!(!source.contains("read_file"), "{source}");
    assert_eq!(times(&source, "My intro."), 1, "{source}");
}

/// A paragraph deleted from between two the rendering says alike. Nothing
/// in the text tells the survivor from the one that went — whichever the
/// person deleted, what is left reads the same, byte for byte — so the
/// survivor is left in the words the rendering said it. Assigning it one
/// of the two published lines would be right for one of these deletions
/// and would write bytes the person never had for the other.
#[test]
#[allow(clippy::unwrap_used)]
fn deleting_one_of_two_paragraphs_a_harness_renders_alike_leaves_the_survivor_as_rendered() {
    for deleted in [0, 1] {
        let w = agent_world(
            "\"claude\", \"gemini\"",
            "---\nname: rev\ndescription: agent rev\n---\nUse the glob tool.\n\nUse the Glob tool.\n\nUpstream body.\n",
            "",
            "",
        );
        let file = rendered(&w, HarnessId::Gemini, "rev");
        let text = fs::read_to_string(&file).unwrap();
        assert_eq!(times(&text, "Use the glob tool."), 2, "{text}");
        // The rendering says both paragraphs the same way, so which one
        // this deletes is which occurrence it cuts out.
        let paragraph = "Use the glob tool.\n\n";
        let at = text.match_indices(paragraph).nth(deleted).unwrap().0;
        fs::write(
            &file,
            format!("{}{}", &text[..at], &text[at + paragraph.len()..]),
        )
        .unwrap();
        edit_body(&file);

        let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
        apply::execute(&w.env, &plan).unwrap();
        resettle(&w);

        let source = fs::read_to_string(captured(&w, "rev")).unwrap();
        assert_eq!(
            prose(&source),
            ["Use the glob tool.", "My body."],
            "deleting paragraph {deleted} put the other paragraph's words on the survivor: {source}"
        );
    }
}

/// Claude renders a body as it was authored, so there is nothing to line
/// up and the pairing is never asked for. A body longer than the pairing's
/// own ceiling still forks, because that ceiling bounds a table this fork
/// never needs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_body_past_the_pairings_ceiling_forks_where_nothing_was_said_differently() {
    let long: String = (0..2_100).map(|at| format!("Line {at}.\n")).collect();
    let w = agent_world(
        "\"claude\"",
        &format!("---\nname: rev\ndescription: agent rev\n---\n{long}\nUpstream body.\n"),
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("Line 2099.") && source.contains("My body."),
        "the capture lost the body it was asked to keep"
    );
}

/// The prose of a captured source, its frontmatter and blank separators
/// dropped. Counting occurrences cannot say which of two lines was said
/// back and which was left alone, so the tests that turn on that read the
/// lines where they stand.
fn prose(source: &str) -> Vec<&str> {
    source
        .lines()
        .skip_while(|line| *line != "---")
        .skip(1)
        .skip_while(|line| *line != "---")
        .skip(1)
        .filter(|line| !line.trim().is_empty())
        .collect()
}
