//! An adopted copy held to the template the pass rendered: its finding
//! names both hashes, the revision that template was read at where its
//! source has one, and the package whose adoption step copies it again.

use std::fs;
use std::path::{Path, PathBuf};

use super::*;
use crate::engine::desired::Desired;
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind};

const WORKFLOW: &str = ".github/workflows/adopted.yml";
const TEMPLATE: &str = ".agents/skills/deploy/templates/adopted.yml";
const SHIPPED: &[u8] = b"name: adopted\non: workflow_dispatch\n";
const SHIPPED_HASH: &str =
    "sha256:7a4e2c6f6f787974ebadf7e284a928d8df73dced947024d314045b8887dd1898";
const EDITED: &[u8] = b"name: edited\n";
const EDITED_HASH: &str = "sha256:f03937d179114adbdaed15dca11c81bcc8656312d412600d17fe54c23968c06c";
const COMMIT: &str = "232f1984db70917fc9864f04e27dc020db12a051";

/// The `deploy` skill rendered from a remote at `commit`, or from a path
/// source where `commit` is `None`, shipping `SHIPPED` as its template.
fn deploy(root: &Path, commit: Option<&str>) -> Desired {
    let artifact = Artifact::Tree {
        canonical: root.join(".agents/skills/deploy"),
        files: vec![(PathBuf::from("templates/adopted.yml"), SHIPPED.to_vec())],
        link: None,
        in_place: false,
    };
    Desired {
        key: "skill:deploy:codex".to_owned(),
        kind: ItemKind::Skill,
        name: "deploy".to_owned(),
        harness: HarnessId::Codex,
        enabled: true,
        method: Method::Copy,
        source_name: "cat".to_owned(),
        provenance: "cat".to_owned(),
        source_commit: commit.map(str::to_owned),
        recorded_fork: false,
        hash: String::new(),
        rendered_hash: artifact.rendered_hash(),
        source: None,
        upstream_skills: None,
        emitted: None,
        reasons: BTreeSet::new(),
        artifact,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_stale_copy_names_its_revision_both_hashes_and_the_adoption_step() {
    // The mutation control drops the byte comparison and keeps the
    // diagnostic: every copy then reads as current and the stale rows fail.
    let stale = |at: &str| {
        vec![format!(
            "differs from template {TEMPLATE}{at}: copy {EDITED_HASH}, template {SHIPPED_HASH}; \
             the adoption step that skill deploy ships copies the template again"
        )]
    };
    for (case, copy, commit, expected) in [
        ("current", Some(SHIPPED), Some(COMMIT), vec![]),
        (
            "stale from a remote",
            Some(EDITED),
            Some(COMMIT),
            stale(&format!(" at {COMMIT}")),
        ),
        ("stale from a path", Some(EDITED), None, stale("")),
        (
            "missing",
            None,
            Some(COMMIT),
            vec!["adopted workflow is missing".to_owned()],
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap();
        fs::write(
            root.join(INVENTORY),
            format!(
                "[{{\"path\":\"{WORKFLOW}\",\"template\":\"{TEMPLATE}\",\"templateHash\":\"{EDITED_HASH}\"}}]"
            ),
        )
        .unwrap();
        if let Some(copy) = copy {
            fs::create_dir_all(root.join(".github/workflows")).unwrap();
            fs::write(root.join(WORKFLOW), copy).unwrap();
        }
        let state = DesiredState {
            items: vec![deploy(&root, commit)],
            ..DesiredState::default()
        };
        let planned = BTreeSet::new();
        let unrendered = super::super::Unrendered {
            planned: &planned,
            leaving: Vec::new(),
            kept: Vec::new(),
            recorded: Default::default(),
        };
        let adopted = collect(&root, &state, &unrendered, &mut Vec::new())
            .unwrap()
            .unwrap();
        let workflow = &adopted.workflows[&root.join(WORKFLOW)];
        assert_eq!(workflow.problems, expected, "{case}");
        assert_eq!(workflow.record.template_hash, SHIPPED_HASH, "{case}");
    }
}
