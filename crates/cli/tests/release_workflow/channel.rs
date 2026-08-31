//! The pre-release channel: how a tag whose version is a release candidate
//! is published, and the one fixed release whose manifests every candidate
//! reads its updates from. None of it runs on a pull request, and the parts
//! that have to agree — the workflow's idea of what a tag is against core's,
//! and the workflow's channel tag against the URLs core sends a candidate
//! to — are two files that only a tag run would otherwise put together.

#[cfg(unix)]
use std::fs;

use crate::test_util::rooted;
use crate::{concurrency_group, job, job_declaring, job_names, run_script, step, workflow};

/// Whether core sends a build of this version to the pre-release channel.
/// Every claim below about what the workflow should do is written against
/// this rather than against a list, so the two cannot drift.
fn core_calls_it_a_candidate(version: &str) -> bool {
    kendex_core::update_channel::feed_url_for(version)
        == kendex_core::update_channel::PRERELEASE_FEED_URL
}

/// The CLI the classifier reads the built version back from, named the way
/// the staging step leaves it in `dist/`. A release job runs on Linux
/// x86_64, so this is the one lane's binary it can execute.
pub(crate) const BUILT_CLI: &str = "kendex-x86_64-unknown-linux-gnu";

/// Runs the classifier step for one tag against a `dist/` holding `cli` as
/// the release binary. Returns the exit code and the `prerelease` output,
/// empty when it wrote none.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn classify_with_cli(ref_name: &str, cli: &str) -> (i32, String) {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    let output = root.join("github.output");
    fs::write(&output, "").unwrap();
    let dist = root.join("dist");
    fs::create_dir_all(&dist).unwrap();
    // Written without the executable bit, because the artifact upload does
    // not carry one across either — the step has to restore it.
    fs::write(dist.join(BUILT_CLI), cli).unwrap();
    fs::set_permissions(dist.join(BUILT_CLI), fs::Permissions::from_mode(0o644)).unwrap();

    let workflow = workflow();
    let script = run_script(&step(&workflow, "name: Classify the tag"));
    let run = std::process::Command::new("bash")
        .arg("-e")
        .arg("-c")
        .arg(&script)
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("GITHUB_REF_NAME", ref_name)
        .env("GITHUB_OUTPUT", &output)
        .output()
        .unwrap();
    let written = fs::read_to_string(&output).unwrap_or_default();
    let value = written
        .lines()
        .find_map(|line| line.strip_prefix("prerelease="))
        .unwrap_or_default()
        .to_owned();
    (run.status.code().unwrap_or(-1), value)
}

/// A release binary that answers `--version` out of the version Cargo
/// built it with, the way the real one does.
#[cfg(unix)]
fn cli_built_as(version: &str) -> String {
    format!("#!/bin/sh\nprintf 'kendex %s\\n' '{version}'\n")
}

/// A run against a release built as `built`.
#[cfg(unix)]
fn classify_built_as(ref_name: &str, built: &str) -> (i32, String) {
    classify_with_cli(ref_name, &cli_built_as(built))
}

/// The ordinary case: the tag and the build agree, which is what every
/// claim about classification is about.
#[cfg(unix)]
fn classify(ref_name: &str) -> (i32, String) {
    classify_built_as(ref_name, ref_name.trim_start_matches('v'))
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
    // The classifier's output, read inside its own job or passed out of it to
    // the channel job. Anything else is a value this test cannot fill in.
    assert!(
        [
            "steps.tag.outputs.prerelease",
            "needs.publish.outputs.prerelease"
        ]
        .contains(&read.trim()),
        "this test only evaluates the classifier's output; rewrite it for: {expression}"
    );
    prerelease == want.trim().trim_matches('\'')
}

/// The `draft` and `prerelease` inputs of the release step, evaluated for
/// one tag through the classifier that feeds them.
#[cfg(unix)]
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
#[cfg(unix)]
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

/// Versions no release can be built as, because Cargo runs the same parser
/// core does and refuses them. Each is a shape a regex written to stand in
/// for that parser waves through: a leading zero in the core, a numeric
/// pre-release identifier with a leading zero, an empty identifier, and an
/// empty build. Published, each would name a manifest version every
/// candidate then fails to read.
pub(crate) const REFUSED_VERSIONS: [&str; 6] = [
    "01.0.0",
    "1.0.0-01",
    "1.0.0-alpha..1",
    "1.0.0+",
    "1.0",
    "1.0.0.1",
];

