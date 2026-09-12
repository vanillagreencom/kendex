//! Every command that opens a subscription's content answers a source
//! nothing has downloaded yet as `SourceReadRefused::SourcePending`, never
//! as words. The pages branch on that kind to draw a neutral line naming
//! Check for updates; a command flattening core's refusal to a string would
//! put a never-downloaded marketplace back under the critical text a real
//! read failure draws. Flatten any one read here to `Failed` and its row
//! goes red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;

use kendex_app::marketplaces::{bundle, package_file, package_view};
use kendex_app::refusal::SourceReadRefused;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::Catalog;

/// A project subscribed to a repository nothing has fetched: the
/// declaration is there and the store holds no mirror for it.
#[allow(clippy::unwrap_used)]
fn pending_subscription() -> (tempfile::TempDir, Env, Catalog) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("dev").join("app");
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = {}\n\n[sources.kit]\nrepo = \"acme/kit\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
        ),
    )
    .unwrap();
    let catalog = Catalog::Subscription {
        scope: Scope::Project { root },
        source: "kit".to_owned(),
    };
    (tmp, Env::fake(&home, FakeOs::Linux), catalog)
}

#[test]
fn every_content_read_answers_an_undownloaded_source_as_its_own_kind() {
    let (_tmp, env, catalog) = pending_subscription();
    type Read = fn(&Env, &Catalog) -> Result<(), SourceReadRefused>;
    let rows: [(&str, Read); 3] = [
        ("bundle", |env, catalog| {
            bundle(env, catalog, "starter", None).map(drop)
        }),
        ("package_view", |env, catalog| {
            package_view(env, catalog, ItemKind::Skill, "deploy", None).map(drop)
        }),
        ("package_file", |env, catalog| {
            package_file(env, catalog, ItemKind::Skill, "deploy", "SKILL.md").map(drop)
        }),
    ];
    for (name, read) in rows {
        let refused = read(&env, &catalog).expect_err(name);
        assert!(
            matches!(refused, SourceReadRefused::SourcePending { ref source } if source == "kit"),
            "{name}: {refused:?}"
        );
    }
}
