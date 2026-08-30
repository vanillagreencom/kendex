//! release.yml runs only on tags, so its build, staging and manifest steps
//! are never exercised by a pull request. Both build commands must emit
//! into the per-target output dir and the staging step must read from that
//! same dir, keyed by the one matrix expression rather than a literal
//! triple. Staging and the manifest are one contract in two halves, and a
//! naming mismatch is otherwise first discovered by a failed tag run
//! because pull requests do not exercise these steps. The two run joined
//! here: a hand-maintained model of Tauri 2 output goes into the real
//! staging script and what it produces goes into the real manifest script.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::sync::OnceLock;

#[path = "../../../test_util.rs"]
mod test_util;

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

/// The lines of one job: its `  name:` line and everything indented under it.
fn job<'a>(workflow: &'a str, name: &str) -> Vec<&'a str> {
    let head = format!("  {name}:");
    let mut lines = workflow.lines().skip_while(|l| *l != head);
    let first = lines
        .next()
        .unwrap_or_else(|| panic!("release.yml declares no {name} job"));
    let indent = first.len() - first.trim_start().len();
    let mut body = vec![first];
    for line in lines {
        if !line.trim().is_empty() && line.len() - line.trim_start().len() <= indent {
            break;
        }
        body.push(line);
    }
    body
}

/// Every job the workflow declares, in file order.
fn job_names(workflow: &str) -> Vec<&str> {
    workflow
        .lines()
        .skip_while(|l| l.trim() != "jobs:")
        .filter(|l| l.starts_with("  ") && !l.starts_with("   "))
        .filter_map(|l| l.trim().strip_suffix(':'))
        .collect()
}

/// The one job whose lines contain `marker`. Asked of the file rather than
/// named here, so moving a step between jobs moves what the claims below are
/// made about rather than quietly leaving them on the wrong job.
fn job_declaring<'a>(workflow: &'a str, marker: &str) -> &'a str {
    let mut found: Vec<&str> = job_names(workflow)
        .into_iter()
        .filter(|name| job(workflow, name).iter().any(|l| l.contains(marker)))
        .collect();
    assert_eq!(found.len(), 1, "{marker} is declared by {found:?}");
    found.remove(0)
}

/// The concurrency group a job declares, if any. A job declaring none never
/// waits behind another run of this workflow, and so is never cancelled while
/// it waits.
fn concurrency_group<'a>(job_lines: &[&'a str]) -> Option<&'a str> {
    job_lines
        .iter()
        .skip_while(|l| l.trim() != "concurrency:")
        .find_map(|l| l.trim().strip_prefix("group: "))
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
        // A key written after the block, like a trailing `shell: bash`,
        // dedents out of it and is not part of the script.
        .take_while(|l| l.trim().is_empty() || l.len() - l.trim_start().len() >= indent)
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

/// One release lane: the platform key the manifest step names it by, the
/// matrix triple, the `runner.os` its image reports, and the modeled bundle
/// output under `target/<triple>/release/bundle` there.
struct Lane {
    platform: &'static str,
    target: &'static str,
    runner_os: &'static str,
    bundle: &'static [&'static str],
}

/// A hand-maintained model of what a full tag run hands the staging step:
/// Tauri 2 bundle names for `productName: kendex` at version 5.1.0 with
/// `createUpdaterArtifacts` on. Tauri signs AppImage, deb, rpm, NSIS, and
/// MSI packages, plus the macOS `.app.tar.gz` it tars from the `.app`. A
/// lane therefore offers the staging step several signatures, but only one
/// belongs in the manifest. Both Apple lanes name their archive
/// identically, which is what the staging step's rename is for.
const LANES: [Lane; 5] = [
    Lane {
        platform: "linux-x86_64",
        target: "x86_64-unknown-linux-gnu",
        runner_os: "Linux",
        bundle: &[
            "appimage/kendex.AppDir/usr/bin/kendex",
            "appimage/kendex_5.1.0_amd64.AppImage",
            "appimage/kendex_5.1.0_amd64.AppImage.sig",
            "deb/kendex_5.1.0_amd64.deb",
            "deb/kendex_5.1.0_amd64.deb.sig",
            "rpm/kendex-5.1.0-1.x86_64.rpm",
            "rpm/kendex-5.1.0-1.x86_64.rpm.sig",
        ],
    },
    Lane {
        platform: "linux-aarch64",
        target: "aarch64-unknown-linux-gnu",
        runner_os: "Linux",
        bundle: &[
            "appimage/kendex.AppDir/usr/bin/kendex",
            "appimage/kendex_5.1.0_aarch64.AppImage",
            "appimage/kendex_5.1.0_aarch64.AppImage.sig",
            "deb/kendex_5.1.0_arm64.deb",
            "deb/kendex_5.1.0_arm64.deb.sig",
            "rpm/kendex-5.1.0-1.aarch64.rpm",
            "rpm/kendex-5.1.0-1.aarch64.rpm.sig",
        ],
    },
    Lane {
        platform: "darwin-x86_64",
        target: "x86_64-apple-darwin",
        runner_os: "macOS",
        bundle: &[
            "dmg/kendex_5.1.0_x64.dmg",
            "macos/kendex.app/Contents/MacOS/kendex",
            "macos/kendex.app.tar.gz",
            "macos/kendex.app.tar.gz.sig",
        ],
    },
    Lane {
        platform: "darwin-aarch64",
        target: "aarch64-apple-darwin",
        runner_os: "macOS",
        bundle: &[
            "dmg/kendex_5.1.0_aarch64.dmg",
            "macos/kendex.app/Contents/MacOS/kendex",
            "macos/kendex.app.tar.gz",
            "macos/kendex.app.tar.gz.sig",
        ],
    },
    Lane {
        platform: "windows-x86_64",
        target: "x86_64-pc-windows-msvc",
        runner_os: "Windows",
        bundle: &[
            "msi/kendex_5.1.0_x64_en-US.msi",
            "msi/kendex_5.1.0_x64_en-US.msi.sig",
            "nsis/kendex_5.1.0_x64-setup.exe",
            "nsis/kendex_5.1.0_x64-setup.exe.sig",
        ],
    },
];

