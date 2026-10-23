//! The per-marketplace summary `kendex index` emits: its field order is a
//! published schema, its metadata comes from the catalog's own
//! `[marketplace]` table, and every string a catalog wrote is capped and
//! control-char-safe before it can reach a terminal or the directory.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::source::index::index;
use kendex_core::source_read::SealedSource;

#[allow(clippy::unwrap_used)]
fn repo() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    (tmp, root)
}

#[allow(clippy::unwrap_used)]
fn skill(root: &Path, name: &str) {
    let dir = root.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\ntags: [git]\n---\nBody.\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn summary(root: &Path) -> kendex_core::source::MarketplaceIndex {
    let sealed = SealedSource::open(root).unwrap();
    index(&sealed, "repo").unwrap()
}

/// Field order is part of the schema: a consumer diffing two summaries must
/// see the same shape every time, so the order is pinned, not incidental.
#[test]
#[allow(clippy::unwrap_used)]
fn the_summary_keeps_its_published_field_order() {
    let (_tmp, root) = repo();
    skill(&root, "gh");
    let json = serde_json::to_value(summary(&root)).unwrap();
    let keys: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        [
            "schema",
            "name",
            "description",
            "author",
            "license",
            "homepage",
            "tags",
            "counts",
            "checked",
            "packages",
            "bundles",
            "found",
            "findings"
        ]
    );
    assert_eq!(json["schema"], 2);
}

/// `[marketplace]` is the catalog speaking about itself: read where present,
/// and never trusted — control characters are shown as escapes and overlong
/// text is cut, because this text reaches terminals and the directory.
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_metadata_is_read_capped_and_control_char_safe() {
    let (_tmp, root) = repo();
    skill(&root, "gh");
    let long = "d".repeat(600);
    fs::write(
        root.join("kendex.toml"),
        format!(
            "[marketplace]\nname = \"Team \\u0007 Tools\"\ndescription = \"{long}\"\n\
             author = \"Ana\"\nlicense = \"MIT\"\nhomepage = \"https://example.com\"\n\
             tags = [\"ai\", \"tools\"]\n"
        ),
    )
    .unwrap();
    let summary = summary(&root);
    let name = summary.name;
    assert!(!name.contains('\u{7}'), "{name:?}");
    assert!(name.contains("\\u{7}"), "{name:?}");
    let description = summary.description.unwrap();
    assert_eq!(description.chars().count(), 500);
    assert_eq!(summary.author.as_deref(), Some("Ana"));
    assert_eq!(summary.license.as_deref(), Some("MIT"));
    assert_eq!(summary.homepage.as_deref(), Some("https://example.com"));
    assert_eq!(summary.tags, ["ai", "tools"]);
}

/// Without a `[marketplace]` table the summary still stands: named by the
/// repository, metadata absent rather than invented.
#[test]
fn a_repo_without_metadata_is_named_by_its_leaf() {
    let (_tmp, root) = repo();
    skill(&root, "gh");
    let summary = summary(&root);
    assert_eq!(summary.name, "repo");
    assert_eq!(summary.description, None);
    assert_eq!(summary.counts.packages, 1);
    assert_eq!(summary.packages[0].kind, "skill");
    assert_eq!(summary.packages[0].name, "gh");
    assert_eq!(summary.packages[0].description.as_deref(), Some("about gh"));
}

/// Bad metadata never takes the catalog down: the packages still list, and
/// the problem is a finding naming the file.
#[test]
#[allow(clippy::unwrap_used)]
fn unreadable_metadata_is_a_finding_not_a_dead_catalog() {
    let (_tmp, root) = repo();
    skill(&root, "gh");
    fs::write(root.join("kendex.toml"), "[marketplace]\nname = 3\n").unwrap();
    let summary = summary(&root);
    assert_eq!(summary.counts.packages, 1);
    assert!(
        summary.findings.iter().any(|finding| finding
            .problem
            .contains("`[marketplace]` could not be read")),
        "{:?}",
        summary.findings
    );
}
