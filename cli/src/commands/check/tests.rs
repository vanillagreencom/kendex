use super::render::render_scope;
use super::test_support::*;
use super::*;

mod hooks;
use hooks::install_claude_hook;

#[test]
fn comma_separated_inline() {
    // Real-world shape from .claude/agents/<name>.md.
    let fm = "name: reviewer-error\nskills: dev, linear\nrole: engineer";
    let skills = parse_skills_field(fm);
    assert_eq!(skills, vec!["dev".to_string(), "linear".to_string()]);
}

#[test]
fn yaml_inline_list_brackets() {
    let fm = "name: rust\nskills: [rust-tooling, rust-runtime, \"rust-unsafe\"]";
    let skills = parse_skills_field(fm);
    assert_eq!(
        skills,
        vec![
            "rust-tooling".to_string(),
            "rust-runtime".to_string(),
            "rust-unsafe".to_string(),
        ]
    );
}

#[test]
fn quoted_values_are_unwrapped() {
    let fm = "skills: \"github\", 'linear'";
    let skills = parse_skills_field(fm);
    assert_eq!(skills, vec!["github".to_string(), "linear".to_string()]);
}

#[test]
fn empty_or_missing_field_yields_empty_vec() {
    assert!(parse_skills_field("name: x").is_empty());
    assert!(parse_skills_field("skills:").is_empty());
    assert!(parse_skills_field("skills: []").is_empty());
}

#[test]
fn required_skills_section_lists_codex_skill_names() {
    let body = "# Agent\n\n## Required Skills\n\n- `dev`: Delegation (`.agents/skills/dev/SKILL.md`)\n- `github`: GitHub helpers (`.agents/skills/github/SKILL.md`)\n\n## Other\n\nText.";
    let skills = parse_required_skills_section(body);
    assert_eq!(skills, vec!["dev".to_string(), "github".to_string()]);
}

#[test]
fn missing_required_skills_section_yields_empty_vec() {
    assert!(parse_required_skills_section("# Agent\n\n## Notes\n").is_empty());
}

#[test]
fn empty_lock_and_empty_disk_yields_no_scope_report() {
    with_sandbox("empty", |_project, _source| {
        let lock = LockFile::default();
        assert!(check_scope(false, &lock, CheckOptions::default()).is_none());
    });
}

#[test]
fn current_install_against_unchanged_source_is_clean() {
    with_sandbox("clean", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "{report:?}");
        assert_eq!(names(&report.current), vec!["alpha"]);
    });
}

#[test]
fn classifies_outdated_removed_and_available() {
    with_sandbox("classify", |project, source| {
        write_skill(source, "alpha", "one");
        write_skill(source, "gone", "was here");
        install_skill_on_disk(project, "alpha");
        install_skill_on_disk(project, "gone");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        lock.add(locked(source, ItemKind::Skill, "gone"));

        // Now drift the source: alpha edited, gone deleted, beta added,
        // plus a hook and an agent the scope never installed.
        write_skill(source, "alpha", "two");
        std::fs::remove_dir_all(source.join("skills").join("gone")).unwrap();
        write_skill(source, "beta", "new");
        write_hook(source, "guard");
        write_agent(source, "helper");

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.has_drift());
        assert_eq!(names(&report.outdated), vec!["alpha"]);
        assert_eq!(names(&report.removed), vec!["gone"]);
        // Only kinds the scope already installs are offered: skills yes,
        // hooks and agents no.
        let offered: Vec<(&str, ItemKind)> = report
            .available
            .iter()
            .map(|a| (a.name.as_str(), a.kind))
            .collect();
        assert_eq!(offered, vec![("beta", ItemKind::Skill)]);
        assert_eq!(report.available[0].source, source.to_string_lossy());

        // Control: --no-available must drop the suggestion and nothing else.
        let muted = check_scope(
            false,
            &lock,
            CheckOptions {
                no_available: true,
                ..CheckOptions::default()
            },
        )
        .unwrap();
        assert!(muted.available.is_empty());
        assert_eq!(names(&muted.outdated), vec!["alpha"]);
        assert_eq!(names(&muted.removed), vec!["gone"]);
    });
}

