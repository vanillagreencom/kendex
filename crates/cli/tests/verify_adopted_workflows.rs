//! Adoption copies use declared source bytes, even if the installed template
//! and its copy were both edited. Refresh only changes the inventory.
#![cfg(unix)]

use std::fs;

use kendex_core::apply;
use kendex_core::attest::{Document, State};
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

use super::verify_records::{commit, kendex, said, write};

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
            kendex_core::commit_offer::scan(&scope, &plan.generated)
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
