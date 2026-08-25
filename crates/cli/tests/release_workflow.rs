//! release.yml runs only on tags, so its build and staging steps are never
//! exercised by a pull request. Both build commands must emit into the
//! per-target output dir and the staging step must read from that same
//! dir, keyed by the one matrix expression rather than a literal triple.

use std::fs;
use std::path::Path;

const TARGET_EXPR: &str = "${{ matrix.target }}";

#[allow(clippy::unwrap_used)]
fn workflow() -> String {
    fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows/release.yml"),
    )
    .unwrap()
}

/// The lines of one step: from its first line to the next `- ` item at the
/// same indentation.
fn step<'a>(workflow: &'a str, first_line_marker: &str) -> Vec<&'a str> {
    let mut lines = workflow
        .lines()
        .skip_while(|l| !l.contains(first_line_marker));
    let first = lines
        .next()
        .unwrap_or_else(|| panic!("no step line containing {first_line_marker}"));
    let indent = first.len() - first.trim_start().len();
    let mut body = vec![first];
    for line in lines {
        let this_indent = line.len() - line.trim_start().len();
        if this_indent == indent && line.trim_start().starts_with("- ") {
            break;
        }
        body.push(line);
    }
    body
}

/// The body of a step's `run: |` block, dedented so bash can run it.
fn run_script(step_lines: &[&str]) -> String {
    let mut lines = step_lines
        .iter()
        .skip_while(|l| l.trim() != "run: |")
        .skip(1)
        .peekable();
    let indent = lines
        .peek()
        .map(|l| l.len() - l.trim_start().len())
        .unwrap_or_else(|| panic!("step has no run: | body"));
    lines
        .map(|l| l.get(indent..).unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n")
}

const APPLE_SECRETS: [&str; 7] = [
    "CERT", "CERT_PW", "IDENTITY", "TEAM", "ISSUER", "KEY_ID", "KEY_P8",
];

/// Runs the macOS signing stage with exactly `set` secrets non-empty and
/// returns the exit code and what it wrote to GITHUB_ENV.
#[allow(clippy::unwrap_used)]
fn stage_signing(set: &[&str]) -> (i32, String) {
    let dir = tempfile::tempdir().unwrap();
    let env_file = dir.path().join("github.env");
    let workflow = workflow();
    let script = run_script(&step(&workflow, "name: Stage macOS signing environment"));
    let mut cmd = std::process::Command::new("bash");
    cmd.arg("-c")
        .arg(&script)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("RUNNER_TEMP", dir.path())
        .env("GITHUB_ENV", &env_file);
    for name in APPLE_SECRETS {
        // A wrapped certificate carries newlines; tauri wants it flat.
        let value = if name == "CERT" { "abc\ndef\n" } else { "v" };
        cmd.env(name, if set.contains(&name) { value } else { "" });
    }
    let status = cmd.status().unwrap();
    let exported = fs::read_to_string(&env_file).unwrap_or_default();
    (status.code().unwrap_or(-1), exported)
}

#[cfg(unix)]
#[test]
fn signing_env_is_exported_only_for_a_complete_secret_set() {
    let (code, exported) = stage_signing(&APPLE_SECRETS);
    assert_eq!(code, 0, "all seven secrets set must succeed");
    for var in [
        "APPLE_CERTIFICATE=abcdef\n",
        "APPLE_CERTIFICATE_PASSWORD=",
        "APPLE_SIGNING_IDENTITY=",
        "APPLE_TEAM_ID=",
        "APPLE_API_ISSUER=",
        "APPLE_API_KEY=",
        "APPLE_API_KEY_PATH=",
    ] {
        assert!(exported.contains(var), "{var} missing from:\n{exported}");
    }

    let (code, exported) = stage_signing(&[]);
    assert_eq!(code, 0, "no secrets must build unsigned");
    assert!(
        exported.is_empty(),
        "no secrets exported anything:\n{exported}"
    );

    for missing in APPLE_SECRETS {
        let set: Vec<&str> = APPLE_SECRETS
            .into_iter()
            .filter(|s| *s != missing)
            .collect();
        let (code, exported) = stage_signing(&set);
        assert_ne!(code, 0, "missing {missing} must fail the lane");
        assert!(
            exported.is_empty(),
            "missing {missing} exported:\n{exported}"
        );
    }
}

fn lane_triples(workflow: &str) -> Vec<&str> {
    workflow
        .lines()
        .filter_map(|l| l.trim().strip_prefix("target: "))
        .collect()
}

#[test]
fn both_build_commands_emit_into_the_per_target_dir() {
    let workflow = workflow();
    for tool in ["cargo build", "tauri build"] {
        let line = workflow
            .lines()
            .find(|l| l.contains(tool))
            .unwrap_or_else(|| panic!("release.yml has no {tool} step"));
        assert!(
            line.contains(&format!("--target {TARGET_EXPR}")),
            "{tool} must pass --target {TARGET_EXPR}: {line}"
        );
    }
}

#[test]
fn staging_reads_only_the_per_target_output_dir() {
    let workflow = workflow();
    let stage = step(&workflow, "name: Stage release assets");
    let mut target_paths = 0;
    for line in &stage {
        for (idx, _) in line.match_indices("target/") {
            // `${{ matrix.target }}` itself contains no slash, so every
            // `target/` here is a filesystem path into the build output.
            let rest = &line[idx..];
            assert!(
                rest.starts_with(&format!("target/{TARGET_EXPR}/release")),
                "staging path is not keyed by the matrix target: {}",
                line.trim()
            );
            target_paths += 1;
        }
    }
    assert!(
        target_paths > 0,
        "staging step never reads the build output dir"
    );
}

#[test]
fn no_lane_triple_is_hardcoded_into_build_or_staging() {
    let workflow = workflow();
    let build_lines: Vec<&str> = workflow
        .lines()
        .filter(|l| l.contains("cargo build") || l.contains("tauri build"))
        .collect();
    let stage = step(&workflow, "name: Stage release assets");
    for triple in lane_triples(&workflow) {
        for line in build_lines.iter().chain(stage.iter()) {
            assert!(
                !line.contains(triple),
                "literal {triple} in a step that must use {TARGET_EXPR}: {}",
                line.trim()
            );
        }
    }
}