#[test]
fn a_kind_whose_root_is_gone_is_a_source_issue_not_removed_or_outdated() {
    with_sandbox("no-condemn", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));

        // The whole skills root vanishes: that is a layout problem, not
        // proof alpha was removed upstream — and `refresh` cannot fix an
        // entry whose kind root does not exist, so it must not prescribe
        // one.
        std::fs::remove_dir_all(source.join("skills")).unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.removed.is_empty(), "{report:?}");
        assert!(report.outdated.is_empty(), "{report:?}");
        assert_eq!(report.source_issues.len(), 1, "{report:?}");
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unreadable { entries, reasons }
                    if entries == &vec!["alpha".to_string()]
                        && reasons[0].contains("skills")
            ),
            "{report:?}"
        );
        assert!(report.has_drift());
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        assert!(out.contains("cannot be inventoried"), "{out}");
        assert!(
            !out.contains("vstack refresh"),
            "must not prescribe refresh: {out}"
        );
    });
}

#[test]
fn an_unreadable_catalog_config_is_reported_instead_of_scanning_default_roots() {
    with_sandbox("bad-catalog", |project, source| {
        // A source that keeps its skills somewhere else entirely, then
        // corrupts the file that says where.
        std::fs::create_dir_all(source.join("pkgs").join("alpha")).unwrap();
        std::fs::write(
            source.join("pkgs").join("alpha").join("SKILL.md"),
            "---\nname: alpha\ndescription: alpha\n---\nbody\n",
        )
        .unwrap();
        std::fs::write(
            source.join("vstack.toml"),
            "[catalog]\nskills = [\"pkgs/*\"]\n",
        )
        .unwrap();
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));

        // Control: with the config intact the entry classifies normally.
        let clean = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(clean.source_issues.is_empty(), "{clean:?}");
        assert!(clean.removed.is_empty(), "{clean:?}");

        std::fs::write(source.join("vstack.toml"), "[catalog]\nskills = [\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.removed.is_empty() && report.outdated.is_empty(),
            "a source scanned at the wrong roots must not be called drift: {report:?}"
        );
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unreadable { entries, reasons }
                    if entries == &vec!["alpha".to_string()]
                        && reasons[0].contains("catalog configuration unreadable")
            ),
            "{report:?}"
        );
    });
}

