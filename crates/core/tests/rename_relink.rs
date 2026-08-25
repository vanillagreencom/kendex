//! Links the pre-rename app wrote point into its old data folder; they
//! are kendex's own stale links, repointed by the next plan rather than
//! reported as a stranger's.

#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    Fixture {
        env,
        home,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn installed_global_skill(f: &Fixture) -> (PathBuf, PathBuf) {
    let catalog = f.home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    let config = f.home.join(".config/kendex");
    fs::create_dir_all(&config).unwrap();
    fs::write(
        config.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    let link = f.home.join(".claude/skills/gh");
    let canonical = f.home.join(".local/share/kendex/rendered/skills/gh");
    assert_eq!(fs::read_link(&link).unwrap(), canonical);
    (link, canonical)
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_link_at_the_old_rendered_path_is_relinked_not_conflicted() {
    let f = fixture();
    let (link, canonical) = installed_global_skill(&f);
    // A pre-move install recorded the target under the old app dir; the
    // dir move carries the tree but cannot rewrite this link.
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(
        f.home.join(".local/share/vstack2/rendered/skills/gh"),
        &link,
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    assert!(
        !report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict),
        "{:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert_eq!(fs::read_link(&link).unwrap(), canonical);
    assert_eq!(
        fs::read_to_string(link.join("SKILL.md")).unwrap(),
        "---\nname: gh\n---\nBody.\n"
    );

    // Reconnected once: the next audit is clean.
    let after = audit(&f.env, &Scope::Global).unwrap();
    assert!(after.plan.ops.is_empty(), "{:?}", after.plan.ops);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_link_pointing_somewhere_foreign_still_conflicts() {
    let f = fixture();
    let (link, _) = installed_global_skill(&f);
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(f.home.join("somewhere-else/gh"), &link).unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    let conflict = report
        .drift
        .iter()
        .find(|row| row.state == DriftState::Conflict)
        .unwrap();
    assert!(conflict.detail.contains("does not own"), "{conflict:?}");
    // The old spelling of a different position is just as foreign: only
    // the legacy twin of this link's own tree is ours to replace.
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(
        f.home.join(".local/share/vstack2/rendered/skills/other"),
        &link,
    )
    .unwrap();
    let report = audit(&f.env, &Scope::Global).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict),
        "{:?}",
        report.drift
    );
}
