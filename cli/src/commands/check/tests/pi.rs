//! Pi package presence: a copied package counts as installed only when Pi
//! will actually LOAD it, which takes the directory AND its `settings.json`
//! registration.

use super::*;

const MANIFEST: &str = "{\"name\":\"@vg/pi-hooks\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{\"extensions\":[\"./ext.ts\"]}}";

/// Install a Pi package exactly as `vstack add` does, so presence is checked
/// against the artifacts the installer really writes.
pub(super) fn install_pi_package(source: &Path, dir_name: &str) {
    let dir = source.join("pi-extensions").join(dir_name);
    let ext = crate::pi_extension::PiExtension::from_dir(&dir).unwrap();
    crate::pi_extension::install_pi_extension(&ext, false).unwrap();
}

/// The lock, the installed package, and the `packages` entry the installer
/// wrote for it.
fn installed(source: &Path) -> (LockFile, PathBuf, PathBuf) {
    write_pi_package(source, "pi-hooks", MANIFEST);
    install_pi_package(source, "pi-hooks");
    let mut lock = LockFile::default();
    lock.add(locked(source, ItemKind::PiExtension, "@vg/pi-hooks"));
    let package = config::pi_packages_dir(false).join("@vg/pi-hooks");
    assert!(package.is_dir(), "installer must copy the package");
    let settings = config::pi_settings_path(false);
    assert!(settings.exists(), "installer must register the package");
    (lock, package, settings)
}

fn phantom_note(report: &ScopeReport) -> String {
    report
        .phantom
        .iter()
        .filter_map(|item| item.detail.clone())
        .collect::<Vec<_>>()
        .join("; ")
}

fn unverifiable_note(report: &ScopeReport) -> String {
    report
        .unverifiable
        .iter()
        .filter_map(|item| item.detail.clone())
        .collect::<Vec<_>>()
        .join("; ")
}

fn write_packages(settings: &Path, entries: &[&str]) {
    let json = serde_json::json!({ "packages": entries });
    std::fs::write(settings, serde_json::to_string_pretty(&json).unwrap()).unwrap();
}

