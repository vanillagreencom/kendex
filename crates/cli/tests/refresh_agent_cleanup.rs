//! Consumer refresh retires recorded agents removed by a manifest rename.

use std::fs;
use std::process::Command;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load, lock_path};
use kendex_core::model::{ItemKind, Scope};

use crate::test_util::{agent_manifest, fixture_env, rooted};

#[test]
#[allow(clippy::unwrap_used)]
fn a_project_refresh_retires_dropped_agents_and_verify_passes() {
    for (case, edited, disabled, replacement) in [
        ("rename", false, false, true),
        ("edited", true, false, true),
        ("disabled", false, true, true),
        ("last-agent", false, false, false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::host_rooted(&home);
        let project = home.join("consumer");
        let sibling = home.join("sibling");
        let catalog = home.join("catalog");
        fs::create_dir_all(catalog.join("agents")).unwrap();
        for name in ["old", "new"] {
            let text = format!("---\nname: {name}\ndescription: Review code\n---\nReview code.\n");
            fs::write(catalog.join(format!("agents/{name}.md")), text).unwrap();
        }
        let manifest = |agent| agent_manifest(&catalog, agent);
        let [scope, sibling_scope] =
            [project.clone(), sibling.clone()].map(|root| Scope::Project { root });
        for (root, target) in [(&project, &scope), (&sibling, &sibling_scope)] {
            fs::create_dir_all(root).unwrap();
            fs::write(root.join("kendex.toml"), manifest(Some("old"))).unwrap();
            let installed = plan_apply(&env, target, &PlanOptions::current()).unwrap();
            apply::execute(&env, &installed.plan).unwrap();
        }
        let old = project.join(".claude/agents/old.md");
        let parked = project.join(".claude/agents/old.md.disabled");
        assert!(old.is_file(), "{case}: fixture installed no agent");
        // Another scope and an unrecorded file must survive this scope's sweep.
        let unmanaged = project.join(".claude/agents/unmanaged.md");
        fs::write(&unmanaged, "My own agent.\n").unwrap();
        let preserved = [
            lock_path(&env, &sibling_scope),
            sibling.join(".claude/agents/old.md"),
            unmanaged,
        ];
        let preserved_bytes = preserved.each_ref().map(|path| fs::read(path).unwrap());
        let changed_manifest = manifest(replacement.then_some("new"));
        fs::write(project.join("kendex.toml"), changed_manifest).unwrap();
        if edited {
            fs::write(&old, "My hand edit.\n").unwrap();
        }
        if disabled {
            fs::rename(&old, &parked).unwrap();
        }
        let recorded = || {
            let entries = load(&lock_path(&env, &scope)).unwrap().entries;
            entries
                .values()
                .any(|entry| entry.kind == ItemKind::Agent && entry.name == "old")
        };
        let removed = || !old.exists() && !parked.exists() && !recorded();
        let kendex = |args: &[&str]| {
            Command::new(env!("CARGO_BIN_EXE_kendex"))
                .args(args)
                .current_dir(&project)
                .env_clear()
                .envs(fixture_env(&home))
                .env("KENDEX_BACKGROUND_REFRESH", "off")
                .env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .output()
                .unwrap()
        };
        let verify = ["verify", "--scope", "project"];
        // Must-fail control: without automatic orphan cleanup, the apply
        // keeps the dropped record and render. The same cleanup assertion
        // used after the consumer command is red, and live verify fails.
        // Disabling removal::verdicts' dropped_agent condition also turns
        // the consumer refresh assertions red with the orphan still installed.
        let without_cleanup = plan_apply(&env, &scope, &PlanOptions::current()).unwrap();
        apply::execute(&env, &without_cleanup.plan).unwrap();
        let control = (old.is_file() || parked.is_file()) && recorded() && !removed();
        let verify_failed = !kendex(&verify).status.success();
        assert!(control && verify_failed, "{case}: control failed");
        if case == "rename" {
            // Removing `new` must leave the unrelated requested orphan `old`.
            // Removing dropped_agent's unfiltered guard makes this assertion red.
            let named = kendex(&["remove", "new", "--sweep", "--scope", "project", "--leave"]);
            assert!(named.status.success(), "{case}: {named:?}");
            assert!(!project.join(".claude/agents/new.md").exists());
            assert!(old.is_file() && recorded(), "named sweep took old");
            fs::write(project.join("kendex.toml"), manifest(Some("new"))).unwrap();
        }
        let mut refresh = vec!["refresh", "--scope", "project", "--yes", "--leave"];
        let mut completed = kendex(&refresh);
        assert!(completed.status.success(), "{case}: {completed:?}");
        if edited {
            assert!(!removed(), "edited orphan must wait for discard-edits");
            assert_eq!(fs::read_to_string(&old).unwrap(), "My hand edit.\n");
            assert!(!kendex(&verify).status.success());
            refresh.push("--discard-edits");
            completed = kendex(&refresh);
            assert!(completed.status.success(), "{case}: {completed:?}");
        }
        let report = String::from_utf8_lossy(&completed.stderr);
        let reported = report.contains("remove agent old for Claude Code");
        assert!(reported, "{case}: removal was not reported: {completed:?}");
        assert!(removed(), "{case}: refresh left the dropped agent behind");
        assert!(kendex(&verify).status.success(), "{case}: verify failed");
        let after = preserved.each_ref().map(|path| fs::read(path).unwrap());
        assert_eq!(after, preserved_bytes, "{case}: changed unowned files");
    }
}
