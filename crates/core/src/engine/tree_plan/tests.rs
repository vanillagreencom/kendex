use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::env::{Env, FakeOs};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::process::Hardened;

use super::super::desired::{Artifact, Desired};
use super::super::item_plan::Planned;
use super::super::written::Written;
use super::plan_tree;

fn git(root: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(root)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// An installed skill render holding a file Git ignores, as a run of the
/// skill's Python scripts leaves a `__pycache__`, is the render: the plan
/// writes nothing over it. No commit carries the ignored file, so a plan
/// that wrote here would name a render no clone differs on.
#[test]
fn an_ignored_file_in_an_installed_render_plans_no_write() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp).join("project");
    fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q"]);
    fs::write(root.join(".gitignore"), "__pycache__/\n").unwrap();
    let canonical = root.join(".agents/skills/demo");
    let files = vec![
        (
            PathBuf::from("SKILL.md"),
            b"---\nname: demo\n---\nBody.\n".to_vec(),
        ),
        (PathBuf::from("scripts/run.py"), b"print('demo')\n".to_vec()),
    ];
    for (relative, bytes) in &files {
        let path = canonical.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    let cache = canonical.join("scripts/__pycache__");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("run.cpython-312.pyc"), b"\0compiled").unwrap();
    let artifact = Artifact::Tree {
        canonical: canonical.clone(),
        files,
        link: None,
        in_place: false,
    };
    let item = Desired {
        key: "skill:demo:claude".to_owned(),
        kind: ItemKind::Skill,
        name: "demo".to_owned(),
        harness: HarnessId::Claude,
        enabled: true,
        method: crate::manifest::Method::Copy,
        source_name: "source".to_owned(),
        provenance: "source".to_owned(),
        source_commit: None,
        recorded_fork: false,
        hash: String::new(),
        rendered_hash: artifact.rendered_hash(),
        source: None,
        upstream_skills: None,
        emitted: None,
        reasons: BTreeSet::new(),
        artifact,
    };
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project { root: root.clone() };
    let owned = BTreeSet::from([canonical]);
    let mut written = Written::default();
    let mut ops = Vec::new();
    let planned = plan_tree(&env, &scope, &item, false, &owned, &mut written, &mut ops).unwrap();
    assert_eq!(planned, Planned::Clean);
    assert!(ops.is_empty(), "{ops:?}");
}
