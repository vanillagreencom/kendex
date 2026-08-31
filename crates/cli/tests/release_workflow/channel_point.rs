//! `tools/release-channel-point`, the guard the release workflow's channel
//! job runs. It is the only thing that writes the fixed pre-release release,
//! and every write it makes is destructive: two manifests overwritten in
//! place, on the one URL every candidate machine reads its updates from. So
//! what is asked of it here is which channel states let a write through and
//! which stop it with the channel as it was.
//!
//! What a write that failed partway leaves, and what the run after it does
//! with that, are `channel_point_failure.rs`. Which tags reach the guard at
//! all, and which job runs it, are `channel.rs`.

#[cfg(unix)]
use std::fs;

#[cfg(unix)]
use crate::channel::{REFUSED_VERSIONS, channel_step_env, core_can_read};
#[cfg(unix)]
use crate::test_util::rooted;
use crate::{job, job_declaring, step, workflow};

/// The binary the guard runs `version-compare` on, named by reading the
/// guard rather than by writing the name down twice: renamed on one side
/// only, every run here would stage a file the guard never looks at and
/// stop, which reads as the guard refusing rather than as a broken fixture.
#[allow(clippy::expect_used)]
pub(crate) fn compare_binary() -> String {
    let script = std::fs::read_to_string(channel_script()).expect("the channel guard");
    script
        .lines()
        .find_map(|line| line.trim().strip_prefix("compare=dist/"))
        .expect("the guard names the binary it compares with")
        .to_owned()
}

/// The guard the channel job runs, as a path this test can execute.
pub(crate) fn channel_script() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{CHANNEL_SCRIPT}"))
}

/// Named once, and checked below against the line the channel job runs: a
/// guard renamed on one side and not the other leaves every test here
/// exercising a file no tag run reaches.
const CHANNEL_SCRIPT: &str = "tools/release-channel-point";

/// What one run of the channel step did.
#[cfg(unix)]
pub(crate) struct Pointed {
    pub(crate) code: i32,
    pub(crate) calls: Vec<String>,
    /// Everything the run printed. A refusal that does not say what it found
    /// leaves nobody able to repair the channel, so the message is part of
    /// the behaviour rather than decoration on it.
    pub(crate) output: String,
    /// What the channel carries once the run is over, sorted, or `None` if
    /// no release is published there.
    pub(crate) after: Option<Vec<String>>,
}

#[cfg(unix)]
impl Pointed {
    pub(crate) fn ran(&self, verb: &str) -> Option<&String> {
        self.calls.iter().find(|c| c.starts_with(verb))
    }
}

/// The state of the pre-release channel a run finds.
#[cfg(unix)]
#[derive(Clone, Copy, Debug)]
pub(crate) enum Channel<'a> {
    /// No channel release published yet.
    Absent,
    /// Published, with nothing uploaded to it — the one state that leaves
    /// the guard with no version to compare and lets the write through.
    Empty,
    /// Published, its manifest naming this version.
    Carrying(&'a str),
    /// Published, carrying `feed.json` and no `latest.json` — the shape a
    /// half-written channel is left in, and the one the guard refuses
    /// because nothing on it can say what version it holds.
    HalfWritten,
    /// Published, with a manifest that names no version at all.
    Unreadable,
}

/// What a release job leaves in `dist` for the channel to publish: the two
/// manifests and one per-target digests document. The digests name carries
/// its target, so the guard cannot hold a list of them and these tests would
/// not notice a guard that published the manifests alone.
#[cfg(unix)]
pub(crate) const STAGED: [&str; 4] = [
    "latest.json",
    "feed.json",
    "digests-x86_64-unknown-linux-gnu.json",
    "digests-x86_64-unknown-linux-gnu.json.sig",
];