#[test]
fn has_drift_is_true_for_each_field_alone_and_available_is_not_drift() {
    let one = || vec![Item::new("x", ItemKind::Skill)];
    let cases: Vec<(&str, ScopeReport)> = vec![
        (
            "outdated",
            ScopeReport {
                outdated: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "removed",
            ScopeReport {
                removed: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "orphaned",
            ScopeReport {
                orphaned: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "phantom",
            ScopeReport {
                phantom: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "missing_skill_refs",
            ScopeReport {
                missing_skill_refs: vec![MissingSkillRef {
                    agent: "a".into(),
                    skill: "s".into(),
                }],
                ..ScopeReport::default()
            },
        ),
        (
            "source_issues",
            ScopeReport {
                source_issues: vec![SourceIssue {
                    source: "owner/repo".into(),
                    problem: SourceProblem::Unresolvable {
                        entries: vec!["x".into()],
                    },
                }],
                ..ScopeReport::default()
            },
        ),
        (
            "invalid_names",
            ScopeReport {
                invalid_names: one(),
                ..ScopeReport::default()
            },
        ),
    ];
    for (field, report) in &cases {
        assert!(report.has_drift(), "{field} alone must be drift");
    }
    assert!(!ScopeReport::default().has_drift(), "all-empty control");
    let suggestion = ScopeReport {
        available: vec![AvailableItem {
            name: "beta".into(),
            kind: ItemKind::Skill,
            source: "owner/repo".into(),
        }],
        ..ScopeReport::default()
    };
    assert!(
        !suggestion.has_drift(),
        "available alone is a suggestion, never drift"
    );
}

#[test]
fn unresolvable_source_is_reported_with_its_entries_not_as_outdated() {
    with_sandbox("unresolvable", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        // The source vanishes entirely (path gone / cache never cloned).
        std::fs::remove_dir_all(source).unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.outdated.is_empty(), "{report:?}");
        assert!(report.removed.is_empty(), "{report:?}");
        assert_eq!(report.source_issues.len(), 1);
        let issue = &report.source_issues[0];
        assert_eq!(issue.source, source.to_string_lossy());
        assert_eq!(
            issue.problem,
            SourceProblem::Unresolvable {
                entries: vec!["alpha".to_string()]
            }
        );
        assert!(report.has_drift());
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        assert!(out.contains("is unreachable"), "{out}");
        assert!(
            !out.contains("vstack refresh"),
            "must not prescribe refresh: {out}"
        );
    });
}

#[test]
fn malformed_installed_asset_with_valid_sibling_is_not_removed() {
    with_sandbox("malformed", |project, source| {
        write_skill(source, "alpha", "one");
        write_skill(source, "beta", "two");
        install_skill_on_disk(project, "alpha");
        install_skill_on_disk(project, "beta");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        lock.add(locked(source, ItemKind::Skill, "beta"));
        // beta's SKILL.md turns unparseable while alpha stays valid.
        std::fs::write(
            source.join("skills").join("beta").join("SKILL.md"),
            "no frontmatter here\n",
        )
        .unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.removed.is_empty(),
            "files still exist, so this is not removal: {report:?}"
        );
        assert_eq!(names(&report.outdated), vec!["beta"], "{report:?}");
        assert_eq!(report.source_issues.len(), 1);
        assert!(
            matches!(&report.source_issues[0].problem, SourceProblem::Discovery { failures } if failures[0].contains("beta")),
            "{report:?}"
        );
        // An uninstalled malformed sibling: same discovery issue, and the
        // valid siblings still classify normally.
        write_skill(source, "gamma", "three");
        std::fs::write(
            source.join("skills").join("gamma").join("SKILL.md"),
            "still broken\n",
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.available.is_empty(), "{report:?}");
        assert!(
            matches!(&report.source_issues[0].problem, SourceProblem::Discovery { failures } if failures.len() == 2),
            "{report:?}"
        );
    });
}

#[test]
fn names_that_would_escape_the_install_roots_are_rejected_for_every_kind() {
    // A crafted lock must not make the session-start check probe outside
    // the roots it owns: each of these is joined into a path if trusted.
    for hostile in [
        "../x",
        "/tmp/x",
        "a/b",
        ".",
        "..",
        "a/../../etc",
        "@scope/../../etc",
        "@/x",
        "@scope/",
        // A leading dash would be read as a flag by the very command the
        // report tells an agent to run.
        "-rf",
    ] {
        for kind in CATALOG_KINDS {
            assert!(
                !is_safe_item_name(kind, hostile),
                "{kind:?} must reject {hostile:?}"
            );
        }
    }
    // The scoped form is the ONE separator vstack accepts, and only for
    // Pi packages.
    assert!(is_safe_item_name(
        ItemKind::PiExtension,
        "@vanillagreen/pi-hooks"
    ));
    for kind in [
        ItemKind::Agent,
        ItemKind::Skill,
        ItemKind::Hook,
        ItemKind::Extra,
    ] {
        assert!(!is_safe_item_name(kind, "@vanillagreen/pi-hooks"));
    }
}

/// Write a Pi package whose directory name deliberately differs from the
/// scoped name its manifest declares — the real shape of every shipped
/// package.
fn write_pi_package(source: &Path, dir_name: &str, manifest: &str) {
    let dir = source.join("pi-extensions").join(dir_name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("package.json"), manifest).unwrap();
    std::fs::write(dir.join("ext.ts"), "export default function () {}\n").unwrap();
}

#[test]
fn a_malformed_pi_package_is_not_reported_removed_while_its_files_exist() {
    with_sandbox("pi-malformed", |_project, source| {
        let manifest = |name: &str| {
            format!(
                "{{\"name\":\"{name}\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{{\"extensions\":[\"./ext.ts\"]}}}}"
            )
        };
        write_pi_package(source, "pi-hooks", &manifest("@vg/pi-hooks"));
        write_pi_package(source, "pi-qol", &manifest("@vg/pi-qol"));
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-hooks"));
        lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-qol"));

        // Control: both parse, neither is removed.
        let clean = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(clean.removed.is_empty(), "{clean:?}");

        // pi-hooks' manifest turns unreadable. Its directory is named
        // `pi-hooks` while the lock name is scoped, so a basename-blind
        // guard would condemn a package whose files are all still there.
        std::fs::write(
            source
                .join("pi-extensions")
                .join("pi-hooks")
                .join("package.json"),
            "{ not json",
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.removed.is_empty(),
            "files still exist, so this is not removal: {report:?}"
        );
        assert!(
            report
                .source_issues
                .iter()
                .any(|i| matches!(&i.problem, SourceProblem::Discovery { failures } if failures.iter().any(|f| f.contains("pi-hooks")))),
            "{report:?}"
        );

        // Control: a package whose directory is genuinely gone IS removed.
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-qol"));
        lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-gone"));
        std::fs::write(
            source
                .join("pi-extensions")
                .join("pi-hooks")
                .join("package.json"),
            manifest("@vg/pi-hooks"),
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.removed), vec!["@vg/pi-gone"], "{report:?}");
    });
}

