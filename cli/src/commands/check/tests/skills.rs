//! Skill presence: which roots count as installed, and what the report names
//! when the reinstall a missing skill prescribes is itself blocked.

use super::*;

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

/// The skill half of the two-fault ordering. A missing project skill prescribes
/// `vstack add`, and that install writes the canonical through `.agents` — a
/// path it refuses outright when it is not this checkout's own directory. Read
/// as a plain phantom, every project skill named the one command the path
/// blocks, and nothing named the path.
#[test]
fn a_missing_project_skill_beside_an_unusable_agents_path_names_the_path_first() {
    with_sandbox("skill-agents-path", |project, source| {
        write_skill(source, "alpha", "one");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        let agents = project.join(".agents");
        let skill =
            crate::skill::Skill::from_file(&source.join("skills").join("alpha").join("SKILL.md"))
                .unwrap();

        // Control: installed, and the scope is clean.
        install_skill_on_disk(project, "alpha");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // Control: `.agents` gone entirely is the ordinary missing install —
        // the reinstall creates the directory, so nothing is in its way.
        std::fs::remove_dir_all(&agents).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["alpha"], "control: {report:?}");
        assert!(report.unverifiable.is_empty(), "control: {report:?}");

        // The same missing skill, with a `.agents` the install refuses.
        std::fs::write(&agents, "not a directory\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "the blocked remedy must not be the headline: {report:?}"
        );
        assert_eq!(names(&report.unverifiable), vec!["alpha"], "{report:?}");
        let note = report.unverifiable[0].detail.clone().unwrap_or_default();
        assert!(
            note.contains(&agents.display().to_string()) && note.contains("not a directory"),
            "the note names the path to repair: {note}"
        );
        assert!(
            note.contains("install path missing"),
            "…and the second fault, so the user is not sent back twice: {note}"
        );

        // Why the order matters: the reinstall the phantom report would have
        // prescribed refuses this path, so following it could never have
        // cleared the report.
        let err = crate::installer::install_skill(
            &skill,
            crate::harness::Harness::ClaudeCode,
            false,
            crate::config::InstallMethod::Symlink,
            None,
        )
        .err()
        .expect("install must refuse a .agents path it cannot write through");
        assert!(
            format!("{err:#}").contains(&agents.display().to_string()),
            "the refusal names the path: {err:#}"
        );

        // Control: repair the named path and the same install completes.
        std::fs::remove_file(&agents).unwrap();
        crate::installer::install_skill(
            &skill,
            crate::harness::Harness::ClaudeCode,
            false,
            crate::config::InstallMethod::Symlink,
            None,
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");
    });
}
