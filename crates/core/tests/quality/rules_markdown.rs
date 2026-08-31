//! The constructs a code span's reach turns on that no walk written here
//! carried: a table cell, a link reference definition, a list item's
//! content column, a tab measured in columns, a backtick inside an
//! autolink, and the start number that decides whether an ordered list may
//! interrupt a paragraph. Each one is a place two backticks pair that
//! should not, or fail to pair where they should, and a switch between
//! them is scored as the wrong thing either way.
//!
//! One test here is not that shape. A markdown extension can turn an
//! indented code block into prose, which quiets every switch inside it, so
//! which dialect the audit reads is a security decision — and the footnote
//! case is the one that proved it.
//!
//! [`super::rules_blocks`] holds the boundaries the old walk did model.

use kendex_core::quality::Severity;

use super::rules::{rules_hit, severity_of, skill};

/// Every leaf block's opener takes the same three spaces, and a fourth is
/// the indented code block — which may not interrupt an open paragraph, so
/// four spaces under one is that paragraph's next line and the span across
/// it survives.
///
/// The control is the second case, opener by opener: three spaces in, each
/// one does break the paragraph, and the switch below stands in the open.
#[test]
fn safety_bypass_opens_no_leaf_block_four_spaces_in() {
    for opener in ["# heading", "=========", "***", "- item", "<div>"] {
        let deep = skill(&[(
            "SKILL.md",
            &format!("The bypass is `git commit\n    {opener}\n--no-verify`, never run it.\n"),
        )]);
        assert!(
            !rules_hit(&deep).contains(&"safety-bypass"),
            "{opener}: {:?}",
            deep.findings
        );

        let near = skill(&[(
            "SKILL.md",
            &format!("The bypass is `git commit\n   {opener}\n--no-verify`, never run it.\n"),
        )]);
        assert_eq!(
            severity_of(&near, "safety-bypass"),
            Some(Severity::Critical),
            "{opener}: {:?}",
            near.findings
        );
    }
}

