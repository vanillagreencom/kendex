use super::*;

/// Every finding as the pair that tells it apart, in the order the
/// registry was read; the fix is asserted for presence, never its words.
fn said(registry: &Registry) -> Vec<(&str, &str)> {
    for finding in &registry.findings {
        assert!(!finding.fix.is_empty(), "{finding} needs a fix");
    }
    registry
        .findings
        .iter()
        .map(|finding| (finding.location.as_str(), finding.problem.as_str()))
        .collect()
}

/// A catalog root holding whatever registry text the test wants.
fn catalog(registry: &str, dirs: &[&str]) -> (tempfile::TempDir, SealedSource) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let root = tmp.path().join("catalog");
    std::fs::create_dir_all(root.join(".claude-plugin")).expect("mkdir");
    std::fs::write(root.join(REGISTRY), registry).expect("write");
    for dir in dirs {
        std::fs::create_dir_all(root.join(dir)).expect("mkdir");
    }
    let sealed = SealedSource::open(&root).expect("open");
    (tmp, sealed)
}

const WSHOBSON: &str = r#"{
  "name": "claude-code-workflows",
  "owner": {"name": "wshobson", "email": "w@example.invalid"},
  "metadata": {"description": "workflows", "version": "1.2.0"},
  "plugins": [
    {"name": "data-science", "source": "./plugins/data-science", "description": "analysis",
     "version": "0.4.0", "author": {"name": "wshobson"}, "license": "MIT",
     "category": "analysis", "homepage": "https://example.invalid", "keywords": ["eda"]},
    {"name": "code-review", "source": "./plugins/code-review", "version": "1.0.0"},
    {"name": "upstream", "source": {"source": "git-subdir", "url": "https://example.invalid/x",
     "path": "plugins/y"}}
  ]
}"#;

#[test]
fn a_source_without_the_registry_is_not_plugin_registry_shaped() {
    let tmp = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(tmp.path().join("catalog/plugins/thing")).expect("mkdir");
    let sealed = SealedSource::open(&tmp.path().join("catalog")).expect("open");
    // A `plugins/` directory is not evidence: guessing here would rename
    // every item in a catalog that never asked for it.
    assert_eq!(read(&sealed).expect("read"), None);
}

#[test]
fn local_entries_are_consumed_and_entries_elsewhere_are_named() {
    let (_tmp, sealed) = catalog(
        WSHOBSON,
        &["plugins/data-science", "plugins/code-review", "plugins/y"],
    );
    let registry = read(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");
    assert_eq!(registry.name, "claude-code-workflows");
    assert_eq!(registry.owner.as_deref(), Some("wshobson"));
    assert_eq!(registry.version.as_deref(), Some("1.2.0"));
    let names: Vec<&str> = registry.plugins.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["data-science", "code-review"]);

    let first = registry.entry("data-science").expect("entry");
    assert_eq!(first.dir, PathBuf::from("plugins/data-science"));
    assert_eq!(first.category.as_deref(), Some("analysis"));
    assert_eq!(first.author.as_deref(), Some("wshobson"));
    assert_eq!(first.keywords, ["eda"]);

    // The skipped entry is named, with what to do about it — never dropped
    // in silence.
    assert_eq!(
        said(&registry),
        [(
            ".claude-plugin/marketplace.json: upstream",
            "`upstream` lives in another repository, which this version does not fetch"
        )]
    );
}

#[test]
fn a_registry_that_does_not_parse_says_so_and_offers_nothing() {
    let (_tmp, sealed) = catalog("{ not json", &[]);
    let registry = read(&sealed).expect("read").expect("recognized");
    assert!(registry.plugins.is_empty());
    let [(at, problem)] = said(&registry)[..] else {
        panic!("{:?}", registry.findings);
    };
    assert_eq!(at, ".claude-plugin/marketplace.json");
    // The JSON reader's own words follow the dash and are not ours to pin.
    assert!(
        problem.starts_with("this catalog's registry is not readable JSON — "),
        "{problem}"
    );
}

/// One row per defect an entry can carry, each tied to its own finding:
/// a path that climbs out, an absolute one, a URL, a name that is a
/// directory, a directory that is not there, and no source at all. One
/// defect producing two findings while another produced none would be
/// six findings too.
#[test]
fn entries_that_lie_about_where_their_files_are_get_refused() {
    let registry = r#"{
      "name": "hostile", "owner": {"name": "x"},
      "plugins": [
        {"name": "escape", "source": "../../../etc"},
        {"name": "absolute", "source": "/etc"},
        {"name": "url", "source": "https://example.invalid/plugin"},
        {"name": "..", "source": "./plugins/dots"},
        {"name": "missing", "source": "./plugins/gone"},
        {"name": "nameless-source"}
      ]
    }"#;
    let (_tmp, sealed) = catalog(registry, &["plugins/dots"]);
    let registry = read(&sealed).expect("read").expect("recognized");
    assert!(registry.plugins.is_empty());
    assert_eq!(
        said(&registry),
        [
            (
                ".claude-plugin/marketplace.json: escape",
                "`escape` points at `../../../etc`, which leads out of the catalog"
            ),
            (
                ".claude-plugin/marketplace.json: absolute",
                "`absolute` points at `/etc`, which leads out of the catalog"
            ),
            (
                ".claude-plugin/marketplace.json: url",
                "`url` lives in another location on the web, which this version does not fetch"
            ),
            (
                ".claude-plugin/marketplace.json: ..",
                "this plugin cannot be installed under its name: `..` names a directory, not an item"
            ),
            (
                ".claude-plugin/marketplace.json: missing",
                "`plugins/gone` is not a directory in this catalog"
            ),
            (
                ".claude-plugin/marketplace.json: nameless-source",
                "`nameless-source` says nowhere where its files are"
            ),
        ]
    );
}

#[test]
fn two_plugins_a_filesystem_cannot_tell_apart_are_a_finding() {
    let registry = r#"{
      "name": "folded", "owner": {"name": "x"},
      "plugins": [
        {"name": "review", "source": "./plugins/review"},
        {"name": "Review", "source": "./plugins/review-upper"}
      ]
    }"#;
    let (_tmp, sealed) = catalog(registry, &["plugins/review", "plugins/review-upper"]);
    let registry = read(&sealed).expect("read").expect("recognized");
    assert_eq!(registry.plugins.len(), 1);
    assert_eq!(
        said(&registry),
        [(
            ".claude-plugin/marketplace.json: Review",
            "`Review` and `review` are the same name once a filesystem has folded case and trailing dots — one would overwrite the other"
        )]
    );
}

#[test]
fn a_registry_with_no_owner_is_read_and_told_about_it() {
    let registry = r#"{"name": "bare", "plugins": []}"#;
    let (_tmp, sealed) = catalog(registry, &[]);
    let registry = read(&sealed).expect("read").expect("recognized");
    assert_eq!(
        said(&registry),
        [(
            ".claude-plugin/marketplace.json",
            "the catalog says who owns it nowhere, and some tools refuse a catalog without an owner"
        )]
    );
}
