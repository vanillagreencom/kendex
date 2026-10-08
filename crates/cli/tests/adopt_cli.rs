//! Adoption's CLI target selection: scope defaults, explicit narrowing and
//! refusals before any content moves. The persisted installations prove
//! which tools received the adopted item even when they share one tree.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use kendex_core::env::Env;
use kendex_core::lock;
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind};

use crate::test_util;
use test_util::rooted;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, project: &Path, kind: ItemKind, flags: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(["adopt", kind.name(), "deploy"])
        .args(flags)
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
#[allow(
    clippy::too_many_lines,
    reason = "one target-selection table shares assertions across item kinds and scopes"
)]
fn adoption_targets_scope_defaults_or_the_explicit_selection() {
    let enabled = "[\"claude\", \"codex\", \"opencode\"]";
    for (case, kind, global, enabled, flags, original, expected) in [
        (
            "three harness default",
            ItemKind::Skill,
            false,
            enabled,
            vec![],
            ".claude/skills/deploy/SKILL.md",
            vec![HarnessId::Claude, HarnessId::Codex, HarnessId::Opencode],
        ),
        (
            "default without Claude",
            ItemKind::Skill,
            false,
            "[\"codex\", \"opencode\"]",
            vec![],
            ".agents/skills/deploy/SKILL.md",
            vec![HarnessId::Codex, HarnessId::Opencode],
        ),
        (
            "Codex alone",
            ItemKind::Skill,
            false,
            enabled,
            vec!["--harness", "codex"],
            ".agents/skills/deploy/SKILL.md",
            vec![HarnessId::Codex],
        ),
        (
            "repeated Codex",
            ItemKind::Skill,
            false,
            enabled,
            vec!["--harness", "codex", "--harness", "codex"],
            ".agents/skills/deploy/SKILL.md",
            vec![HarnessId::Codex],
        ),
        (
            "no enabled harness",
            ItemKind::Skill,
            false,
            "[]",
            vec![],
            ".claude/skills/deploy/SKILL.md",
            vec![],
        ),
        (
            "unknown harness",
            ItemKind::Skill,
            false,
            enabled,
            vec!["--harness", "unknown"],
            ".agents/skills/deploy/SKILL.md",
            vec![],
        ),
        (
            "project agent skips unsupported Antigravity",
            ItemKind::Agent,
            false,
            "[\"claude\", \"antigravity\"]",
            vec![],
            ".claude/agents/deploy.md",
            vec![HarnessId::Claude],
        ),
        (
            "global skill skips unsupported Cursor",
            ItemKind::Skill,
            true,
            "[\"claude\", \"cursor\"]",
            vec!["--global"],
            ".claude/skills/deploy/SKILL.md",
            vec![HarnessId::Claude],
        ),
        (
            "project agent has no supported enabled harness",
            ItemKind::Agent,
            false,
            "[\"antigravity\"]",
            vec![],
            ".claude/agents/deploy.md",
            vec![],
        ),
        (
            "global skill has no supported enabled harness",
            ItemKind::Skill,
            true,
            "[\"cursor\"]",
            vec!["--global"],
            ".claude/skills/deploy/SKILL.md",
            vec![],
        ),
        (
            "explicit unsupported harness still refuses",
            ItemKind::Agent,
            false,
            "[\"claude\", \"antigravity\"]",
            vec!["--harness", "claude", "--harness", "antigravity"],
            ".claude/agents/deploy.md",
            vec![],
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("project");
        fs::create_dir_all(&project).unwrap();
        let env = Env::host_rooted(&home);
        let root = if global { &home } else { &project };
        let original = root.join(original);
        fs::create_dir_all(original.parent().unwrap()).unwrap();
        let content =
            "---\nname: deploy\ndescription: Deploy the project\n---\nKeep these authored bytes.\n";
        fs::write(&original, content).unwrap();
        let setup = format!("schema = 6\n[install]\nharnesses = {enabled}\n");
        let manifest_path = if global {
            env.global_manifest_file()
        } else {
            project.join("kendex.toml")
        };
        let lock_path = if global {
            env.global_lock_file()
        } else {
            project.join(".kendex-lock.json")
        };
        fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
        fs::write(&manifest_path, &setup).unwrap();

        let output = kendex(&home, &project, kind, &flags);
        assert_eq!(output.status.success(), !expected.is_empty(), "{case}");
        if expected.is_empty() {
            assert_eq!(fs::read_to_string(&manifest_path).unwrap(), setup, "{case}");
            assert_eq!(fs::read_to_string(&original).unwrap(), content, "{case}");
            assert!(!original.is_symlink(), "{case}");
            assert!(!original.parent().unwrap().is_symlink(), "{case}");
            assert!(!lock_path.exists(), "{case}");
            continue;
        }

        let recorded = lock::load(&lock_path).unwrap();
        let mut actual: Vec<_> = recorded
            .entries
            .values()
            .filter(|entry| entry.kind == kind && entry.name == "deploy")
            .map(|entry| entry.harness)
            .collect();
        actual.sort();
        let mut expected = expected;
        expected.sort();
        assert_eq!(actual, expected, "{case}");
        let declared = manifest::load_current(&manifest_path).unwrap().unwrap();
        let in_place = kind == ItemKind::Skill && !global;
        assert_eq!(
            declared.declared(kind)["deploy"].source,
            if in_place { "in-place" } else { "local" },
            "{case}"
        );
        let source = if in_place {
            project.join(".agents/skills/deploy/SKILL.md")
        } else {
            let local = if global {
                env.global_local_source_dir()
            } else {
                project.join(".kendex-local")
            };
            local.join(if kind == ItemKind::Agent {
                "agents/deploy.md"
            } else {
                "skills/deploy/SKILL.md"
            })
        };
        assert_eq!(fs::read_to_string(source).unwrap(), content, "{case}");
        if !in_place {
            assert!(
                fs::read_to_string(&original)
                    .unwrap()
                    .contains("Keep these authored bytes."),
                "{case}"
            );
            if kind == ItemKind::Agent {
                assert!(!original.is_symlink(), "{case}");
            }
            continue;
        }
        let claude = project.join(".claude/skills/deploy");
        if expected.contains(&HarnessId::Claude) {
            assert!(claude.is_symlink(), "{case}");
            assert_eq!(
                kendex_core::paths::canonical(&claude).unwrap(),
                project.join(".agents/skills/deploy"),
                "{case}"
            );
        } else {
            assert!(!claude.exists(), "{case}");
        }
    }
}
