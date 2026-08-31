//! How far a code span reaches, which is one markdown block. A switch named
//! inside a span is a mention and a switch outside one is a use, so every
//! block boundary the reading misses hides a use, and every boundary it
//! invents reports a mention. Both directions are here, one against the
//! other, because a fix in either direction alone is a fix in the wrong one.

use kendex_core::quality::Severity;

use super::rules::{rules_hit, severity_of, skill};

/// A code span closes on a later line of the same paragraph. Read one line
/// at a time the opener meets no match on its own line and the close meets
/// none on the next, so the switch quoted between them was reported as one
/// standing in the open.
///
/// The control is the second case: the reach is the paragraph, not the
/// document. A backtick whose partner stands past a blank line quotes
/// nothing, and the switch beside it still counts.
#[test]
fn safety_bypass_leaves_a_switch_quoted_by_a_span_that_crosses_a_newline() {
    let across = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n--no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&across).contains(&"safety-bypass"),
        "{:?}",
        across.findings
    );

    let apart = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n\n--no-verify` runs it.\n",
    )]);
    assert_eq!(
        severity_of(&apart, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        apart.findings
    );
}

/// The line an indented block opens on is the block's own text, the same
/// as the line under it. Reading it as prose let a backtick there quote
/// what the block prints literally, so a switch on a block's first line
/// scored nothing and the same switch one line down scored Critical.
///
/// The control is the second case: in prose those same marks are
/// markdown's, and they do quote.
#[test]
fn safety_bypass_reads_the_line_an_indented_block_opens_on_as_code() {
    let opens = skill(&[("SKILL.md", "Run it:\n\n    git commit `--no-verify`\n")]);
    assert_eq!(
        severity_of(&opens, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        opens.findings
    );

    let prose = skill(&[("SKILL.md", "Run it: git commit `--no-verify`\n")]);
    assert!(
        !rules_hit(&prose).contains(&"safety-bypass"),
        "{:?}",
        prose.findings
    );
}

/// A heading is a block of its own, so a run of backticks left open at the
/// end of one does not reach the paragraph under it. Joining the two into
/// a single run paired those stray backticks, and the switch standing
/// between them read as quoted: one unmatched backtick on each of two
/// lines, and a line telling a reader to pass git the switch scored
/// nothing.
#[test]
fn safety_bypass_reads_a_switch_a_heading_keeps_out_of_a_span() {
    let result = skill(&[(
        "SKILL.md",
        "# Committing past the `hook\nPass --no-verify` when it complains.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// A heading underlined with `=` is the same block boundary written the
/// other way round, and the underline closes it. A run reaching past that
/// paired the two stray backticks and swallowed the line under it.
#[test]
fn safety_bypass_reads_a_switch_a_setext_heading_keeps_out_of_a_span() {
    let result = skill(&[(
        "SKILL.md",
        "Committing past the `hook\n=========================\nPass --no-verify` when it complains.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// Each list item is a block of its own, so a backtick left open in one
/// does not reach the next. A line carrying no marker continues the item
/// above it, which is the second case: a span still crosses the newline
/// inside one item.
#[test]
fn safety_bypass_reads_a_switch_a_list_item_keeps_out_of_a_span() {
    let items = skill(&[(
        "SKILL.md",
        "- Write `git commit\n- Pass --no-verify` to git.\n",
    )]);
    assert_eq!(
        severity_of(&items, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        items.findings
    );

    let one = skill(&[(
        "SKILL.md",
        "- The bypass is `git commit\n  --no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&one).contains(&"safety-bypass"),
        "{:?}",
        one.findings
    );
}

/// A blockquote opening inside prose is a block of its own, so a backtick
/// in the prose above one does not reach into it. Its findings still weigh
/// one severity less, which is what a quotation is worth.
///
/// The control is the second case: two quoted lines are one block, so a
/// span opened on the first still closes on the second.
#[test]
fn safety_bypass_reads_a_switch_a_blockquote_keeps_out_of_a_span() {
    let into = skill(&[(
        "SKILL.md",
        "Write `git commit\n> Pass --no-verify` to git.\n",
    )]);
    assert_eq!(
        severity_of(&into, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        into.findings
    );

    let within = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit\n> --no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&within).contains(&"safety-bypass"),
        "{:?}",
        within.findings
    );
}

