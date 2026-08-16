//! VST-258: the `vstack check` process contract that the session-drift-check
//! hook and the Pi port branch on — exit 0 clean / 1 drift / 2 failed,
//! `--quiet` silent when clean, `--json` on stdout. Drives the built binary
//! against a hand-written lock and source; always `--offline`.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_target_tmp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

struct Sandbox {
    root: PathBuf,
    source: PathBuf,
    project: PathBuf,
    home: PathBuf,
    xdg: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let root = unique_target_tmp_dir(name);
        let source = root.join("source");
        let project = root.join("project");
        let home = root.join("home");
        let xdg = root.join("xdg");
        for dir in [&source, &project, &home, &xdg] {
            fs::create_dir_all(dir).unwrap();
        }
        // An empty lock pins the project root here: `project_root()` walks
        // up from CWD to the nearest lock, and CARGO_TARGET_TMPDIR sits
        // inside the vstack checkout, which has one of its own.
        fs::write(
            lock_path(&project),
            "{\n  \"version\": 1,\n  \"entries\": {}\n}\n",
        )
        .unwrap();
        Self {
            root,
            source,
            project,
            home,
            xdg,
        }
    }

    fn write_skill(&self, name: &str, body: &str) {
        let dir = self.source.join("skills").join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {name}\n---\n{body}\n"),
        )
        .unwrap();
    }

    fn write_agent(&self, name: &str) {
        let dir = self.source.join("agents");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(format!("{name}.md")),
            format!(
                "---\nname: {name}\ndescription: {name}\nmodel: sonnet\nrole: engineer\n---\nbody\n"
            ),
        )
        .unwrap();
    }

    fn write_hook(&self, name: &str) {
        let dir = self.source.join("hooks");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(format!("{name}.sh")),
            format!(
                "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# matcher: Bash\n# description: {name}\n# ---\nexit 0\n"
            ),
        )
        .unwrap();
    }

    /// Install `name` on disk and record it in the lock with the CURRENT
    /// source hash, computed by the binary itself via `add`.
    fn install(&self, name: &str) {
        self.install_kind("--skill", name);
    }

    fn install_kind(&self, flag: &str, name: &str) {
        let output = self
            .vstack()
            .args([
                "add",
                self.source.to_str().unwrap(),
                flag,
                name,
                "--harness",
                "claude",
                "--no-auto-skills",
                "-y",
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn vstack(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vstack"));
        command
            .current_dir(&self.project)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg);
        command
    }

    fn check(&self, args: &[&str]) -> Output {
        self.vstack()
            .arg("check")
            .args(["--offline", "--scope", "project"])
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

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn lock_path(project: &Path) -> PathBuf {
    project.join(".vstack-lock.json")
}

#[test]
fn clean_install_exits_zero_and_quiet_prints_nothing() {
    let sb = Sandbox::new("check-clean");
    sb.write_skill("alpha", "one");
    sb.install("alpha");

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0), "{}", text(&quiet.stderr));
    assert!(
        quiet.stderr.is_empty(),
        "quiet clean must be silent: {}",
        text(&quiet.stderr)
    );
    assert!(quiet.stdout.is_empty(), "{}", text(&quiet.stdout));

    let json = sb.check(&["--json"]);
    assert_eq!(json.status.code(), Some(0));
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(parsed["drift"], false);
    assert!(json.stderr.is_empty(), "{}", text(&json.stderr));

    // Control: the verbose report is not silent.
    let verbose = sb.check(&[]);
    assert_eq!(verbose.status.code(), Some(0));
    assert!(
        text(&verbose.stderr).contains("✓ alpha (skill)"),
        "{}",
        text(&verbose.stderr)
    );
}

#[test]
fn drifted_install_exits_one_with_report_on_stderr_and_json_on_stdout() {
    let sb = Sandbox::new("check-drift");
    sb.write_skill("alpha", "one");
    sb.install("alpha");
    sb.write_skill("alpha", "two"); // source moved on
    sb.write_skill("beta", "new"); // suggestion, not drift

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.starts_with("vstack drift — project scope:"), "{err}");
    assert!(err.contains("`vstack refresh`"), "{err}");
    assert!(
        err.contains("beta"),
        "suggestions ride along with drift: {err}"
    );
    assert!(quiet.stdout.is_empty());

    let json = sb.check(&["--json"]);
    assert_eq!(json.status.code(), Some(1));
    assert!(json.stderr.is_empty(), "{}", text(&json.stderr));
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(parsed["drift"], true);
    assert_eq!(parsed["scopes"][0]["outdated"][0]["name"], "alpha");
    assert_eq!(parsed["scopes"][0]["available"][0]["name"], "beta");
}

