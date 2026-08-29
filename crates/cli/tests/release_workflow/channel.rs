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

/// The CLI the classifier reads the built version back from, named the way
/// the staging step leaves it in `dist/`. A release job runs on Linux
/// x86_64, so this is the one lane's binary it can execute.
const BUILT_CLI: &str = "kendex-x86_64-unknown-linux-gnu";

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
    assert_eq!(
        read.trim(),
        "steps.tag.outputs.prerelease",
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
const REFUSED_VERSIONS: [&str; 6] = [
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
fn core_can_read(version: &str) -> bool {
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

/// The state of the pre-release channel a run finds.
#[cfg(unix)]
#[derive(Clone, Copy, Debug)]
enum Channel<'a> {
    /// No channel release published yet.
    Absent,
    /// Published, with nothing uploaded to it — the one state that leaves
    /// the guard with no version to compare and lets the write through.
    Empty,
    /// Published, its manifest naming this version.
    Carrying(&'a str),
    /// Published, with a manifest that names no version at all.
    Unreadable,
}

/// Runs the pre-release channel step with `gh` stubbed. `fail` is a
/// fragment of the one `gh` call that should fail, standing in for the
/// transient errors every read here has to tell apart from an answer.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn point_channel(channel: Channel, new_version: &str, fail: Option<&str>) -> Pointed {
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
    // Records every call and answers the three the run reads: whether the
    // channel is among the repository's releases, whether it carries a
    // manifest, and what that manifest says. `--output` is honoured rather
    // than assumed, so a step downloading to some other name would read no
    // version and be caught.
    fs::write(
        bin.join("gh"),
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
         if [ -n \"$GH_FAIL\" ]; then\n\
           case \"$*\" in *\"$GH_FAIL\"*) exit 1 ;; esac\n\
         fi\n\
         case \"$2\" in\n\
           */releases)\n\
             [ -n \"$GH_EXISTS\" ] && printf '%s\\n' \"$CHANNEL\"\n\
             exit 0\n\
             ;;\n\
           */releases/tags/*)\n\
             [ -n \"$GH_HAS_MANIFEST\" ] && printf 'latest.json\\n'\n\
             exit 0\n\
             ;;\n\
         esac\n\
         if [ \"$1 $2\" = \"release download\" ]; then\n\
           while [ $# -gt 0 ]; do\n\
             [ \"$1\" = \"--output\" ] && out=$2\n\
             shift\n\
           done\n\
           [ -n \"$out\" ] || exit 1\n\
           printf '%s\\n' \"$GH_MANIFEST\" > \"$out\"\n\
         fi\n\
         exit 0\n",
    )
    .unwrap();
    fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();

    let (exists, has_manifest, manifest) = match channel {
        Channel::Absent => ("", "", String::new()),
        Channel::Empty => ("1", "", String::new()),
        Channel::Carrying(version) => ("1", "1", format!(r#"{{"version":"{version}"}}"#)),
        Channel::Unreadable => ("1", "1", "{}".to_owned()),
    };

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
        .env("GH_EXISTS", exists)
        .env("GH_HAS_MANIFEST", has_manifest)
        .env("GH_MANIFEST", &manifest)
        .env("GH_FAIL", fail.unwrap_or_default())
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

/// A read that failed is not an empty channel. Every one of these leaves
/// the guard unable to say what the channel carries, and a run that
/// treated that as "nothing there" would upload over whatever is — which
/// is the rollback the guard exists to prevent, reached through a lost
/// connection instead of a stale tag.
#[cfg(unix)]
#[test]
fn a_read_it_could_not_make_stops_the_write() {
    for (state, failing) in [
        (Channel::Carrying("2.0.0-rc1"), "/releases --paginate"),
        (Channel::Carrying("2.0.0-rc1"), "/releases/tags/"),
        (Channel::Carrying("2.0.0-rc1"), "release download"),
    ] {
        let run = point_channel(state, "1.0.0-rc1", Some(failing));
        assert_ne!(run.code, 0, "{failing} was survivable: {:?}", run.calls);
        assert!(
            run.ran("release upload").is_none(),
            "{failing} still uploaded: {:?}",
            run.calls
        );
    }

    // A manifest that names no version is the same answer: nothing here
    // can tell whether this tag is ahead of what is published.
    let run = point_channel(Channel::Unreadable, "1.0.0-rc1", None);
    assert_ne!(run.code, 0, "an unreadable manifest was survivable");
    assert!(run.ran("release upload").is_none(), "{:?}", run.calls);
}

/// Both manifests reach the channel whether or not the release behind it
/// exists yet, and the upload replaces what is there. Without `--clobber`
/// the first candidate's manifests stay and every later one is refused, so
/// the channel would freeze on rc1 while reporting success.
#[cfg(unix)]
#[test]
fn every_candidate_replaces_both_manifests_on_the_channel() {
    for state in [
        Channel::Absent,
        Channel::Empty,
        Channel::Carrying("1.0.0-rc1"),
    ] {
        let run = point_channel(state, "1.0.0-rc2", None);
        assert_eq!(run.code, 0, "{state:?}: {:?}", run.calls);
        assert_eq!(
            run.ran("release create").is_some(),
            matches!(state, Channel::Absent),
            "{state:?}: {:?}",
            run.calls
        );
        let upload = run
            .ran("release upload")
            .unwrap_or_else(|| panic!("{state:?} uploaded nothing: {:?}", run.calls));
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
            let run = point_channel(Channel::Carrying(carried), tagged, None);
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
