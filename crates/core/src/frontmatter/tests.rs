use super::*;

fn scalar<'a>(map: &'a Map, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

#[test]
fn splits_on_exact_terminator_lines_only() {
    let (yaml, body) = split("---\nname: x\n---\nBody --- dashes\n").unwrap();
    assert_eq!(yaml, "name: x\n");
    assert_eq!(body, "Body --- dashes\n");
    assert_eq!(
        split("---\nname: x\n----broken\n"),
        Err("unterminated frontmatter".to_owned())
    );
    assert_eq!(
        split("no frontmatter"),
        Err("file has no frontmatter".to_owned())
    );
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

/// One row per YAML the parsers refuse, and the refusal: the whole
/// message where the parser composes it, and the key it names where the
/// YAML library's own words follow. A strict key gets no salvage: an anchor
/// under `tools` or `role`, and a broken block scalar, are refused
/// outright. Adversarial YAML is refused by name: aliases, a duplicate
/// key, nesting past the depth bound, a document past the byte bound,
/// more nodes than the bound, complex keys, and multiple documents.
#[test]
fn a_yaml_the_parsers_refuse_is_named_by_what_it_did() {
    let deep = format!("a: {}{}", "[".repeat(40), "]".repeat(40));
    let big = format!("a: {}\n", "x".repeat(MAX_YAML_BYTES));
    let many = "k: [".to_owned() + &"a,".repeat(MAX_NODES + 1) + "]";
    let rows: [(&str, bool, &str, bool); 10] = [
        ("tools: *x\n", true, "`tools`: ", false),
        ("role: *alias\n", true, "`role`: ", false),
        (
            "description: |bad\n  content\n",
            true,
            "`description`: ",
            false,
        ),
        (
            "a: &x 1\nb: *x\n",
            false,
            "YAML aliases are not accepted in frontmatter",
            true,
        ),
        ("a: 1\na: 2\n", true, "duplicate frontmatter key `a`", true),
        (
            &deep,
            true,
            "`a`: frontmatter nests deeper than 16 levels",
            true,
        ),
        (
            &big,
            true,
            "frontmatter is 65540 bytes — the limit is 65536",
            true,
        ),
        (
            &many,
            true,
            "`k`: frontmatter exceeds 4096 YAML nodes",
            true,
        ),
        (
            "? [a, b]\n: c\n",
            false,
            "YAML complex keys are not accepted in frontmatter",
            true,
        ),
        (
            "a: 1\n---\nb: 2\n",
            false,
            "multiple YAML documents in frontmatter",
            true,
        ),
    ];
    for (yaml, tolerant, refusal, whole) in rows {
        let refused = match tolerant {
            true => parse_tolerant(yaml).map(drop),
            false => parse(yaml).map(drop),
        }
        .unwrap_err();
        match whole {
            true => assert_eq!(refused, refusal, "{yaml:?}"),
            false => assert!(refused.starts_with(refusal), "{yaml:?}: {refused}"),
        }
    }
}

#[test]
fn scalars_stay_strings_and_null_forms_collapse() {
    let map = parse("a: no\nb: \"null\"\nc: ~\nd: 007\n").unwrap();
    assert_eq!(map.get("a").and_then(Value::as_str), Some("no"));
    assert_eq!(map.get("b").and_then(Value::as_str), Some("null"));
    assert_eq!(map.get("c"), Some(&Value::Null));
    assert_eq!(map.get("d").and_then(Value::as_str), Some("007"));
}
