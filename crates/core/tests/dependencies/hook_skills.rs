//! Hook headers declare required skills separately from companion hooks.
//! Companion allowlists limit where the companion is needed, not its caller.

use super::hooks::{findings_on, messages};
use super::*;

const CHECK: &str = "#!/usr/bin/env bash\n# ---\n# name: skill-load-check\n# event: PreToolUse\n# matcher: Bash\n# harnesses: [claude, codex, opencode, cursor, pi, gemini, copilot, antigravity]\n# requires: [skill-load-record]\n# requires-skills: [commit-guards]\n# ---\nexit 0\n";
const RECORDER: &str = "#!/usr/bin/env bash\n# ---\n# name: skill-load-record\n# event: PostToolUse\n# harnesses: [copilot]\n# requires: [skill-load-check]\n# ---\nexit 0\n";
const DECLARED: &str = "[hooks.skill-load-check]\nsource = \"cat\"\n";
const ALL: &str = "\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\", \"gemini\", \"copilot\", \"antigravity\"";

/// The catalog recorder runs on all four harnesses, while the check needs
/// it only on Copilot. Local opt-outs still remove the check on Copilot.
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
            Some(
                "missing required dependency: skill-load-check requires skill-load-record, which is switched off",
            ),
        ),
        (
            FOUR,
            Some("harnesses = [\"claude\"]"),
            Some(
                "missing required dependency: GitHub Copilot runs skill-load-check without skill-load-record, which it requires",
            ),
        ),
        ("\"claude\"", Some("enabled = false"), None),
        ("\"codex\"", Some("enabled = false"), None),
        ("\"pi\"", Some("harnesses = [\"pi\"]"), None),
        (
            FOUR,
            None,
            Some(
                "skill-load-check requires skill-load-record, which the catalog 'cat' does not offer",
            ),
        ),
    ] {
        let f = world();
        let check = CHECK.replace("# requires:", "# requires-on: [copilot]\n# requires:");
        fs::write(f.source.join("hooks/skill-load-check.sh"), check).unwrap();
        fs::write(
            f.source.join("hooks/skill-load-record.sh"),
            RECORDER.replace(
                "# harnesses: [copilot]",
                "# harnesses: [claude, codex, pi, copilot]",
            ),
        )
        .unwrap();
        let recorder_decl = match recorder {
            Some(settings) => {
                format!("\n[hooks.skill-load-record]\nsource = \"cat\"\n{settings}\n")
            }
            None => {
                fs::remove_file(f.source.join("hooks/skill-load-record.sh")).unwrap();
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
        let findings = findings_on(&report, "skill-load-check");
        assert_eq!(
            findings
                .iter()
                .filter(|w| {
                    w.message.starts_with("missing required dependency:")
                        || w.message
                            == "skill-load-check requires skill-load-record, which the catalog 'cat' does not offer"
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
            let check = format!("hook:skill-load-check:{}", tool.name());
            let guard = format!("skill:commit-guards:{}", tool.name());
            let record = format!("hook:skill-load-record:{}", tool.name());
            let selected = tools.contains(&format!("\"{}\"", tool.name()));
            let stays = selected && !(missing && tool == HarnessId::Copilot);
            assert_eq!(
                lock.entries.contains_key(&check),
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

/// Script or advisory file written for each tool. This fixture permits all
/// tools, including the two the catalog's skill-load-check excludes.
const TOOLS: [(HarnessId, &str); 8] = [
    (HarnessId::Claude, ".claude/hooks/skill-load-check.sh"),
    (HarnessId::Codex, ".codex/hooks/skill-load-check.sh"),
    (
        HarnessId::Opencode,
        ".opencode/instructions/kendex-hook-skill-load-check.md",
    ),
    (
        HarnessId::Cursor,
        ".cursor/rules/safety-skill-load-check.mdc",
    ),
    (HarnessId::Pi, ".pi/kendex/hooks/skill-load-check.sh"),
    (HarnessId::Gemini, ".gemini/hooks/skill-load-check.sh"),
    (HarnessId::Copilot, ".github/hooks/skill-load-check.sh"),
    (HarnessId::Antigravity, ".agents/hooks/skill-load-check.sh"),
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
    fs::write(f.source.join("hooks/skill-load-check.sh"), CHECK).unwrap();
    fs::write(f.source.join("hooks/skill-load-record.sh"), RECORDER).unwrap();
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

/// Declaring the check alone installs its skill and that skill's own
/// dependency on every tool. Only Copilot receives the recorder, including
/// its reverse dependency on the check. Claude retains the check without it.
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
        findings_on(&report, "skill-load-check")
            .iter()
            .all(|w| !w.message.starts_with("missing required dependency:")),
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    let lock = lock_of(&f);
    for (tool, hook_file) in TOOLS {
        assert!(f.project.join(hook_file).is_file(), "{tool:?}: {hook_file}");
        let check = &lock.entries[&format!("hook:skill-load-check:{}", tool.name())];
        assert!(check.enabled);
        let mut reasons = BTreeSet::from([Reason::Requested]);
        if tool == HarnessId::Copilot {
            reasons.insert(by(ItemKind::Hook, "skill-load-record", tool));
        }
        assert_eq!(check.reasons, reasons, "{tool:?}");
        let guard = &lock.entries[&format!("skill:commit-guards:{}", tool.name())];
        assert_eq!(
            guard.reasons,
            BTreeSet::from([by(ItemKind::Hook, "skill-load-check", tool)])
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
                .contains_key(&format!("hook:skill-load-record:{}", tool.name())),
            tool == HarnessId::Copilot,
            "{tool:?}"
        );
        assert!(
            !lock
                .entries
                .contains_key(&format!("hook:commit-guards:{}", tool.name()))
        );
    }
    assert!(
        f.project
            .join(".github/hooks/skill-load-record.sh")
            .is_file()
    );
    assert!(
        !f.project
            .join(".claude/hooks/skill-load-record.sh")
            .exists()
    );
    let manifest = manifest_of(&f);
    assert!(manifest.skills.is_empty());
    assert_eq!(
        manifest
            .hooks
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["skill-load-check"]
    );
}

/// The local recorder declaration must deliver the catalog companion wherever
/// this repository requests its judge. Retained records are not planned deliveries.
#[test]
#[allow(clippy::unwrap_used)]
fn local_skill_load_declarations_retain_all_four_judges() {
    let checkout = test_util::checkout_root();
    let local = manifest::load_current(&checkout.join("kendex-local.toml"))
        .unwrap()
        .unwrap();
    let expected = [
        HarnessId::Claude,
        HarnessId::Codex,
        HarnessId::Pi,
        HarnessId::Copilot,
    ];
    let f = world();
    fs::create_dir_all(f.project.join(".pi")).unwrap();
    fs::write(
        f.project.join(".pi/settings.json"),
        r#"{"packages":["./packages/@vanillagreen/pi-hooks"]}"#,
    )
    .unwrap();
    let mut declared = manifest_of(&f);
    declared.install.harnesses = expected.to_vec();
    declared.hooks.clear();
    for name in ["skill-load-check", "skill-load-record"] {
        fs::copy(
            checkout.join(format!("hooks/{name}.sh")),
            f.source.join(format!("hooks/{name}.sh")),
        )
        .unwrap();
        let mut declaration = local.hooks[name].clone();
        declaration.source = "cat".to_owned();
        declared.hooks.insert(name.to_owned(), declaration);
    }
    fs::write(
        f.project.join("kendex.toml"),
        toml::to_string_pretty(&declared).unwrap(),
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        report.declaration_status,
        kendex_core::engine::DeclarationStatus::Complete,
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    let lock = lock_of(&f);
    for tool in expected {
        for name in ["skill-load-check", "skill-load-record"] {
            let key = format!("hook:{name}:{}", tool.name());
            assert!(lock.entries.contains_key(&key), "{tool:?}: {name}");
            assert!(report.installations.contains_key(&key), "{tool:?}: {name}");
        }
    }

    // The planted local restriction reaches the current removal pass with a
    // record of all four judges, rather than only checking a fresh install.
    declared
        .hooks
        .get_mut("skill-load-record")
        .unwrap()
        .harnesses = Some(vec![HarnessId::Copilot]);
    fs::write(
        f.project.join("kendex.toml"),
        toml::to_string_pretty(&declared).unwrap(),
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        report.declaration_status,
        kendex_core::engine::DeclarationStatus::Complete
    );
    assert!(
        findings_on(&report, "skill-load-check").is_empty(),
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    let lock = lock_of(&f);
    // Without a sweep, the orphaned recorder retains its record and keeps the
    // judge it required. The engine's installation set holds current delivery.
    for tool in expected {
        for name in ["skill-load-check", "skill-load-record"] {
            let key = format!("hook:{name}:{}", tool.name());
            assert!(
                lock.entries.contains_key(&key),
                "retained: {tool:?}: {name}"
            );
            assert_eq!(
                report.installations.contains_key(&key),
                name == "skill-load-check" || tool == HarnessId::Copilot,
                "control local-restriction: {tool:?}: {name}"
            );
        }
    }
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
        "skill-load-record",
        "[suppressed]\nhook = [\"skill-load-record\"]\n",
        Missing::Removed,
    ),
    (
        ItemKind::Hook,
        "skill-load-record",
        "[hooks.skill-load-record]\nsource = \"cat\"\nenabled = false\n",
        Missing::Disabled,
    ),
    (
        ItemKind::Hook,
        "skill-load-record",
        "[hooks.skill-load-record]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
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
                    ..PlanOptions::default()
                },
            )
            .unwrap();
            assert_eq!(
                report.declaration_status,
                kendex_core::engine::DeclarationStatus::Incomplete,
                "{kind:?} {cause:?} refresh={refresh}"
            );
            let findings = findings_on(&report, "skill-load-check");
            let expected = match cause {
                Missing::OtherTools => "missing required dependency: GitHub Copilot runs skill-load-check without skill-load-record, which it requires".to_owned(),
                Missing::Removed => format!("missing required dependency: skill-load-check requires {dep}, which is kept removed"),
                Missing::Disabled => format!("missing required dependency: skill-load-check requires {dep}, which is switched off"),
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
                assert!(findings.iter().any(|w| w.remediation.as_deref() == Some(&format!("add the {kind_name} {dep} again to restore it, or drop it from skill-load-check's dependencies"))));
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
                        .contains_key(&format!("hook:skill-load-check:{}", tool.name())),
                    stays,
                    "{extra}: {tool:?} refresh={refresh}"
                );
            }
            assert!(
                !f.project
                    .join(".github/hooks/skill-load-record.sh")
                    .exists(),
                "{extra} refresh={refresh}"
            );
            for name in ["skill-load-check", "skill-load-record"] {
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
                ..PlanOptions::default()
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
