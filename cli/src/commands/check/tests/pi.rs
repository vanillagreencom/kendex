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
