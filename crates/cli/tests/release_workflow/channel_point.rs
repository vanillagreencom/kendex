//! `tools/release-channel-point`, the guard the release workflow's channel
//! job runs. It is the only thing that writes the fixed pre-release release,
//! and every write it makes is destructive: two manifests overwritten in
//! place, on the one URL every candidate machine reads its updates from. So
//! what is asked of it here is not what it does when the calls succeed but
//! what it leaves behind when one of them does not.
//!
//! Which tags reach it at all, and which job runs it, are `channel.rs`.

#[cfg(unix)]
use std::fs;

#[cfg(unix)]
use crate::channel::{REFUSED_VERSIONS, channel_step_env, core_can_read};
#[cfg(unix)]
use crate::test_util::rooted;
use crate::{job, job_declaring, step, workflow};

/// The guard the channel job runs, as a path this test can execute.
fn channel_script() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{CHANNEL_SCRIPT}"))
}

/// Named once, and checked below against the line the channel job runs: a
/// guard renamed on one side and not the other leaves every test here
/// exercising a file no tag run reaches.
const CHANNEL_SCRIPT: &str = "tools/release-channel-point";

/// What one run of the channel step did.
#[cfg(unix)]
struct Pointed {
    code: i32,
    calls: Vec<String>,
    /// Everything the run printed. A channel left half written is bad; one
    /// that announces itself as repaired is what stops anyone looking, so
    /// the message is part of the behaviour rather than decoration on it.
    output: String,
    /// What the channel carries once the run is over, sorted, or `None` if
    /// no release is published there.
    after: Option<Vec<String>>,
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
    /// Published, carrying `feed.json` and no `latest.json` — the shape a
    /// half-written channel is left in, which the guard reads as fresh.
    HalfWritten,
    /// Published, with a manifest that names no version at all.
    Unreadable,
}

