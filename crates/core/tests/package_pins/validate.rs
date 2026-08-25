//! The manifest findings that keep a hold honest: an item's rev is a full
//! commit id from a repo source, or it is a finding naming the fix.

use kendex_core::manifest;

const REPO: &str = "owner/catalog";

#[test]
#[allow(clippy::unwrap_used)]
fn an_item_rev_that_is_not_a_commit_id_is_a_finding() {
    let table: toml::Table = format!(
        "schema = 6\n[sources.cat]\nrepo = \"{REPO}\"\n[skills.gh]\nsource = \"cat\"\nrev = \"v1\"\n"
    )
    .parse()
    .unwrap();
    let findings = manifest::validate(&table);
    assert!(
        findings
            .iter()
            .any(|f| f.problem.contains("full commit id")),
        "{findings:?}"
    );

    let table: toml::Table = format!(
        "schema = 6\n[sources.cat]\nrepo = \"{REPO}\"\n[skills.gh]\nsource = \"cat\"\nrev = \"{}\"\n",
        "a".repeat(40)
    )
    .parse()
    .unwrap();
    assert_eq!(manifest::validate(&table), vec![]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_rev_on_a_path_source_is_a_finding() {
    let table: toml::Table = format!(
        "schema = 6\n[sources.here]\npath = \"catalog\"\n[skills.gh]\nsource = \"here\"\nrev = \"{}\"\n",
        "a".repeat(40)
    )
    .parse()
    .unwrap();
    let findings = manifest::validate(&table);
    assert!(
        findings
            .iter()
            .any(|f| f.problem.contains("only an item from a repo source")),
        "{findings:?}"
    );
}
