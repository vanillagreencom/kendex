//! Adoption's CLI target selection: scope defaults, explicit narrowing and
//! refusals before any content moves. The persisted installations prove
//! which tools received the adopted skill even when they share one tree.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use kendex_core::lock;
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind};

use crate::test_util;
use test_util::rooted;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, project: &Path, harnesses: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(["adopt", "skill", "deploy"])
        .args(harnesses)
        .current_dir(project)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

#[test]
#[allow(clippy::unwrap_used)]
fn adoption_targets_scope_defaults_or_the_explicit_selection() {
    let enabled = "[\"claude\", \"codex\", \"opencode\"]";
    for (case, enabled, flags, original, expected) in [
        (
            "three harness default",
            enabled,
            vec![],
            ".claude/skills/deploy",
            vec![HarnessId::Claude, HarnessId::Codex, HarnessId::Opencode],
        ),
        (
            "default without Claude",
            "[\"codex\", \"opencode\"]",
            vec![],
            ".agents/skills/deploy",
            vec![HarnessId::Codex, HarnessId::Opencode],
        ),
        (
            "Codex alone",
            enabled,
            vec!["--harness", "codex"],
            ".agents/skills/deploy",
            vec![HarnessId::Codex],
        ),
        (
            "repeated Codex",
            enabled,
            vec!["--harness", "codex", "--harness", "codex"],
            ".agents/skills/deploy",
            vec![HarnessId::Codex],
        ),
        (
            "no enabled harness",
            "[]",
            vec![],
            ".claude/skills/deploy",
            vec![],
        ),
        (
            "unknown harness",
            enabled,
            vec!["--harness", "unknown"],
            ".agents/skills/deploy",
            vec![],
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("project");
        let original = project.join(original);
        fs::create_dir_all(&original).unwrap();
        let content =
            "---\nname: deploy\ndescription: Deploy the project\n---\nKeep these authored bytes.\n";
        fs::write(original.join("SKILL.md"), content).unwrap();
        let setup = format!("schema = 6\n[install]\nharnesses = {enabled}\n");
        let manifest_path = project.join("kendex.toml");
        fs::write(&manifest_path, &setup).unwrap();

        let output = kendex(&home, &project, &flags);
        assert_eq!(output.status.success(), !expected.is_empty(), "{case}");
        if expected.is_empty() {
            assert_eq!(fs::read_to_string(&manifest_path).unwrap(), setup, "{case}");
            assert_eq!(
                fs::read_to_string(original.join("SKILL.md")).unwrap(),
                content,
                "{case}"
            );
            assert!(!original.is_symlink(), "{case}");
            assert!(!project.join(".kendex-lock.json").exists(), "{case}");
            continue;
        }

        let recorded = lock::load(&project.join(".kendex-lock.json")).unwrap();
        let mut actual: Vec<_> = recorded
            .entries
            .values()
            .filter(|entry| entry.kind == ItemKind::Skill && entry.name == "deploy")
            .map(|entry| entry.harness)
            .collect();
        actual.sort();
        let mut expected = expected;
        expected.sort();
        assert_eq!(actual, expected, "{case}");
        let declared = manifest::load_current(&manifest_path).unwrap().unwrap();
        assert_eq!(declared.skills["deploy"].source, "in-place", "{case}");
        assert_eq!(
            fs::read_to_string(project.join(".agents/skills/deploy/SKILL.md")).unwrap(),
            content,
            "{case}"
        );
        let claude = project.join(".claude/skills/deploy");
        if expected.contains(&HarnessId::Claude) {
            assert!(claude.is_symlink(), "{case}");
            assert_eq!(
                fs::canonicalize(claude).unwrap(),
                project.join(".agents/skills/deploy"),
                "{case}"
            );
        } else {
            assert!(!claude.exists(), "{case}");
        }
    }
}
