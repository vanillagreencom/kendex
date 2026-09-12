//! Every command that opens an installed package's source answers a source
//! nothing has downloaded yet as `SourceReadRefused::SourcePending`, never
//! as words. The page branches on that kind to draw the same neutral line
//! its header draws for the timeline; a command flattening core's refusal
//! to a string would put the Files tab and the Overview back under the
//! critical text a real read failure draws while the header says not
//! downloaded yet. Flatten any one read here to `Failed` and its row goes
//! red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;

use kendex_app::packages::{file, files, readme};
use kendex_app::refusal::SourceReadRefused;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

/// A project declaring a skill from a repository nothing has fetched: the
/// declaration is there and the store holds no mirror for it.
#[allow(clippy::unwrap_used)]
fn pending_declaration() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("dev").join("app");
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = {}\n\n[sources.kit]\nrepo = \"acme/kit\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"kit\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
        ),
    )
    .unwrap();
    (
        tmp,
        Env::fake(&home, FakeOs::Linux),
        Scope::Project { root },
    )
}

#[test]
fn every_package_read_answers_an_undownloaded_source_as_its_own_kind() {
    let (_tmp, env, scope) = pending_declaration();
    type Read = fn(&Env, &Scope) -> Result<(), SourceReadRefused>;
    let rows: [(&str, Read); 3] = [
        ("files", |env, scope| {
            files(env, scope, ItemKind::Skill, "deploy").map(drop)
        }),
        ("file", |env, scope| {
            file(env, scope, ItemKind::Skill, "deploy", "SKILL.md").map(drop)
        }),
        ("readme", |env, scope| {
            readme(env, scope, ItemKind::Skill, "deploy").map(drop)
        }),
    ];
    for (name, read) in rows {
        let refused = read(&env, &scope).expect_err(name);
        assert!(
            matches!(refused, SourceReadRefused::SourcePending { ref source } if source == "kit"),
            "{name}: {refused:?}"
        );
    }
}