/// One channel and one `dist`, which the guard can be run against more than
/// once. What a run leaves behind is what the next one reads, assets and
/// manifest contents alike: an upload copies the staged file onto the
/// channel and the download copies it back, so the two are asked of the same
/// channel rather than of a second fixture posed to look like the first
/// one's wreckage.
///
/// The stub keeps the channel as a directory, one file per asset, so a call
/// reads what the calls before it actually wrote. A run cannot be shown a
/// channel that never existed, and the assertions below are about the state
/// the run left rather than the calls it happened to make.
#[cfg(unix)]
pub(crate) struct Fixture {
    /// Held for its `Drop`: the paths below live inside it.
    _dir: tempfile::TempDir,
    root: std::path::PathBuf,
    published: std::path::PathBuf,
}

#[cfg(unix)]
#[allow(clippy::unwrap_used)]
impl Fixture {
    pub(crate) fn new(channel: Channel, staged: &[&str]) -> Fixture {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let root = rooted(&dir);
        let dist = root.join("dist");
        fs::create_dir_all(&dist).unwrap();
        for name in staged {
            fs::write(dist.join(name), "{}").unwrap();
        }
        // The release stages its own CLI beside the manifests, and the
        // guard orders the two versions by running it. This is that binary
        // — the one these tests were built from — so the ordering under
        // test is the parser candidates read their feed with rather than a
        // stub posed to agree with it.
        fs::copy(env!("CARGO_BIN_EXE_kendex"), dist.join(compare_binary())).unwrap();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::write(
            bin.join("gh"),
            "#!/bin/sh\n\
             printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
             if [ -s \"$GH_FAIL\" ] && printf '%s\\n' \"$*\" | grep -qFf \"$GH_FAIL\"; then\n\
               if [ \"$1 $2\" = \"release upload\" ]; then\n\
                 # `--clobber` deletes an asset before uploading its\n\
                 # replacement, so an upload that fails loses what it was\n\
                 # replacing. GH_LANDED names the replacements that got up\n\
                 # before it gave up; the rest are gone.\n\
                 shift 3\n\
                 while [ $# -gt 0 ]; do\n\
                   case \"$1\" in --repo) shift 2; continue ;; --*) shift; continue ;; esac\n\
                   name=$(basename \"$1\")\n\
                   rm -f \"$GH_CHANNEL/$name\"\n\
                   for got in $GH_LANDED; do\n\
                     [ \"$got\" = \"$name\" ] && cp \"$1\" \"$GH_CHANNEL/$name\"\n\
                   done\n\
                   shift\n\
                 done\n\
               fi\n\
               exit 1\n\
             fi\n\
             case \"$1 $2\" in\n\
               \"release create\") mkdir -p \"$GH_CHANNEL\"; exit 0 ;;\n\
               \"release upload\")\n\
                 shift 3\n\
                 while [ $# -gt 0 ]; do\n\
                   case \"$1\" in --repo) shift 2; continue ;; --*) shift; continue ;; esac\n\
                   cp \"$1\" \"$GH_CHANNEL/$(basename \"$1\")\"\n\
                   shift\n\
                 done\n\
                 exit 0 ;;\n\
               \"release download\")\n\
                 dir=\"\"; want=\"\"\n\
                 while [ $# -gt 0 ]; do\n\
                   [ \"$1\" = \"--dir\" ] && dir=$2\n\
                   [ \"$1\" = \"--pattern\" ] && want=\"$want $2\"\n\
                   shift\n\
                 done\n\
                 [ -n \"$dir\" ] || exit 1\n\
                 # The channel's version is the only thing the guard comes\n\
                 # down here for. Any other pattern is a call it does not\n\
                 # make, and answering one would document behaviour it does\n\
                 # not have.\n\
                 [ \"$want\" = \" latest.json\" ] || exit 1\n\
                 mkdir -p \"$dir\"\n\
                 if [ -e \"$GH_CHANNEL/latest.json\" ]; then\n\
                   cp \"$GH_CHANNEL/latest.json\" \"$dir/latest.json\"\n\
                 fi\n\
                 exit 0 ;;\n\
             esac\n\
             case \"$2\" in\n\
               */releases)\n\
                 [ -d \"$GH_CHANNEL\" ] && printf '%s\\n' \"$CHANNEL\"\n\
                 exit 0\n\
                 ;;\n\
               */releases/tags/*)\n\
                 [ -d \"$GH_CHANNEL\" ] || exit 1\n\
                 ls \"$GH_CHANNEL\"\n\
                 exit 0\n\
                 ;;\n\
             esac\n\
             exit 0\n",
        )
        .unwrap();
        fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();

        let published = root.join("channel");
        if !matches!(channel, Channel::Absent) {
            fs::create_dir_all(&published).unwrap();
        }
        if matches!(channel, Channel::Carrying(_) | Channel::Unreadable) {
            // The seed for a channel no run here wrote. Past the first
            // upload the channel carries what that upload put on it.
            let seed = match channel {
                Channel::Carrying(version) => format!(r#"{{"version":"{version}"}}"#),
                _ => "{}".to_owned(),
            };
            fs::write(published.join("latest.json"), seed).unwrap();
            fs::write(published.join("feed.json"), "{}").unwrap();
        }
        if matches!(channel, Channel::HalfWritten) {
            fs::write(published.join("feed.json"), "{}").unwrap();
        }
        Fixture {
            _dir: dir,
            root,
            published,
        }
    }

    /// Runs the guard. `fail` holds fragments of the `gh` calls that should
    /// fail, standing in for the transient errors every read here has to
    /// tell apart from an answer; `landed` names the assets a failing upload
    /// gets onto the channel before it gives up.
    pub(crate) fn run(&self, new_version: &str, fail: &[&str], landed: &[&str]) -> Pointed {
        let log = self.root.join("gh.log");
        let failing = self.root.join("gh.fail");
        // Per run, so the calls below are this run's and not the last one's,
        // and so the version the guard reads back is one this run's own
        // download wrote rather than a leftover of the run before it.
        fs::write(&log, "").unwrap();
        fs::write(&failing, fail.join("\n")).unwrap();
        fs::remove_dir_all(self.root.join("manifest")).ok();
        // What the release job stages is the manifest of the tag it built.
        let staged_manifest = self.root.join("dist/latest.json");
        if staged_manifest.is_file() {
            fs::write(
                &staged_manifest,
                format!(r#"{{"version":"{new_version}"}}"#),
            )
            .unwrap();
        }
        let run = std::process::Command::new(channel_script())
            .current_dir(&self.root)
            .env_clear()
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.root.join("bin").display(),
                    std::env::var("PATH").unwrap_or_default()
                ),
            )
            .env("GH_LOG", &log)
            .env("GH_FAIL", &failing)
            .env("GH_LANDED", landed.join(" "))
            .env("GH_CHANNEL", &self.published)
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
        let after = fs::read_dir(&self.published).ok().map(|entries| {
            let mut names: Vec<String> = entries
                .filter_map(Result::ok)
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        });
        Pointed {
            code: run.status.code().unwrap_or(-1),
            calls,
            output: format!(
                "{}{}",
                String::from_utf8_lossy(&run.stdout),
                String::from_utf8_lossy(&run.stderr)
            ),
            after,
        }
    }
}

/// One run against a channel in this state, with the release's whole output
/// staged.
#[cfg(unix)]
fn point_channel(channel: Channel, new_version: &str, fail: &[&str]) -> Pointed {
    point_channel_staging(channel, new_version, fail, &STAGED)
}

/// The same, with the release's output named rather than assumed, for the
/// cases that are about what `dist` held.
#[cfg(unix)]
fn point_channel_staging(
    channel: Channel,
    new_version: &str,
    fail: &[&str],
    staged: &[&str],
) -> Pointed {
    Fixture::new(channel, staged).run(new_version, fail, &[])
}

/// A read that failed is not an empty channel. Every one of these leaves
/// the guard unable to say what the channel carries, and a run that
/// treated that as "nothing there" would upload over whatever is — which
/// is the rollback the guard exists to prevent, reached through a lost
/// connection instead of a stale tag.
///
/// Each names the read it could not make, because every one of these stops
/// the run whatever the guard concludes afterwards — a download nobody
/// checked leaves no manifest to read, which stops the write too, under a
/// message sending the operator at a channel that is fine.
#[cfg(unix)]
#[test]
fn a_read_it_could_not_make_stops_the_write() {
    for (state, failing, said) in [
        (
            Channel::Carrying("2.0.0-rc1"),
            "/releases --paginate",
            "releases could not be listed",
        ),
        (
            Channel::Carrying("2.0.0-rc1"),
            "/releases/tags/",
            "its assets could not be read",
        ),
        (
            Channel::Carrying("2.0.0-rc1"),
            "release download",
            "manifest could not be downloaded",
        ),
    ] {
        let run = point_channel(state, "1.0.0-rc1", &[failing]);
        assert_ne!(run.code, 0, "{failing} was survivable: {:?}", run.calls);
        assert!(
            run.ran("release upload").is_none(),
            "{failing} still uploaded: {:?}",
            run.calls
        );
        assert!(
            run.output.contains(said),
            "{failing} was reported as something else: {}",
            run.output
        );
    }

    // A manifest that names no version is the same answer: nothing here
    // can tell whether this tag is ahead of what is published.
    let run = point_channel(Channel::Unreadable, "1.0.0-rc1", &[]);
    assert_ne!(run.code, 0, "an unreadable manifest was survivable");
    assert!(run.ran("release upload").is_none(), "{:?}", run.calls);
}

/// The ordering runs the release's own binary, so a `dist` without it is a
/// run that can order nothing.
///
/// The download that stages it is a step of its own in the workflow and can
/// arrive with nothing in it, so the guard reads for the file rather than
/// trusting the step above it — and stops, naming what it could not find,
/// because a write it cannot justify is what it exists to refuse.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_release_that_staged_no_binary_stops_the_write() {
    let channel = Fixture::new(Channel::Carrying("1.0.0-rc1"), &STAGED);
    fs::remove_file(channel.root.join("dist").join(compare_binary())).unwrap();
    let run = channel.run("1.0.0-rc2", &[], &[]);
    assert_ne!(
        run.code, 0,
        "a dist with no binary was survivable: {:?}",
        run.calls
    );
    assert!(
        run.ran("release upload").is_none(),
        "it uploaded anyway: {:?}",
        run.calls
    );
    assert!(
        run.output
            .contains("the release's own binary is not in dist"),
        "the stop was reported as something else: {}",
        run.output
    );
}

