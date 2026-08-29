//! Signing what a lane publishes. `kendex update` refuses a download the
//! release key does not cover and one the release's digests document does
//! not name, so a lane that stages `kendex-<target>` without both publishes
//! an update every client turns away. That is a tag-run failure otherwise,
//! because release.yml never runs on a pull request; here the real step
//! runs the real script against a signer this test controls.

#[cfg(unix)]
use std::collections::BTreeMap;
#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::path::Path;

#[cfg(unix)]
use crate::test_util::rooted;
#[cfg(unix)]
use crate::{LANES, expand, run_script, signed_artifacts};
use crate::{step, workflow};

/// What one lane's signing step did: its exit code, what it said, the
/// signature files left in `dist/`, and the digests document it wrote.
#[cfg(unix)]
struct Signed {
    code: i32,
    said: String,
    sigs: Vec<String>,
    document: String,
}

#[cfg(unix)]
fn command_name(lane: &crate::Lane) -> String {
    match lane.runner_os {
        "Windows" => format!("kendex-{}.exe", lane.target),
        _ => format!("kendex-{}", lane.target),
    }
}

/// The signing step run over one lane in a tree holding the `dist/` that
/// lane staged, the real `tools/release-digests`, and a `tauri` the test
/// wrote: `body` is the shell the shim runs, which decides which
/// signatures appear.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn sign(lane: &crate::Lane, dist: &BTreeMap<String, String>, body: &str) -> Signed {
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    fs::create_dir_all(root.join("dist")).unwrap();
    for (name, contents) in dist {
        fs::write(root.join("dist").join(name), contents).unwrap();
    }

    // The step calls the script out of the checkout, so the tree it runs in
    // carries the real one rather than a restatement of what it does.
    fs::create_dir_all(root.join("tools")).unwrap();
    let script = root.join("tools/release-digests");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/release-digests"),
        &script,
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

    let shim = root.join("ui/node_modules/.bin");
    fs::create_dir_all(&shim).unwrap();
    let shim = shim.join("tauri");
    fs::write(&shim, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();

    let workflow = workflow();
    let step_script = expand(
        &run_script(&step(&workflow, "name: Sign this lane's downloads")),
        lane,
    );
    let run = std::process::Command::new("bash")
        // The flags a `shell: bash` step gets on a runner.
        .args(["-eo", "pipefail", "-c", &step_script])
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("GITHUB_REF_NAME", "v5.1.0")
        .output()
        .unwrap();
    // The bundler already signed its own artifacts, and staging carried
    // those into `dist/`; what this step did is what was not there before.
    let mut sigs: Vec<String> = fs::read_dir(root.join("dist"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".sig") && !dist.contains_key(name))
        .collect();
    sigs.sort();
    Signed {
        code: run.status.code().unwrap_or(-1),
        said: format!(
            "{}{}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        ),
        sigs,
        document: fs::read_to_string(
            root.join("dist")
                .join(format!("digests-{}.json", lane.target)),
        )
        .unwrap_or_default(),
    }
}

/// A signer that answers for every file it is handed.
#[cfg(unix)]
const SIGNS: &str = r#"printf 'sig' > "$3.sig""#;

/// Every lane signs the command the staging step left and the document it
/// wrote about that lane, and the names come from staging rather than
/// being spelled a second time here: two spellings agree until one is
/// edited, and the Windows lane's `.exe` is exactly where they would part.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn each_lane_signs_the_command_and_the_document_it_published() {
    for lane in &LANES {
        let staged = crate::stage_assets(lane);
        let signed = sign(lane, &staged, SIGNS);
        assert_eq!(signed.code, 0, "{}: {}", lane.target, signed.said);

        let command = command_name(lane);
        assert!(
            staged.contains_key(&command),
            "{} signed {command}, which staging never left: {:?}",
            lane.target,
            staged.keys().collect::<Vec<_>>()
        );
        assert_eq!(
            signed.sigs,
            vec![
                format!("digests-{}.json.sig", lane.target),
                format!("{command}.sig"),
            ],
            "{}",
            lane.target
        );

        let document: serde_json::Value = serde_json::from_str(&signed.document).unwrap();
        assert_eq!(document["schema"].as_u64(), Some(1), "{}", lane.target);
        assert_eq!(
            document["version"].as_str(),
            Some("5.1.0"),
            "{}",
            lane.target
        );
        assert_eq!(
            document["target"].as_str(),
            Some(lane.target),
            "{}",
            lane.target
        );
    }
}

