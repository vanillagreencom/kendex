//! Where one package's record sits, and whose it is.

use std::path::Path;

use super::*;

/// Every legal name gets a record path of its own, and no name's record is
/// another name's directory.
///
/// The plugin half of a namespaced name is the case that matters: arming
/// `plugin/leaf` has to make a directory called `plugin`, and a record read
/// as the directory itself would report a plain package of that name as
/// armed — a licence to run a checker nobody authorised, which is the whole
/// of what this module refuses.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture preconditions")]
fn one_package_s_record_is_never_another_s() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = crate::paths::canonical(tmp.path()).unwrap();

    arm(&dir, "guards/hooks").unwrap();

    for (name, want) in [
        ("guards/hooks", true),
        ("guards", false),
        ("hooks", false),
        ("guards/other", false),
    ] {
        assert_eq!(recorded(&dir, name).unwrap(), want, "recorded({name})");
    }
}

/// A disarm drops the record it wrote, and a second one is not an error:
/// the uninstaller may run in a repository nothing armed.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture preconditions")]
fn a_disarm_leaves_no_licence_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = crate::paths::canonical(tmp.path()).unwrap();
    arm(&dir, "guards/hooks").unwrap();

    disarm(&dir, "guards/hooks").unwrap();
    disarm(&dir, "guards/hooks").unwrap();

    assert!(!recorded(&dir, "guards/hooks").unwrap());
}

/// A name kendex would refuse to install gets no record and no path built
/// out of it — never a traversal, and never a silent yes.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture preconditions")]
fn an_illegal_name_is_refused_rather_than_sanitised() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = crate::paths::canonical(tmp.path()).unwrap();

    for name in ["../escape", "a/b/c", "", "-flag"] {
        arm(&dir, name).unwrap();
        assert!(!recorded(&dir, name).unwrap(), "recorded({name})");
    }
    assert!(!Path::new(&dir).join(DIR).exists(), "nothing was written");
}
