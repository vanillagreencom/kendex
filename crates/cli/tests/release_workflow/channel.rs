//! The pre-release channel: how a tag whose version is a release candidate
//! is published, and the one fixed release whose manifests every candidate
//! reads its updates from. None of it runs on a pull request, and the parts
//! that have to agree — the workflow's idea of what a tag is against core's,
//! and the workflow's channel tag against the URLs core sends a candidate
//! to — are two files that only a tag run would otherwise put together.

#[cfg(unix)]
use std::fs;

use crate::test_util::rooted;
use crate::{run_script, step, workflow};

/// Whether core sends a build of this version to the pre-release channel.
/// Every claim below about what the workflow should do is written against
/// this rather than against a list, so the two cannot drift.
fn core_calls_it_a_candidate(version: &str) -> bool {
    kendex_core::update_channel::feed_url_for(version)
        == kendex_core::update_channel::PRERELEASE_FEED_URL
}

/// Runs the classifier step for one tag and returns its exit code and the
/// `prerelease` output it wrote, empty when it wrote none.
#[allow(clippy::unwrap_used)]
fn classify(ref_name: &str) -> (i32, String) {
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    let output = root.join("github.output");
    std::fs::write(&output, "").unwrap();
    let workflow = workflow();
    let script = run_script(&step(&workflow, "name: Classify the tag"));
    let run = std::process::Command::new("bash")
        .arg("-e")
        .arg("-c")
        .arg(&script)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("GITHUB_REF_NAME", ref_name)
        .env("GITHUB_OUTPUT", &output)
        .output()
        .unwrap();
    let written = std::fs::read_to_string(&output).unwrap_or_default();
    let value = written
        .lines()
        .find_map(|line| line.strip_prefix("prerelease="))
        .unwrap_or_default()
        .to_owned();
    (run.status.code().unwrap_or(-1), value)
}

/// Evaluates one of the workflow's `steps.tag.outputs.prerelease == '…'`
/// expressions against the value the classifier wrote, the way a runner
/// would, rather than transcribing what the file says. An `if:` is already
/// an expression and carries no delimiters; a `with:` input needs them.
fn eval_flag(expression: &str, prerelease: &str) -> bool {
    let trimmed = expression.trim();
    let body = match trimmed.strip_prefix("${{") {
        Some(rest) => rest
            .strip_suffix("}}")
            .unwrap_or_else(|| panic!("unclosed GitHub expression: {expression}"))
            .trim(),
        None => trimmed,
    };
    let (read, want) = body
        .split_once("==")
        .unwrap_or_else(|| panic!("not a comparison: {expression}"));
    assert_eq!(
        read.trim(),
        "steps.tag.outputs.prerelease",
        "this test only evaluates the classifier's output; rewrite it for: {expression}"
    );
    prerelease == want.trim().trim_matches('\'')
}

/// The `draft` and `prerelease` inputs of the release step, evaluated for
/// one tag through the classifier that feeds them.
#[allow(clippy::unwrap_used)]
fn publish_inputs(ref_name: &str) -> (bool, bool) {
    let (code, prerelease) = classify(ref_name);
    assert_eq!(code, 0, "{ref_name} did not classify");
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
        eval_flag(line, &prerelease)
    };
    (input("draft"), input("prerelease"))
}

/// The workflow and the build it produces have to mean the same thing by
/// "candidate". SemVer keeps build metadata after a `+` and out of the
/// version, so v1.0.0+build-1 is a full release that merely contains a
/// dash — the tag shape that made the two halves disagree, and the reason
/// this is asked of core rather than of a hand-written list.
#[test]
fn the_workflow_and_the_build_agree_on_what_a_candidate_is() {
    for version in [
        "1.0.0",
        "5.0.1",
        "10.2.3",
        "1.0.0+build-1",
        "1.0.0+1-2-3",
        "1.0.0-rc1",
        "1.0.0-rc2",
        "5.1.0-beta.1",
        "1.0.0-rc1+build-1",
    ] {
        let (code, prerelease) = classify(&format!("v{version}"));
        assert_eq!(code, 0, "v{version} did not classify");
        assert_eq!(
            prerelease,
            core_calls_it_a_candidate(version).to_string(),
            "the workflow and core disagree about {version}"
        );
    }
}

