//! Keeping the files of an item pinned to a commit. The declaration moves
//! to the local source, which has no revisions — so the pin has to go with
//! it, or the manifest the capture just wrote cannot be planned at all.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;
use kendex_core::{apply, engine, manifest};

const REPO: &str = "acme/catalog";

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path) -> String {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@example.com",
            "-c",
            "user.name=T",
            "commit",
            "--quiet",
            "-m",
            "one",
        ],
    );
    let head = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&head.stdout).trim().to_owned()
}

#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_pinned_item_leaves_the_scope_plannable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let upstream = home.join("git").join(REPO);
    fs::create_dir_all(upstream.join("skills/deploy")).unwrap();
    fs::write(
        upstream.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    let pinned = commit(&upstream);

    let project: PathBuf = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let env = Env::fake(&home, FakeOs::Linux).with_var(
        "KENDEX_GIT_BASE",
        &format!("file://{}", home.join("git").display()),
    );
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::write(
        manifest::manifest_path(&env, &scope),
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\nrev = \"{pinned}\"\n"
        ),
    )
    .unwrap();
    // Files somebody else left where the pinned item installs.
    let here = project.join(".claude/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(
        here.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nBy hand.\n",
    )
    .unwrap();

    let plan = engine::adopt::adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "deploy",
        &[HarnessId::Claude],
    )
    .unwrap();
    apply::execute(&env, &plan).unwrap();

    let written = fs::read_to_string(manifest::manifest_path(&env, &scope)).unwrap();
    assert!(
        !written.contains("rev ="),
        "the pin was carried onto a source that has no revisions:\n{written}"
    );
    let after = engine::audit(&env, &scope);
    assert!(
        after.is_ok(),
        "the scope cannot be planned after keeping the files: {:?}",
        after.err()
    );
}
