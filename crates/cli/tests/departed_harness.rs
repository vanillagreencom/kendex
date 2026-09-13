//! Refresh removes a declared skill only from harnesses its declaration drops.

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::process::Command;

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_removes_only_the_departed_harness_and_verify_passes() {
    for drop_opencode in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("project");
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::create_dir_all(project.join("catalog/skills/ship")).unwrap();
        fs::write(
            project.join("catalog/skills/ship/SKILL.md"),
            "---\nname: ship\ndescription: ship the branch\n---\nShip the branch.\n",
        )
        .unwrap();
        let declare = |harnesses: &str| {
            fs::write(project.join("kendex.toml"), format!(
                "schema = 6\n[sources.cat]\npath = \"catalog\"\n[install]\nmethod = \"copy\"\nharnesses = [{harnesses}]\n[skills.ship]\nsource = \"cat\"\n"
            )).unwrap();
        };
        let run = |args: &[&str]| {
            let output = Command::new(env!("CARGO_BIN_EXE_kendex"))
                .args(args)
                .current_dir(&project)
                .env_clear()
                .envs(test_util::fixture_env(&home))
                .env("KENDEX_BACKGROUND_REFRESH", "off")
                .env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(0), "{args:?}: {output:?}");
        };
        declare("\"claude\", \"opencode\"");
        run(&["refresh", "--scope", "project", "--yes", "--leave"]);
        let render = project.join(".opencode/skills/ship/SKILL.md");
        assert!(render.is_file());
        declare(if drop_opencode {
            "\"claude\""
        } else {
            "\"claude\", \"opencode\""
        });
        run(&["refresh", "--scope", "project", "--yes", "--leave"]);
        assert_eq!(render.exists(), !drop_opencode);
        let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
        assert_eq!(
            lock.entries.contains_key("skill:ship:opencode"),
            !drop_opencode
        );
        assert!(lock.entries.contains_key("skill:ship:claude"));
        assert!(project.join(".claude/skills/ship/SKILL.md").is_file());
        run(&["verify", "--scope", "project"]);
    }
}
