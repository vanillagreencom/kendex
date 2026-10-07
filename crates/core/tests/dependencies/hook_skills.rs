//! Hook headers declare required skills separately from companion hooks.
//! Companion allowlists limit where the companion is needed, not its caller.

use super::hooks::{findings_on, messages};
use super::*;

const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# harnesses: [claude, codex, opencode, cursor, pi, gemini, copilot, antigravity]\n# requires: [recorder]\n# requires-skills: [commit-guards]\n# ---\nexit 0\n";
const RECORDER: &str = "#!/usr/bin/env bash\n# ---\n# name: recorder\n# event: PostToolUse\n# harnesses: [copilot]\n# requires: [judge]\n# ---\nexit 0\n";
const DECLARED: &str = "[hooks.judge]\nsource = \"cat\"\n";
const ALL: &str = "\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\", \"gemini\", \"copilot\", \"antigravity\"";

/// The catalog recorder runs on all four harnesses, while the judge needs
/// it only on Copilot. Local opt-outs still remove the judge on Copilot.
#[test]
#[allow(clippy::unwrap_used)]
fn requiring_hook_scopes_companions_without_scoping_required_skills() {
    use kendex_core::engine::DeclarationStatus::{Complete, Incomplete};
    const FOUR: &str = "\"claude\", \"codex\", \"pi\", \"copilot\"";
    for (tools, recorder, warning) in [
        (FOUR, Some("harnesses = [\"copilot\"]"), None),
        (
            FOUR,
            Some("enabled = false"),
            Some("missing required dependency: judge requires recorder, which is switched off"),
        ),
        (
            FOUR,
            Some("harnesses = [\"claude\"]"),
            Some(
                "missing required dependency: GitHub Copilot runs judge without recorder, which it requires",
            ),
        ),
        ("\"claude\"", Some("enabled = false"), None),
        ("\"codex\"", Some("enabled = false"), None),
        ("\"pi\"", Some("harnesses = [\"pi\"]"), None),
        (
            FOUR,
            None,
            Some("judge requires recorder, which the catalog 'cat' does not offer"),
        ),
    ] {
        let f = world();
        let judge = JUDGE.replace("# requires:", "# requires-on: [copilot]\n# requires:");
        fs::write(f.source.join("hooks/judge.sh"), judge).unwrap();
        fs::write(
            f.source.join("hooks/recorder.sh"),
            RECORDER.replace(
                "# harnesses: [copilot]",
                "# harnesses: [claude, codex, pi, copilot]",
            ),
        )
        .unwrap();
        let recorder_decl = match recorder {
            Some(settings) => {
                format!("\n[hooks.recorder]\nsource = \"cat\"\n{settings}\n")
            }
            None => {
                fs::remove_file(f.source.join("hooks/recorder.sh")).unwrap();
                String::new()
            }
        };
        declare(
            &f,
            tools,
            &format!("harnesses = [{tools}]\n{recorder_decl}"),
        );
        let report = audit(&f.env, &f.scope).unwrap();
        let missing = warning.is_some();
        assert_eq!(
            report.declaration_status,
            if missing { Incomplete } else { Complete },
            "{tools} {recorder:?}"
        );
        let findings = findings_on(&report, "judge");
        assert_eq!(
            findings
                .iter()
                .filter(|w| {
                    w.message.starts_with("missing required dependency:")
                        || w.message
                            == "judge requires recorder, which the catalog 'cat' does not offer"
                })
                .map(|w| w.message.as_str())
                .collect::<Vec<_>>(),
            warning.into_iter().collect::<Vec<_>>(),
            "{:?}",
            messages(&report)
        );
        apply::execute(&f.env, &report.plan).unwrap();
        let lock = lock_of(&f);
        for (tool, file) in TOOLS {
            let judge = format!("hook:judge:{}", tool.name());
            let guard = format!("skill:commit-guards:{}", tool.name());
            let record = format!("hook:recorder:{}", tool.name());
            let selected = tools.contains(&format!("\"{}\"", tool.name()));
            let stays = selected && !(missing && tool == HarnessId::Copilot);
            assert_eq!(
                lock.entries.contains_key(&judge),
                stays,
                "{tools} {recorder:?} {tool:?}"
            );
            assert_eq!(f.project.join(file).is_file(), stays);
            assert_eq!(lock.entries.contains_key(&guard), selected);
            if !missing && tools.contains("copilot") {
                assert_eq!(
                    lock.entries.contains_key(&record),
                    tool == HarnessId::Copilot
                );
            }
        }
    }
}

