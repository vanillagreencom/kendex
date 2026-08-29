//! The pre-release channel: how a tag whose version is a release candidate
//! is published, and the one fixed release whose manifests every candidate
//! reads its updates from. None of it runs on a pull request, and the two
//! halves — the workflow's channel tag and the URLs core sends a candidate
//! to — are one name in two files that only a tag run would otherwise put
//! together.

#[cfg(unix)]
use std::fs;

#[cfg(unix)]
use crate::{run_script, test_util::rooted};
use crate::{step, workflow};

/// The one GitHub expression this workflow's correctness rests on, in the
/// only two shapes a tag takes here. Everything below evaluates it the way
/// a runner would rather than transcribing what the file says, so an
/// inverted `!` or a swapped pair fails here and not on a tag. An `if:` is
/// already an expression and carries no delimiters; a `with:` input needs
/// them, and without them would reach the action as its own literal text.
fn contains_dash(expression: &str, ref_name: &str) -> bool {
    let trimmed = expression.trim();
    let body = match trimmed.strip_prefix("${{") {
        Some(rest) => rest
            .strip_suffix("}}")
            .unwrap_or_else(|| panic!("unclosed GitHub expression: {expression}"))
            .trim(),
        None => trimmed,
    };
    let (negated, call) = match body.strip_prefix('!') {
        Some(rest) => (true, rest.trim()),
        None => (false, body),
    };
    assert_eq!(
        call, "contains(github.ref_name, '-')",
        "this test only evaluates the pre-release test; rewrite it for: {call}"
    );
    ref_name.contains('-') != negated
}

/// The `with:` inputs of the release step, evaluated for one tag.
#[allow(clippy::unwrap_used)]
fn publish_inputs(ref_name: &str) -> (bool, bool) {
    let workflow = workflow();
    let publish = step(&workflow, "uses: softprops/action-gh-release@v2");
    let input = |name: &str| {
        let line = publish
            .iter()
            .find_map(|l| l.trim().strip_prefix(&format!("{name}: ")))
            .unwrap_or_else(|| panic!("the release step declares no {name}"));
        // A `with:` input outside `${{ }}` reaches the action as that text,
        // and every non-empty string reads as true there.
        assert!(
            line.trim().starts_with("${{"),
            "{name} is a literal, not an expression: {line}"
        );
        contains_dash(line, ref_name)
    };
    (input("draft"), input("prerelease"))
}

/// A full release is still the draft `docs/RELEASING.md` describes, and a
/// candidate is published outright. Published is the whole point: a draft's
/// assets are unreachable, so a candidate nobody can download tests
/// nothing. Marked pre-release is what keeps it away from everyone else,
/// since GitHub resolves `latest` past pre-releases.
#[test]
fn a_candidate_publishes_and_a_full_release_stays_a_draft() {
    for tag in ["v1.0.0", "v5.0.1", "v10.2.3"] {
        assert_eq!(publish_inputs(tag), (true, false), "{tag}");
    }
    for tag in ["v1.0.0-rc1", "v1.0.0-rc2", "v5.1.0-beta.1"] {
        assert_eq!(publish_inputs(tag), (false, true), "{tag}");
    }
}

/// One value of the pre-release channel step's `env:` block.
#[allow(clippy::unwrap_used)]
fn channel_step_env(name: &str) -> String {
    let workflow = workflow();
    step(&workflow, "name: Point the pre-release channel at this tag")
        .iter()
        .find_map(|l| l.trim().strip_prefix(&format!("{name}: ")))
        .unwrap_or_else(|| panic!("the channel step sets no {name}"))
        .to_owned()
}

