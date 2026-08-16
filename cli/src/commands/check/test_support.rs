//! Fixtures shared by the `check` tests in this module tree.

use super::*;
use crate::config::{InstallMethod, LockEntry};
use crate::test_util::{with_home_and_config, with_project_root};
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn tmpdir(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "vstack-check-{label}-{}-{nanos}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

pub(super) fn write_skill(source: &Path, name: &str, body: &str) {
    let dir = source.join("skills").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name} skill\n---\n\n{body}\n"),
    )
    .unwrap();
}

pub(super) fn write_hook(source: &Path, name: &str) {
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::write(
        source.join("hooks").join(format!("{name}.sh")),
        format!(
            "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# matcher: Bash\n# description: {name}\n# ---\nexit 0\n"
        ),
    )
    .unwrap();
}

pub(super) fn write_agent(source: &Path, name: &str) {
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::write(
        source.join("agents").join(format!("{name}.md")),
        format!(
            "---\nname: {name}\ndescription: {name}\nmodel: sonnet\nrole: engineer\n---\n\nbody\n"
        ),
    )
    .unwrap();
}

/// Lock entry with the hash the source has RIGHT NOW, so it reads as
/// current until the source changes.
pub(super) fn locked(source: &Path, kind: ItemKind, name: &str) -> LockEntry {
    let mut entry = LockEntry {
        name: name.into(),
        kind,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-08-15T00:00:00Z".into(),
        source_hash: String::new(),
    };
    entry.source_hash = config::compute_source_hash(&entry);
    entry
}

/// Materialize a project-scope skill so it is neither phantom nor orphaned.
pub(super) fn install_skill_on_disk(project: &Path, name: &str) {
    let dir = project.join(".agents").join("skills").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("SKILL.md"), "installed\n").unwrap();
    std::fs::write(dir.join(".vstack-refreshed"), "").unwrap();
}

pub(super) fn names(items: &[Item]) -> Vec<&str> {
    items.iter().map(|i| i.name.as_str()).collect()
}

pub(super) fn with_sandbox<R>(label: &str, body: impl FnOnce(&Path, &Path) -> R) -> R {
    let root = tmpdir(label);
    let home = root.join("home");
    let config_dir = root.join("config");
    let project = root.join("project");
    let source = root.join("source");
    for dir in [&home, &config_dir, &project, &source] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let result = with_home_and_config(&home, &config_dir, || {
        with_project_root(&project, || body(&project, &source))
    });
    let _ = std::fs::remove_dir_all(&root);
    result
}