/// The GitHub expressions the staging step is written in, filled for one
/// lane the way a runner fills them.
fn expand(script: &str, lane: &Lane) -> String {
    let filled = script
        .replace(TARGET_EXPR, lane.target)
        .replace("${{ runner.os }}", lane.runner_os);
    assert!(
        !filled.contains("${{"),
        "the staging step reads an expression this test leaves unfilled:\n{filled}"
    );
    filled
}

/// Every file of a flat directory, mapped to its contents.
#[allow(clippy::unwrap_used)]
fn contents_of(dir: &Path) -> BTreeMap<String, String> {
    fs::read_dir(dir)
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            (
                path.file_name().unwrap().to_string_lossy().into_owned(),
                fs::read_to_string(&path).unwrap(),
            )
        })
        .collect()
}

/// Runs the staging step over one lane's build output and returns the
/// `dist/` it produced. Every file carries its own lane and bundle path as
/// its contents, so a name two lanes both stage stays legible afterwards
/// rather than becoming a silent overwrite.
#[allow(clippy::unwrap_used)]
fn stage_assets(lane: &Lane) -> BTreeMap<String, String> {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("target").join(lane.target).join("release");
    let binary = if lane.runner_os == "Windows" {
        "kendex.exe"
    } else {
        "kendex"
    };
    fs::create_dir_all(&out).unwrap();
    fs::write(out.join(binary), format!("{} {binary}", lane.target)).unwrap();
    for entry in lane.bundle {
        let path = out.join("bundle").join(entry);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("{} {entry}", lane.target)).unwrap();
    }
    let workflow = workflow();
    let script = expand(
        &run_script(&step(&workflow, "name: Stage release assets")),
        lane,
    );
    let run = std::process::Command::new("bash")
        // A `shell: bash` step gets these flags on a runner, so a cp or a
        // find that fails stops the lane here the way it would there.
        .args(["-eo", "pipefail", "-c", &script])
        .current_dir(dir.path())
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .unwrap();
    assert_eq!(
        run.status.code(),
        Some(0),
        "{} failed to stage: {}",
        lane.target,
        String::from_utf8_lossy(&run.stderr)
    );
    contents_of(&dir.path().join("dist"))
}

/// A whole tag run: every lane staged, merged into the one `dist/` the
/// publish job downloads them all into, and the signed artifact each lane
/// contributed to it.
struct Release {
    dist: BTreeMap<String, String>,
    signed: Vec<(&'static str, String)>,
}

fn release() -> &'static Release {
    static RELEASE: OnceLock<Release> = OnceLock::new();
    RELEASE.get_or_init(|| {
        let mut dist: BTreeMap<String, String> = BTreeMap::new();
        let mut signed = Vec::new();
        for lane in &LANES {
            let staged = stage_assets(lane);
            let mut updaters: Vec<String> = staged
                .keys()
                .filter(|name| staged.contains_key(&format!("{name}.sig")))
                .cloned()
                .collect();
            assert_eq!(
                updaters.len(),
                1,
                "{} staged {updaters:?}; a lane leaves the manifest step exactly one signed artifact",
                lane.platform
            );
            signed.push((lane.platform, updaters.remove(0)));
            for (name, body) in staged {
                if let Some(earlier) = dist.insert(name.clone(), body) {
                    panic!("two lanes both stage {name}: {} and {earlier}", lane.target);
                }
            }
        }
        Release { dist, signed }
    })
}

/// Every signed artifact a full tag run leaves in `dist/`, one per lane:
/// whatever the staging step put there beside a signature of its own name.
fn signed_artifacts() -> &'static [(&'static str, String)] {
    &release().signed
}

