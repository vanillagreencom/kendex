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

/// Every signed artifact a full tag run leaves in `dist/`, one per lane.
const SIGNED_ARTIFACTS: [(&str, &str); 5] = [
    ("linux-x86_64", "kendex_5.1.0_amd64.AppImage"),
    ("linux-aarch64", "kendex_5.1.0_aarch64.AppImage"),
    ("darwin-x86_64", "kendex-x86_64-apple-darwin.app.tar.gz"),
    ("darwin-aarch64", "kendex-aarch64-apple-darwin.app.tar.gz"),
    ("windows-x86_64", "kendex_5.1.0_x64-setup.exe"),
];

/// Runs the manifest step over a `dist/` holding exactly `present`
/// artifacts, each beside its signature, and returns the exit code, the
/// `latest.json` it wrote, and what it said doing so.
#[allow(clippy::unwrap_used)]
fn write_manifest(present: &[&str]) -> (i32, String, String) {
    let dir = tempfile::tempdir().unwrap();
    let dist = dir.path().join("dist");
    fs::create_dir_all(&dist).unwrap();
    for artifact in present {
        fs::write(dist.join(artifact), "bytes").unwrap();
        fs::write(
            dist.join(format!("{artifact}.sig")),
            format!("sig-of-{artifact}"),
        )
        .unwrap();
    }
    let workflow = workflow();
    let script = run_script(&step(&workflow, "name: Write the signed update manifest"));
    let run = std::process::Command::new("bash")
        .arg("-c")
        .arg(&script)
        .current_dir(dir.path())
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("GITHUB_REF_NAME", "v5.1.0")
        .env("GITHUB_REPOSITORY", "vanillagreencom/kendex")
        .output()
        .unwrap();
    let manifest = fs::read_to_string(dist.join("latest.json")).unwrap_or_default();
    let said = String::from_utf8_lossy(&run.stdout).into_owned();
    (run.status.code().unwrap_or(-1), manifest, said)
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn the_manifest_pairs_every_signature_with_the_artifact_it_signs() {
    let artifacts: Vec<&str> = SIGNED_ARTIFACTS.iter().map(|(_, file)| *file).collect();
    let (code, manifest, _) = write_manifest(&artifacts);
    assert_eq!(code, 0, "a complete set must succeed");
    let manifest: serde_json::Value = serde_json::from_str(&manifest).unwrap();
    assert_eq!(manifest["version"].as_str(), Some("5.1.0"));
    for (platform, artifact) in SIGNED_ARTIFACTS {
        let entry = &manifest["platforms"][platform];
        assert_eq!(
            entry["signature"].as_str(),
            Some(format!("sig-of-{artifact}").as_str()),
            "{platform}"
        );
        assert_eq!(
            entry["url"].as_str(),
            Some(
                format!(
                    "https://github.com/vanillagreencom/kendex/releases/download/v5.1.0/{artifact}"
                )
                .as_str()
            ),
            "{platform}"
        );
    }
}

/// `kendex update` fetches the AppImage's signature by appending `.sig` to
/// the download URL core builds, so that URL has to name the artifact a tag
/// run actually signs. A rename on either side leaves the app half of the
/// command fetching a file no release carries.
#[test]
fn the_appimage_url_core_builds_is_the_artifact_the_release_signs() {
    let base = "https://github.com/vanillagreencom/kendex/releases/download/v5.1.0";
    for (platform, target) in [
        ("linux-x86_64", "x86_64-unknown-linux-gnu"),
        ("linux-aarch64", "aarch64-unknown-linux-gnu"),
    ] {
        let artifact = SIGNED_ARTIFACTS
            .iter()
            .find(|(key, _)| *key == platform)
            .map(|(_, file)| *file)
            .unwrap_or_default();
        assert_eq!(
            kendex_core::update_feed::app_image_url("5.1.0", target).unwrap_or_default(),
            Some(format!("{base}/{artifact}")),
            "{platform}"
        );
    }
}

/// Tauri v2 signs the AppImage itself. The `.AppImage.tar.gz` shape belongs
/// to the deprecated v1-compatible updater, and looking for it leaves Linux
/// out of the manifest with the job still green.
#[test]
fn no_step_hunts_for_the_v1_compatible_linux_updater_archive() {
    let workflow = workflow();
    for name in [
        "name: Stage release assets",
        "name: Write the signed update manifest",
    ] {
        for line in step(&workflow, name) {
            assert!(!line.contains("AppImage.tar.gz"), "{name}: {}", line.trim());
        }
    }
}

/// One lane that stopped signing is invisible in a manifest that merely
/// has entries: the platform it left out offers an Update the manifest
/// cannot answer, and every other lane keeps the release green. Each
/// platform is therefore required by name.
#[cfg(unix)]
#[test]
fn a_lane_missing_its_signature_fails_the_job_by_name() {
    for (absent, artifact) in SIGNED_ARTIFACTS {
        let rest: Vec<&str> = SIGNED_ARTIFACTS
            .iter()
            .filter(|(_, file)| *file != artifact)
            .map(|(_, file)| *file)
            .collect();
        let (code, manifest, said) = write_manifest(&rest);
        assert_ne!(code, 0, "missing {absent} must fail the job");
        assert!(manifest.is_empty(), "{absent}: {manifest}");
        assert!(said.contains(absent), "{absent} unnamed in: {said}");
    }
}

/// An unsigned release publishes a manifest the app would read as "nothing
/// to install", so the job stops instead.
#[cfg(unix)]
#[test]
fn a_release_with_nothing_signed_fails_the_job() {
    let (code, manifest, _) = write_manifest(&[]);
    assert_ne!(code, 0);
    assert!(manifest.is_empty(), "{manifest}");
}

fn lane_triples(workflow: &str) -> Vec<&str> {
    workflow
        .lines()
        .filter_map(|l| l.trim().strip_prefix("target: "))
        .collect()
}

/// Read past the comments: a commented-out copy of the command carrying
/// the flag would vouch for a real line that had lost it, and the step
/// already keeps a comment block about `--target` directly above itself.
#[test]
fn both_build_commands_emit_into_the_per_target_dir() {
    let workflow = workflow();
    for tool in ["cargo build", "tauri build"] {
        let lines: Vec<&str> = workflow
            .lines()
            .filter(|l| !l.trim_start().starts_with('#') && l.contains(tool))
            .collect();
        assert!(!lines.is_empty(), "release.yml has no {tool} step");
        for line in lines {
            assert!(
                line.contains(&format!("--target {TARGET_EXPR}")),
                "{tool} must pass --target {TARGET_EXPR}: {line}"
            );
        }
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
    let triples = lane_triples(&workflow);
    // With no triples read, every assertion below is unreachable and the
    // test passes over any hardcoded path. A matrix written in YAML flow
    // style reads as no lanes, so the count has to match the lanes too.
    let lanes = workflow
        .lines()
        .filter(|l| l.trim().trim_start_matches("- ").starts_with("os: "))
        .count();
    assert!(!triples.is_empty(), "release.yml declares no lane targets");
    assert_eq!(triples.len(), lanes, "every lane must name its own target");
    let build_lines: Vec<&str> = workflow
        .lines()
        .filter(|l| l.contains("cargo build") || l.contains("tauri build"))
        .collect();
    let stage = step(&workflow, "name: Stage release assets");
    for triple in triples {
        for line in build_lines.iter().chain(stage.iter()) {
            assert!(
                !line.contains(triple),
                "literal {triple} in a step that must use {TARGET_EXPR}: {}",
                line.trim()
            );
        }
    }
}
