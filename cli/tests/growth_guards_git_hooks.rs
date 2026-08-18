//! `vstack add` / `vstack refresh` arm the growth-guards git shims in a
//! project, so the guard chain runs for every tool that commits — not only
//! the harnesses with their own hook system.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

struct Sandbox {
    root: PathBuf,
    source: PathBuf,
    project: PathBuf,
    home: PathBuf,
    xdg: PathBuf,
    pi_dir: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let root = unique_temp_dir(name);
        let source = root.join("source");
        let project = root.join("project");
        let home = root.join("home");
        let xdg = root.join("xdg");
        let pi_dir = root.join("pi");
        for dir in [&project, &home, &xdg, &pi_dir] {
            fs::create_dir_all(dir).unwrap();
        }
        // A source carrying the real skill: the shims under test are the ones
        // this repo ships, not a stub.
        fs::create_dir_all(source.join("skills")).unwrap();
        let skill = Path::new(env!("CARGO_MANIFEST_DIR")).join("../skills/growth-guards");
        copy_tree(&skill, &source.join("skills/growth-guards"));
        fs::write(source.join("vstack.toml"), "[agent-skills]\n").unwrap();
        Self {
            root,
            source,
            project,
            home,
            xdg,
            pi_dir,
        }
    }

    fn vstack(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vstack"));
        command
            .current_dir(&self.project)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg)
            .env("PI_CODING_AGENT_DIR", &self.pi_dir);
        command
    }

    fn git_init(&self) {
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.project)
            .args(["-c", "init.defaultBranch=main", "init", "-q"])
            .status()
            .unwrap();
        assert!(status.success(), "git init failed");
    }

    fn add(&self) -> String {
        let output = self
            .vstack()
            .arg("add")
            .arg(&self.source)
            .args(["--skill", "growth-guards", "--harness", "claude-code", "-y"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "vstack add failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stderr).into_owned()
    }

    fn refresh(&self) -> String {
        let output = self
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "vstack refresh failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stderr).into_owned()
    }

    fn try_remove(&self) -> std::process::Output {
        self.vstack()
            .args(["remove", "growth-guards", "--scope", "project"])
            .output()
            .unwrap()
    }

    fn remove(&self) -> String {
        let output = self.try_remove();
        assert!(
            output.status.success(),
            "vstack remove failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stderr).into_owned()
    }

    fn hook(&self, name: &str) -> PathBuf {
        self.project.join(".git/hooks").join(name)
    }

    fn check(&self, args: &[&str]) -> std::process::Output {
        self.vstack()
            .args(["check", "--offline", "--scope", "project"])
            .args(args)
            .output()
            .unwrap()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn add_and_refresh_arm_the_git_shims_in_a_git_project() {
    let sandbox = Sandbox::new("gg-hooks-git");
    sandbox.git_init();

    let added = sandbox.add();
    assert!(
        added.contains("growth-guards git hooks"),
        "add did not report the hook install\n{added}"
    );
    for hook in ["vstack-guards", "pre-commit", "commit-msg"] {
        assert!(
            sandbox.hook(hook).is_file(),
            "{hook} was not installed by add"
        );
    }
    let pre_commit = fs::read_to_string(sandbox.hook("pre-commit")).unwrap();
    assert!(pre_commit.contains("vstack-guards"), "{pre_commit}");

    // Repairing on refresh is the point: a shim deleted after install comes
    // back without a re-add.
    fs::remove_file(sandbox.hook("pre-commit")).unwrap();
    let refreshed = sandbox.refresh();
    assert!(
        refreshed.contains("armed"),
        "refresh did not report the hook install\n{refreshed}"
    );
    assert_eq!(
        fs::read_to_string(sandbox.hook("pre-commit")).unwrap(),
        pre_commit,
        "refresh must restore the shim exactly"
    );

    // core.hooksPath would redirect every hook and silently disable the
    // repo's own; the install must never set it.
    let config = Command::new("git")
        .arg("-C")
        .arg(&sandbox.project)
        .args(["config", "--get", "core.hooksPath"])
        .output()
        .unwrap();
    assert!(
        String::from_utf8_lossy(&config.stdout).trim().is_empty(),
        "the install set core.hooksPath"
    );
}

/// #1482: the drift the shims can suffer — another writer replacing the hook
/// file and silently dropping the marked line — must be visible to the drift
/// command, not only to someone who notices an ungated commit.
#[test]
fn vstack_check_folds_in_the_shim_verdict() {
    let sandbox = Sandbox::new("gg-hooks-check");
    sandbox.git_init();
    sandbox.add();

    let clean = sandbox.check(&[]);
    let stderr = String::from_utf8_lossy(&clean.stderr);
    assert!(
        clean.status.success(),
        "an armed repository must check clean\n{stderr}"
    );
    assert!(
        stderr.contains("git hooks: armed"),
        "the listing must show the verdict\n{stderr}"
    );

    // A second hook manager's install step: the file is replaced whole, still
    // a perfectly runnable hook, only the guard line is gone.
    let hook = sandbox.hook("pre-commit");
    fs::write(&hook, "#!/bin/sh\nexit 0\n").unwrap();
    let mut perms = fs::metadata(&hook).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
    fs::set_permissions(&hook, perms).unwrap();

    let drifted = sandbox.check(&[]);
    let stderr = String::from_utf8_lossy(&drifted.stderr);
    assert_eq!(
        drifted.status.code(),
        Some(1),
        "a disarmed shim is drift and must exit like it\n{stderr}"
    );
    assert!(stderr.contains("NOT armed"), "{stderr}");

    let json_run = sandbox.check(&["--json"]);
    assert_eq!(json_run.status.code(), Some(1));
    let report: serde_json::Value = serde_json::from_slice(&json_run.stdout).unwrap();
    assert_eq!(report["drift"], true, "{report}");
    let hooks = &report["scopes"][0]["git_hooks"];
    assert_eq!(hooks["state"], "unarmed", "{report}");
    assert!(
        hooks["detail"].as_str().unwrap().contains("guard line"),
        "{report}"
    );
}

/// Shims hidden behind a later `core.hooksPath` are armed-but-dormant: no
/// commit runs them, so `check` fails — with that state's own wording, not
/// the drifted one's.
#[test]
fn a_dormant_shim_behind_core_hooks_path_fails_check_with_its_own_wording() {
    let sandbox = Sandbox::new("gg-hooks-check-dormant");
    sandbox.git_init();
    sandbox.add();
    fs::create_dir_all(sandbox.project.join("myhooks")).unwrap();
    let status = Command::new("git")
        .arg("-C")
        .arg(&sandbox.project)
        .args(["config", "core.hooksPath", "myhooks"])
        .status()
        .unwrap();
    assert!(status.success());

    let out = sandbox.check(&[]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(1),
        "dormant shims gate nothing and must not check clean\n{stderr}"
    );
    assert!(
        stderr.contains("dormant") && stderr.contains("core.hooksPath"),
        "{stderr}"
    );
}

#[test]
fn a_non_git_project_is_skipped_with_a_note() {
    let sandbox = Sandbox::new("gg-hooks-nongit");

    let added = sandbox.add();
    assert!(
        added.contains("growth-guards git hooks: skipped"),
        "a non-git project must say why it was skipped\n{added}"
    );
    assert!(
        !sandbox.project.join(".git").exists(),
        "no git directory may be created"
    );
    let refreshed = sandbox.refresh();
    assert!(
        refreshed.contains("growth-guards git hooks: skipped"),
        "refresh must skip a non-git project too\n{refreshed}"
    );
}

#[test]
fn a_project_without_the_skill_is_left_alone() {
    let sandbox = Sandbox::new("gg-hooks-absent");
    sandbox.git_init();
    // Install nothing: the source's skill stays unselected.
    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--harness", "claude-code", "--copy", "-y", "--skill", ""])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stderr.contains("growth-guards git hooks"),
        "nothing should be reported when the skill is not installed\n{stderr}"
    );
    assert!(!sandbox.hook("pre-commit").exists());
}

#[test]
fn one_refresh_arms_a_project_whose_installed_skill_lacks_the_installer() {
    let sandbox = Sandbox::new("gg-hooks-adopt");
    sandbox.git_init();
    sandbox.add();

    // A project whose installed copy of the skill carries no installer, with
    // nothing armed: one refresh must both restore it and use it.
    let installed = sandbox
        .project
        .join(".agents/skills/growth-guards/scripts/install-git-hooks");
    fs::remove_file(&installed).unwrap();
    for hook in ["vstack-guards", "pre-commit", "commit-msg"] {
        let _ = fs::remove_file(sandbox.hook(hook));
    }

    let refreshed = sandbox.refresh();
    assert!(installed.is_file(), "refresh must restore the installer");
    assert!(
        sandbox.hook("pre-commit").is_file(),
        "the same refresh that brings in the installer must arm the shims\n{refreshed}"
    );
}

#[test]
fn removing_the_skill_disarms_the_shims() {
    let sandbox = Sandbox::new("gg-hooks-remove");
    sandbox.git_init();
    sandbox.add();
    assert!(sandbox.hook("pre-commit").is_file());

    let removed = sandbox.remove();
    assert!(
        removed.contains("growth-guards git hooks"),
        "remove did not report the disarm\n{removed}"
    );
    // Left behind, the shims fail closed and every later commit is blocked.
    for hook in ["vstack-guards", "pre-commit", "commit-msg"] {
        assert!(
            !sandbox.hook(hook).exists(),
            "{hook} survived the removal and would block every commit"
        );
    }
}

#[test]
fn a_removal_whose_shim_cleanup_fails_keeps_the_skill() {
    let sandbox = Sandbox::new("gg-hooks-remove-fails");
    sandbox.git_init();
    sandbox.add();

    // A delegate the uninstaller may not edit: symlinked out of the hooks
    // directory, still carrying the guard line.
    let elsewhere = sandbox.root.join("linked-pre-commit");
    fs::rename(sandbox.hook("pre-commit"), &elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, sandbox.hook("pre-commit")).unwrap();

    let output = sandbox.try_remove();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "removal must fail when the shims cannot be cleaned up\n{stderr}"
    );
    assert!(
        stderr.contains("was NOT removed"),
        "the failure must say the skill was kept\n{stderr}"
    );
    // Removing the skill on top of a live delegate would block every commit;
    // keeping it installed is the recoverable state.
    assert!(
        sandbox
            .project
            .join(".agents/skills/growth-guards/scripts/pre-commit")
            .exists(),
        "the skill must still be installed"
    );
    assert!(sandbox.hook("vstack-guards").is_file(), "helper kept");
}

#[test]
fn a_disk_only_install_still_has_its_shims_removed() {
    let sandbox = Sandbox::new("gg-hooks-diskonly");
    sandbox.git_init();
    sandbox.add();
    assert!(sandbox.hook("pre-commit").is_file());

    // Removal supports items the lock no longer records; the shims must go
    // with the files either way.
    let lock = sandbox.project.join(".vstack-lock.json");
    let text = fs::read_to_string(&lock).unwrap();
    let stripped: serde_json::Value = {
        let mut value: serde_json::Value = serde_json::from_str(&text).unwrap();
        if let Some(entries) = value.get_mut("entries").and_then(|e| e.as_object_mut()) {
            entries.remove("growth-guards");
        }
        value
    };
    fs::write(&lock, serde_json::to_string_pretty(&stripped).unwrap()).unwrap();

    sandbox.remove();
    for hook in ["vstack-guards", "pre-commit", "commit-msg"] {
        assert!(
            !sandbox.hook(hook).exists(),
            "{hook} survived a disk-only removal and would block every commit"
        );
    }
}