/// A channel version nothing can put in an order is the same answer again.
/// The guard's whole job is to refuse a write it cannot justify, and it
/// cannot say `NEW_VERSION` moves the channel forward from a string that is
/// not a version — so it writes nothing rather than clobbering whatever is
/// really there. Each of these is refused by core too, asked of core rather
/// than asserted from the shapes, and the versions the test below drives
/// through are all accepted, so this cannot pass by refusing everything.
#[cfg(unix)]
#[test]
fn a_channel_version_that_is_not_a_version_stops_the_write() {
    let malformed: Vec<&str> = REFUSED_VERSIONS
        .into_iter()
        .chain([
            "not a version",
            "5",
            "",
            "v1.0.0",
            "1.0.0-rc1 ",
            // A digit outside ASCII. The guard's own pattern is where this
            // is decided, and a regex engine that reads `\d` as any Unicode
            // digit would order this against a candidate rather than refuse
            // it.
            "1.0.0-1\u{661}",
        ])
        .collect();
    for carried in malformed {
        assert!(
            !core_can_read(carried),
            "{carried} reads, so it is not an example of anything"
        );
        let run = point_channel(Channel::Carrying(carried), "1.0.0-rc2", &[]);
        assert_ne!(run.code, 0, "{carried} was survivable: {:?}", run.calls);
        assert!(
            run.ran("release upload").is_none(),
            "{carried} still uploaded: {:?}",
            run.calls
        );
    }
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
        let run = point_channel(state, "1.0.0-rc2", &[]);
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
        // The digests document and the signature beside it, named the way
        // an update names them rather than spelled here: a guard that
        // published the document alone leaves every candidate holding a
        // statement it cannot check, which reads as a broken update path
        // and not as a channel missing a file.
        let document = kendex_core::release_digests::release_digests_url(
            kendex_core::update_channel::PRERELEASE_MANIFEST_URL,
            "x86_64-unknown-linux-gnu",
        )
        .unwrap();
        for url in [
            document.clone(),
            kendex_core::update_feed::signature_url(&document),
        ] {
            let file = url.rsplit('/').next().unwrap_or_default();
            assert!(
                upload.contains(&format!("dist/{file}")),
                "dist/{file} missing from {upload}"
            );
        }
    }
}

