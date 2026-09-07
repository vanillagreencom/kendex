use super::*;
use crate::tags::Tag;

fn frontmatter(body: &str) -> Metadata {
    from_markdown(&format!("---\n{body}\n---\nbody text\n"))
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
    // A blank summary in TOML is absent too, the same rule as the markdown
    // header, so the row falls back to the description.
    let blank = from_toml("description = \"a db\"\nsummary = \"  \"\n");
    assert_eq!(blank.summary, None);
    assert_eq!(blank.summary_or_description(), Some("a db"));
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
fn a_file_with_no_frontmatter_says_nothing_about_itself() {
    assert_eq!(from_markdown("# Just a heading\n"), Metadata::default());
}

#[test]
fn toml_carries_the_same_two_keys() {
    let meta = from_toml("description = \"ships things\"\ntags = [\"release\", \"git\"]\n");
    assert_eq!(meta.description.as_deref(), Some("ships things"));
    assert_eq!(meta.tags, vec![Tag::Git, Tag::Release]);
}

#[test]
fn reads_a_plain_description() {
    let meta = frontmatter("description: reviews code\ntags: [review, testing]");
    assert_eq!(meta.description.as_deref(), Some("reviews code"));
}

/// One row per spelling a tag list takes in a header: the tags it decodes
/// to, in vocabulary order however they were written, and the words kept
/// for the warning. A trailing comment is ordinary YAML, and reading it as
/// part of the value loses every tag on the item and then names the
/// comment as the mistake. Blank lines and comments sit inside a block
/// sequence all the time; a reader that stops at the first one drops the
/// rest of the list silently. The dashes under `tags` belong to `tags`,
/// so a later key's list items are not swept up as tags. An empty list is
/// no tags and no complaint. Casing and padding are the author's
/// business, a repeated tag is one tag, and the same bad word twice is one
/// mistake whatever case it was written in.
#[test]
fn a_tag_list_decodes_to_its_tags_and_keeps_the_rest_for_the_warning() {
    let rows: [(&str, &[Tag], &[&str]); 14] = [
        ("tags: [review, testing]", &[Tag::Review, Tag::Testing], &[]),
        (
            "tags:\n  - review\n  - security",
            &[Tag::Review, Tag::Security],
            &[],
        ),
        ("tags: review, docs", &[Tag::Review, Tag::Docs], &[]),
        ("tags: [review] # main job", &[Tag::Review], &[]),
        ("tags: review # main job", &[Tag::Review], &[]),
        (
            "tags:\n  - review\n\n  # the other one\n  - security",
            &[Tag::Review, Tag::Security],
            &[],
        ),
        (
            "tags:\n  - review\nallowed-tools:\n  - Bash\n  - Read",
            &[Tag::Review],
            &[],
        ),
        ("tags: []", &[], &[]),
        ("tags:", &[], &[]),
        ("tags: [review, wizardry]", &[Tag::Review], &["wizardry"]),
        ("tags: [review, review]", &[Tag::Review], &[]),
        (
            "tags: [ Review , SECURITY ]",
            &[Tag::Review, Tag::Security],
            &[],
        ),
        ("tags: [testing, review]", &[Tag::Review, Tag::Testing], &[]),
        ("tags: [tests, Tests]", &[], &["tests"]),
    ];
    for (body, tags, unknown) in rows {
        let meta = frontmatter(body);
        assert_eq!(meta.tags, tags, "{body:?}");
        assert_eq!(meta.unknown_tags, unknown, "{body:?}");
    }
}

/// One row per shape the unknown-tag warning takes. A near miss is one
/// letter from correct, so the warning says which letter — printing the
/// whole vocabulary makes the reader do that work. Nothing close means no
/// guess, since naming a tag it plainly is not would send the reader to
/// fix the wrong thing; that arm lists the whole vocabulary, in its
/// order, pinned here as the fifteen names rather than built from
/// `tags::ALL_TAGS`, which the warning reads too. Several bad words are
/// counted rather than all listed. Nothing unknown is nothing to warn
/// about.
#[test]
fn the_unknown_tag_warning_names_the_nearest_tag_or_the_vocabulary() {
    let rows = [
        (
            "tags: [tests]",
            Some("`tests` is not a tag — did you mean `testing`?"),
        ),
        (
            "tags: [wizardry]",
            Some(
                "`wizardry` is not a tag — the tags are review, testing, debugging, refactoring, planning, research, docs, security, performance, git, release, data, ui, integration, automation",
            ),
        ),
        (
            "tags: [tests, wizardry, sorcery]",
            Some("`tests` is not a tag — did you mean `testing`? (and 2 others)"),
        ),
        ("tags: [review]", None),
    ];
    for (body, warning) in rows {
        assert_eq!(
            frontmatter(body).unknown_warning().as_deref(),
            warning,
            "{body}"
        );
    }
}

/// A markdown header that never closes inside the cap is not a header, and
/// guessing at half of one would report a description the file does not have.
#[test]
fn an_unterminated_header_says_nothing() {
    let runaway = format!("---\ndescription: real\n{}", "x".repeat(80 * 1024));
    assert_eq!(from_markdown(&runaway), Metadata::default());
}
