use super::*;

/// One source frontmatter and the frontmatter its installed copy carries.
/// The body follows both unchanged.
const ROWS: &[(&str, &str, &str)] = &[
    (
        "kendex keys are cut and kept keys keep their bytes",
        "name: gh\ndescription: \"Use gh\" # why\nsummary: Work with GitHub\ntags: [review]\nlicense: MIT\nallowed-tools: Bash(gh:*)\nuser-invocable: false\ndependencies:\n  required: [git]\nrepo-effects:\n  check: scripts/check.sh\n  # kept with its entry\nunknown-key: x\n",
        "name: gh\ndescription: \"Use gh\" # why\nlicense: MIT\nallowed-tools: Bash(gh:*)\nuser-invocable: false\nrepo-effects:\n  check: scripts/check.sh\n  # kept with its entry\n",
    ),
    (
        "metadata keeps its strings, quoted, and drops what is not one",
        "name: gh\nmetadata:\n  version: 1\n  author: acme\n  list: [a]\n  nested:\n    k: v\ndescription: d\n",
        "name: gh\nmetadata:\n  version: \"1\"\n  author: \"acme\"\ndescription: d\n",
    ),
    (
        "metadata with no string value is left out whole",
        "name: gh\nmetadata:\n  list: [a]\ndescription: d\n",
        "name: gh\ndescription: d\n",
    ),
    (
        "metadata that is not a map is left out",
        "name: gh\nmetadata: plain\ndescription: d\n",
        "name: gh\ndescription: d\n",
    ),
    (
        "required commands become compatibility at the end",
        "name: gh\ndependencies:\n  commands:\n    - command: gh\n      purpose: Call GitHub\n    - command: jq\n      purpose: Read JSON\n      optional: true\n    - command: gh\n      purpose: Again\n    - command: git\n      purpose: History\ndescription: d\n",
        "name: gh\ndescription: d\ncompatibility: \"Requires these commands on PATH: gh, git\"\n",
    ),
    (
        "an authored compatibility stands as written",
        "name: gh\ncompatibility: Needs a GitHub token\ndependencies:\n  commands:\n    - command: gh\n      purpose: Call GitHub\ndescription: d\n",
        "name: gh\ncompatibility: Needs a GitHub token\ndescription: d\n",
    ),
    (
        "only optional commands state no requirement",
        "name: gh\ndependencies:\n  commands:\n    - command: jq\n      purpose: Read JSON\n      optional: true\n",
        "name: gh\n",
    ),
    (
        "a leading comment stays",
        "# publisher note\nname: gh\ntags: [review]\n",
        "# publisher note\nname: gh\n",
    ),
    ("an empty block stays empty", "", ""),
];

const BODY: &str = "\n# Body\n\ntags: [not frontmatter]\n";

fn skill(yaml: &str, newline: &str) -> String {
    format!("---\n{yaml}---\n{BODY}").replace('\n', newline)
}

#[test]
fn an_installed_copy_carries_the_shared_key_set_and_keeps_the_rest_of_its_bytes() {
    for (what, source, installed) in ROWS {
        for newline in ["\n", "\r\n"] {
            let out = installed_keys(&skill(source, newline));
            assert_eq!(out, skill(installed, newline), "{what} ({newline:?})");
            assert_eq!(installed_keys(&out), out, "{what}: cut twice");
            let (yaml, _) = crate::frontmatter::split(&out).unwrap();
            let parsed = crate::frontmatter::parse_tolerant(yaml).unwrap();
            for (key, _) in parsed.map.entries() {
                assert!(INSTALLED_KEYS.contains(&key), "{what}: {key}");
            }
        }
    }
}

#[test]
fn a_derived_compatibility_past_the_bound_is_left_out() {
    let commands: String = (0..60)
        .map(|n| format!("    - command: tool-{n:04}\n      purpose: p\n"))
        .collect();
    let source = skill(
        &format!("name: gh\ndependencies:\n  commands:\n{commands}"),
        "\n",
    );
    assert_eq!(installed_keys(&source), skill("name: gh\n", "\n"));
}

#[test]
fn text_without_readable_frontmatter_is_unchanged() {
    for text in [
        "# No block\n",
        "---\nname: gh\n",
        "---\nname: a\nname: b\n---\n",
    ] {
        assert_eq!(installed_keys(text), text);
        assert_eq!(authored_keys(text, &skill(ROWS[0].1, "\n")), text);
    }
}

/// The cut keys come back from the publisher's file, the person's edits
/// stay, and cutting the result again gives the copy back.
#[test]
fn an_edited_copy_takes_back_what_its_install_cut() {
    for (what, source, _) in ROWS {
        for newline in ["\n", "\r\n"] {
            let authored = skill(source, newline);
            let copy = installed_keys(&authored).replace("# Body", "# Edited body");
            let restored = authored_keys(&copy, &authored);
            assert!(restored.contains("# Edited body"), "{what}");
            assert_eq!(installed_keys(&restored), copy, "{what} ({newline:?})");
            let map = |text: &str| {
                let (yaml, _) = crate::frontmatter::split(text).unwrap();
                crate::frontmatter::parse_tolerant(yaml).unwrap().map
            };
            let (restored, authored) = (map(&restored), map(&authored));
            for (key, value) in authored.entries() {
                assert_eq!(restored.get(key), Some(value), "{what}: {key}");
            }
            assert_eq!(
                restored.entries().count(),
                authored.entries().count(),
                "{what}"
            );
        }
    }
}

#[test]
fn a_key_the_person_wrote_into_the_copy_is_theirs() {
    let authored = skill(
        "name: gh\ndescription: d\ntags: [review]\nmetadata:\n  version: 1\n",
        "\n",
    );
    let copy = skill(
        "name: gh\ndescription: edited\nmetadata:\n  version: \"2\"\ntags: [testing]\n",
        "\n",
    );
    assert_eq!(authored_keys(&copy, &authored), copy);
}

#[test]
fn dropped_metadata_names_every_value_the_cut_leaves_out() {
    for (yaml, dropped) in [
        ("name: gh\n", vec![]),
        ("metadata:\n  a: x\n  b: \"1\"\n", vec![]),
        (
            "metadata:\n  a: x\n  b: [1]\n  c:\n  d:\n    e: f\n",
            vec!["metadata.b", "metadata.c", "metadata.d"],
        ),
        ("metadata: plain\n", vec!["metadata"]),
        ("metadata: [a]\n", vec!["metadata"]),
    ] {
        let map = crate::frontmatter::parse_tolerant(yaml).unwrap().map;
        assert_eq!(dropped_metadata(&map), dropped, "{yaml:?}");
    }
}