/// A thematic break ends the block above it, so the two stray backticks on
/// either side belong to different blocks and quote nothing. A reading that
/// knows only the boundaries somebody wrote down joins the three lines,
/// pairs those backticks, and drops the finding — a switch in the open,
/// scored as a mention, in a number somebody installs on.
///
/// The control is the second case: take the break out and the same two
/// lines are one paragraph, where the span is real and the mention is a
/// mention.
#[test]
fn safety_bypass_reads_a_switch_a_thematic_break_keeps_out_of_a_span() {
    let across = skill(&[(
        "SKILL.md",
        "Describe `the hook\n***\nRun git commit --no-verify` now.\n",
    )]);
    assert_eq!(
        severity_of(&across, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        across.findings
    );

    let joined = skill(&[(
        "SKILL.md",
        "Describe `the hook\nand git commit --no-verify` now.\n",
    )]);
    assert!(
        !rules_hit(&joined).contains(&"safety-bypass"),
        "{:?}",
        joined.findings
    );
}

/// A line opening a raw HTML block ends the paragraph above it, and what
/// stands inside the block is HTML rather than prose — no span of markdown's
/// reaches into it or out of it. Reading those lines as one paragraph paired
/// the stray backticks and hid the switch between them.
///
/// The control is the second case: a tag named in the middle of a sentence
/// opens no block, so that paragraph still holds its span.
#[test]
fn safety_bypass_reads_a_switch_a_raw_html_block_keeps_out_of_a_span() {
    let across = skill(&[(
        "SKILL.md",
        "Describe `the hook\n<div>\nRun git commit --no-verify` now.\n",
    )]);
    assert_eq!(
        severity_of(&across, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        across.findings
    );

    let named = skill(&[(
        "SKILL.md",
        "Describe `the hook\nin a <div> and git commit --no-verify` now.\n",
    )]);
    assert!(
        !rules_hit(&named).contains(&"safety-bypass"),
        "{:?}",
        named.findings
    );
}

/// A quoted paragraph carries on through a line that drops its `>`, which
/// is markdown's lazy continuation, and the span opened above it closes
/// there. Comparing the two lines' markers instead invents a boundary the
/// document has not got, and a harmless mention was reported Critical.
///
/// The control is the second case: a blank line does end the quoted
/// paragraph, so the line under it opens a block of its own and the switch
/// there stands in the open.
#[test]
fn safety_bypass_leaves_a_switch_quoted_across_a_lazy_blockquote_continuation() {
    let lazy = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit\n--no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&lazy).contains(&"safety-bypass"),
        "{:?}",
        lazy.findings
    );

    let apart = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit\n\n--no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&apart, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        apart.findings
    );
}

/// Four spaces may not interrupt an open paragraph, so an indented line
/// under prose is that paragraph's next line and the span on it is real.
/// Reading the indent as a code block threw the span away and reported the
/// flag the document was naming as a switch somebody runs.
///
/// The control is the second case: with a blank line above it the same
/// indent does open a block, and the marks there are the shell's.
#[test]
fn safety_bypass_leaves_a_switch_quoted_by_an_indented_continuation() {
    let under = skill(&[("SKILL.md", "Name the flag below:\n    `--no-verify`\n")]);
    assert!(
        !rules_hit(&under).contains(&"safety-bypass"),
        "{:?}",
        under.findings
    );

    let apart = skill(&[("SKILL.md", "Name the flag below:\n\n    `--no-verify`\n")]);
    assert_eq!(
        severity_of(&apart, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        apart.findings
    );
}

/// A fence opens inside a blockquote the same as anywhere else, and what
/// it holds is code. Reading the line before its markers were consumed
/// left the fence unrecognised, so the two runs of backticks paired as an
/// inline span and the switch quoted between them was scored a mention —
/// the same silence this whole reading exists to close, in the reading
/// itself.
///
/// The control is the second case: a quoted line whose switch stands in an
/// inline span is still naming it, and naming it is not running it.
#[test]
fn safety_bypass_reads_a_switch_a_quoted_fence_holds_as_code() {
    let fenced = skill(&[("SKILL.md", "> ```sh\n> git commit --no-verify\n> ```\n")]);
    assert_eq!(
        severity_of(&fenced, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        fenced.findings
    );

    let named = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&named).contains(&"safety-bypass"),
        "{:?}",
        named.findings
    );
}

