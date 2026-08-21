//! `kendex check --catalog` as a CI gate: it must fail on content that
//! would not install, and it must pass on what `kendex init` writes.
//! HarnessKit's equivalent always exited 0, which made it unusable for
//! exactly this.
#![cfg(unix)]

use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn fixture() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/bad-catalog")
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_seeded_bad_catalog_fails_the_check() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = fixture();
    let output = kendex(
        home,
        home,
        &["check", "--catalog", catalog.to_str().unwrap()],
    );

    assert!(!output.status.success(), "a broken catalog must not pass");
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    // Both passes have to have run: structure and safety.
    assert!(said.contains("[error] safety:"), "{said}");
    assert!(said.contains("rce"), "{said}");
    assert!(said.contains("prompt-injection"), "{said}");
    assert!(said.contains("credential-theft"), "{said}");
    // The capitalised agent name is a loader problem, not a safety one.
    assert!(said.contains("lowercase letters"), "{said}");
    // Every finding travels with its fix.
    assert!(said.contains("    fix: "), "{said}");
}

/// `--json` wraps the same findings in the versioned envelope the indexer
/// consumes: schema, typed findings, the counts, and one `ok` verdict.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn the_json_envelope_carries_typed_findings_and_the_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = home.join("catalog");
    std::fs::create_dir_all(catalog.join("agents")).unwrap();
    // A capitalised agent name is breakage: loaders that demand lowercase
    // cannot hold it.
    std::fs::write(
        catalog.join("agents/Helper.md"),
        "---\ndescription: helps\n---\nBody.\n",
    )
    .unwrap();
    // Naming a credential file is a warning-grade safety finding, so this
    // skill warns without being held back.
    std::fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    std::fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github helper\n---\nRead ~/.aws/credentials to pick a profile.\n",
    )
    .unwrap();

    let output = kendex(
        home,
        home,
        &["check", "--catalog", catalog.to_str().unwrap(), "--json"],
    );
    assert!(!output.status.success());
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout is the JSON envelope");
    assert_eq!(json["schema"], 1);
    assert_eq!(json["ok"], false);
    assert!(json["breakage"].as_u64().unwrap() >= 1, "{json}");
    assert_eq!(json["warned"], 1, "{json}");
    assert_eq!(json["held_back"], 0, "{json}");
    let findings = json["findings"].as_array().unwrap();
    let name_breakage = findings
        .iter()
        .find(|f| f["severity"] == "error" && f["rule"].is_null())
        .unwrap_or_else(|| panic!("{json}"));
    assert_eq!(name_breakage["kind"], "agent");
    assert_eq!(name_breakage["name"], "Helper");
    assert_eq!(name_breakage["file"], "agents/Helper.md");
    let safety = findings
        .iter()
        .find(|f| f["rule"] == "credential-theft")
        .unwrap_or_else(|| panic!("{json}"));
    assert_eq!(safety["pass"], "safety");
    assert_eq!(safety["kind"], "skill");
    assert_eq!(safety["name"], "gh");
}

/// The scaffolding kendex writes must survive kendex's own gate. A starting
/// point that fails the check on its first run teaches people to ignore it.
#[test]
#[allow(clippy::unwrap_used)]
fn what_init_scaffolds_passes_the_check() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = home.join("catalog");
    std::fs::create_dir_all(&catalog).unwrap();

    for (name, kind) in [
        ("reviewer", "agent"),
        ("release-notes", "skill"),
        ("guard-bash", "hook"),
    ] {
        let output = kendex(home, &catalog, &["init", name, "--kind", kind]);
        assert!(
            output.status.success(),
            "init {kind} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let output = kendex(
        home,
        home,
        &["check", "--catalog", catalog.to_str().unwrap()],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    assert!(said.contains("3 item(s)"), "{said}");
    assert!(said.contains("0 breakage"), "{said}");
    assert!(said.contains("0 held back"), "{said}");
}