#[test]
fn the_last_item_of_a_kind_is_reported_removed_when_its_root_is_readable_and_empty() {
    with_sandbox("last-item", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        let mut entry = locked(source, ItemKind::Skill, "alpha");
        // A legacy lock with no recorded hash: the hash check cannot
        // report drift for it, so only a removal verdict can.
        entry.source_hash = String::new();
        lock.add(entry);

        // The source deletes its last skill but keeps the root.
        std::fs::remove_dir_all(source.join("skills").join("alpha")).unwrap();
        assert!(source.join("skills").is_dir(), "root still readable");

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.removed), vec!["alpha"], "{report:?}");
        assert!(report.source_issues.is_empty(), "{report:?}");

        // Control: remove the ROOT as well and the verdict must retract —
        // a moved layout is not proof of removal.
        std::fs::remove_dir_all(source.join("skills")).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.removed.is_empty(), "{report:?}");
        assert!(!report.source_issues.is_empty(), "{report:?}");
    });
}

#[test]
fn an_item_renamed_in_its_own_manifest_is_removed_under_the_old_name() {
    with_sandbox("renamed-manifest", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        let mut entry = locked(source, ItemKind::Skill, "alpha");
        entry.source_hash = String::new();
        lock.add(entry);

        // The directory keeps its old basename while SKILL.md declares a
        // new name. `refresh` resolves the locked name against DECLARED
        // names, so nothing here can ever satisfy `alpha` again — the
        // matching directory name is not evidence of survival.
        std::fs::write(
            source.join("skills").join("alpha").join("SKILL.md"),
            "---\nname: renamed-alpha\ndescription: renamed\n---\n\nbody\n",
        )
        .unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.removed), vec!["alpha"], "{report:?}");
        assert!(report.source_issues.is_empty(), "{report:?}");

        // Control: make that same directory unparseable and the verdict
        // retracts — an unreadable manifest could be any item's.
        std::fs::write(
            source.join("skills").join("alpha").join("SKILL.md"),
            "no frontmatter\n",
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.removed.is_empty(), "{report:?}");
        assert!(!report.source_issues.is_empty(), "{report:?}");
    });
}

#[test]
fn one_missing_configured_root_never_prescribes_a_removal() {
    with_sandbox("partial-roots", |project, source| {
        std::fs::write(
            source.join("vstack.toml"),
            "[catalog]\nskills = [\"skills\", \"pkgs/skills\"]\n",
        )
        .unwrap();
        write_skill(source, "alpha", "one");
        std::fs::create_dir_all(source.join("pkgs").join("skills").join("beta")).unwrap();
        std::fs::write(
            source
                .join("pkgs")
                .join("skills")
                .join("beta")
                .join("SKILL.md"),
            "---\nname: beta\ndescription: beta\n---\n\nbody\n",
        )
        .unwrap();
        install_skill_on_disk(project, "alpha");
        install_skill_on_disk(project, "beta");
        let mut lock = LockFile::default();
        for name in ["alpha", "beta"] {
            let mut entry = locked(source, ItemKind::Skill, name);
            entry.source_hash = String::new();
            lock.add(entry);
        }

        // Control: both roots present, both entries classify normally.
        let clean = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(clean.removed.is_empty(), "{clean:?}");
        assert!(clean.source_issues.is_empty(), "{clean:?}");

        // One configured root disappears. The surviving root cannot vouch
        // for what the missing one used to supply, so the whole kind is a
        // layout problem to inspect — never a `vstack remove` to run.
        std::fs::remove_dir_all(source.join("pkgs").join("skills")).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.removed.is_empty(),
            "a still-readable sibling root must not condemn beta: {report:?}"
        );
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unreadable { entries, reasons }
                    if entries == &vec!["alpha".to_string(), "beta".to_string()]
                        && reasons[0].contains("skills")
            ),
            "{report:?}"
        );
    });
}