/// Runs the pre-release channel step with `gh` stubbed, and returns every
/// command line it ran. `channel_exists` is what `gh release view` answers.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn point_channel(channel_exists: bool) -> (i32, Vec<String>) {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    let dist = root.join("dist");
    fs::create_dir_all(&dist).unwrap();
    for name in ["latest.json", "feed.json"] {
        fs::write(dist.join(name), "{}").unwrap();
    }
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let log = root.join("gh.log");
    // `release view` is the only call whose answer changes the run; the
    // stub records every call either way so the assertions can read them.
    fs::write(
        bin.join("gh"),
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
         [ \"$1 $2\" = \"release view\" ] && exit \"$GH_VIEW_EXIT\"\nexit 0\n",
    )
    .unwrap();
    fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();

    let workflow = workflow();
    let script = run_script(&step(
        &workflow,
        "name: Point the pre-release channel at this tag",
    ));
    // `shell: bash` on a runner is `bash -e`, so a failed `gh` fails the
    // step. Without it the exit code below is the last command's alone and
    // an upload that never landed would read as a run that worked.
    let run = std::process::Command::new("bash")
        .arg("-e")
        .arg("-c")
        .arg(&script)
        .current_dir(&root)
        .env_clear()
        .env(
            "PATH",
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("GH_LOG", &log)
        .env("GH_VIEW_EXIT", if channel_exists { "0" } else { "1" })
        .env("GITHUB_REPOSITORY", "vanillagreencom/kendex")
        .env("CHANNEL", channel_step_env("CHANNEL"))
        .env("GH_TOKEN", "token")
        .output()
        .unwrap();
    let calls = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    (run.status.code().unwrap_or(-1), calls)
}

/// The step runs for a candidate and for nothing else. Running it on a full
/// release would leave the candidates' channel pointing at a draft whose
/// assets do not resolve, so a candidate would be offered an update that
/// 404s until somebody published the draft by hand.
#[test]
fn the_channel_is_repointed_for_a_candidate_and_no_other_tag() {
    let workflow = workflow();
    let guard = step(&workflow, "name: Point the pre-release channel at this tag")
        .iter()
        .find_map(|l| l.trim().strip_prefix("if: "))
        .expect("the channel step runs unconditionally")
        .to_owned();
    for tag in ["v1.0.0-rc1", "v1.0.0-rc2"] {
        assert!(contains_dash(&guard, tag), "{tag}");
    }
    for tag in ["v1.0.0", "v5.0.1"] {
        assert!(!contains_dash(&guard, tag), "{tag}");
    }
}

/// Both manifests reach the channel whether or not the release behind it
/// exists yet, and the upload replaces what is there. Without `--clobber`
/// the first candidate's manifests stay and every later one is refused, so
/// the channel would freeze on rc1 while reporting success.
#[cfg(unix)]
#[test]
fn every_candidate_replaces_both_manifests_on_the_channel() {
    for exists in [true, false] {
        let (code, calls) = point_channel(exists);
        assert_eq!(code, 0, "exists={exists}: {calls:?}");
        let created = calls.iter().any(|c| c.starts_with("release create"));
        assert_eq!(created, !exists, "exists={exists}: {calls:?}");
        let upload = calls
            .iter()
            .find(|c| c.starts_with("release upload"))
            .unwrap_or_else(|| panic!("exists={exists} uploaded nothing: {calls:?}"));
        // Named from the URLs rather than by hand: a manifest renamed on
        // one side and not the other publishes to a name nothing reads.
        for url in [
            kendex_core::update_channel::PRERELEASE_FEED_URL,
            kendex_core::update_channel::PRERELEASE_MANIFEST_URL,
        ] {
            let file = url.rsplit('/').next().unwrap_or_default();
            assert!(
                upload.contains(&format!("dist/{file}")),
                "dist/{file} missing from {upload}"
            );
        }
        assert!(upload.contains("--clobber"), "{upload}");
    }
}

/// The channel tag in the workflow and the URLs core sends a candidate to
/// are one name in two files, and a tag run is the only thing that would
/// otherwise put them together. A rename on either side leaves candidates
/// reading a URL nothing publishes to, which reads to them as up to date.
#[test]
fn the_channel_tag_is_the_one_core_sends_a_candidate_to() {
    let channel = channel_step_env("CHANNEL");
    for url in [
        kendex_core::update_channel::PRERELEASE_FEED_URL,
        kendex_core::update_channel::PRERELEASE_MANIFEST_URL,
    ] {
        assert!(
            url.contains(&format!("/releases/download/{channel}/")),
            "{url} is not served from the {channel} release"
        );
    }
}