/// Script or advisory file written for each tool. The fixture's judge names
/// all eight tools.
const TOOLS: [(HarnessId, &str); 8] = [
    (HarnessId::Claude, ".claude/hooks/judge.sh"),
    (HarnessId::Codex, ".codex/hooks/judge.sh"),
    (
        HarnessId::Opencode,
        ".opencode/instructions/kendex-hook-judge.md",
    ),
    (HarnessId::Cursor, ".cursor/rules/safety-judge.mdc"),
    (HarnessId::Pi, ".pi/kendex/hooks/judge.sh"),
    (HarnessId::Gemini, ".gemini/hooks/judge.sh"),
    (HarnessId::Copilot, ".github/hooks/judge.sh"),
    (HarnessId::Antigravity, ".agents/hooks/judge.sh"),
];

#[allow(clippy::unwrap_used)]
fn declare(f: &Fixture, tools: &str, extra: &str) {
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{tools}]\nmethod = \"copy\"\n\n{DECLARED}\n{extra}",
            source_path(&f.source)
        ),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world() -> Fixture {
    let f = fixture("");
    fs::create_dir_all(f.source.join("hooks")).unwrap();
    fs::write(f.source.join("hooks/judge.sh"), JUDGE).unwrap();
    fs::write(f.source.join("hooks/recorder.sh"), RECORDER).unwrap();
    fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    skill(
        &f.source,
        "commit-guards",
        "dependencies:\n  required: [library-base]\n",
    );
    skill(&f.source, "library-base", "");
    let library = f.source.join("skills/commit-guards/scripts/lib");
    fs::create_dir_all(&library).unwrap();
    fs::write(library.join("command-position.sh"), "fixture-library\n").unwrap();
    declare(&f, ALL, "");
    f
}

/// The typed reasons distinguish a hook from a skill with the same name.
fn by(kind: ItemKind, name: &str, harness: HarnessId) -> Reason {
    Reason::RequiredBy {
        by: kendex_core::lock::InstallRef {
            source: "cat".to_owned(),
            kind,
            name: name.to_owned(),
            harness,
        },
    }
}

