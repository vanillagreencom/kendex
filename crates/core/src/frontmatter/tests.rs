use super::*;

fn scalar<'a>(map: &'a Map, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

#[test]
fn splits_on_exact_terminator_lines_only() {
    let (yaml, body) = split("---\nname: x\n---\nBody --- dashes\n").unwrap();
    assert_eq!(yaml, "name: x\n");
    assert_eq!(body, "Body --- dashes\n");
    assert!(split("---\nname: x\n----broken\n").is_err());
    assert!(split("no frontmatter").is_err());
    // Trailing whitespace on either marker is tolerated.
    let (yaml, _) = split("--- \nname: x\n---  \nBody\n").unwrap();
    assert_eq!(yaml, "name: x\n");
}

#[test]
fn block_scalars_arrays_and_nested_maps_parse() {
    let parsed = parse_tolerant(concat!(
        "description: >\n  folded text\n  stays text\n",
        "tools:\n  - Read\n  - Grep\n",
        "hooks:\n  PreToolUse:\n    command: ./x.sh\n",
    ))
    .unwrap();
    let description = scalar(&parsed.map, "description").unwrap();
    assert!(description.starts_with("folded text"));
    assert!(!description.contains('>'));
    assert_eq!(parsed.map.string_list("tools").unwrap(), ["Read", "Grep"]);
    let Some(Value::Map(hooks)) = parsed.map.get("hooks") else {
        panic!("hooks should be a nested map");
    };
    assert!(hooks.get("PreToolUse").is_some());
    assert!(parsed.warnings.is_empty());
}

#[test]
fn plain_inline_values_are_taken_verbatim_like_harness_loaders_do() {
    let parsed = parse_tolerant(concat!(
        "description: Use when: reviewing Rust\n",
        "note: *important* agent\n",
        "tags: uses #tags here\n",
        "quoted: \"a: b\"\n",
    ))
    .unwrap();
    assert_eq!(
        scalar(&parsed.map, "description"),
        Some("Use when: reviewing Rust")
    );
    assert_eq!(scalar(&parsed.map, "note"), Some("*important* agent"));
    assert_eq!(scalar(&parsed.map, "tags"), Some("uses #tags here"));
    assert_eq!(scalar(&parsed.map, "quoted"), Some("a: b"));
    // The anchor-looking value was salvaged with a warning.
    assert!(parsed.warnings.iter().any(|w| w.contains("note")));
}

#[test]
fn strict_keys_get_no_salvage() {
    assert!(parse_tolerant("tools: *x\n").is_err());
    assert!(parse_tolerant("role: *alias\n").is_err());
    let broken_block = "description: |bad\n  content\n";
    assert!(parse_tolerant(broken_block).is_err());
}

#[test]
fn absent_empty_and_csv_lists_stay_distinct() {
    let parsed = parse_tolerant("tools:\nother: Read, Grep , \n").unwrap();
    assert_eq!(
        parsed.map.string_list("tools").unwrap(),
        Vec::<String>::new()
    );
    assert_eq!(parsed.map.string_list("other").unwrap(), ["Read", "Grep"]);
    assert_eq!(parsed.map.string_list("absent"), None);
    let flow = parse_tolerant("tools: []\n").unwrap();
    assert_eq!(flow.map.string_list("tools").unwrap(), Vec::<String>::new());
}

#[test]
fn adversarial_yaml_is_refused() {
    assert!(parse("a: &x 1\nb: *x\n").unwrap_err().contains("alias"));
    assert!(
        parse_tolerant("a: 1\na: 2\n")
            .unwrap_err()
            .contains("duplicate")
    );
    let deep = format!("a: {}{}", "[".repeat(40), "]".repeat(40));
    assert!(parse_tolerant(&deep).unwrap_err().contains("deeper"));
    let big = format!("a: {}\n", "x".repeat(MAX_YAML_BYTES));
    assert!(parse_tolerant(&big).unwrap_err().contains("bytes"));
    let many = "k: [".to_owned() + &"a,".repeat(MAX_NODES + 1) + "]";
    assert!(parse_tolerant(&many).unwrap_err().contains("nodes"));
    assert!(
        parse("? [a, b]\n: c\n")
            .unwrap_err()
            .contains("complex keys")
    );
    assert!(parse("a: 1\n---\nb: 2\n").unwrap_err().contains("multiple"));
}