#[test]
fn an_explicitly_empty_catalog_list_reports_its_entries_removed() {
    with_sandbox("empty-catalog-list", |project, source| {
        // `skills = []` says the source ships no skills at all — positive
        // evidence, unlike an absent key whose default root is simply
        // missing.
        std::fs::write(source.join("vstack.toml"), "[catalog]\nskills = []\n").unwrap();
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        let mut entry = locked(source, ItemKind::Skill, "alpha");
        entry.source_hash = String::new();
        lock.add(entry);

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.removed), vec!["alpha"], "{report:?}");
        assert!(report.source_issues.is_empty(), "{report:?}");

        // Control: drop the key entirely and, with no `skills/` directory,
        // the same lock is unverifiable rather than removed.
        std::fs::write(source.join("vstack.toml"), "[catalog]\nhooks = []\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.removed.is_empty(), "{report:?}");
        assert!(!report.source_issues.is_empty(), "{report:?}");
    });
}

#[test]
fn a_skill_the_disk_scan_finds_outside_the_canonical_root_is_not_a_phantom() {
    // VST-195's class: `scan_installed_skills_on_disk` knows about roots
    // the canonical path check does not — checkout-anchored roots in a
    // worktree, and the Codex home root in global scope. Routing phantom
    // through the canonical path alone reported those installs missing at
    // every session start. This drives the Codex-home root, which needs no
    // git fixture, and proves the same wiring: the scan's evidence wins.
    with_sandbox("second-root", |_project, source| {
        write_skill(source, "alpha", "one");
        let anchored = config::codex_home_dir().join("skills").join("alpha");
        std::fs::create_dir_all(&anchored).unwrap();
        std::fs::write(anchored.join("SKILL.md"), "installed\n").unwrap();
        std::fs::write(anchored.join(".vstack-refreshed"), "").unwrap();
        // Deliberately NOT installed at the canonical global path.
        assert!(
            !config::global_state_dir()
                .join("skills")
                .join("alpha")
                .exists()
        );

        let scanned: Vec<String> = config::scan_installed_skills_on_disk(true)
            .into_iter()
            .map(|item| item.name)
            .collect();
        assert!(
            scanned.contains(&"alpha".to_string()),
            "fixture must be visible to the disk scan: {scanned:?}"
        );

        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        let report = check_scope(true, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "a skill the scan can see is installed: {report:?}"
        );
        assert!(report.orphaned.is_empty(), "{report:?}");

        // Inverse control: remove that copy and the same entry IS a phantom.
        std::fs::remove_dir_all(&anchored).unwrap();
        let report = check_scope(true, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["alpha"], "{report:?}");
        assert!(report.has_drift());
    });
}

#[test]
fn a_missing_install_is_phantom_for_every_kind_not_just_skills() {
    with_sandbox("phantom-kinds", |project, source| {
        write_skill(source, "alpha", "one");
        write_agent(source, "rust");
        write_hook(source, "guard");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        lock.add(locked(source, ItemKind::Agent, "rust"));
        lock.add(locked(source, ItemKind::Hook, "guard"));

        // Everything the lock claims, present on disk.
        let agents = project.join(".claude").join("agents");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::write(agents.join("rust.md"), "---\nname: rust\n---\nbody\n").unwrap();
        // Installed as `vstack add` installs it — script AND settings.json
        // registration — because presence now demands both.
        install_claude_hook(source, "guard");
        let hooks = project.join(".claude").join("hooks");

        let package = config::pi_packages_dir(false).join("@vg/pi-hooks");
        std::fs::create_dir_all(&package).unwrap();
        std::fs::write(package.join("package.json"), "{}").unwrap();
        write_pi_package(
            source,
            "pi-hooks",
            "{\"name\":\"@vg/pi-hooks\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{\"extensions\":[\"./ext.ts\"]}}",
        );
        lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-hooks"));

        let clean = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(clean.phantom.is_empty(), "control: {clean:?}");

        // Now delete the agent file, the hook script and the Pi package.
        // The source hash is unchanged, so without a presence check all
        // three read as current.
        std::fs::remove_file(agents.join("rust.md")).unwrap();
        std::fs::remove_file(hooks.join("guard.sh")).unwrap();
        std::fs::remove_dir_all(&package).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        let mut phantom = names(&report.phantom);
        phantom.sort();
        assert_eq!(phantom, vec!["@vg/pi-hooks", "guard", "rust"], "{report:?}");
        assert!(report.has_drift());
    });
}

