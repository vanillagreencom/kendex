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
        self.write_hook_for_event(name, "PreToolUse");
    }

    fn write_hook_for_event(&self, name: &str, event: &str) {
        let dir = self.source.join("hooks");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(format!("{name}.sh")),
            format!(
                "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: {event}\n# matcher: Bash\n# description: {name}\n# ---\nexit 0\n"
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

    /// `check` WITHOUT `--offline` — the session-start path, which may
    /// background a cache refresh but must never wait on one.
    fn check_online(&self, args: &[&str]) -> Output {
        self.vstack()
            .arg("check")
            .args(["--scope", "project"])
            .args(args)
            .output()
            .unwrap()
    }

    /// A cache directory shaped like a clone of `origin`, with a `.git` that
    /// is not a repository: any fetch attempt fails fast, and the recorded
    /// origin is what makes the cache resolvable at all.
    fn fake_cache(&self, key: &str, origin: &str) -> PathBuf {
        let dir = self.home.join(".vstack").join("cache").join(key);
        fs::create_dir_all(dir.join(".git")).unwrap();
        fs::write(
            dir.join(".git").join("config"),
            format!("[remote \"origin\"]\n\turl = {origin}\n"),
        )
        .unwrap();
        dir
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
    for hostile in ["../escape", "/tmp/escape", "a/b", "-escape"] {
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
        vec!["-escape", "../escape", "/tmp/escape", "a/b"],
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

/// VST-258 round 3: the session-start check never touches the network. A
/// remote source that is due for a refresh and unreachable must not cost the
/// session anything — the fetch is handed to a detached process and the check
/// answers from what is on disk.
#[test]
fn a_due_but_unreachable_remote_never_delays_the_check() {
    let sb = Sandbox::new("check-no-network");
    // A cache that resolves (origin recorded) but can never fetch, holding a
    // real source tree so the scope itself stays clean.
    let cache = sb.fake_cache("github.com_owner_repo", "https://github.com/owner/repo.git");
    let skill = cache.join("skills").join("alpha");
    fs::create_dir_all(&skill).unwrap();
    // Two item roots is what makes a directory a vstack source.
    fs::create_dir_all(cache.join("agents")).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: alpha\ndescription: alpha\n---\nbody\n",
    )
    .unwrap();
    let output = sb
        .vstack()
        .args([
            "add",
            "owner/repo",
            "--skill",
            "alpha",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "add: {}", text(&output.stderr));
    // No stamp, so the cache is due on the very next check.
    let stamp = cache.join(".git").join("vstack-fetch-stamp");
    let _ = fs::remove_file(&stamp);

    let started = std::time::Instant::now();
    let quiet = sb.check_online(&["--quiet"]);
    let elapsed = started.elapsed();
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "session-start check must not wait on the network: took {elapsed:?}"
    );
    assert_eq!(
        quiet.status.code(),
        Some(0),
        "nothing local drifted: {}",
        text(&quiet.stderr)
    );

    // The refresh was handed off: the detached process writes the stamp.
    let mut recorded = String::new();
    for _ in 0..100 {
        if let Ok(content) = fs::read_to_string(&stamp) {
            recorded = content;
            if recorded.starts_with("failed") {
                break;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    assert!(
        recorded.starts_with("failed"),
        "the detached refresh must record its outcome, got {recorded:?}"
    );

    // The next check reads that outcome — offline too, since it is a disk
    // read — and one failure is reported without being drift.
    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let failures = parsed["cache_refresh_failures"].as_array().unwrap();
    assert_eq!(failures.len(), 1, "{parsed}");
    assert_eq!(failures[0]["source"], "owner/repo");
    assert_eq!(failures[0]["persistent"], false);
    assert_eq!(parsed["drift"], false);
    assert_eq!(json.status.code(), Some(0));
}

/// A hook or agent installed into several harnesses is present only when
/// every recorded harness still has its artifact.
#[test]
fn a_missing_artifact_in_one_harness_of_several_is_drift() {
    let sb = Sandbox::new("check-multi-harness");
    sb.write_agent("rust");
    sb.write_hook("guard");
    let install = |flag: &str, name: &str| {
        let output = sb
            .vstack()
            .args([
                "add",
                sb.source.to_str().unwrap(),
                flag,
                name,
                "--harness",
                "claude,cursor,opencode",
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
    };
    install("--agent", "rust");
    install("--hook", "guard");

    let clean = sb.check(&["--quiet"]);
    assert_eq!(clean.status.code(), Some(0), "{}", text(&clean.stderr));
    assert!(clean.stderr.is_empty(), "{}", text(&clean.stderr));

    // Delete the CURSOR artifacts only; the Claude ones stay.
    let cursor_rule = sb.project.join(".cursor/rules/safety-guard.mdc");
    let cursor_agent = sb.project.join(".cursor/rules/rust.mdc");
    assert!(
        cursor_rule.exists() && cursor_agent.exists(),
        "add must have written both"
    );
    fs::remove_file(&cursor_rule).unwrap();
    fs::remove_file(&cursor_agent).unwrap();

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("missing from disk"), "{err}");
    assert!(err.contains("guard (hook)"), "{err}");
    assert!(err.contains("rust (agent)"), "{err}");
    // The per-harness detail rides along, so a partial miss is not read as
    // "everything is gone".
    assert!(
        err.contains("cursor"),
        "detail must name the harness: {err}"
    );

    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let phantom = parsed["scopes"][0]["phantom"].as_array().unwrap();
    assert_eq!(phantom.len(), 2, "{parsed}");
    assert!(
        phantom
            .iter()
            .all(|p| p["detail"].as_str().unwrap_or_default().contains("cursor")),
        "{parsed}"
    );
}

/// The JSON contract for an unverifiable source, pinned at the process
/// boundary: consumers branch on these field names.
#[test]
fn an_unreadable_source_reports_a_tagged_json_shape() {
    let sb = Sandbox::new("check-unreadable-json");
    sb.write_skill("alpha", "one");
    sb.install("alpha");
    // The whole skills root moves away: nothing about the entry can be
    // verified, and `refresh` cannot fix it.
    fs::rename(sb.source.join("skills"), sb.source.join("skills-moved")).unwrap();

    let json = sb.check(&["--json"]);
    assert_eq!(json.status.code(), Some(1), "{}", text(&json.stderr));
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let issues = parsed["scopes"][0]["source_issues"].as_array().unwrap();
    assert_eq!(issues.len(), 1, "{parsed}");
    let issue = &issues[0];
    assert_eq!(issue["problem"], "unreadable");
    assert_eq!(issue["entries"][0], "alpha");
    assert!(
        issue["reasons"][0]
            .as_str()
            .unwrap_or_default()
            .contains("skills"),
        "{parsed}"
    );
    assert!(
        issue.get("failures").is_none(),
        "each variant serializes only its own fields: {parsed}"
    );
    // And it never prescribes a refresh that cannot help.
    let quiet = sb.check(&["--quiet"]);
    let err = text(&quiet.stderr);
    assert!(err.contains("cannot be inventoried"), "{err}");
    assert!(!err.contains("vstack refresh"), "{err}");
}

/// A Codex hook whose event has no native equivalent installs as prose inside
/// agent TOMLs. In a scope with no Codex agents there is nothing to write —
/// and nothing to miss, so it must not read as permanent drift no `add` or
/// `refresh` could ever clear.
#[test]
fn a_codex_prose_fallback_hook_is_not_drift_before_an_agent_exists() {
    let sb = Sandbox::new("check-codex-prose");
    // TaskCompleted has no Codex equivalent, so this installs as prose only.
    sb.write_hook_for_event("guard", "TaskCompleted");
    sb.write_agent("rust");
    let add = |args: &[&str]| {
        let output = sb
            .vstack()
            .args(["add", sb.source.to_str().unwrap()])
            .args(args)
            .args(["--harness", "codex", "--no-auto-skills", "-y"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stderr).into_owned()
    };

    // No Codex agent anywhere yet.
    let log = add(&["--hook", "guard"]);
    assert!(
        log.contains("no artifact yet"),
        "add must say it wrote nothing rather than claim a plain success: {log}"
    );
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(
        quiet.status.code(),
        Some(0),
        "an unwritable-yet fallback is not drift: {}",
        text(&quiet.stderr)
    );
    assert!(quiet.stderr.is_empty(), "{}", text(&quiet.stderr));

    // Installing a Codex agent gives the fallback somewhere to live; the lock
    // entry is what drives that, so it must still record codex.
    add(&["--agent", "rust"]);
    let toml = sb.project.join(".codex/agents/rust.toml");
    let content = fs::read_to_string(&toml).unwrap();
    assert!(content.contains("## Safety: guard"), "{content}");
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0), "{}", text(&quiet.stderr));

    // Control: with an agent present, losing the prose IS drift.
    fs::write(
        &toml,
        content.replace("## Safety: guard", "## Safety: removed"),
    )
    .unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("guard (hook)"), "{err}");
}
