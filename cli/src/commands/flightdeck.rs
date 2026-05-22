use anyhow::{Context, Result};
use clap::ValueEnum;
use std::collections::BTreeSet;
use std::env;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum PermissionScope {
    /// Migrate the default user store at $HOME/.vstack/flightdeck/projects
    User,
    /// Migrate the FLIGHTDECK_RUN_STORE_ROOT override when set
    Project,
    /// Migrate both the user store and FLIGHTDECK_RUN_STORE_ROOT when distinct
    All,
}

pub fn migrate_permissions(scope: PermissionScope, dry_run: bool) -> Result<()> {
    #[cfg(unix)]
    {
        unix::migrate_permissions(scope, dry_run)
    }
    #[cfg(not(unix))]
    {
        let _ = (scope, dry_run);
        anyhow::bail!("flightdeck permission migration is only supported on Unix-like systems")
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    const STORE_DIR_MODE: u32 = 0o700;
    const STORE_FILE_MODE: u32 = 0o600;
    const GROUP_OTHER_WRITE: u32 = 0o022;

    #[derive(Debug, Default, PartialEq, Eq)]
    struct MigrationReport {
        roots: usize,
        checked: usize,
        changed: usize,
        refused: Vec<String>,
    }

    pub(super) fn migrate_permissions(scope: PermissionScope, dry_run: bool) -> Result<()> {
        let roots = migration_roots(scope)?;
        if roots.is_empty() {
            println!("No Flightdeck run-store roots found for scope {scope:?}.");
            return Ok(());
        }

        let mut total = MigrationReport::default();
        for root in roots {
            let report = migrate_projects_dir(&root, dry_run)?;
            total.roots += report.roots;
            total.checked += report.checked;
            total.changed += report.changed;
            total.refused.extend(report.refused);
        }

        let action = if dry_run { "would change" } else { "changed" };
        println!(
            "Flightdeck permission migration: roots={} checked={} {action}={} refused={}",
            total.roots,
            total.checked,
            total.changed,
            total.refused.len()
        );

        if !total.refused.is_empty() {
            eprintln!("Refused unsafe paths:");
            for refusal in &total.refused {
                eprintln!("  - {refusal}");
            }
            anyhow::bail!(
                "Flightdeck permission migration refused {} unsafe path(s)",
                total.refused.len()
            );
        }

        Ok(())
    }

    fn migration_roots(scope: PermissionScope) -> Result<Vec<PathBuf>> {
        let mut roots = Vec::new();
        let mut seen = BTreeSet::new();
        let include_user = matches!(scope, PermissionScope::User | PermissionScope::All);
        let include_project = matches!(scope, PermissionScope::Project | PermissionScope::All);

        if include_user {
            let home = env::var_os("HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .or_else(dirs::home_dir)
                .context("HOME is not set and no home directory could be resolved")?;
            push_existing_projects_root(&mut roots, &mut seen, home.join(".vstack/flightdeck"));
        }

        if include_project {
            if let Some(root) =
                env::var_os("FLIGHTDECK_RUN_STORE_ROOT").filter(|value| !value.is_empty())
            {
                let root = absolutize(PathBuf::from(root))?;
                push_existing_projects_root(&mut roots, &mut seen, root);
            } else if matches!(scope, PermissionScope::Project) {
                println!(
                    "FLIGHTDECK_RUN_STORE_ROOT is not set; no project-scoped run store to migrate."
                );
            }
        }

        Ok(roots)
    }

    fn push_existing_projects_root(
        roots: &mut Vec<PathBuf>,
        seen: &mut BTreeSet<PathBuf>,
        store_root: PathBuf,
    ) {
        let projects = store_root.join("projects");
        if !projects.exists() {
            println!(
                "Flightdeck run-store projects dir not found: {}",
                projects.display()
            );
            return;
        }
        let key = fs::canonicalize(&projects).unwrap_or_else(|_| projects.clone());
        if seen.insert(key) {
            roots.push(projects);
        }
    }

    fn absolutize(path: PathBuf) -> Result<PathBuf> {
        if path.is_absolute() {
            Ok(path)
        } else {
            Ok(env::current_dir()?.join(path))
        }
    }

    fn migrate_projects_dir(projects: &Path, dry_run: bool) -> Result<MigrationReport> {
        let mut report = MigrationReport {
            roots: 1,
            ..MigrationReport::default()
        };
        for entry in WalkDir::new(projects)
            .follow_links(false)
            .contents_first(false)
        {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    report.refused.push(format!(
                        "{}: failed to walk path",
                        error
                            .path()
                            .map(Path::display)
                            .map(|p| p.to_string())
                            .unwrap_or_else(|| "<unknown>".to_owned())
                    ));
                    continue;
                }
            };
            report.checked += 1;
            inspect_and_fix(entry.path(), dry_run, &mut report);
        }
        Ok(report)
    }

    fn inspect_and_fix(path: &Path, dry_run: bool, report: &mut MigrationReport) {
        let metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) => {
                report
                    .refused
                    .push(format!("{}: stat failed: {error}", path.display()));
                return;
            }
        };
        let mode = metadata.mode() & 0o777;
        if metadata.file_type().is_symlink() {
            report
                .refused
                .push(format!("{}: symlinks are not allowed", path.display()));
            return;
        }
        let uid = current_uid();
        if let Some(uid) = uid {
            if metadata.uid() != uid {
                report.refused.push(format!(
                    "{}: owned by uid {}, not {}",
                    path.display(),
                    metadata.uid(),
                    uid
                ));
                return;
            }
        }
        if (mode & GROUP_OTHER_WRITE) != 0 {
            report.refused.push(format!(
                "{}: group/other write bits set (mode={mode:o})",
                path.display()
            ));
            return;
        }

        let expected = if metadata.is_dir() {
            STORE_DIR_MODE
        } else if metadata.is_file() {
            STORE_FILE_MODE
        } else {
            report.refused.push(format!(
                "{}: expected regular file or directory",
                path.display()
            ));
            return;
        };

        if mode == expected {
            return;
        }

        if dry_run {
            println!("would chmod {}: {mode:o}→{expected:o}", path.display());
            report.changed += 1;
            return;
        }

        match fs::set_permissions(path, fs::Permissions::from_mode(expected)) {
            Ok(()) => {
                println!("chmod {}: {mode:o}→{expected:o}", path.display());
                report.changed += 1;
            }
            Err(error) => report.refused.push(format!(
                "{}: chmod {mode:o}→{expected:o} failed: {error}",
                path.display()
            )),
        }
    }

    fn current_uid() -> Option<u32> {
        unsafe extern "C" {
            fn getuid() -> u32;
        }
        Some(unsafe { getuid() })
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::fs::{self, File};
        use std::os::unix::fs::PermissionsExt;
        use std::time::{SystemTime, UNIX_EPOCH};

        #[test]
        fn dry_run_reports_without_changing_modes() {
            let root = temp_dir("dry-run");
            let projects = root.join("projects");
            let run = projects.join("proj/runs/run-1");
            fs::create_dir_all(&run).expect("dirs");
            let state = run.join("state.json");
            fs::write(&state, "{}").expect("state");
            fs::set_permissions(&projects, fs::Permissions::from_mode(0o755))
                .expect("projects perms");
            fs::set_permissions(&state, fs::Permissions::from_mode(0o644)).expect("state perms");

            let report = migrate_projects_dir(&projects, true).expect("dry run");

            assert_eq!(report.changed, 5);
            assert!(report.refused.is_empty());
            assert_eq!(mode(&projects), 0o755);
            assert_eq!(mode(&state), 0o644);
            fs::remove_dir_all(root).ok();
        }

        #[test]
        fn migrate_sets_dirs_0700_and_files_0600() {
            let root = temp_dir("migrate");
            let projects = root.join("projects");
            let run = projects.join("proj/runs/run-1");
            fs::create_dir_all(&run).expect("dirs");
            let state = run.join("state.json");
            fs::write(&state, "{}").expect("state");
            for dir in [
                &projects,
                &projects.join("proj"),
                &projects.join("proj/runs"),
                &run,
            ] {
                fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).expect("dir perms");
            }
            fs::set_permissions(&state, fs::Permissions::from_mode(0o644)).expect("state perms");

            let report = migrate_projects_dir(&projects, false).expect("migrate");

            assert_eq!(report.changed, 5);
            assert!(report.refused.is_empty());
            for dir in [
                &projects,
                &projects.join("proj"),
                &projects.join("proj/runs"),
                &run,
            ] {
                assert_eq!(mode(dir), 0o700, "{}", dir.display());
            }
            assert_eq!(mode(&state), 0o600);
            fs::remove_dir_all(root).ok();
        }

        #[test]
        fn refuses_group_writable_paths() {
            let root = temp_dir("refuse");
            let projects = root.join("projects");
            fs::create_dir_all(&projects).expect("dirs");
            let file = projects.join("state.json");
            File::create(&file).expect("file");
            fs::set_permissions(&file, fs::Permissions::from_mode(0o660)).expect("file perms");

            let report = migrate_projects_dir(&projects, false).expect("migrate");

            assert_eq!(mode(&file), 0o660);
            assert_eq!(report.refused.len(), 1);
            assert!(report.refused[0].contains("group/other write bits"));
            fs::remove_dir_all(root).ok();
        }

        fn mode(path: &Path) -> u32 {
            fs::symlink_metadata(path)
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777
        }

        fn temp_dir(label: &str) -> PathBuf {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            env::temp_dir().join(format!("vstack-flightdeck-migrate-{label}-{nonce}"))
        }
    }
}