/// The two halves this document is read against: the command the feed
/// names for a target, and the download the manifest step names for that
/// platform. Take either away and the lane refuses rather than publishing
/// a statement missing a download; change its bytes and the digest moves
/// with them, so the field is measured rather than restated.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn the_document_measures_the_two_downloads_a_lane_publishes() {
    for lane in &LANES {
        let staged = crate::stage_assets(lane);
        let app = signed_artifacts()
            .iter()
            .find(|(platform, _)| *platform == lane.platform)
            .map(|(_, file)| file.clone())
            .unwrap();
        let published = sign(lane, &staged, SIGNS);
        let document: serde_json::Value = serde_json::from_str(&published.document).unwrap();

        for (field, file) in [("command", command_name(lane)), ("app", app)] {
            let mut moved = staged.clone();
            moved.insert(file.clone(), "bytes from somewhere else".to_owned());
            let other: serde_json::Value =
                serde_json::from_str(&sign(lane, &moved, SIGNS).document).unwrap();
            assert_ne!(
                document[field], other[field],
                "{}: the {field} digest ignores {file}",
                lane.target
            );

            let mut gone = staged.clone();
            gone.remove(&file);
            let refused = sign(lane, &gone, SIGNS);
            assert_ne!(
                refused.code, 0,
                "{}: a lane with no {file} published a document anyway: {}",
                lane.target, refused.document
            );
        }
    }
}

/// The lane that matters: a signer that leaves nothing behind has
/// published a download no client can verify, and every other lane still
/// being green would let the tag through. It fails here, naming the file
/// that went unsigned — whichever of the two it was.
#[cfg(unix)]
#[test]
fn a_download_that_went_unsigned_fails_the_job_by_name() {
    for (shim, unsigned) in [
        ("exit 0", "kendex-"),
        (r#": > "$3.sig""#, "kendex-"),
        // A signer that answers for the command and not the document.
        (
            r#"case "$3" in *digests-*) exit 0 ;; *) printf 'sig' > "$3.sig" ;; esac"#,
            "digests-",
        ),
    ] {
        for lane in &LANES {
            let staged = crate::stage_assets(lane);
            let signed = sign(lane, &staged, shim);
            assert_ne!(signed.code, 0, "{}: {}", lane.target, signed.said);
            assert!(
                signed.said.contains(&format!("{unsigned}{}", lane.target)),
                "{} unnamed in: {}",
                lane.target,
                signed.said
            );
        }
    }
}

/// A signer that fails stops the lane rather than being stepped over.
#[cfg(unix)]
#[test]
fn a_signer_that_fails_stops_the_lane() {
    for lane in &LANES {
        let staged = crate::stage_assets(lane);
        let signed = sign(lane, &staged, "exit 3");
        assert_ne!(signed.code, 0, "{}: {}", lane.target, signed.said);
    }
}

/// The step signs under the release keypair and no other, so the command,
/// the document and the app bundles are held to one key.
#[test]
fn the_step_signs_under_the_release_key() {
    let workflow = workflow();
    let lines = step(&workflow, "name: Sign this lane's downloads").join("\n");
    assert!(
        lines.contains("TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}"),
        "{lines}"
    );
    assert!(lines.contains("tools/release-digests"), "{lines}");
}

/// The publish job downloads two signatures per lane, and its `add` globs
/// have to pick the updater bundle's. A glob that also matched the
/// command's would name a download the app cannot install, and only a tag
/// run puts the two steps together: here a `dist/` carrying nothing but
/// command signatures has to leave every platform unanswered.
#[cfg(unix)]
#[test]
fn no_platform_is_answered_by_a_command_signature() {
    let mut dist = std::collections::BTreeMap::new();
    for lane in &LANES {
        dist.insert(
            format!("{}.sig", command_name(lane)),
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