/// Handed nothing to publish, the run stops rather than reporting a channel
/// it moved. An unmatched glob is left literal by the shell, so an upload
/// built by pasting patterns together names files that are not there and a
/// `dist` that arrived empty would still read as a channel repointed.
#[cfg(unix)]
#[test]
fn a_run_handed_no_manifests_writes_nothing() {
    let run = point_channel_staging(Channel::Carrying("1.0.0-rc1"), "1.0.0-rc2", &[], &[]);
    assert_ne!(run.code, 0, "{:?}", run.calls);
    assert!(
        run.ran("release upload").is_none(),
        "an empty dist still uploaded: {:?}",
        run.calls
    );
    // Both names, as a sentence: pasted together they read as a typo in a
    // CI log, which is the one place this message is ever read.
    assert!(
        run.output.contains("handed no latest.json or feed.json"),
        "{}",
        run.output
    );
}

/// The channel's two manifests are one answer, and either one alone is half
/// of it: the app stays on the version the stale latest.json names while
/// `kendex update` follows feed.json to the new one, with nothing on the
/// channel reporting the two as disagreeing. Driven over both names, so
/// neither direction can regress on its own.
#[cfg(unix)]
#[test]
fn a_run_handed_half_the_manifests_writes_nothing() {
    for (missing, staged) in [
        (
            "latest.json",
            ["feed.json", "digests-x86_64-unknown-linux-gnu.json"],
        ),
        (
            "feed.json",
            ["latest.json", "digests-x86_64-unknown-linux-gnu.json"],
        ),
    ] {
        let run = point_channel_staging(Channel::Carrying("1.0.0-rc1"), "1.0.0-rc2", &[], &staged);
        assert_ne!(run.code, 0, "{missing}: {:?}", run.calls);
        assert!(
            run.ran("release upload").is_none(),
            "half the answer still went up without {missing}: {:?}",
            run.calls
        );
        assert!(
            run.output.contains(&format!("was handed no {missing}")),
            "the run did not say which half it was missing: {}",
            run.output
        );
    }
}

