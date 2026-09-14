//! The single mutable feed pointer used by the candidate and main channels.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use crate::test_util::rooted;
use crate::{job, job_declaring, step, workflow};

const SCRIPT: &str = "tools/release-channel-point";
const TARGET: &str = "x86_64-unknown-linux-gnu";
const REPOSITORY: &str = "vanillagreencom/kendex";
const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{SCRIPT}"))
}

fn feed(version: &str, build: Option<u64>) -> String {
    let identity = build.map_or(String::new(), |build| {
        format!(r#""main_build":{build},"commit":"{COMMIT}","#)
    });
    format!(
        r#"{{"schema":1,{identity}"version":"{version}","assets":{{"{TARGET}":"https://example.test/build/kendex"}},"apps":{{}},"digests":{{"{TARGET}":"https://example.test/build/digests.json"}},"pub_date":"2026-09-14T00:00:00Z","platforms":{{}}}}"#
    )
}

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    channel: PathBuf,
}

impl Fixture {
    #[allow(clippy::unwrap_used)]
    fn new(current: Option<(&str, Option<u64>)>, candidate: (&str, Option<u64>)) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = rooted(&dir);
        let dist = root.join("dist");
        let bin = root.join("bin");
        let channel = root.join("channel-release");
        fs::create_dir_all(&dist).unwrap();
        fs::create_dir_all(&bin).unwrap();
        fs::write(dist.join("feed.json"), feed(candidate.0, candidate.1)).unwrap();
        fs::write(
            dist.join("kendex-x86_64-unknown-linux-gnu"),
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$IDENTITY_LOG\"\n\
             if [ \"$1\" = release-main-build ]; then\n\
               [ \"${FAIL_IDENTITY:-}\" != \"$2\" ] || exit 1\n\
               jq -r '.main_build // empty' \"$2\"\n\
               exit 0\n\
             fi\n\
             exec \"$REAL_KENDEX\" \"$@\"\n",
        )
        .unwrap();
        fs::set_permissions(
            dist.join("kendex-x86_64-unknown-linux-gnu"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::write(
            bin.join("gh"),
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
             case \"$1 $2\" in\n\
               'api repos/'*) case \"$2\" in\n\
                 */releases) [ -d \"$GH_CHANNEL\" ] && printf '%s\\n' \"$CHANNEL\"; exit 0 ;;\n\
                 */releases/tags/*) [ -d \"$GH_CHANNEL\" ] || exit 1; ls \"$GH_CHANNEL\"; exit 0 ;;\n\
               esac ;;\n\
               'release download')\n\
                 while [ $# -gt 0 ]; do [ \"$1\" = --dir ] && out=$2; shift; done\n\
                 mkdir -p \"$out\"; cp \"$GH_CHANNEL/feed.json\" \"$out/feed.json\"; exit 0 ;;\n\
               'release create') mkdir -p \"$GH_CHANNEL\"; exit 0 ;;\n\
               'release upload')\n\
                 rm -f \"$GH_CHANNEL/feed.json\"\n\
                 [ \"${GH_FAIL:-}\" != upload ] || exit 1\n\
                 mkdir -p \"$GH_CHANNEL\"; cp \"$4\" \"$GH_CHANNEL/feed.json\"; exit 0 ;;\n\
             esac\n\
             exit 1\n",
        )
        .unwrap();
        fs::set_permissions(bin.join("gh"), fs::Permissions::from_mode(0o755)).unwrap();
        if let Some((version, build)) = current {
            fs::create_dir_all(&channel).unwrap();
            fs::write(channel.join("feed.json"), feed(version, build)).unwrap();
        }
        Self {
            _dir: dir,
            root,
            channel,
        }
    }

    #[allow(clippy::unwrap_used)]
    fn run(&self, channel: &str, version: &str, build: Option<u64>) -> Output {
        self.run_with_identity_failure(channel, version, build, "")
    }

    #[allow(clippy::unwrap_used)]
    fn run_with_identity_failure(
        &self,
        channel: &str,
        version: &str,
        build: Option<u64>,
        failed_feed: &str,
    ) -> Output {
        Command::new(script())
            .current_dir(&self.root)
            .env_clear()
            .envs(crate::test_util::fixture_env(&self.root))
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.root.join("bin").display(),
                    std::env::var("PATH").unwrap_or_default()
                ),
            )
            .env("REAL_KENDEX", env!("CARGO_BIN_EXE_kendex"))
            .env("IDENTITY_LOG", self.root.join("identity.log"))
            .env("FAIL_IDENTITY", failed_feed)
            .env("GH_LOG", self.root.join("gh.log"))
            .env("GH_FAIL", "")
            .env("GH_CHANNEL", &self.channel)
            .env("GITHUB_REPOSITORY", REPOSITORY)
            .env("CHANNEL", channel)
            .env("NEW_VERSION", version)
            .env(
                "NEW_BUILD",
                build.map(|n| n.to_string()).unwrap_or_default(),
            )
            .output()
            .unwrap()
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.root.join("gh.log")).unwrap_or_default()
    }

    fn identity_calls(&self) -> String {
        fs::read_to_string(self.root.join("identity.log")).unwrap_or_default()
    }
}