/// Why those four must never reach a manifest, asked of core rather than
/// asserted from the shapes. The valid versions beside them are the ones
/// they shadow — a pre-release identifier may be a bare zero, and may be
/// alphanumeric with dots — so this cannot pass by refusing everything.
#[test]
fn core_refuses_the_versions_a_regex_would_wave_through() {
    for version in REFUSED_VERSIONS {
        assert!(
            !core_can_read(version),
            "{version} reads, so it is not an example of anything"
        );
    }
    for version in ["1.0.0-0", "1.0.0-alpha.1", "1.0.0+build.1", "1.0.0-rc1+b"] {
        assert!(core_can_read(version), "{version}");
    }
}

/// What a candidate reading the channel's manifest makes of a version:
/// `ReleaseFeed::parse` is what runs on it on every machine, and a version
/// it refuses stops that install from seeing any update at all.
pub(crate) fn core_can_read(version: &str) -> bool {
    let feed = format!(r#"{{"schema":1,"version":"{version}","assets":{{}}}}"#);
    kendex_core::update_feed::ReleaseFeed::parse(feed.as_bytes()).is_ok()
}

/// The tag has to be the version the release was built as. That is what
/// keeps the refused versions above out: none of them can be a Cargo
/// version, so no build reports one, and a tag naming one cannot match.
/// It also catches a tag that is perfectly good SemVer and still wrong —
/// v1.0.1 over a 1.0.0 build publishes a feed naming downloads that were
/// never uploaded, which a regex could never have seen.
#[cfg(unix)]
#[test]
fn a_tag_that_is_not_the_version_built_fails_the_job() {
    for tag in REFUSED_VERSIONS {
        let (code, prerelease) = classify_built_as(&format!("v{tag}"), "1.0.0");
        assert_ne!(code, 0, "v{tag} was accepted as {prerelease}");
        assert!(prerelease.is_empty(), "v{tag} wrote {prerelease}");
    }
    // Both directions of a plain mismatch, and the leading v is not part
    // of the version on either side of the comparison.
    for (tag, built) in [
        ("v1.0.1", "1.0.0"),
        ("v1.0.0", "1.0.1"),
        ("v1.0.0", "1.0.0-rc1"),
        ("v1.0.0-rc1", "1.0.0"),
    ] {
        let (code, prerelease) = classify_built_as(tag, built);
        assert_ne!(code, 0, "{tag} over a {built} build was accepted");
        assert!(prerelease.is_empty(), "{tag} wrote {prerelease}");
    }
}

/// A release whose CLI cannot be run, or that answers nothing, says
/// nothing about what it was built as. Either way the tag stops rather
/// than being classified on a guess about its own text — which is the
/// whole of what a run has to go on once the parser is out of reach.
#[cfg(unix)]
#[test]
fn a_release_that_cannot_report_its_version_fails_the_job() {
    for cli in [
        "#!/bin/sh\nexit 1\n",
        "#!/bin/sh\necho 'kendex 1.0.0'\nexit 1\n",
        "#!/bin/sh\n",
        "not a program at all\n",
    ] {
        let (code, prerelease) = classify_with_cli("v1.0.0", cli);
        assert_ne!(code, 0, "{cli:?} was accepted as {prerelease}");
        assert!(prerelease.is_empty(), "{cli:?} wrote {prerelease}");
    }
}

/// The name the classifier reaches for is the one a tag run actually
/// leaves in `dist/`. Renamed on either side, the step reads nothing and
/// every tag stops at a version it cannot find.
#[cfg(unix)]
#[test]
fn the_classifier_reads_a_binary_the_release_stages() {
    assert!(
        crate::release().dist.contains_key(BUILT_CLI),
        "no lane stages {BUILT_CLI}"
    );
    assert!(
        run_script(&step(&workflow(), "name: Classify the tag")).contains(BUILT_CLI),
        "the classifier does not read {BUILT_CLI}"
    );
}

/// A full release is still the draft `docs/RELEASING.md` describes, and a
/// candidate is published outright. Published is the whole point: a draft's
/// assets are unreachable, so a candidate nobody can download tests
/// nothing. Marked pre-release is what keeps it away from everyone else,
/// since GitHub resolves `latest` past pre-releases.
#[cfg(unix)]
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
#[cfg(unix)]
#[test]
fn the_channel_is_repointed_for_a_candidate_and_no_other_tag() {
    let workflow = workflow();
    let repointing = job_declaring(&workflow, "name: Point the pre-release channel at this tag");
    let guard = job(&workflow, repointing)
        .iter()
        .find_map(|l| l.trim().strip_prefix("if: "))
        .expect("the channel job runs unconditionally")
        .to_owned();
    // The value that `if:` reads has to be one the publish job passes out.
    // Named but never declared, it is empty on every tag and the channel is
    // never repointed at all — which reads to a candidate as up to date.
    assert!(
        job(&workflow, "publish")
            .iter()
            .any(|l| l.trim() == "prerelease: ${{ steps.tag.outputs.prerelease }}"),
        "the publish job does not pass the classifier's verdict out"
    );
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
pub(crate) fn channel_step_env(name: &str) -> String {
    let workflow = workflow();
    step(&workflow, "name: Point the pre-release channel at this tag")
        .iter()
        .find_map(|l| l.trim().strip_prefix(&format!("{name}: ")))
        .unwrap_or_else(|| panic!("the channel step sets no {name}"))
        .to_owned()
}

/// What a burst of tags does to one job, under GitHub's concurrency rules:
/// one run of a group executes, one waits, and a third arrival replaces the
/// one that was waiting rather than joining a queue behind it — the same
/// behaviour `.github/workflows/review-gate-writer.yml` is written around.
/// Returns, per tag in push order, whether that tag's job got to run at all.
/// The burst is the worst case a group has to answer for: every tag arrives
/// while the first is still executing.
fn burst(group: Option<&str>, tags: usize) -> Vec<bool> {
    let mut ran = vec![group.is_none(); tags];
    if group.is_none() {
        return ran;
    }
    let mut waiting = None;
    for (arrival, slot) in ran.iter_mut().enumerate() {
        if arrival == 0 {
            *slot = true; // Nothing holds the group yet.
        } else {
            waiting = Some(arrival); // Replaces whatever was waiting.
        }
    }
    // Whatever still waits when the burst ends runs once the group frees.
    if let Some(last) = waiting {
        ran[last] = true;
    }
    ran
}

/// Candidates cut close enough together that the later ones reach this
/// workflow while the first is still publishing. Each has to end in a release
/// or in a visible failure: a run cancelled while it waited for a concurrency
/// group is neither, and answers its tag with nothing at all. So the job that
/// publishes the release holds no group, at any size of burst.
#[test]
fn overlapping_tags_each_publish_their_release() {
    let workflow = workflow();
    let publishing = job_declaring(&workflow, "uses: softprops/action-gh-release@v2");
    let group = concurrency_group(&job(&workflow, publishing));
    for tags in 2..=6 {
        assert!(
            burst(group, tags).iter().all(|&ran| ran),
            "the {publishing} job is in {group:?}, which loses a tag in a burst of {tags}"
        );
    }
    // The claim above is only worth making if the model can see tags lost. A
    // group keeps the first arrival and the last however many arrive, so what
    // a burst drops is every repoint in between, not one.
    for tags in 2..=6 {
        let ran = burst(Some("held"), tags);
        assert!(
            ran[0] && ran[tags - 1],
            "a burst of {tags} dropped an end: {ran:?}"
        );
        assert!(
            ran[1..tags - 1].iter().all(|&ran| !ran),
            "a burst of {tags} kept a repoint in the middle: {ran:?}"
        );
    }
}

/// Two runs interleaving a read and a write of the channel would leave the
/// older manifests on it however carefully each one compares, so the job that
/// writes the channel is serialized — and it is the only one, because the
/// group costs a run in a burst and nothing else here is worth that. Cancelling
/// the run in progress instead would answer a candidate with a channel written
/// halfway.
#[test]
fn the_channel_write_is_the_only_thing_a_group_holds() {
    let workflow = workflow();
    let writing = job_declaring(&workflow, "name: Point the pre-release channel at this tag");
    for name in job_names(&workflow) {
        let group = concurrency_group(&job(&workflow, name));
        assert_eq!(
            group.is_some(),
            name == writing,
            "the {name} job is in {group:?}"
        );
    }
    assert!(
        job(&workflow, writing)
            .iter()
            .any(|l| l.trim() == "cancel-in-progress: false"),
        "the {writing} job cancels a channel write in progress"
    );
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