/// The forward-only rule, asked of a channel this guard wrote rather than of
/// one the fixture posed. The version comes back out of the manifest the
/// first run uploaded, so the read the whole rule rests on is driven end to
/// end: a stub that put an empty file up there would leave the second run
/// with no version and no `hold` to make.
#[cfg(unix)]
#[test]
fn a_channel_this_guard_wrote_holds_against_an_older_tag() {
    let channel = Fixture::new(Channel::Empty, &STAGED);
    let wrote = channel.run("1.0.0-rc9", &[], &[]);
    assert_eq!(wrote.code, 0, "the first run refused: {}", wrote.output);

    let older = channel.run("1.0.0-rc2", &[], &[]);
    assert_eq!(
        older.code, 0,
        "the older tag was an error: {}",
        older.output
    );
    assert!(
        older.ran("release upload").is_none(),
        "the older tag rolled the channel back: {:?}",
        older.calls
    );
    assert!(
        older
            .output
            .contains("carries 1.0.0-rc9, ahead of 1.0.0-rc2"),
        "{}",
        older.output
    );
    assert_eq!(
        older.after, wrote.after,
        "the run that held still changed the channel: {:?}",
        older.calls
    );
}

/// The accepting side of the pair rule. Only the two manifests are required,
/// so a release built for fewer targets still points the channel — a guard
/// that grew to require a per-target document would refuse every one of them
/// and hold the channel until somebody read the job log.
#[cfg(unix)]
#[test]
fn a_release_with_no_digests_document_still_points_the_channel() {
    let run = point_channel_staging(
        Channel::Carrying("1.0.0-rc1"),
        "1.0.0-rc2",
        &[],
        &["latest.json", "feed.json"],
    );
    assert_eq!(
        run.code, 0,
        "a release with no digests was refused: {}",
        run.output
    );
    let upload = run
        .ran("release upload")
        .unwrap_or_else(|| panic!("nothing was published: {:?}", run.calls));
    for name in ["dist/latest.json", "dist/feed.json"] {
        assert!(upload.contains(name), "{name} missing from {upload}");
    }
}