#[test]
fn the_main_pointer_refuses_an_unauthenticated_build() {
    let current = format!("5.0.1+main.42.{COMMIT}");
    let offered = format!("5.0.1+main.43.{COMMIT}");
    for failed in ["dist/feed.json", "channel/feed.json"] {
        let fixture = Fixture::new(Some((&current, Some(42))), (&offered, Some(43)));
        let run = fixture.run_with_identity_failure("rolling-main", &offered, Some(43), failed);
        assert!(!run.status.success(), "{failed}");
        assert!(!fixture.calls().contains("release upload"), "{failed}");
    }
}

#[test]
fn a_channel_publishes_only_one_pointer() {
    let fixture = Fixture::new(None, ("1.0.0-rc2", None));
    let run = fixture.run("prerelease", "1.0.0-rc2", None);
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let calls = fixture.calls();
    let upload = calls
        .lines()
        .find(|line| line.starts_with("release upload"))
        .expect("the channel was not written");
    assert!(upload.contains("dist/feed.json"), "{upload}");
    assert!(!upload.contains("latest.json"), "{upload}");
    assert_eq!(fs::read_dir(&fixture.channel).unwrap().count(), 1);
}

#[test]
fn an_existing_channel_without_a_pointer_fails_closed() {
    let offered = format!("5.0.1+main.43.{COMMIT}");
    let fixture = Fixture::new(None, (&offered, Some(43)));
    fs::create_dir_all(&fixture.channel).unwrap();

    let run = fixture.run("rolling-main", &offered, Some(43));

    assert!(!run.status.success(), "{run:?}");
    assert!(
        String::from_utf8_lossy(&run.stdout)
            .contains("release-channel-point: channel-assets=empty"),
        "{run:?}"
    );
    let calls = fixture.calls();
    assert!(!calls.contains("release create"), "{calls}");
    assert!(!calls.contains("release upload"), "{calls}");
}

#[test]
fn the_candidate_pointer_moves_only_to_a_newer_version() {
    for (candidate, writes) in [
        ("1.0.0-rc3", true),
        ("1.0.0-rc10", false),
        ("1.0.0-rc2", false),
        ("1.0.0-rc1", false),
    ] {
        let fixture = Fixture::new(Some(("1.0.0-rc2", None)), (candidate, None));
        let run = fixture.run("prerelease", candidate, None);
        assert!(run.status.success(), "{candidate}: {run:?}");
        assert_eq!(
            fixture.calls().contains("release upload"),
            writes,
            "{candidate}"
        );
    }
}

#[test]
fn the_main_pointer_authenticates_both_builds_and_moves_only_forward() {
    for (candidate, writes) in [(43, true), (42, false), (41, false)] {
        let current = format!("5.0.1+main.42.{COMMIT}");
        let offered = format!("5.0.1+main.{candidate}.{COMMIT}");
        let fixture = Fixture::new(Some((&current, Some(42))), (&offered, Some(candidate)));
        let run = fixture.run("rolling-main", &offered, Some(candidate));
        assert!(run.status.success(), "{candidate}: {run:?}");
        assert_eq!(
            fixture.calls().contains("release upload"),
            writes,
            "{candidate}"
        );
        let identities = fixture.identity_calls();
        assert!(
            identities.contains("release-main-build dist/feed.json"),
            "{identities}"
        );
        assert!(
            identities.contains("release-main-build channel/feed.json"),
            "{identities}"
        );
    }
}

#[test]
fn the_workflow_publishes_an_immutable_main_release_before_the_pointer() {
    let release = workflow();
    let classify = crate::run_script(&step(&release, "name: Classify the tag"));
    for part in ["GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT", "commit"] {
        assert!(classify.contains(part), "immutable tag omits {part}");
    }
    assert!(!classify.contains("release_ref=rolling-main"));
    let publish = job_declaring(&release, "uses: softprops/action-gh-release@v2");
    let point = job_declaring(&release, "name: Point the rolling channel at this build");
    assert_ne!(publish, point);
    assert!(
        job(&release, point)
            .iter()
            .any(|line| line.trim() == "needs: publish")
    );
    assert!(script().is_file());
}
