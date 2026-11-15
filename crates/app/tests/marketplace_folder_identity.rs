//! Folder cards retain directory suffixes while spelling aliases share an identity.

use std::fs;

use kendex_app::marketplaces::rows;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

use crate::test_util::rooted;

#[test]
#[allow(clippy::unwrap_used)]
fn folder_suffixes_produce_distinct_marketplace_rows() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        "schema = 8\n[sources.plain]\npath = 'catalog'\n[sources.suffixed]\npath = 'catalog.git'\n[sources.alias]\npath = './catalog.git/'\n",
    )
    .unwrap();
    let listed = rows(&env, &[Scope::Global]).unwrap();
    for (alias, folder) in [
        ("plain", "catalog"),
        ("suffixed", "catalog.git"),
        ("alias", "catalog.git"),
    ] {
        let row = listed.iter().find(|row| row.name == alias).unwrap();
        let expected = kendex_core::paths::slashed(&home.join(folder));
        assert_eq!(row.repo_identity.as_deref(), Some(expected.as_str()));
        assert_eq!(row.resolved_path.as_deref(), Some(expected.as_str()));
    }
    let identities: std::collections::BTreeSet<_> =
        listed.iter().map(|row| &row.repo_identity).collect();
    assert_eq!(identities.len(), 2);
}
