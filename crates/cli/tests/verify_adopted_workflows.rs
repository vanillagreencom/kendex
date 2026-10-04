//! Adoption copies use declared source bytes, even if the installed template
//! and its copy were both edited. Refresh only changes the inventory.
#![cfg(unix)]

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::attest::{Document, Row, State};
use kendex_core::commit_offer::{self, Before};
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

use super::verify_records::{commit, git, kendex, repository, said, write};
use crate::test_util::rooted;

const WORKFLOW: &str = ".github/workflows/adopted.yml";
const TEMPLATE: &str = ".agents/skills/deploy/templates/adopted.yml";
const VERIFY: &[&str] = &["verify", "--scope", "project", "--json"];
const BYTES: &str = "name: adopted\non: workflow_dispatch\n";
const HASH: &str = "sha256:7a4e2c6f6f787974ebadf7e284a928d8df73dced947024d314045b8887dd1898";

#[test]
#[allow(clippy::unwrap_used)]
fn adopted_workflow_equality_uses_declared_templates_without_writing_yaml() {
    // The production mutation control disables the byte comparison while
    // keeping its diagnostic; the edited-copy row must then fail this test.
    for (case, kind, expected) in [
        ("equal", "adopted-workflow", State::Ok),
        ("copy-edited", "adopted-workflow", State::Failed),
        ("copy-missing", "adopted-workflow", State::Failed),
        (
            "template-and-copy-edited",
            "adopted-workflow",
            State::Failed,
        ),
        ("template-undeclared", "adopted-workflow", State::Failed),
        ("invalid-inventory", "inventory", State::Failed),
    ] {
        let world = super::verify_records::adoption_world(BYTES);
        let project = &world.project;
        let env = Env::fake(&world.home, FakeOs::Linux);
        let scope = Scope::Project {
            root: project.clone(),
        };
        write(&project.join(WORKFLOW), BYTES);
        let inventory = project.join(".kendex-generated.json");
        let mut entries: Vec<serde_json::Value> =
            serde_json::from_str(&fs::read_to_string(&inventory).unwrap()).unwrap();
        entries.push(serde_json::json!({"path":WORKFLOW,"template":TEMPLATE,"templateHash":HASH}));
        fs::write(&inventory, serde_json::to_string(&entries).unwrap()).unwrap();
        let plan = plan_apply(&env, &scope, &PlanOptions::default()).unwrap();
        apply::execute(&env, &plan.plan).unwrap();
        let recorded: Vec<serde_json::Value> =
            serde_json::from_slice(&fs::read(&inventory).unwrap()).unwrap();
        assert_eq!(
            recorded.iter().find(|entry| entry.is_object()).unwrap()["templateHash"],
            HASH
        );
        commit(project, "adoption");
        match case {
            "equal" => {}
            "copy-edited" => write(&project.join(WORKFLOW), "name: edited\n"),
            "copy-missing" => fs::remove_file(project.join(WORKFLOW)).unwrap(),
            "template-and-copy-edited" => {
                write(&project.join(WORKFLOW), "name: edited\n");
                write(&project.join(TEMPLATE), "name: edited\n");
            }
            "template-undeclared" => {
                let text = fs::read_to_string(&inventory).unwrap();
                assert_eq!(text.matches(TEMPLATE).count(), 2);
                fs::write(
                    &inventory,
                    text.replace(
                        &format!("\"template\":\"{TEMPLATE}\""),
                        "\"template\":\"unmanaged/templates/adopted.yml\"",
                    ),
                )
                .unwrap();
            }
            "invalid-inventory" => fs::write(&inventory, "1\n").unwrap(),
            _ => unreachable!(),
        }
        let before = fs::read(project.join(WORKFLOW)).ok();
        let plan = plan_apply(&env, &scope, &PlanOptions::default()).unwrap();
        let owned = plan.generated.owned(project);
        assert!(
            !owned.contains(&project.join(WORKFLOW)),
            "{case}: adoption is not restore ownership"
        );
        apply::execute(&env, &plan.plan).unwrap();
        if case == "invalid-inventory" {
            assert_eq!(fs::read_to_string(&inventory).unwrap(), "1\n");
        }
        assert!(
            commit_offer::scan(&scope, &plan.generated, &Before::Untaken)
                .unwrap()
                .is_none_or(|scan| scan.owned.iter().all(|owned| owned.path != WORKFLOW)),
            "{case}: adoption is not commit or deletion ownership"
        );
        assert_eq!(
            fs::read(project.join(WORKFLOW)).ok(),
            before,
            "{case}: refresh must not sync YAML"
        );
        let output = kendex(&world.home, project, VERIFY);
        let document: Document = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|error| panic!("{case}: {error}: {}", said(&output)));
        let row = document.rows.iter().find(|row| row.kind == kind).unwrap();
        assert_eq!(row.state, expected, "{case}: {}", said(&output));
        assert_eq!(row.positions.len(), 1);
        assert_eq!(
            row.positions[0].path,
            if kind == "inventory" {
                ".kendex-generated.json"
            } else {
                WORKFLOW
            }
        );
        assert_eq!(
            output.status.success(),
            expected == State::Ok,
            "{case}: {}",
            said(&output)
        );
    }
}

