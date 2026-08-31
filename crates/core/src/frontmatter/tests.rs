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