#[test]
fn suggestions_alone_exit_zero_and_stay_quiet() {
    let sb = Sandbox::new("check-suggest");
    sb.write_skill("alpha", "one");
    sb.install("alpha");
    sb.write_skill("beta", "new");

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0), "{}", text(&quiet.stderr));
    assert!(quiet.stderr.is_empty(), "{}", text(&quiet.stderr));

    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(parsed["drift"], false);
    assert_eq!(parsed["scopes"][0]["available"][0]["name"], "beta");
}

#[test]
fn corrupt_lock_exits_two() {
    let sb = Sandbox::new("check-corrupt");
    fs::write(lock_path(&sb.project), "{ not json").unwrap();
    for args in [&[][..], &["--quiet"][..], &["--json"][..]] {
        let output = sb.check(args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?}: {}",
            text(&output.stderr)
        );
        assert!(
            text(&output.stderr).contains("Error"),
            "{}",
            text(&output.stderr)
        );
    }
}

/// VST-258 review round 2: the phantom case must cover every kind. A source
/// hash that has not moved is not evidence the install is intact.
#[test]
fn a_deleted_agent_or_hook_install_is_drift_even_when_the_source_is_unchanged() {
    let sb = Sandbox::new("check-phantom-kinds");
    sb.write_skill("alpha", "one");
    sb.write_agent("rust");
    sb.write_hook("guard");
    sb.install("alpha");
    sb.install_kind("--agent", "rust");
    sb.install_kind("--hook", "guard");

    // Control: a complete install is clean and silent.
    let clean = sb.check(&["--quiet"]);
    assert_eq!(clean.status.code(), Some(0), "{}", text(&clean.stderr));
    assert!(clean.stderr.is_empty(), "{}", text(&clean.stderr));

    let agent = sb.project.join(".claude/agents/rust.md");
    let hook = sb.project.join(".claude/hooks/guard.sh");
    assert!(
        agent.exists() && hook.exists(),
        "add must have written both"
    );
    fs::remove_file(&agent).unwrap();
    fs::remove_file(&hook).unwrap();

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("missing from disk"), "{err}");
    assert!(err.contains("rust (agent)"), "{err}");
    assert!(err.contains("guard (hook)"), "{err}");

    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let phantom = parsed["scopes"][0]["phantom"].as_array().unwrap();
    let mut kinds: Vec<&str> = phantom
        .iter()
        .map(|p| p["kind"].as_str().unwrap())
        .collect();
    kinds.sort();
    assert_eq!(kinds, vec!["agent", "hook"], "{parsed}");
}

/// A lock entry whose name is not a single safe path component is never
/// resolved against the filesystem and never rendered back to the agent.
#[test]
fn a_traversal_lock_name_is_rejected_rather_than_resolved() {
    let sb = Sandbox::new("check-traversal");
    sb.write_skill("alpha", "one");
    sb.install("alpha");

    let raw = fs::read_to_string(lock_path(&sb.project)).unwrap();
    let mut lock: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let entry = lock["entries"]["alpha"].clone();
    for hostile in ["../escape", "/tmp/escape", "a/b", ".hidden"] {
        let mut copy = entry.clone();
        copy["name"] = serde_json::Value::String(hostile.to_string());
        lock["entries"][hostile] = copy;
    }
    fs::write(lock_path(&sb.project), lock.to_string()).unwrap();

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("<invalid name>"), "{err}");
    assert!(!err.contains("escape"), "never echoed verbatim: {err}");

    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let mut rejected: Vec<&str> = parsed["scopes"][0]["invalid_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["name"].as_str().unwrap())
        .collect();
    rejected.sort();
    assert_eq!(
        rejected,
        vec!["../escape", ".hidden", "/tmp/escape", "a/b"],
        "{parsed}"
    );
    // Control: the valid sibling still classifies normally.
    assert!(
        parsed["scopes"][0]["invalid_names"]
            .as_array()
            .unwrap()
            .iter()
            .all(|i| i["name"] != "alpha"),
        "{parsed}"
    );
}