#[test]
fn scalars_stay_strings_and_null_forms_collapse() {
    let map = parse("a: no\nb: \"null\"\nc: ~\nd: 007\n").unwrap();
    assert_eq!(map.get("a").and_then(Value::as_str), Some("no"));
    assert_eq!(map.get("b").and_then(Value::as_str), Some("null"));
    assert_eq!(map.get("c"), Some(&Value::Null));
    assert_eq!(map.get("d").and_then(Value::as_str), Some("007"));
}

fn span_of(text: &str) -> Result<&str, NameProblem> {
    name_value_span(text).map(|span| &text[span])
}

#[test]
fn finds_the_inline_value_and_only_it() {
    assert_eq!(span_of("---\nname: gh\n---\nBody.\n"), Ok("gh"));
    assert_eq!(span_of("---\nname : gh\n---\n"), Ok("gh"));
    assert_eq!(span_of("---\nname:   gh  \n---\n"), Ok("gh"));
    assert_eq!(span_of("---\r\nname: gh\r\n---\r\n"), Ok("gh"));
    assert_eq!(span_of("---\nname: gh #edited\n...\n"), Ok("gh #edited"));
    assert_eq!(span_of("---\nname: \"gh\"\n---\n"), Ok("\"gh\""));
    assert_eq!(span_of("---\nname: 'gh'\n---\n"), Ok("'gh'"));
    // A comment after a quoted value belongs to the line, not the
    // value; an escaped quote does not close the scalar.
    assert_eq!(span_of("---\nname: \"gh\" # package\n---\n"), Ok("\"gh\""));
    assert_eq!(span_of("---\nname: 'it''s' # x\n---\n"), Ok("'it''s'"));
    assert_eq!(
        span_of("---\nname: \"a\\\"b\" # c\n---\n"),
        Ok("\"a\\\"b\"")
    );
    // A comment-only or blank line after the entry is not a
    // continuation of its value, indented or not.
    assert_eq!(span_of("---\nname: gh\n  # note\n---\n"), Ok("gh"));
    assert_eq!(span_of("---\nname: gh\n\ndesc: d\n---\n"), Ok("gh"));
    // Not a top-level entry, and not the `name` key.
    assert_eq!(
        span_of("---\nmeta:\n  name: inner\nname: outer\n---\n"),
        Ok("outer")
    );
    assert_eq!(
        span_of("---\nnames: many\n---\n"),
        Err(NameProblem::Missing { insert_at: 4 })
    );
}

#[test]
fn refuses_what_is_not_one_scalar() {
    assert_eq!(span_of("Body.\n"), Err(NameProblem::NoFrontmatter));
    assert_eq!(
        span_of("---\nname: a\nname: b\n---\n"),
        Err(NameProblem::Twice)
    );
    for text in [
        "---\nname: [copy]\n---\n",
        "---\nname: |\n  gh\n---\n",
        "---\nname: >\n  gh\n---\n",
        "---\nname: &anchor gh\n---\n",
        "---\nname: gh\n  continued\n---\n",
        "---\nname: gh\n  # note\n  continued\n---\n",
        "---\nname:\n---\n",
        "---\nname: \"gh\n---\n",
        "---\nname: \"gh\" trailing\n---\n",
        "---\nname: \"gh\"#glued\n---\n",
    ] {
        assert_eq!(span_of(text), Err(NameProblem::NotAScalar), "{text:?}");
    }
}
