use super::*;
use crate::tags::Tag;

fn frontmatter(body: &str) -> Metadata {
    from_markdown(&format!("---\n{body}\n---\nbody text\n"))
}

#[test]
fn reads_a_description_and_an_inline_tag_list() {
    let meta = frontmatter("description: reviews code\ntags: [review, testing]");
    assert_eq!(meta.description.as_deref(), Some("reviews code"));
    assert_eq!(meta.tags, vec![Tag::Review, Tag::Testing]);
}

/// The summary is the marketplace's line and the description the agent's;
/// a package that writes only the description is shown that one.
#[test]
fn a_summary_is_read_beside_the_description_and_stands_in_for_it() {
    let both = frontmatter(
        "description: Load to run preflight.\nsummary: Diff-scoped shellcheck and TOML checks.",
    );
    assert_eq!(
        both.summary.as_deref(),
        Some("Diff-scoped shellcheck and TOML checks.")
    );
    assert_eq!(
        both.summary_or_description(),
        Some("Diff-scoped shellcheck and TOML checks.")
    );

    let only = frontmatter("description: Load to run preflight.\nsummary: \"  \"");
    assert_eq!(only.summary, None);
    assert_eq!(
        only.summary_or_description(),
        Some("Load to run preflight.")
    );

    let toml = from_toml(
        "description = \"a db\"\nsummary = \"Query the app database\"\ncommand = \"db\"\n",
    );
    assert_eq!(toml.summary.as_deref(), Some("Query the app database"));
    assert_eq!(
        from_toml("command = \"db\"\n").summary_or_description(),
        None
    );
}

#[test]
fn reads_a_block_tag_list() {
    let meta = frontmatter("tags:\n  - review\n  - security");
    assert_eq!(meta.tags, vec![Tag::Review, Tag::Security]);
}

#[test]
fn an_unbracketed_inline_list_is_still_a_list() {
    let meta = frontmatter("tags: review, docs");
    assert_eq!(meta.tags, vec![Tag::Review, Tag::Docs]);
}

/// A trailing comment is ordinary YAML. Reading it as part of the value
/// loses every tag on the item and then names the comment as the mistake.
#[test]
fn a_trailing_comment_is_not_part_of_a_tag() {
    for body in ["tags: [review] # main job", "tags: review # main job"] {
        let meta = frontmatter(body);
        assert_eq!(meta.tags, vec![Tag::Review], "{body}");
        assert!(meta.unknown_tags.is_empty(), "{body}");
    }
}

/// Blank lines and comments sit inside a block sequence all the time; a
/// reader that stops at the first one drops the rest of the list silently.
#[test]
fn a_blank_line_or_comment_does_not_end_a_block_list() {
    let meta = frontmatter("tags:\n  - review\n\n  # the other one\n  - security");
    assert_eq!(meta.tags, vec![Tag::Review, Tag::Security]);
}

/// The dashes under `tags` belong to `tags`. A later key's list items must
/// not be swept up as tags too.
#[test]
fn a_block_list_ends_at_the_next_key() {
    let meta = frontmatter("tags:\n  - review\nallowed-tools:\n  - Bash\n  - Read");
    assert_eq!(meta.tags, vec![Tag::Review]);
    assert!(meta.unknown_tags.is_empty());
}

/// A folded description is prose, not the character that introduces it.
#[test]
fn a_folded_description_is_read_as_its_text() {
    let meta = frontmatter("description: >\n  a long description\n  over two lines");
    assert_eq!(
        meta.description.as_deref(),
        Some("a long description over two lines")
    );
}

#[test]
fn an_empty_tag_list_is_no_tags_and_no_complaint() {
    for body in ["tags: []", "tags:"] {
        let meta = frontmatter(body);
        assert!(meta.tags.is_empty(), "{body}");
        assert!(meta.unknown_tags.is_empty(), "{body}");
    }
}

#[test]
fn a_word_that_is_not_a_tag_is_kept_for_the_warning() {
    let meta = frontmatter("tags: [review, wizardry]");
    assert_eq!(meta.tags, vec![Tag::Review]);
    assert_eq!(meta.unknown_tags, vec!["wizardry".to_owned()]);
}

#[test]
fn a_repeated_tag_is_still_one_tag() {
    assert_eq!(
        frontmatter("tags: [review, review]").tags,
        vec![Tag::Review]
    );
}

#[test]
fn casing_and_padding_are_the_authors_business() {
    let meta = frontmatter("tags: [ Review , SECURITY ]");
    assert_eq!(meta.tags, vec![Tag::Review, Tag::Security]);
}

#[test]
fn tags_come_back_in_vocabulary_order_however_they_were_written() {
    assert_eq!(
        frontmatter("tags: [testing, review]").tags,
        vec![Tag::Review, Tag::Testing]
    );
}

#[test]
fn a_file_with_no_frontmatter_says_nothing_about_itself() {
    assert_eq!(from_markdown("# Just a heading\n"), Metadata::default());
}

#[test]
fn toml_carries_the_same_two_keys() {
    let meta = from_toml("description = \"ships things\"\ntags = [\"release\", \"git\"]\n");
    assert_eq!(meta.description.as_deref(), Some("ships things"));
    assert_eq!(meta.tags, vec![Tag::Git, Tag::Release]);
}

/// A near miss is one letter from correct, so the warning says which letter
/// — printing the whole vocabulary makes the reader do that work.
#[test]
fn a_near_miss_is_told_what_it_nearly_was() {
    let meta = frontmatter("tags: [tests]");
    let warning = meta.unknown_warning().unwrap();
    assert!(warning.contains("did you mean `testing`?"), "{warning}");
}

/// Nothing close means no guess: naming a tag it plainly is not would send
/// the reader to fix the wrong thing.
#[test]
fn a_word_nothing_like_a_tag_gets_the_vocabulary() {
    let meta = frontmatter("tags: [wizardry]");
    let warning = meta.unknown_warning().unwrap();
    assert!(!warning.contains("did you mean"), "{warning}");
    assert!(warning.contains("review, testing"), "{warning}");
}

#[test]
fn several_bad_words_are_counted_rather_than_all_listed() {
    let meta = frontmatter("tags: [tests, wizardry, sorcery]");
    let warning = meta.unknown_warning().unwrap();
    assert!(warning.contains("and 2 others"), "{warning}");
}

#[test]
fn nothing_unknown_means_nothing_to_warn_about() {
    assert_eq!(frontmatter("tags: [review]").unknown_warning(), None);
}

/// The same word twice is one mistake, whatever case it was written in.
#[test]
fn a_repeated_bad_word_is_reported_once() {
    let meta = frontmatter("tags: [tests, Tests]");
    assert_eq!(meta.unknown_tags.len(), 1);
}

/// A markdown header that never closes inside the cap is not a header, and
/// guessing at half of one would report a description the file does not have.
#[test]
fn an_unterminated_header_says_nothing() {
    let runaway = format!("---\ndescription: real\n{}", "x".repeat(80 * 1024));
    assert_eq!(from_markdown(&runaway), Metadata::default());
}