/// The copy's row under each reading, with the run's closing line.
#[allow(clippy::unwrap_used)]
fn adopted_row(home: &Path, project: &Path, at_record: bool) -> (Row, String, bool) {
    let mut args = VERIFY.to_vec();
    if at_record {
        args.push("--at-record");
    }
    let output = kendex(home, project, &args);
    let document: Document = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("{error}: {}", said(&output)));
    let row = document
        .rows
        .into_iter()
        .find(|row| row.kind == "adopted-workflow")
        .unwrap();
    (row, said(&output), output.status.success())
}

/// A declared source revision bumped past the one the copy was adopted
/// from: the plain scope weighs the copy against the template at the
/// revision declared now, before and after the refresh that renders it,
/// and its closing line counts the failed copy beside the lock entries.
/// `--at-record` weighs it at the commit the record names, which the
/// unrefreshed record still holds at the adopted revision.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_left_behind_by_a_revision_bump_fails_the_plain_project_scope() {
    const NEXT: &str = "name: adopted\non: push\n";
    const NEXT_HASH: &str =
        "sha256:93da44c51bfe3a68dafdba23ee225ea88b2ad0ed4899e92715a90a9b1b26343a";
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("cat");
    let project = home.join("dev/app");
    write(&catalog.join("kendex.toml"), "[catalog]\n");
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Deploy\n---\nDeploy.\n",
    );
    write(&catalog.join("skills/deploy/templates/adopted.yml"), BYTES);
    repository(&catalog);
    commit(&catalog, "adopted revision");
    let adopted = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
    write(&catalog.join("skills/deploy/templates/adopted.yml"), NEXT);
    commit(&catalog, "next revision");
    let next = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
    let manifest = |rev: &str| {
        format!(
            "schema = 6\n[sources.cat]\nrepo = \"file://{}\"\nrev = \"{rev}\"\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        )
    };
    write(&project.join("kendex.toml"), &manifest(&adopted));
    repository(&project);
    commit(&project, "before kendex");
    for args in [&["source", "refresh"][..], &["apply", "-y", "--leave"]] {
        let output = kendex(&home, &project, args);
        assert!(output.status.success(), "{}", said(&output));
    }
    write(&project.join(WORKFLOW), BYTES);
    let inventory = project.join(".kendex-generated.json");
    let mut entries: Vec<serde_json::Value> =
        serde_json::from_str(&fs::read_to_string(&inventory).unwrap()).unwrap();
    entries.push(serde_json::json!({"path":WORKFLOW,"template":TEMPLATE,"templateHash":HASH}));
    fs::write(&inventory, serde_json::to_string(&entries).unwrap()).unwrap();
    let output = kendex(&home, &project, &["apply", "-y", "--leave"]);
    assert!(output.status.success(), "{}", said(&output));
    commit(&project, "adopted");
    let (row, printed, passed) = adopted_row(&home, &project, false);
    assert_eq!(row.state, State::Ok, "{printed}");
    assert!(passed, "{printed}");

    write(&project.join("kendex.toml"), &manifest(&next));
    let stale = format!(
        "differs from template {TEMPLATE} at {next}: copy {HASH}, template {NEXT_HASH}; \
         the adoption step that skill deploy ships copies the template again"
    );
    let (row, printed, _) = adopted_row(&home, &project, false);
    assert_eq!(row.state, State::Failed, "{printed}");
    assert_eq!(row.detail.as_deref(), Some(stale.as_str()), "{printed}");
    let (row, printed, _) = adopted_row(&home, &project, true);
    assert_eq!(
        row.state,
        State::Ok,
        "the record still names {adopted}: {printed}"
    );

    let output = kendex(
        &home,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(output.status.success(), "{}", said(&output));
    for at_record in [false, true] {
        let (row, printed, passed) = adopted_row(&home, &project, at_record);
        assert_eq!(row.state, State::Failed, "at record {at_record}: {printed}");
        assert_eq!(row.detail.as_deref(), Some(stale.as_str()), "{printed}");
        assert!(!passed, "{printed}");
        assert!(
            printed.contains("1 checked, 1 OK, 0 failed; 1 other row failed"),
            "the closing line counts the failed copy: {printed}"
        );
    }
}