/// A raw HTML block opened inside a blockquote ends where that quote does.
/// Only a paragraph continues lazily, so a line that has dropped the
/// marker has left the block; carrying no depth on the open block ran it
/// on to the next blank line, swallowing a paragraph whose span was real
/// and reporting the switch it quoted as one standing in the open.
///
/// The control is the second case: while the quote does continue, the
/// block holds, and the marks inside it are the document's own HTML rather
/// than markdown's.
#[test]
fn safety_bypass_ends_a_quoted_html_block_where_its_quote_ends() {
    let left = skill(&[(
        "SKILL.md",
        "> <div>\nThe bypass is `git commit\n--no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&left).contains(&"safety-bypass"),
        "{:?}",
        left.findings
    );

    let held = skill(&[(
        "SKILL.md",
        "> <div>\n> The bypass is `git commit\n> --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&held, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        held.findings
    );
}

/// A fence closes on a marker standing at the depth its opener stood at.
/// Inside a fenced block every further `>` is the code's own text, so a
/// quoted marker closes nothing; consuming it as a container marker ended
/// the block early and turned the code under it back into prose, where a
/// pair of backticks quoted the switch and the finding went away.
///
/// The control is the second case: a marker at the opener's own depth does
/// close it, and the line under that is prose again.
#[test]
fn safety_bypass_closes_a_fence_only_at_the_depth_it_opened_in() {
    let quoted = skill(&[(
        "SKILL.md",
        "```sh\n> ```\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&quoted, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        quoted.findings
    );

    let plain = skill(&[(
        "SKILL.md",
        "```sh\n```\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&plain).contains(&"safety-bypass"),
        "{:?}",
        plain.findings
    );
}

/// A whole tag alone on its line opens a raw HTML block where no paragraph
/// stands open, whatever its name. Refusing that kind everywhere left the
/// tag and the line under it reading as one paragraph, where the backticks
/// paired and quoted a switch nothing had quoted.
///
/// The control is the second case, and it is the half the refusal got
/// right: this kind may not interrupt a paragraph, so under an open one
/// the same tag is that paragraph's next line and the span across it is
/// real.
#[test]
fn safety_bypass_opens_a_block_at_a_whole_tag_only_where_no_paragraph_is() {
    let alone = skill(&[(
        "SKILL.md",
        "<span>\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&alone, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        alone.findings
    );

    let within = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n<span>\n--no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&within).contains(&"safety-bypass"),
        "{:?}",
        within.findings
    );
}

/// A tag holding nothing opens no raw-text block. `<script/>` has no
/// content for markdown to read raw and no closing tag coming, so taking
/// it for the kind that ends at `</script>` ran the block to the end of
/// the document and threw away every span below it.
///
/// The control is the second case: a real `<script>` does hold its content
/// raw, and the marks in there are the script's rather than markdown's.
#[test]
fn safety_bypass_leaves_a_span_under_a_tag_that_holds_nothing() {
    let empty = skill(&[(
        "SKILL.md",
        "<script/>\n\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&empty).contains(&"safety-bypass"),
        "{:?}",
        empty.findings
    );

    let holding = skill(&[(
        "SKILL.md",
        "<script>\nThe bypass is `git commit --no-verify`, never run it.\n</script>\n",
    )]);
    assert_eq!(
        severity_of(&holding, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        holding.findings
    );
}

/// A line entering a deeper quote has left the paragraph above it, so the
/// paragraph that decides whether a whole tag may open a block is the one
/// this line could continue rather than any open paragraph at all. Asking
/// the question globally refused the tag, read both quoted lines as one
/// paragraph, paired the backticks and suppressed a real bypass.
///
/// The control is the second case, and it is the rule the gate is for: at
/// the paragraph's own depth the tag does continue it, and the span across
/// it is real.
#[test]
fn safety_bypass_opens_a_block_at_a_tag_that_entered_a_deeper_quote() {
    let deeper = skill(&[(
        "SKILL.md",
        "Read this.\n> <span>\n> The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&deeper, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        deeper.findings
    );

    let alongside = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit\n> <span>\n> --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&alongside).contains(&"safety-bypass"),
        "{:?}",
        alongside.findings
    );
}

/// A whole tag alone on its line opens a block whatever its name.
/// `<textarea/>` starts no raw-text block — the character behind the name
/// is neither whitespace nor `>` — and markdown's prose excludes the four
/// raw-text names from the whole-tag kind as well, so on the page it opens
/// nothing. No implementation reads it that way: `pulldown-cmark` and
/// commonmark.js both open the whole-tag block, whose reach is the next
/// blank line. The line under it is the block's own text, the span it
/// would have carried is gone, and the switch that span quoted is
/// reported — over-counting, which is the safe side of this ledger.
///
/// The control is the second case: the kind ends at a blank line, so a
/// paragraph past one carries its span and its switch is a mention again.
#[test]
fn safety_bypass_opens_a_block_at_a_raw_text_tag_that_holds_nothing() {
    let under = skill(&[(
        "SKILL.md",
        "<textarea/>\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&under, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        under.findings
    );

    let past = skill(&[(
        "SKILL.md",
        "<textarea/>\n\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&past).contains(&"safety-bypass"),
        "{:?}",
        past.findings
    );
}

/// A declaration is `<!` and an ASCII letter of either case, and it opens a
/// block that ends on the `>` its own line carries. Both spellings of a
/// doctype are the same block, so a span cannot survive one and be cut by
/// the other — which is what reading the letter's case as part of the
/// condition would do.
#[test]
fn safety_bypass_reads_a_declaration_the_same_in_either_case() {
    let lower = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n<!doctype html>\n--no-verify`, never run it.\n",
    )]);
    let upper = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n<!DOCTYPE html>\n--no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&lower, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        lower.findings
    );
    assert_eq!(
        severity_of(&lower, "safety-bypass"),
        severity_of(&upper, "safety-bypass"),
        "{:?} {:?}",
        lower.findings,
        upper.findings
    );
}

/// A backtick fence's info string may hold no backtick. Markdown reads such
/// a line as a paragraph carrying a code span, so opening a fence there
/// swallowed the lines under it, threw away the spans they held, and
/// reported the switch one of them quoted as a switch standing in the open.
///
/// The control is the second case: an ordinary info string opens the fence
/// it always did, and what the fence holds is code at full weight.
#[test]
fn safety_bypass_opens_no_fence_where_an_info_string_holds_a_backtick() {
    let info = skill(&[(
        "SKILL.md",
        "> ``` bad`x` info\n> The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&info).contains(&"safety-bypass"),
        "{:?}",
        info.findings
    );

    let ordinary = skill(&[("SKILL.md", "```sh\ngit commit --no-verify\n```\n")]);
    assert_eq!(
        severity_of(&ordinary, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        ordinary.findings
    );
}

/// The limit belongs to the backtick, not to info strings. A tilde fence's
/// info string may hold backticks and tildes alike, so it opens the block it
/// always opened and the switch inside stands as code — which is what a
/// reader that refused every backtick in an info string would lose.
#[test]
fn safety_bypass_opens_a_tilde_fence_whose_info_string_holds_a_backtick() {
    let tilde = skill(&[("SKILL.md", "~~~ aa ``` ~~~\ngit commit --no-verify\n~~~\n")]);
    assert_eq!(
        severity_of(&tilde, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        tilde.findings
    );
}

/// A closing fence carries no info string, so a marker with words behind it
/// is a line of the block's own text and the block runs on. Accepting it as
/// a close would end the block early and hand the lines below it back to
/// markdown, where a pair of backticks quotes the switch and the finding
/// goes quiet.
#[test]
fn safety_bypass_keeps_a_fence_open_past_a_marker_carrying_words() {
    let carried = skill(&[(
        "SKILL.md",
        "```\n``` aaa\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&carried, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        carried.findings
    );
}

/// The slash and the `>` of an empty tag are one thing. Markdown allows
/// spacing before that slash and none after it, so `<span/   >` is a line
/// of prose; taking it for a whole tag opened a block that runs to the next
/// blank line and threw away every span under it.
///
/// The control is the second case: written contiguously the tag is whole,
/// and the block it opens is real.
#[test]
fn safety_bypass_opens_no_block_at_a_slash_parted_from_its_bracket() {
    let parted = skill(&[(
        "SKILL.md",
        "<span/   >\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&parted).contains(&"safety-bypass"),
        "{:?}",
        parted.findings
    );

    let whole = skill(&[(
        "SKILL.md",
        "<span/>\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&whole, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        whole.findings
    );
}

/// A fence's own marker stands at most three spaces into its container, and
/// a fourth is the indented code block instead. Measured from the start of
/// the line rather than from where the quote's markers end, a marker four
/// spaces past a `>` opened a fence markdown has none of, and the quoted
/// prose under it lost the span it really holds.
///
/// The control is the second case: three spaces past the marker is a fence,
/// and what it holds is code.
#[test]
fn safety_bypass_opens_no_fence_four_spaces_past_a_quote() {
    let deep = skill(&[(
        "SKILL.md",
        ">     ```sh\n> The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&deep).contains(&"safety-bypass"),
        "{:?}",
        deep.findings
    );

    let near = skill(&[("SKILL.md", ">    ```sh\n> git commit --no-verify\n> ```\n")]);
    assert_eq!(
        severity_of(&near, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        near.findings
    );
}

/// A raw-text block ends on the closing tag of its own name. Markdown
/// says otherwise in as many words — the end condition is a line holding
/// `</pre>`, `</script>`, `</style>` or `</textarea>`, "case-insensitive;
/// it need not match the start tag" — and `pulldown-cmark` requires the
/// match, so a `</pre>` under a `<script>` leaves the block open and the
/// paragraph below it is read as the script's own text. The switch that
/// paragraph's span quoted is reported: over-counting, the safe side, on
/// a shape that stands nowhere in the shipped tree. Correcting the parser
/// by hand here would be the walk this module exists to have deleted.
///
/// The control is the second case: the block does end at its own closing
/// tag, and the paragraph under that carries the span again.
#[test]
fn safety_bypass_ends_a_raw_text_block_at_a_closing_tag_of_its_own_name() {
    let mismatched = skill(&[(
        "SKILL.md",
        "<script>\nfoo\n</pre>\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&mismatched, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        mismatched.findings
    );

    let matched = skill(&[(
        "SKILL.md",
        "<script>\nfoo\n</script>\nThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&matched).contains(&"safety-bypass"),
        "{:?}",
        matched.findings
    );
}