/// Declaring the judge alone installs its skill and that skill's own
/// dependency on every tool. Only Copilot receives the recorder, including
/// its reverse dependency on the judge. Claude retains the judge without it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_installs_required_skills_on_every_tool_and_its_companion_only_where_needed() {
    let f = world();
    // A hook sharing the skill's name must not satisfy the skill edge.
    fs::write(f.source.join("hooks/commit-guards.sh"), RECORDER).unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        report.declaration_status,
        kendex_core::engine::DeclarationStatus::Complete
    );
    assert!(
        findings_on(&report, "judge")
            .iter()
            .all(|w| !w.message.starts_with("missing required dependency:")),
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    let lock = lock_of(&f);
    for (tool, hook_file) in TOOLS {
        assert!(f.project.join(hook_file).is_file(), "{tool:?}: {hook_file}");
        let judge = &lock.entries[&format!("hook:judge:{}", tool.name())];
        assert!(judge.enabled);
        let mut reasons = BTreeSet::from([Reason::Requested]);
        if tool == HarnessId::Copilot {
            reasons.insert(by(ItemKind::Hook, "recorder", tool));
        }
        assert_eq!(judge.reasons, reasons, "{tool:?}");
        let guard = &lock.entries[&format!("skill:commit-guards:{}", tool.name())];
        assert_eq!(
            guard.reasons,
            BTreeSet::from([by(ItemKind::Hook, "judge", tool)])
        );
        let emitted = guard.emitted.as_ref().unwrap();
        assert!(!emitted.paths.is_empty());
        for path in &emitted.paths {
            assert_eq!(
                fs::read_to_string(f.project.join(path).join("scripts/lib/command-position.sh"))
                    .unwrap(),
                "fixture-library\n"
            );
        }
        assert_eq!(
            lock.entries[&format!("skill:library-base:{}", tool.name())].reasons,
            BTreeSet::from([by(ItemKind::Skill, "commit-guards", tool)])
        );
        assert_eq!(
            lock.entries
                .contains_key(&format!("hook:recorder:{}", tool.name())),
            tool == HarnessId::Copilot,
            "{tool:?}"
        );
        assert!(
            !lock
                .entries
                .contains_key(&format!("hook:commit-guards:{}", tool.name()))
        );
    }
    assert!(f.project.join(".github/hooks/recorder.sh").is_file());
    assert!(!f.project.join(".claude/hooks/recorder.sh").exists());
    let manifest = manifest_of(&f);
    assert!(manifest.skills.is_empty());
    assert_eq!(
        manifest
            .hooks
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["judge"]
    );
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Missing {
    Removed,
    Disabled,
    OtherTools,
}

const OPT_OUTS: [(ItemKind, &str, &str, Missing); 5] = [
    (
        ItemKind::Skill,
        "commit-guards",
        "[suppressed]\nskill = [\"commit-guards\"]\n",
        Missing::Removed,
    ),
    (
        ItemKind::Skill,
        "commit-guards",
        "[skills.commit-guards]\nsource = \"cat\"\nenabled = false\n",
        Missing::Disabled,
    ),
    (
        ItemKind::Hook,
        "recorder",
        "[suppressed]\nhook = [\"recorder\"]\n",
        Missing::Removed,
    ),
    (
        ItemKind::Hook,
        "recorder",
        "[hooks.recorder]\nsource = \"cat\"\nenabled = false\n",
        Missing::Disabled,
    ),
    (
        ItemKind::Hook,
        "recorder",
        "[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
        Missing::OtherTools,
    ),
];

/// A user opt-out is a missing requirement, unlike the companion's own
/// allowlist. The fresh install and refresh both withhold the requiring
/// hook and remove its Copilot companion rather than writing half a pair.
#[test]
#[allow(clippy::unwrap_used)]
fn removed_or_disabled_requirements_withhold_only_tools_that_need_them() {
    for (kind, dep, extra, cause) in OPT_OUTS {
        for refresh in [false, true] {
            let f = world();
            if refresh {
                apply_now(&f);
            }
            declare(&f, ALL, extra);
            let report = plan_apply(
                &f.env,
                &f.scope,
                &PlanOptions {
                    sweep_unneeded: true,
                    ..PlanOptions::current()
                },
            )
            .unwrap();
            assert_eq!(
                report.declaration_status,
                kendex_core::engine::DeclarationStatus::Incomplete,
                "{kind:?} {cause:?} refresh={refresh}"
            );
            let findings = findings_on(&report, "judge");
            let expected = match cause {
                Missing::OtherTools => "missing required dependency: GitHub Copilot runs judge without recorder, which it requires".to_owned(),
                Missing::Removed => format!("missing required dependency: judge requires {dep}, which is kept removed"),
                Missing::Disabled => format!("missing required dependency: judge requires {dep}, which is switched off"),
            };
            assert!(
                findings
                    .iter()
                    .any(|w| w.kind == ItemKind::Hook && w.message == expected),
                "{extra}: {:?}",
                messages(&report)
            );
            if cause == Missing::Removed {
                let kind_name = kind.name();
                assert!(findings.iter().any(|w| w.remediation.as_deref() == Some(&format!("add the {kind_name} {dep} again to restore it, or drop it from judge's dependencies"))));
            }
            apply::execute(&f.env, &report.plan).unwrap();
            let lock = lock_of(&f);
            for (tool, hook_file) in TOOLS {
                let stays = kind == ItemKind::Hook && tool != HarnessId::Copilot;
                assert_eq!(
                    f.project.join(hook_file).is_file(),
                    stays,
                    "{extra}: {tool:?} refresh={refresh}"
                );
                assert_eq!(
                    lock.entries
                        .contains_key(&format!("hook:judge:{}", tool.name())),
                    stays,
                    "{extra}: {tool:?} refresh={refresh}"
                );
            }
            assert!(
                !f.project.join(".github/hooks/recorder.sh").exists(),
                "{extra} refresh={refresh}"
            );
            for name in ["judge", "recorder"] {
                let registry = f.project.join(format!(".github/hooks/{name}.json"));
                if registry.exists() {
                    let value: serde_json::Value =
                        serde_json::from_str(&fs::read_to_string(registry).unwrap()).unwrap();
                    if let Some(hooks) = value.get("hooks") {
                        assert!(
                            hooks
                                .as_object()
                                .unwrap()
                                .values()
                                .all(|entries| entries.as_array().unwrap().is_empty()),
                            "{extra}: {name} remained registered"
                        );
                    }
                }
            }
        }
    }
}

fn same_named_hook_and_skill() -> std::io::Result<Fixture> {
    let f = super::hooks::hook_fixture(
        "[hooks.shared]\nsource = \"cat\"\n\n[skills.shared]\nsource = \"cat\"\n",
    );
    skill(&f.source, "shared", "");
    fs::write(
        f.source.join("hooks/shared.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: shared\n# event: PreToolUse\n# requires-skills: [shared]\n# ---\nexit 0\n",
    )?;
    Ok(f)
}

/// The app removes a skill by kind even when its requiring hook shares the
/// name. Both the saved dependency edge and a live catalog must preserve
/// that distinction. A bare CLI name still removes both declarations.
#[test]
#[allow(clippy::unwrap_used)]
fn a_same_named_hook_does_not_undo_a_skill_removal_when_its_catalog_returns() {
    for (kind, offline) in [
        (Some(ItemKind::Skill), true),
        (Some(ItemKind::Skill), false),
        (None, true),
        (None, false),
    ] {
        let f = same_named_hook_and_skill().unwrap();
        apply_now(&f);
        let lock = lock_of(&f);
        for tool in [HarnessId::Claude, HarnessId::Codex] {
            assert_eq!(
                lock.entries[&format!("skill:shared:{}", tool.name())].reasons,
                BTreeSet::from([Reason::Requested, by(ItemKind::Hook, "shared", tool)])
            );
            assert!(
                lock.entries
                    .contains_key(&format!("hook:shared:{}", tool.name()))
            );
        }

        let hidden = f.source.with_extension("offline");
        if offline {
            fs::rename(&f.source, &hidden).unwrap();
        }
        let removal = ops::remove(&f.env, &f.scope, &["shared".to_owned()], kind, false).unwrap();
        apply::execute(&f.env, &removal.plan).unwrap();
        let manifest = manifest_of(&f);
        assert!(!manifest.skills.contains_key("shared"));
        assert_eq!(manifest.hooks.contains_key("shared"), kind.is_some());
        assert_eq!(
            manifest.is_suppressed(ItemKind::Skill, "shared"),
            kind.is_some()
        );
        assert!(!manifest.is_suppressed(ItemKind::Hook, "shared"));
        let lock = lock_of(&f);
        for (tool, dir) in [(HarnessId::Claude, ".claude"), (HarnessId::Codex, ".codex")] {
            assert!(
                !lock
                    .entries
                    .contains_key(&format!("skill:shared:{}", tool.name()))
            );
            assert!(!f.project.join(dir).join("skills/shared/SKILL.md").exists());
            if offline {
                assert_eq!(
                    lock.entries
                        .contains_key(&format!("hook:shared:{}", tool.name())),
                    kind.is_some()
                );
            }
        }
        if offline {
            assert!(!removal.notes.is_empty());
            fs::rename(&hidden, &f.source).unwrap();
        }

        let returned = plan_apply(
            &f.env,
            &f.scope,
            &PlanOptions {
                sweep_unneeded: true,
                ..PlanOptions::current()
            },
        )
        .unwrap();
        assert_eq!(
            returned.warnings.iter().any(|w| {
                w.kind == ItemKind::Hook
                    && w.name == "shared"
                    && w.message
                        == "missing required dependency: shared requires shared, which is kept removed"
            }),
            kind.is_some(),
            "{kind:?} offline={offline}"
        );
        apply::execute(&f.env, &returned.plan).unwrap();
        let manifest = manifest_of(&f);
        assert_eq!(manifest.hooks.contains_key("shared"), kind.is_some());
        assert!(!manifest.is_suppressed(ItemKind::Hook, "shared"));
        let lock = lock_of(&f);
        for (tool, dir) in [(HarnessId::Claude, ".claude"), (HarnessId::Codex, ".codex")] {
            assert!(
                !lock
                    .entries
                    .contains_key(&format!("skill:shared:{}", tool.name()))
            );
            assert!(
                !lock
                    .entries
                    .contains_key(&format!("hook:shared:{}", tool.name()))
            );
            assert!(!f.project.join(dir).join("skills/shared/SKILL.md").exists());
            assert!(!f.project.join(dir).join("hooks/shared.sh").exists());
        }
    }
}
