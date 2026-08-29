//! Signing the command binary. `kendex update` refuses a download the
//! release key does not cover, so a lane that stages `kendex-<target>` and
//! no signature beside it publishes an update every client turns away. That
//! is a tag-run failure otherwise, because release.yml never runs on a pull
//! request; here the real step runs against a signer this test controls.

#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[cfg(unix)]
use crate::test_util::rooted;
#[cfg(unix)]
use crate::{LANES, expand, run_script};
use crate::{step, workflow};

/// The signing step run over one lane in a tree holding that lane's staged
/// binary and a `tauri` the test wrote: `body` is the shell the shim runs,
/// which decides whether a signature appears. Returns the exit code, what
/// the step said, and the signature files left in `dist/`.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn sign(lane: &crate::Lane, body: &str) -> (i32, String, Vec<String>) {
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    let binary = match lane.runner_os {
        "Windows" => format!("kendex-{}.exe", lane.target),
        _ => format!("kendex-{}", lane.target),
    };
    fs::create_dir_all(root.join("dist")).unwrap();
    fs::write(root.join("dist").join(&binary), "the built command").unwrap();

    let shim = root.join("ui/node_modules/.bin");
    fs::create_dir_all(&shim).unwrap();
    let shim = shim.join("tauri");
    fs::write(&shim, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();

    let workflow = workflow();
    let script = expand(
        &run_script(&step(&workflow, "name: Sign the kendex command")),
        lane,
    );
    let run = std::process::Command::new("bash")
        // The flags a `shell: bash` step gets on a runner.
        .args(["-eo", "pipefail", "-c", &script])
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .unwrap();
    let mut left: Vec<String> = fs::read_dir(root.join("dist"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".sig"))
        .collect();
    left.sort();
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    (run.status.code().unwrap_or(-1), said, left)
}

/// Every lane signs the command the staging step left, and the expected
/// name comes from that step rather than being spelled a second time here:
/// two spellings agree until one is edited, and the Windows lane's `.exe`
/// is exactly where they would part.
#[cfg(unix)]
#[test]
fn each_lane_signs_the_command_it_staged() {
    for lane in &LANES {
        let staged = crate::stage_assets(lane);
        let (code, said, sigs) = sign(lane, r#"printf 'sig' > "$3.sig""#);
        assert_eq!(code, 0, "{}: {said}", lane.target);
        assert_eq!(sigs.len(), 1, "{}: {sigs:?}", lane.target);
        let signed = sigs[0].trim_end_matches(".sig");
        assert!(
            staged.contains_key(signed),
            "{} signed {signed}, which staging never left: {:?}",
            lane.target,
            staged.keys().collect::<Vec<_>>()
        );
    }
}

/// The lane that matters: a signer that leaves nothing behind has published
/// a command no client can verify, and every other lane still being green
/// would let the tag through. It fails here, naming the binary.
#[cfg(unix)]
#[test]
fn a_lane_that_produced_no_signature_fails_the_job_by_name() {
    for empty in ["exit 0", r#": > "$3.sig""#] {
        for lane in &LANES {
            let (code, said, _) = sign(lane, empty);
            assert_ne!(code, 0, "{}: {said}", lane.target);
            assert!(
                said.contains(&format!("kendex-{}", lane.target)),
                "{} unnamed in: {said}",
                lane.target
            );
        }
    }
}

/// A signer that fails stops the lane rather than being stepped over.
#[cfg(unix)]
#[test]
fn a_signer_that_fails_stops_the_lane() {
    for lane in &LANES {
        let (code, said, _) = sign(lane, "exit 3");
        assert_ne!(code, 0, "{}: {said}", lane.target);
    }
}

/// The step signs under the release keypair and no other, so the command
/// and the app bundles are held to one key.
#[test]
fn the_step_signs_under_the_release_key() {
    let workflow = workflow();
    let lines = step(&workflow, "name: Sign the kendex command").join("\n");
    assert!(
        lines.contains("TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}"),
        "{lines}"
    );
    assert!(lines.contains("signer sign"), "{lines}");
}

/// The publish job now downloads two signatures per lane, and its `add`
/// globs have to pick the updater bundle's. A glob that also matched the
/// command's would name a download the app cannot install, and only a tag
/// run puts the two steps together: here a `dist/` carrying nothing but
/// command signatures has to leave every platform unanswered.
#[cfg(unix)]
#[test]
fn no_platform_is_answered_by_a_command_signature() {
    let mut dist = std::collections::BTreeMap::new();
    for lane in &LANES {
        let ext = match lane.runner_os {
            "Windows" => ".exe",
            _ => "",
        };
        dist.insert(
            format!("kendex-{}{ext}.sig", lane.target),
            "the command signature".to_owned(),
        );
    }
    let (code, manifest, said) = crate::run_manifest(&dist);
    assert_ne!(code, 0, "{said}");
    assert!(manifest.is_empty(), "{manifest}");
    for lane in &LANES {
        assert!(
            said.contains(lane.platform),
            "{} was answered by a command signature: {said}",
            lane.platform
        );
    }
}
