//! The folders a registry must not take: a project under a temporary
//! path is a fixture or a throwaway, and its entry outlives it, flagged on
//! Home as a folder that is gone until somebody removes it by hand.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};

/// The roots a platform hands out for temporary files under fixed names,
/// beside whatever `TMPDIR` says: `mktemp` on Linux, and on macOS, where
/// `/tmp` and `/var` resolve under `/private`, the canonical spellings too.
const TEMP_ROOTS: [&str; 4] = ["/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp"];

/// The harness scratchpad convention: a `.scratch` directory anywhere on
/// the path, which is where an agent's fixture projects live.
const SCRATCH_SEGMENT: &str = ".scratch";

/// Why a folder counts as temporary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Temporary {
    /// Under the directory the platform hands out for temporary files.
    PlatformTempDir(PathBuf),
    /// Under one of [`TEMP_ROOTS`].
    TempRoot(PathBuf),
    /// A path segment is named [`SCRATCH_SEGMENT`].
    ScratchSegment,
}

impl std::fmt::Display for Temporary {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Temporary::PlatformTempDir(dir) => write!(
                out,
                "it is under {}, where this machine keeps temporary files",
                dir.display()
            ),
            Temporary::TempRoot(root) => {
                write!(out, "it is under {}, a temporary folder", root.display())
            }
            Temporary::ScratchSegment => write!(out, "it is under a {SCRATCH_SEGMENT} folder"),
        }
    }
}

/// Why `canonical` is a temporary folder, or nothing where it is not.
///
/// Judged on the canonical spelling, so a link into a scratch folder is
/// the scratch folder; the temp dir is resolved the same way, since on
/// macOS `TMPDIR` is spelled under `/var` and resolves under `/private`.
pub fn temporary(env: &Env, canonical: &Path) -> Option<Temporary> {
    let temp_dir =
        crate::paths::canonical(env.temp_dir()).unwrap_or_else(|_| env.temp_dir().to_path_buf());
    if canonical.starts_with(&temp_dir) {
        return Some(Temporary::PlatformTempDir(temp_dir));
    }
    if let Some(root) = TEMP_ROOTS
        .iter()
        .map(Path::new)
        .find(|root| canonical.starts_with(root))
    {
        return Some(Temporary::TempRoot(root.to_path_buf()));
    }
    canonical
        .components()
        .any(|segment| segment.as_os_str() == SCRATCH_SEGMENT)
        .then_some(Temporary::ScratchSegment)
}

/// Refuse to register `path` where it is a temporary folder the registry
/// does not hold yet and the registry is not itself temporary.
///
/// A registry that is itself under a temporary path is a fixture's, and
/// dies with it: what it holds never reaches a person's projects list, so
/// a test that registers a project into an isolated config dir needs no
/// flag. The real registry, and a debug build's sandbox under the data
/// dir, refuse.
///
/// An entry already on the list was asked for once, with the flag; a
/// later install into that folder adds nothing to the registry, so there
/// is nothing left to refuse.
///
/// The registry is judged in the same spelling the folder is: the file
/// may not exist yet, so `paths::absolute` resolves what is there and
/// folds the rest on. Judged as written, a config dir spelled under a
/// temporary root and linked to a kept folder would exempt a kept list.
pub fn refuse_temporary(env: &Env, path: &Path) -> Result<()> {
    let canonical = crate::paths::canonical(path).map_err(|e| CoreError::io(path, e))?;
    if temporary(env, &crate::paths::absolute(&env.settings_file())).is_some()
        || super::load(env)?.projects.contains(&canonical)
    {
        return Ok(());
    }
    match temporary(env, &canonical) {
        Some(reason) => Err(CoreError::TemporaryProject {
            path: canonical,
            reason,
        }),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    /// One row per reason, and one folder that is none of them. The temp
    /// dir is the fixture's own and exists on no host: a real one is
    /// resolved before the comparison, and on macOS `/var` resolves under
    /// `/private`, which no row spelled by hand would start with.
    #[test]
    fn a_folder_is_temporary_for_the_reason_its_path_carries() {
        let env = Env::fake("/home/pat", FakeOs::Linux).with_temp_dir("/kx-fixture-temp");
        let rows = [
            (
                "/kx-fixture-temp/kx.1/proj",
                Some(Temporary::PlatformTempDir(PathBuf::from(
                    "/kx-fixture-temp",
                ))),
            ),
            (
                "/tmp/proj",
                Some(Temporary::TempRoot(PathBuf::from("/tmp"))),
            ),
            (
                "/home/pat/dev/.scratch/kx/proj",
                Some(Temporary::ScratchSegment),
            ),
            ("/home/pat/dev/app", None),
        ];
        for (path, expected) in rows {
            assert_eq!(temporary(&env, Path::new(path)), expected, "{path}");
        }
    }

    /// The isolation rule: a fixture home under the temp dir holds a
    /// registry nobody keeps, so a temporary folder registers there.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_registry_under_a_temporary_path_takes_a_temporary_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::paths::canonical(tmp.path()).unwrap();
        let project = home.join("proj");
        std::fs::create_dir(&project).unwrap();
        let env = Env::fake(&home, FakeOs::Linux).with_temp_dir(&home);
        assert!(refuse_temporary(&env, &project).is_ok());
        let kept = Env::fake("/home/pat", FakeOs::Linux).with_temp_dir(&home);
        assert!(matches!(
            refuse_temporary(&kept, &project),
            Err(CoreError::TemporaryProject {
                reason: Temporary::PlatformTempDir(_),
                ..
            })
        ));
    }

    /// A registry spelled under the temp dir through a link to a kept
    /// folder is the kept folder's: judged as written it would be exempt,
    /// and a kept list would take a temporary folder with no flag. The
    /// kept folder sits under the workspace's target dir, the one place a
    /// unit test has that no temporary root covers.
    #[cfg(unix)]
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_registry_spelled_under_the_temp_dir_is_judged_where_it_resolves() {
        let tmp = tempfile::tempdir().unwrap();
        let temp = crate::paths::canonical(tmp.path()).unwrap();
        let target = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/tmp");
        std::fs::create_dir_all(&target).unwrap();
        let kept_root = tempfile::tempdir_in(&target).unwrap();
        let kept = crate::paths::canonical(kept_root.path()).unwrap();
        let probe = Env::fake(&kept, FakeOs::Linux).with_temp_dir(&temp);
        assert_eq!(
            temporary(&probe, &kept),
            None,
            "{} is itself temporary, so nothing here can stand for a kept registry",
            kept.display()
        );
        std::os::unix::fs::symlink(&kept, temp.join("link")).unwrap();
        let project = temp.join("proj");
        std::fs::create_dir(&project).unwrap();
        let env = Env::fake(temp.join("link"), FakeOs::Linux).with_temp_dir(&temp);
        assert!(matches!(
            refuse_temporary(&env, &project),
            Err(CoreError::TemporaryProject {
                reason: Temporary::PlatformTempDir(_),
                ..
            })
        ));
    }
}