/// A tag core cannot parse would reach the release channel while the
/// workflow guessed from its punctuation, so the tag stops here instead.
/// The version has to be the tag without its leading v, and a build whose
/// version is not SemVer cannot compare itself to a feed at all.
#[test]
fn a_tag_that_is_not_semver_fails_the_job() {
    for tag in ["v1.0", "vnightly-1", "v1.0.0.1", "release-1.0.0", "v1.0.0-"] {
        let (code, prerelease) = classify(tag);
        assert_ne!(code, 0, "{tag} was accepted as {prerelease}");
        assert!(prerelease.is_empty(), "{tag} wrote {prerelease}");
    }
}

/// A full release is still the draft `docs/RELEASING.md` describes, and a
/// candidate is published outright. Published is the whole point: a draft's
/// assets are unreachable, so a candidate nobody can download tests
/// nothing. Marked pre-release is what keeps it away from everyone else,
/// since GitHub resolves `latest` past pre-releases.
#[test]
fn a_candidate_publishes_and_a_full_release_stays_a_draft() {
    for tag in ["v1.0.0", "v5.0.1", "v1.0.0+build-1"] {
        assert_eq!(publish_inputs(tag), (true, false), "{tag}");
    }
    for tag in ["v1.0.0-rc1", "v1.0.0-rc2", "v5.1.0-beta.1"] {
        assert_eq!(publish_inputs(tag), (false, true), "{tag}");
    }
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
    for tag in ["v1.0.0-rc1", "v1.0.0-rc2", "v1.0.0", "v1.0.0+build-1"] {
        let (code, prerelease) = classify(tag);
        assert_eq!(code, 0, "{tag} did not classify");
        assert_eq!(
            eval_flag(&guard, &prerelease),
            core_calls_it_a_candidate(tag.trim_start_matches('v')),
            "{tag}"
        );
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

/// What one run of the channel step did.
#[cfg(unix)]
struct Pointed {
    code: i32,
    calls: Vec<String>,
}

#[cfg(unix)]
impl Pointed {
    fn ran(&self, verb: &str) -> Option<&String> {
        self.calls.iter().find(|c| c.starts_with(verb))
    }
}

/// Runs the pre-release channel step with `gh` stubbed. `carries` is the
/// version the channel's own `latest.json` already names — `None` for a
/// channel release that does not exist yet.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn point_channel(carries: Option<&str>, new_version: &str) -> Pointed {
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
    // Records every call, and answers the two the run reads: whether the
    // channel release is there, and what its manifest says it carries.
    // `--output` is honoured rather than assumed so a step that downloaded
    // to some other name would read an empty version and be caught.
    fs::write(
        bin.join("gh"),
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
         if [ \"$1 $2\" = \"release view\" ]; then\n\
           [ -n \"$GH_CARRIES\" ] || exit 1\n\
           exit 0\n\
         fi\n\
         if [ \"$1 $2\" = \"release download\" ]; then\n\
           [ -n \"$GH_CARRIES\" ] || exit 1\n\
           while [ $# -gt 0 ]; do\n\
             [ \"$1\" = \"--output\" ] && out=$2\n\
             shift\n\
           done\n\
           [ -n \"$out\" ] || exit 1\n\
           printf '{\"version\":\"%s\"}\\n' \"$GH_CARRIES\" > \"$out\"\n\
         fi\n\
         exit 0\n",
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
        .env("GH_CARRIES", carries.unwrap_or_default())
        .env("GITHUB_REPOSITORY", "vanillagreencom/kendex")
        .env("CHANNEL", channel_step_env("CHANNEL"))
        .env("NEW_VERSION", new_version)
        .env("GH_TOKEN", "token")
        .output()
        .unwrap();
    let calls = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    Pointed {
        code: run.status.code().unwrap_or(-1),
        calls,
    }
}

/// Both manifests reach the channel whether or not the release behind it
/// exists yet, and the upload replaces what is there. Without `--clobber`
/// the first candidate's manifests stay and every later one is refused, so
/// the channel would freeze on rc1 while reporting success.
#[cfg(unix)]
#[test]
fn every_candidate_replaces_both_manifests_on_the_channel() {
    for carries in [None, Some("1.0.0-rc1")] {
        let run = point_channel(carries, "1.0.0-rc2");
        assert_eq!(run.code, 0, "carries={carries:?}: {:?}", run.calls);
        assert_eq!(
            run.ran("release create").is_some(),
            carries.is_none(),
            "carries={carries:?}: {:?}",
            run.calls
        );
        let upload = run
            .ran("release upload")
            .unwrap_or_else(|| panic!("carries={carries:?} uploaded nothing: {:?}", run.calls));
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

/// Whether core reads `latest` as ahead of `running` — the same comparison
/// the running build makes of the channel it is pointed at, and what the
/// step in the workflow has to arrive at from bash.
#[allow(clippy::unwrap_used)]
fn core_reads_as_newer(latest: &str, running: &str) -> bool {
    let feed =
        format!(r#"{{"schema":1,"version":"{latest}","assets":{{"t":"https://example.test/k"}}}}"#);
    kendex_core::update_feed::ReleaseFeed::parse(feed.as_bytes())
        .unwrap()
        .relation_to(running)
        .unwrap()
        == kendex_core::update_feed::VersionRelation::Newer
}

/// The channel only moves forward. A tag re-run after a later one would
/// otherwise put its own older manifests back, and every candidate machine
/// would quietly drop to that release and stop being offered anything —
/// which on this channel is indistinguishable from the update path being
/// broken, the very thing the channel exists to test.
///
/// The step's bash and core have to reach one answer, so the expectation
/// is asked of core rather than written out: whatever a build would call
/// newer is what the channel is allowed to move to.
#[cfg(unix)]
#[test]
fn a_tag_behind_the_channel_leaves_it_alone() {
    let versions = [
        "1.0.0-rc1",
        "1.0.0-rc2",
        "1.0.0-rc9",
        "1.0.0-rc10",
        "1.0.0-beta.1",
        "1.1.0-rc1",
        "2.0.0-rc1",
        "1.0.0-rc2+build",
    ];
    for carried in versions {
        for tagged in versions {
            let run = point_channel(Some(carried), tagged);
            assert_eq!(run.code, 0, "{carried} -> {tagged}: {:?}", run.calls);
            // Equal versions re-run the same tag, which refreshes rather
            // than rolls back, so only a strictly newer carried version
            // holds the channel.
            let refused = core_reads_as_newer(carried, tagged);
            assert_eq!(
                run.ran("release upload").is_none(),
                refused,
                "channel carries {carried}, tag is {tagged}: {:?}",
                run.calls
            );
        }
    }
}

/// Two tag runs that interleave a read and a write would leave the older
/// manifests on the channel however carefully each one compares, so the
/// job that owns the channel takes a concurrency group and the runs queue.
/// Cancelling instead would answer a tag with no release at all.
#[test]
fn two_publishes_cannot_interleave_their_writes_to_the_channel() {
    let workflow = workflow();
    let publish: Vec<&str> = workflow
        .lines()
        .skip_while(|l| l.trim() != "publish:")
        .take_while(|l| l.trim() != "steps:")
        .collect();
    let value = |key: &str| {
        publish
            .iter()
            .find_map(|l| l.trim().strip_prefix(&format!("{key}: ")))
            .unwrap_or_else(|| panic!("the publish job declares no {key}:\n{publish:#?}"))
    };
    assert!(!value("group").is_empty());
    assert_eq!(value("cancel-in-progress"), "false");
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
