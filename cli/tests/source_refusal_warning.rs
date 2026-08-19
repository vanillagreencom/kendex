//! A refused source has two report channels: the structured one every
//! `refresh` entry is reported through, and a warning printed where resolution
//! happens. `verify` and `check` build no structured report, so for them the
//! warning is the only thing that tells the user why their source produced
//! nothing.

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

#[test]
fn verify_tells_the_user_why_a_source_was_refused() {
    let root = unique_temp_dir("source-refusal-warning");
    let project = root.join("project");
    let home = root.join("home");
    fs::create_dir_all(project.join(".claude/skills/demo")).unwrap();
    fs::create_dir_all(project.join(".agents/skills/demo")).unwrap();
    fs::create_dir_all(&home).unwrap();
    let skill = "---\nname: demo\ndescription: Demo\nlicense: MIT\n---\n# Demo\n";
    fs::write(project.join(".claude/skills/demo/SKILL.md"), skill).unwrap();
    fs::write(project.join(".agents/skills/demo/SKILL.md"), skill).unwrap();
    // Refused before any git runs, so the case needs no cache entry of its own.
    fs::write(
        project.join(".vstack-lock.json"),
        r#"{
  "version": 1,
  "entries": {
    "demo": {
      "name": "demo",
      "kind": "skill",
      "source": "https://user:ghp_TESTTOKEN@github.com/owner/repo.git",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z",
      "source_hash": "deadbeef"
    }
  }
}
"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_vstack"))
        .arg("verify")
        .current_dir(&project)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("PI_CODING_AGENT_DIR", root.join("pi"))
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();

    assert!(
        stderr.contains("credential-bearing remote source URLs are not supported"),
        "the refusal must reach the user\nstderr:\n{stderr}\nstdout:\n{stdout}"
    );
    assert!(stderr.contains("<redacted>"), "{stderr}");
    assert!(!stderr.contains("ghp_TESTTOKEN"), "{stderr}");
    assert!(!stdout.contains("ghp_TESTTOKEN"), "{stdout}");

    let _ = fs::remove_dir_all(root);
}

/// The three commands that look at a locked item's source must name the same
/// cause and the same remedy for the same state. `check` reported `outdated`
/// and `verify` a bare `src:!` for a clone that is simply not on this machine —
/// neither of which `vstack add` is obviously the answer to.
#[test]
fn check_and_verify_name_the_same_cause_as_refresh() {
    let root = unique_temp_dir("unresolved-source-diagnostics");
    let project = root.join("project");
    let home = root.join("home");
    fs::create_dir_all(project.join(".claude/skills/demo")).unwrap();
    fs::create_dir_all(project.join(".agents/skills/demo")).unwrap();
    fs::create_dir_all(&home).unwrap();
    let skill = "---\nname: demo\ndescription: Demo\nlicense: MIT\n---\n# Demo\n";
    fs::write(project.join(".claude/skills/demo/SKILL.md"), skill).unwrap();
    fs::write(project.join(".agents/skills/demo/SKILL.md"), skill).unwrap();
    fs::write(
        project.join(".vstack-lock.json"),
        r#"{
  "version": 1,
  "entries": {
    "demo": {
      "name": "demo",
      "kind": "skill",
      "source": "owner/repo",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z",
      "source_hash": "deadbeef"
    }
  }
}
"#,
    )
    .unwrap();

    // The cause and the command, asserted separately rather than as one
    // substring: `check` builds a report and spends its own clause on the
    // remedy, while `verify` and `refresh` print a line that carries both.
    // What the contract requires is that all three name the same two things.
    let expected = ["remote cache not present", "`vstack add owner/repo`"];
    for command in ["check", "verify", "refresh"] {
        let output = Command::new(env!("CARGO_BIN_EXE_vstack"))
            .arg(command)
            .current_dir(&project)
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("PI_CODING_AGENT_DIR", root.join("pi"))
            .output()
            .unwrap();
        let combined = String::from_utf8_lossy(&output.stderr).into_owned()
            + &String::from_utf8_lossy(&output.stdout);
        for want in expected {
            assert!(
                combined.contains(want),
                "vstack {command} omits {want}:\n{combined}"
            );
        }
        assert!(
            !combined.contains("outdated"),
            "vstack {command} calls an unresolved source outdated:\n{combined}"
        );
    }

    let _ = fs::remove_dir_all(root);
}

/// A source vstack REFUSED is not one that is absent, and `vstack add` is not
/// its remedy — running it refuses again. All three commands must name the
/// refusal itself, as `refresh` already did.
#[test]
fn check_and_verify_report_a_refusal_rather_than_the_re_clone_advice() {
    let root = unique_temp_dir("refused-source-diagnostics");
    let project = root.join("project");
    let home = root.join("home");
    fs::create_dir_all(project.join(".claude/skills/demo")).unwrap();
    fs::create_dir_all(project.join(".agents/skills/demo")).unwrap();
    fs::create_dir_all(&home).unwrap();
    let skill = "---\nname: demo\ndescription: Demo\nlicense: MIT\n---\n# Demo\n";
    fs::write(project.join(".claude/skills/demo/SKILL.md"), skill).unwrap();
    fs::write(project.join(".agents/skills/demo/SKILL.md"), skill).unwrap();
    // Refused before any git runs, so the case needs no cache entry.
    fs::write(
        project.join(".vstack-lock.json"),
        r#"{
  "version": 1,
  "entries": {
    "demo": {
      "name": "demo",
      "kind": "skill",
      "source": "git://github.com/owner/repo.git",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z",
      "source_hash": "deadbeef"
    }
  }
}
"#,
    )
    .unwrap();

    for command in ["check", "verify", "refresh"] {
        let output = Command::new(env!("CARGO_BIN_EXE_vstack"))
            .arg(command)
            .current_dir(&project)
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("PI_CODING_AGENT_DIR", root.join("pi"))
            .output()
            .unwrap();
        let combined = String::from_utf8_lossy(&output.stderr).into_owned()
            + &String::from_utf8_lossy(&output.stdout);
        assert!(
            combined.contains("transport `git` is not supported"),
            "vstack {command} must name the refusal:\n{combined}"
        );
        assert!(
            !combined.contains("remote cache not present"),
            "vstack {command} sends the user back to the refusal:\n{combined}"
        );
        assert!(
            !combined.contains("outdated"),
            "vstack {command} calls a refused source outdated:\n{combined}"
        );
    }

    let _ = fs::remove_dir_all(root);
}