/// Runs the guard with `gh` stubbed. `fail` holds fragments of the `gh`
/// calls that should fail, standing in for the transient errors every read
/// here has to tell apart from an answer; `landed` names the manifests a
/// failing upload gets onto the channel before it gives up.
///
/// The stub keeps the channel as a directory, one file per asset, so a call
/// reads what the calls before it actually wrote. A run cannot be shown a
/// channel that never existed, and the assertions below are about the state
/// the run left rather than the calls it happened to make.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn point_channel(channel: Channel, new_version: &str, fail: &[&str], landed: &[&str]) -> Pointed {
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
    let failing = root.join("gh.fail");
    fs::write(&failing, fail.join("\n")).unwrap();
    let published = root.join("channel");
    fs::write(
        bin.join("gh"),
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
         if [ -s \"$GH_FAIL\" ] && printf '%s\\n' \"$*\" | grep -qFf \"$GH_FAIL\"; then\n\
           if [ \"$1 $2\" = \"release upload\" ]; then\n\
             # `--clobber` deletes an asset before uploading its replacement,\n\
             # so an upload that fails loses what it was replacing.\n\
             shift 3\n\
             while [ $# -gt 0 ]; do\n\
               case \"$1\" in --repo) shift 2; continue ;; --*) shift; continue ;; esac\n\
               rm -f \"$GH_CHANNEL/$(basename \"$1\")\"\n\
               shift\n\
             done\n\
             for name in $GH_LANDED; do touch \"$GH_CHANNEL/$name\"; done\n\
           fi\n\
           exit 1\n\
         fi\n\
         case \"$1 $2\" in\n\
           \"release create\") mkdir -p \"$GH_CHANNEL\"; exit 0 ;;\n\
           \"release delete\") rm -rf \"$GH_CHANNEL\"; exit 0 ;;\n\
           \"release delete-asset\")\n\
             [ -e \"$GH_CHANNEL/$4\" ] || exit 1\n\
             rm -f \"$GH_CHANNEL/$4\"\n\
             exit 0 ;;\n\
           \"release upload\")\n\
             shift 3\n\
             while [ $# -gt 0 ]; do\n\
               case \"$1\" in --repo) shift 2; continue ;; --*) shift; continue ;; esac\n\
               touch \"$GH_CHANNEL/$(basename \"$1\")\"\n\
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
             mkdir -p \"$dir\"\n\
             for name in $want; do\n\
               [ -e \"$GH_CHANNEL/$name\" ] || continue\n\
               case \"$name\" in\n\
                 latest.json) printf '%s\\n' \"$GH_MANIFEST\" > \"$dir/latest.json\" ;;\n\
                 feed.json) printf '%s\\n' \"$GH_FEED\" > \"$dir/feed.json\" ;;\n\
               esac\n\
             done\n\
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

    let manifest = match channel {
        Channel::Carrying(version) => format!(r#"{{"version":"{version}"}}"#),
        _ => "{}".to_owned(),
    };
    if !matches!(channel, Channel::Absent) {
        fs::create_dir_all(&published).unwrap();
    }
    if matches!(channel, Channel::Carrying(_) | Channel::Unreadable) {
        for name in ["latest.json", "feed.json"] {
            fs::write(published.join(name), "").unwrap();
        }
    }
    if matches!(channel, Channel::HalfWritten) {
        fs::write(published.join("feed.json"), "").unwrap();
    }

    let run = std::process::Command::new(channel_script())
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
        .env("GH_FAIL", &failing)
        .env("GH_LANDED", landed.join(" "))
        .env("GH_CHANNEL", &published)
        .env("GH_MANIFEST", &manifest)
        .env(
            "GH_FEED",
            r#"{"schema":1,"version":"published","assets":{}}"#,
        )
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
    let after = fs::read_dir(&published).ok().map(|entries| {
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
        let run = point_channel(state, "1.0.0-rc1", &[failing], &[]);
        assert_ne!(run.code, 0, "{failing} was survivable: {:?}", run.calls);
        assert!(
            run.ran("release upload").is_none(),
            "{failing} still uploaded: {:?}",
            run.calls
        );
    }

    // A manifest that names no version is the same answer: nothing here
    // can tell whether this tag is ahead of what is published.
    let run = point_channel(Channel::Unreadable, "1.0.0-rc1", &[], &[]);
    assert_ne!(run.code, 0, "an unreadable manifest was survivable");
    assert!(run.ran("release upload").is_none(), "{:?}", run.calls);
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
        .chain(["not a version", "5", "", "v1.0.0", "1.0.0-rc1 "])
        .collect();
    for carried in malformed {
        assert!(
            !core_can_read(carried),
            "{carried} reads, so it is not an example of anything"
        );
        let run = point_channel(Channel::Carrying(carried), "1.0.0-rc2", &[], &[]);
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
        let run = point_channel(state, "1.0.0-rc2", &[], &[]);
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

/// `gh release upload --clobber` deletes an asset before uploading its
/// replacement, and says in its own help that a failed upload loses the
/// original. A candidate reading a channel with no `latest.json` sees no
/// update at all, so an upload that fell over halfway would break every
/// candidate machine until somebody re-ran a tag. What came down goes back
/// up. Not an atomic swap — there is no such thing here — but a failure
/// that leaves the channel as it found it.
#[cfg(unix)]
#[test]
fn a_failed_upload_puts_back_what_the_channel_had() {
    let run = point_channel(
        Channel::Carrying("1.0.0-rc1"),
        "1.0.0-rc2",
        &["dist/latest.json"],
        &[],
    );
    assert_ne!(
        run.code, 0,
        "a failed upload was survivable: {:?}",
        run.calls
    );
    let restored = run
        .calls
        .iter()
        .filter(|c| c.starts_with("release upload"))
        .nth(1)
        .unwrap_or_else(|| panic!("nothing was put back: {:?}", run.calls));
    // Both names, and from the copies on disk: the shell expanded the glob
    // against what the download actually wrote, so a manifest that never
    // came down could not appear here.
    for name in ["saved/latest.json", "saved/feed.json"] {
        assert!(restored.contains(name), "{name} not restored: {restored}");
    }
    assert!(restored.contains("--clobber"), "{restored}");
    assert_eq!(
        run.after,
        Some(vec!["feed.json".to_owned(), "latest.json".to_owned()]),
        "the channel is not carrying what it was: {:?}",
        run.calls
    );
    assert!(
        run.output.contains("is back as this run found it"),
        "{}",
        run.output
    );
}

/// A channel this run created, and could not then write, is a channel that
/// was not there before this run. There is nothing to put back on it: the
/// copies the case above restores from are of manifests the channel already
/// carried, and a fresh one carried none. So the release goes, and what a
/// half-populated channel would have said — that a candidate is up to date
/// on manifests naming downloads that were never uploaded — is not said at
/// all. The tag it was created on stays: `gh release create` reuses one, so
/// a run cannot tell a tag it made from a tag that was already there, and a
/// tag carrying no release publishes nothing either way.
#[cfg(unix)]
#[test]
fn a_failed_upload_removes_a_channel_this_run_created() {
    let run = point_channel(
        Channel::Absent,
        "1.0.0-rc2",
        &["dist/feed.json"],
        &["latest.json"],
    );
    assert_ne!(
        run.code, 0,
        "a failed upload was survivable: {:?}",
        run.calls
    );
    assert_eq!(
        run.after, None,
        "the channel this run created was left behind: {:?}",
        run.calls
    );
    assert!(
        run.ran(&format!("release delete {}", channel_step_env("CHANNEL")))
            .is_some(),
        "nothing removed the channel: {:?}",
        run.calls
    );
    assert!(run.output.contains("has been removed"), "{}", run.output);
}

/// A channel published but carrying nothing is the other fresh state, and
/// the one the case above leaves behind. Nothing comes back here either,
/// because nothing was there — what has to go is whatever this run put on
/// it, so the next tag finds the empty channel the last one found.
#[cfg(unix)]
#[test]
fn a_failed_upload_takes_back_what_it_put_on_an_empty_channel() {
    let run = point_channel(
        Channel::Empty,
        "1.0.0-rc2",
        &["dist/feed.json"],
        &["latest.json"],
    );
    assert_ne!(
        run.code, 0,
        "a failed upload was survivable: {:?}",
        run.calls
    );
    assert_eq!(
        run.after,
        Some(Vec::new()),
        "the channel kept what this run put on it: {:?}",
        run.calls
    );
    assert!(
        run.output.contains("is back as this run found it"),
        "{}",
        run.output
    );
}

/// The restore is `gh` calls too, and they fail the way every other call
/// here can. What must not happen then is the run reporting a channel it did
/// not put back: a half-written channel that announces itself as repaired is
/// what stops anyone looking at it. So the message says it could not, and
/// names what is on the channel for whoever has to repair it.
#[cfg(unix)]
#[test]
fn a_restore_that_could_not_finish_says_what_the_channel_carries() {
    let run = point_channel(
        Channel::Carrying("1.0.0-rc1"),
        "1.0.0-rc2",
        &["dist/feed.json", "saved/"],
        &["latest.json"],
    );
    assert_ne!(
        run.code, 0,
        "a failed restore was survivable: {:?}",
        run.calls
    );
    assert_eq!(
        run.after,
        Some(vec!["latest.json".to_owned()]),
        "the fixture did not leave a half-written channel: {:?}",
        run.calls
    );
    assert!(
        run.output.contains("could not be put back")
            && run.output.contains("It carries latest.json"),
        "{}",
        run.output
    );
    assert!(
        !run.output.contains("is back as this run found it"),
        "a channel that was not put back was reported as put back: {}",
        run.output
    );
}

/// Every command the restore runs changes the asset set on its way to
/// failing: `--clobber` deletes an asset before uploading its replacement,
/// and a `delete-asset` only runs once a saved upload has already landed. So
/// the set as the restore found it is not the set the operator will find,
/// and naming that one is worse than naming none, because it reads as
/// current and sends them at the wrong thing.
#[cfg(unix)]
#[test]
fn a_restore_that_changed_the_channel_names_what_is_there_now() {
    let run = point_channel(
        Channel::HalfWritten,
        "1.0.0-rc2",
        &["dist/latest.json", "delete-asset"],
        &["latest.json"],
    );
    assert_ne!(
        run.code, 0,
        "a failed restore was survivable: {:?}",
        run.calls
    );
    // The saved feed.json is back up, and the latest.json this run added is
    // still there because taking it off is the command that failed.
    assert_eq!(
        run.after,
        Some(vec!["feed.json".to_owned(), "latest.json".to_owned()]),
        "the restore left the channel unchanged, so this proves nothing: {:?}",
        run.calls
    );
    assert!(
        run.output.contains("It carries feed.json latest.json"),
        "{}",
        run.output
    );
    // What the channel carried when the restore began, and so what a snapshot
    // taken before it would have named.
    assert!(
        !run.output.contains("It carries latest.json"),
        "the message names the channel as the restore found it: {}",
        run.output
    );
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
            let run = point_channel(Channel::Carrying(carried), tagged, &[], &[]);
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
    // The job has to check the repository out, or that line runs nothing.
    assert!(
        job(&workflow, job_declaring(&workflow, CHANNEL_SCRIPT))
            .iter()
            .any(|l| l.contains("actions/checkout")),
        "the channel job never checks out {CHANNEL_SCRIPT}"
    );
}