/// A table cell is a leaf block of its own, so a run of backticks opened in
/// one meets no partner in the next and quotes nothing.
///
/// The control is the second case: take the delimiter row away and the same
/// three lines are one paragraph, where the span is real.
#[test]
fn safety_bypass_reads_a_switch_a_table_row_keeps_out_of_a_span() {
    let tabled = skill(&[(
        "SKILL.md",
        "| head |\n| --- |\n| Write `git commit |\n| --no-verify` to git. |\n",
    )]);
    assert_eq!(
        severity_of(&tabled, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        tabled.findings
    );

    let joined = skill(&[(
        "SKILL.md",
        "| head |\n| Write `git commit |\n| --no-verify` to git. |\n",
    )]);
    assert!(
        !rules_hit(&joined).contains(&"safety-bypass"),
        "{:?}",
        joined.findings
    );
}

/// A footnote definition takes four-space-indented content below it as
/// that footnote's prose, where a reader without the extension has an
/// indented code block. Inside a block a backtick is the shell's own
/// character and the switch beside it counts; in prose the backticks pair
/// and the same switch reads as a mention. So enabling footnotes put a
/// one-line audit bypass in every document: `[^a]: note` at the top, and
/// every indented block below it went quiet.
///
/// This is why the reading enables no extension the shipped tree does not
/// use — no file in it defines a footnote. Both cases here are the same
/// document, one carrying the label and one not, and they score alike
/// because without the extension the label is prose like any other.
#[test]
fn safety_bypass_survives_a_footnote_label_above_an_indented_block() {
    let labelled = skill(&[(
        "SKILL.md",
        "[^a]: note\n\n    The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&labelled, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        labelled.findings
    );

    let plain = skill(&[(
        "SKILL.md",
        "Read this.\n\n    The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&plain, "safety-bypass"),
        severity_of(&labelled, "safety-bypass"),
        "{:?} {:?}",
        plain.findings,
        labelled.findings
    );
}

/// A link reference definition carries no inline content, so the backticks
/// in its label are literal characters and quote nothing. Reading the line
/// as a paragraph quoted the switch its label spells and scored a use as a
/// mention.
///
/// The control is the second case: the same label in a sentence is inline
/// content, and there the marks do quote.
#[test]
fn safety_bypass_reads_a_switch_a_link_definition_spells() {
    let defined = skill(&[(
        "SKILL.md",
        "Read this.\n\n[`git commit --no-verify`]: src/main.rs\n",
    )]);
    assert_eq!(
        severity_of(&defined, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        defined.findings
    );

    let inline = skill(&[(
        "SKILL.md",
        "Read this.\n\n[`git commit --no-verify`] is the shape.\n",
    )]);
    assert!(
        !rules_hit(&inline).contains(&"safety-bypass"),
        "{:?}",
        inline.findings
    );
}

/// Four spaces are measured from a list item's content column, not from the
/// start of the line. Under an item whose content starts four in, a
/// continuation paragraph at four is the item's own prose and the marks on
/// it are markdown's; reading it as an indented code block threw its span
/// away and reported the switch that span quoted.
///
/// The control is the second case: with no item above it, the same four
/// spaces do open a code block, and the marks in there are the shell's.
#[test]
fn safety_bypass_measures_an_indent_from_a_list_items_content_column() {
    let item = skill(&[(
        "SKILL.md",
        "16. Say this.\n\n    The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&item).contains(&"safety-bypass"),
        "{:?}",
        item.findings
    );

    let alone = skill(&[(
        "SKILL.md",
        "Say this.\n\n    The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&alone, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        alone.findings
    );
}

/// An indent is a count of columns, and a tab is as many of them as it
/// takes to reach the next stop. A tab under a two-column list item is two
/// columns of item content, not the four that open a code block; reading
/// any leading tab as a block threw the line's span away.
///
/// The control is the second case: with no item above it, that same tab is
/// four columns from the margin and does open a block.
#[test]
fn safety_bypass_measures_a_tab_in_columns_rather_than_as_an_indent() {
    let item = skill(&[(
        "SKILL.md",
        "- Say this.\n\n\tThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&item).contains(&"safety-bypass"),
        "{:?}",
        item.findings
    );

    let alone = skill(&[(
        "SKILL.md",
        "Say this.\n\n\tThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&alone, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        alone.findings
    );
}

/// A backtick inside an autolink is a byte of the address, not a delimiter.
/// Pairing it with the next one in the line quoted the text between them
/// and left the switch past it standing in the open.
///
/// The control is the second case: written as bare text the same address
/// carries a real delimiter, the pair closes early, and the switch is
/// outside every span.
#[test]
fn safety_bypass_leaves_a_backtick_in_an_autolink_unpaired() {
    let linked = skill(&[(
        "SKILL.md",
        "See <https://example.com/a`b> and `git commit --no-verify` now.\n",
    )]);
    assert!(
        !rules_hit(&linked).contains(&"safety-bypass"),
        "{:?}",
        linked.findings
    );

    let bare = skill(&[(
        "SKILL.md",
        "See https://example.com/a`b and `git commit --no-verify` now.\n",
    )]);
    assert_eq!(
        severity_of(&bare, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        bare.findings
    );
}

/// An ordered list interrupts a paragraph only where it starts at one, so
/// a `2.` under prose is that paragraph's next line and the span across it
/// closes. Reading every number alike invented a boundary and reported a
/// mention.
///
/// The control is the second case: `1.` does interrupt, and the switch
/// under it stands in a block of its own.
#[test]
fn safety_bypass_lets_only_a_first_ordered_item_break_a_paragraph() {
    let second = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n2. --no-verify` to git.\n",
    )]);
    assert!(
        !rules_hit(&second).contains(&"safety-bypass"),
        "{:?}",
        second.findings
    );

    let first = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n1. --no-verify` to git.\n",
    )]);
    assert_eq!(
        severity_of(&first, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        first.findings
    );
}

/// The block-level tag names are markdown's own list, whoever holds it.
/// A name on it opens a block wherever it stands, an open paragraph
/// included, and one off it is the whole-tag kind, which may not interrupt
/// a paragraph. `search` and `hgroup` are the pair that tells a current
/// list from a stale one: HTML has both, markdown lists only the first,
/// and a copy that guessed by looking at HTML would read them alike.
#[test]
fn safety_bypass_opens_a_block_at_the_tags_markdown_lists_and_no_others() {
    let listed = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n<search>\n--no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&listed, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        listed.findings
    );

    let unlisted = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n<hgroup>\n--no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&unlisted).contains(&"safety-bypass"),
        "{:?}",
        unlisted.findings
    );
}

/// A blockquote marker takes the whitespace behind it, a tab included, so
/// what is left of a quoted prose line is prose. Leaving the tab in the
/// remainder read the line as an indented code block, threw its span away
/// and reported the switch the quotation was naming.
///
/// The control is the second case: four columns past the marker really is
/// a code block inside the quote, and the marks in there are the shell's.
#[test]
fn safety_bypass_takes_a_tab_behind_a_blockquote_marker() {
    let quoted = skill(&[(
        "SKILL.md",
        ">\tThe bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert!(
        !rules_hit(&quoted).contains(&"safety-bypass"),
        "{:?}",
        quoted.findings
    );

    let indented = skill(&[(
        "SKILL.md",
        ">     The bypass is `git commit --no-verify`, never run it.\n",
    )]);
    assert_eq!(
        severity_of(&indented, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        indented.findings
    );
}