#[test]
fn a_pi_package_needs_its_settings_registration_not_just_its_directory() {
    with_sandbox("pi-registration", |_project, source| {
        let (lock, package, settings) = installed(source);

        // Control: the full install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "control: {report:?}");

        // Only the registration goes; the copied package stays.
        write_packages(&settings, &[]);
        assert!(
            package.is_dir(),
            "the copy must survive, or this proves nothing"
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["@vg/pi-hooks"], "{report:?}");
        assert!(
            phantom_note(&report).contains("package present but not registered"),
            "{report:?}"
        );
        assert!(report.has_drift());

        // An entry pointing at a different package is not this one's.
        write_packages(&settings, &["./packages/@vg/pi-qol"]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("package present but not registered"),
            "{report:?}"
        );

        // Neither is one whose name merely starts with this package's:
        // entries are compared as paths, never as substrings.
        write_packages(&settings, &["./packages/@vg/pi-hooks-extra"]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("package present but not registered"),
            "{report:?}"
        );

        // A hand-edited entry Pi still resolves to our package directory is
        // the registration, whatever its spelling.
        write_packages(&settings, &["packages/@vg/pi-hooks/"]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");

        write_packages(&settings, &[&package.to_string_lossy()]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");
    });
}

/// A `settings.json` that cannot be read says nothing about any package's
/// registration. Collapsing that into "not registered" reported correctly
/// installed packages as missing and sent users to reinstall them, when the
/// only broken thing was the settings file.
#[test]
fn an_unreadable_pi_settings_file_is_reported_as_itself_not_as_a_missing_package() {
    with_sandbox("pi-settings-unreadable", |_project, source| {
        let (lock, package, settings) = installed(source);
        let registered = std::fs::read_to_string(&settings).unwrap();

        std::fs::write(&settings, "{ not json").unwrap();
        assert!(
            package.is_dir(),
            "the copy must survive, or this proves nothing"
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "an unreadable settings file is not a missing install: {report:?}"
        );
        assert_eq!(
            names(&report.unverifiable),
            vec!["@vg/pi-hooks"],
            "{report:?}"
        );
        let note = unverifiable_note(&report);
        assert!(
            note.contains(&settings.display().to_string()),
            "the note names the settings file: {note}"
        );
        assert!(
            note.contains("Pi settings unreadable"),
            "the note names the fault: {note}"
        );
        assert!(
            !note.contains("not registered"),
            "the missing-registration remedy points at the wrong fault: {note}"
        );
        assert!(
            report.has_drift(),
            "an install nothing can verify is not clean either: {report:?}"
        );
        assert!(
            !report.current.iter().any(|i| i.name == "@vg/pi-hooks"),
            "it must not also be listed as current: {report:?}"
        );

        // Control: a settings file that READS fine and lacks the entry is
        // still the missing-registration report.
        write_packages(&settings, &[]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.unverifiable.is_empty(), "{report:?}");
        assert!(
            phantom_note(&report).contains("package present but not registered"),
            "{report:?}"
        );

        // Control: the registration restored, everything is clean again.
        std::fs::write(&settings, registered).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.unverifiable.is_empty(), "{report:?}");
        assert!(report.phantom.is_empty(), "{report:?}");
        assert!(!report.has_drift(), "{report:?}");
    });
}

/// A settings file that PARSES but whose shape vstack cannot act on is the
/// same fault as one that does not parse at all. Answering `false` there
/// called every copied package unregistered and prescribed a reinstall — while
/// the installer rejected the very same shape, so the prescribed remedy could
/// not run and the drift could never clear.
#[test]
fn a_pi_settings_shape_vstack_cannot_act_on_is_unverifiable_not_unregistered() {
    with_sandbox("pi-settings-shape", |_project, source| {
        let (lock, package, settings) = installed(source);
        let registered = std::fs::read_to_string(&settings).unwrap();
        let extension = crate::pi_extension::PiExtension::from_dir(
            &source.join("pi-extensions").join("pi-hooks"),
        )
        .unwrap();

        for (case, malformed) in [
            ("root is an array", r#"["./packages/@vg/pi-hooks"]"#),
            ("root is a string", r#""packages""#),
            (
                "packages is an object",
                r#"{"packages": {"0": "./packages/@vg/pi-hooks"}}"#,
            ),
            (
                "packages is a string",
                r#"{"packages": "./packages/@vg/pi-hooks"}"#,
            ),
        ] {
            std::fs::write(&settings, malformed).unwrap();
            assert!(
                package.is_dir(),
                "{case}: the copy must survive, or this proves nothing"
            );
            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(
                report.phantom.is_empty(),
                "{case}: a settings file nothing can read is not a missing package: {report:?}"
            );
            assert_eq!(
                names(&report.unverifiable),
                vec!["@vg/pi-hooks"],
                "{case}: {report:?}"
            );
            let note = unverifiable_note(&report);
            assert!(
                note.contains(&settings.display().to_string()),
                "{case}: the note names the settings file: {note}"
            );
            assert!(
                !note.contains("not registered"),
                "{case}: the missing-registration remedy points at the wrong fault: {note}"
            );
            assert!(report.has_drift(), "{case}: {report:?}");

            // The other half: the installer must refuse the same shape it
            // just reported, and leave the file exactly as it found it.
            let err = crate::pi_extension::install_pi_extension(&extension, false)
                .expect_err("install must refuse a settings shape it cannot read");
            assert!(
                format!("{err:#}").contains(&settings.display().to_string()),
                "{case}: the refusal names the file: {err:#}"
            );
            assert_eq!(
                std::fs::read_to_string(&settings).unwrap(),
                malformed,
                "{case}: the user's settings must be byte-identical after a refusal"
            );
        }

        // Control: a readable settings file without the entry is still the
        // missing-registration report, and installing repairs it.
        write_packages(&settings, &[]);
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.unverifiable.is_empty(), "control: {report:?}");
        assert!(
            phantom_note(&report).contains("package present but not registered"),
            "control: {report:?}"
        );
        crate::pi_extension::install_pi_extension(&extension, false).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // Control: the original registration is clean.
        std::fs::write(&settings, registered).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");
    });
}

#[test]
fn a_pi_package_whose_directory_is_gone_stays_a_missing_install() {
    with_sandbox("pi-directory-gone", |_project, source| {
        let (lock, package, _settings) = installed(source);
        std::fs::remove_dir_all(&package).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["@vg/pi-hooks"], "{report:?}");
        assert!(
            phantom_note(&report).contains("install path missing"),
            "{report:?}"
        );
    });
}