/// A channel a write did not finish on is not a channel this run may take.
/// Carrying nothing is a release nothing has published to, and any tag may
/// have it; carrying assets with no `latest.json` is a release whose version
/// is gone, and calling that fresh lets every tag past the comparison this
/// guard exists to make — an older one included, which is the rollback it
/// refuses everywhere else. Repair is a person's.
#[cfg(unix)]
#[test]
fn a_channel_a_write_did_not_finish_on_stops_the_run() {
    let run = point_channel(Channel::HalfWritten, "1.0.0-rc2", &[]);
    assert_ne!(run.code, 0, "{:?}", run.calls);
    assert!(
        run.ran("release upload").is_none(),
        "a half-written channel was written over: {:?}",
        run.calls
    );
    // Named, because the one thing that clears this state is somebody
    // looking at the channel.
    assert!(
        run.output.contains("no latest.json"),
        "the run did not say what it found: {}",
        run.output
    );
}

/// A run that stops publishes nothing, the channel itself included. Every
/// refusal here says nothing was written, and a channel this run created on
/// its way to stopping would make that false — an empty release candidates
/// read as no update at all, left behind by a run that reported it had
/// touched nothing. Both refusals that can follow the creation are driven:
/// a version nothing can order, and a `dist` holding no manifests.
#[cfg(unix)]
#[test]
fn a_run_that_stops_leaves_no_channel_behind() {
    let unorderable = point_channel(Channel::Absent, "not a version", &[]);
    let empty = point_channel_staging(Channel::Absent, "1.0.0-rc2", &[], &[]);
    for run in [unorderable, empty] {
        assert_ne!(run.code, 0, "{:?}", run.calls);
        assert!(
            run.ran("release create").is_none(),
            "a channel was published by a run that wrote nothing: {:?}",
            run.calls
        );
        assert_eq!(
            run.after, None,
            "the channel is there after a run that said it wrote nothing: {:?}",
            run.calls
        );
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
            let run = point_channel(Channel::Carrying(carried), tagged, &[]);
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

/// The guard is a file the workflow names, so the two have to agree: renamed
/// on one side, every test here exercises something no tag run reaches.
#[test]
fn the_channel_job_runs_the_guard_these_tests_run() {
    let workflow = workflow();
    assert!(
        step(&workflow, "name: Point the pre-release channel at this tag")
            .iter()
            .any(|l| l.trim() == format!("run: {CHANNEL_SCRIPT}")),
        "the channel step does not run {CHANNEL_SCRIPT}"
    );
    assert!(channel_script().is_file(), "{CHANNEL_SCRIPT} is not a file");
    // The guard runs a binary the channel job never builds: it arrives in
    // the artifact the publish job uploads. Named on three sides — the
    // upload, the guard, and the classifier that reads the same lane's
    // binary — and a rename on any one of them leaves the guard with
    // nothing to order versions with and every candidate stopped.
    let compare = compare_binary();
    assert_eq!(
        compare,
        crate::channel::BUILT_CLI,
        "the guard compares with a binary the classifier does not read"
    );
    let staged: Vec<&str> = workflow
        .lines()
        .skip_while(|line| line.trim() != "name: manifests")
        .take_while(|line| !line.trim().starts_with("if-no-files-found"))
        .collect();
    assert!(
        staged
            .iter()
            .any(|line| line.trim() == format!("dist/{compare}")),
        "the manifests artifact does not carry dist/{compare}: {staged:?}"
    );
    // The job has to check the repository out, or that line runs nothing.
    assert!(
        job(&workflow, job_declaring(&workflow, CHANNEL_SCRIPT))
            .iter()
            .any(|l| l.contains("actions/checkout")),
        "the channel job never checks out {CHANNEL_SCRIPT}"
    );
}