/// Runs the manifest step over a `dist/` holding exactly `files`, and
/// returns the exit code, the `latest.json` it wrote, and what it said
/// doing so.
#[allow(clippy::unwrap_used)]
fn run_manifest(files: &BTreeMap<String, String>) -> (i32, String, String) {
    let dir = tempfile::tempdir().unwrap();
    let dist = dir.path().join("dist");
    fs::create_dir_all(&dist).unwrap();
    for (name, body) in files {
        fs::write(dist.join(name), body).unwrap();
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

/// Runs the manifest step over a `dist/` holding exactly `present`
/// artifacts, each beside its signature.
fn write_manifest(present: &[&str]) -> (i32, String, String) {
    let mut files = BTreeMap::new();
    for artifact in present {
        files.insert((*artifact).to_owned(), "bytes".to_owned());
        files.insert(format!("{artifact}.sig"), format!("sig-of-{artifact}"));
    }
    run_manifest(&files)
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn the_manifest_pairs_every_signature_with_the_artifact_it_signs() {
    let artifacts: Vec<&str> = signed_artifacts()
        .iter()
        .map(|(_, file)| file.as_str())
        .collect();
    let (code, manifest, _) = write_manifest(&artifacts);
    assert_eq!(code, 0, "a complete set must succeed");
    let manifest: serde_json::Value = serde_json::from_str(&manifest).unwrap();
    assert_eq!(manifest["version"].as_str(), Some("5.1.0"));
    for (platform, artifact) in signed_artifacts() {
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

/// `kendex update` fetches both of these by name, so both have to be files
/// a tag run actually publishes: the AppImage the manifest step names, and
/// the `.sig` beside it that its `kendex_*_amd64.AppImage.sig` glob matches.
/// This test checks both names during pull requests because release.yml
/// runs on tags only.
#[cfg(unix)]
#[test]
fn the_urls_core_builds_are_the_artifact_the_release_signs_and_its_signature() {
    let base = "https://github.com/vanillagreencom/kendex/releases/download/v5.1.0";
    for (platform, target) in [
        ("linux-x86_64", "x86_64-unknown-linux-gnu"),
        ("linux-aarch64", "aarch64-unknown-linux-gnu"),
    ] {
        let artifact = signed_artifacts()
            .iter()
            .find(|(key, _)| *key == platform)
            .map(|(_, file)| file.as_str())
            .unwrap_or_default();
        assert_eq!(
            kendex_core::update_feed::app_image_url("5.1.0", target).unwrap_or_default(),
            Some(format!("{base}/{artifact}")),
            "{platform}"
        );
        assert_eq!(
            kendex_core::update_feed::app_image_signature_url("5.1.0", target).unwrap_or_default(),
            Some(format!("{base}/{artifact}.sig")),
            "{platform}"
        );
    }
}

/// Tauri v2 signs the AppImage itself. The `.AppImage.tar.gz` shape belongs
/// to the deprecated v1-compatible updater, and looking for it leaves Linux
/// out of the inputs, so the tag job fails before writing the manifest.
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
    for (absent, artifact) in signed_artifacts() {
        let rest: Vec<&str> = signed_artifacts()
            .iter()
            .filter(|(_, file)| file != artifact)
            .map(|(_, file)| file.as_str())
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

/// The staging step's globs and the manifest step's `add` patterns are two
/// halves of one naming contract that only a tag run ever puts together.
/// Here the halves meet: the hand-maintained Tauri 2 output model goes
/// through the real staging script, and what it leaves in `dist/` goes to
/// the real manifest script. A mismatch between the staging globs and the
/// `add` patterns fails this test rather than a tag run.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn every_lane_the_staging_step_stages_reaches_the_manifest() {
    let release = release();
    let (code, manifest, said) = run_manifest(&release.dist);
    assert_eq!(code, 0, "a full tag run must write a manifest: {said}");
    let manifest: serde_json::Value = serde_json::from_str(&manifest).unwrap();
    for (platform, artifact) in &release.signed {
        let entry = &manifest["platforms"][platform];
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
        // Both Apple lanes bundle the same file name, so a signature that
        // came from the other lane is the rename having stopped working.
        let lane = LANES
            .iter()
            .find(|lane| lane.platform == *platform)
            .unwrap();
        assert!(
            entry["signature"]
                .as_str()
                .unwrap_or_default()
                .starts_with(lane.target),
            "{platform} carries another lane's signature: {entry}"
        );
    }
}

/// A lane added to the matrix with no fixture here publishes a platform
/// nothing above covers, and every assertion still passes.
#[test]
fn the_lane_fixture_covers_every_lane_the_matrix_builds() {
    let workflow = workflow();
    let mut declared = lane_triples(&workflow);
    declared.sort_unstable();
    let mut covered: Vec<&str> = LANES.iter().map(|lane| lane.target).collect();
    covered.sort_unstable();
    assert_eq!(covered, declared);
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

mod channel;
mod channel_point;
mod channel_point_failure;
mod signing;