#[test]
fn pi_legacy_lock_name_is_neither_removed_nor_offered_again() {
    with_sandbox("pi-legacy", |_project, source| {
        let (current, legacy) = crate::pi_extension::PI_EXTENSION_RENAMES
            .iter()
            .find_map(|(current, legacy)| legacy.first().map(|l| (*current, *l)))
            .expect("at least one rename on record");
        let dir = source.join("pi-extensions").join("pkg");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("package.json"),
            format!(
                "{{\"name\":\"{current}\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{{\"extensions\":[\"./ext.ts\"]}}}}"
            ),
        )
        .unwrap();
        std::fs::write(dir.join("ext.ts"), "export default function () {}\n").unwrap();
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::PiExtension, legacy));

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.removed.is_empty(), "{report:?}");
        assert!(
            report.available.iter().all(|a| a.name != current),
            "{report:?}"
        );
    });
}

#[test]
fn gather_reports_recorded_cache_failures_from_disk_and_never_fetches() {
    with_sandbox("gather-cache", |project, _source| {
        let cache = config::remote_cache_dir("owner/repo").unwrap();
        std::fs::create_dir_all(cache.join(".git")).unwrap();
        std::fs::write(
            cache.join(".git").join("config"),
            "[remote \"origin\"]\n\turl = https://github.com/owner/repo.git\n",
        )
        .unwrap();
        // A remote that has been failing for longer than two TTLs: the
        // stamp is the ONLY evidence gather is allowed to use.
        let stamp = cache.join(".git").join("vstack-fetch-stamp");
        let first = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (config::REMOTE_CACHE_FAILURE_IS_DRIFT.as_secs() + 3600);
        std::fs::write(&stamp, format!("failed {first} {first} reset\n")).unwrap();
        let before = std::fs::read_to_string(&stamp).unwrap();

        // The cache is a real, current source tree, so the SCOPE is
        // clean: the only thing that can make this report drift is the
        // recorded cache failure.
        write_skill(&cache, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        let mut entry = locked(&cache, ItemKind::Skill, "alpha");
        entry.source = "owner/repo".into();
        entry.source_hash = config::compute_source_hash(&entry);
        lock.add(entry);
        lock.save(&project.join(".vstack-lock.json")).unwrap();

        // `--offline` still reports it: reading a stamp is a disk read,
        // and offline is exactly when a user wants to know.
        let offline = gather(
            ScopeFilter::Project,
            CheckOptions {
                offline: true,
                ..CheckOptions::default()
            },
        )
        .unwrap();
        assert_eq!(offline.cache_refresh_failures.len(), 1, "{offline:?}");
        let failure = &offline.cache_refresh_failures[0];
        assert_eq!(failure.source, "owner/repo");
        assert!(failure.persistent, "two TTLs of failure is drift");
        assert!(failure.reason.contains("git reset failed"), "{failure:?}");
        assert!(failure.reason.contains("not re-checked"), "{failure:?}");
        assert!(
            offline.scopes.iter().all(|scope| !scope.has_drift()),
            "control: the scope itself is clean, so only the cache can be drift: {offline:?}"
        );
        assert!(offline.drift, "a persistent cache failure is drift");
        assert_eq!(offline.outcome(), CheckOutcome::Drift);
        let quiet = render_report(&offline, true);
        assert!(quiet.contains("vstack refresh"), "remedy named: {quiet}");
        assert_eq!(
            std::fs::read_to_string(&stamp).unwrap(),
            before,
            "gather must not touch the cache"
        );
    });
}

#[test]
fn json_shape_carries_every_case_and_drift_flag() {
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: Vec::new(),
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 1,
            missing_skill_refs: vec![MissingSkillRef {
                agent: "rust".into(),
                skill: "dev".into(),
            }],
            ..ScopeReport::default()
        }],
    };
    let json: serde_json::Value =
        serde_json::from_str(&config::to_json_pretty(&report).unwrap()).unwrap();
    assert_eq!(json["drift"], true);
    assert!(json["cache_refresh_failures"].is_array());
    let scope = &json["scopes"][0];
    for key in [
        "outdated",
        "removed",
        "orphaned",
        "phantom",
        "missing_skill_refs",
        "source_issues",
        "invalid_names",
        "available",
    ] {
        assert!(scope[key].is_array(), "missing {key}: {scope}");
    }
    assert_eq!(scope["missing_skill_refs"][0]["agent"], "rust");
    assert!(scope.get("current").is_none(), "current is human-only");
    assert_eq!(report.outcome(), CheckOutcome::Drift);
}
