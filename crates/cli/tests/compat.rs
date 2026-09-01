//! Black-box tests for the binding surface: bare-form add, report routing
//! (dry-run + stubbed gh), self-update against a local release feed, and
//! init scaffolding.
#![cfg(unix)]

#[path = "../../fixture_url.rs"]
mod fixture_url;
use fixture_url::file_url;

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

/// A lock naming the version this build writes and the project it sits in
/// — the two records every project lock carries, without either of which a
/// read refuses it.
#[allow(clippy::unwrap_used)]
fn lock_of(proj: &Path, entries: &str) -> String {
    format!(
        r#"{{"version":{},"root":{},"entries":{{{entries}}}}}"#,
        kendex_core::lock::LOCK_VERSION,
        serde_json::to_string(&proj.display().to_string()).unwrap()
    )
}

#[allow(clippy::expect_used)]
fn kendex_in(home: &Path, cwd: &Path, args: &[&str], envs: &[(&str, String)]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    for (key, value) in envs {
        command.env(key, value);
    }
    command.output().expect("kendex binary runs")
}

/// Runs a copy of the binary that was written moments ago, from `home`.
///
/// Exec of a just-written file answers ETXTBSY while any process still
/// holds a descriptor open for writing it. Nothing here keeps one — but a
/// sibling test in this binary forks to run its own command, that child
/// inherits ours for the moment between its fork and its exec, and under
/// load that moment is long enough to land in. The descriptor goes as soon
/// as the child execs, so the answer is to ask again rather than to stop
/// copying.
fn kendex_copy(exe: &Path, home: &Path, args: &[&str], envs: &[(&str, String)]) -> Output {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let mut command = Command::new(exe);
        command
            .args(args)
            .env_clear()
            .env("HOME", home)
            .env("KENDEX_REAL_HOME", "1")
            .env("PATH", std::env::var("PATH").unwrap_or_default());
        for (key, value) in envs {
            command.env(key, value);
        }
        match command.output() {
            Ok(output) => return output,
            Err(error)
                if error.kind() == std::io::ErrorKind::ExecutableFileBusy
                    && std::time::Instant::now() < deadline =>
            {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Err(error) => panic!("running {}: {error}", exe.display()),
        }
    }
}

/// The CLI replaces a desktop app only where the release publishes one it
/// installed. Elsewhere the app arrives by its own route and is not the
/// command's to touch or to describe.
fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// Whether this target's release carries an app for the command to
/// replace, asked of the helper the command itself asks. Restating the
/// mapping here would let the test hold one contract while the code holds
/// another, and agree again only by luck. The version is any valid SemVer:
/// it is parsed and then plays no part in the answer.
fn publishes_an_app_image() -> bool {
    matches!(
        kendex_core::update_feed::app_image_url("9.9.9", env!("KENDEX_TARGET")),
        Ok(Some(_))
    )
}

#[allow(clippy::unwrap_used)]
fn sandbox_with_catalog() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join("catalog/skills/gh")).unwrap();
    fs::write(
        home.join("catalog/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\nBody.\n",
    )
    .unwrap();
    fs::create_dir_all(home.join("proj/.claude")).unwrap();
    tmp
}

#[test]
fn bare_form_maps_to_add_flag_for_flag() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let catalog = home.join("catalog").display().to_string();

    let output = kendex_in(
        home,
        &home.join("proj"),
        &[&catalog, "--skill", "gh", "--harness", "claude", "-y"],
        &[],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(home.join("proj/.agents/skills/gh/SKILL.md").is_file());
    assert!(home.join("proj/.claude/skills/gh").is_symlink());
}

#[test]
fn report_dry_run_routes_by_ownership_and_rejects_scope_all() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");
    // Locked assets from the canonical upstream route to it. The skill is
    // symlinked, as every installed skill is; delivery is not ownership.
    fs::write(
        proj.join(".kendex-lock.json"),
        lock_of(
            &proj,
            r#""agent:orch:claude":{"name":"orch","kind":"agent","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true},"skill:size-ratchet:claude":{"name":"size-ratchet","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true}"#,
        ),
    )
    .unwrap();

    let upstream = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--agent",
            "orch",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(upstream.status.success());
    let text = String::from_utf8_lossy(&upstream.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");

    let skill = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(skill.status.success());
    let text = String::from_utf8_lossy(&skill.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");

    let local = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--asset",
            "mystery",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    let text = String::from_utf8_lossy(&local.stderr);
    assert!(text.contains("ownership: project-local"), "{text}");
    assert!(!text.contains("--label"), "{text}");

    // Naming a kind lets the lock resolve it: the label and the body marker
    // are the ones `--skill` would stamp.
    let asset = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--asset",
            "size-ratchet",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(asset.status.success());
    let text = String::from_utf8_lossy(&asset.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");
    assert!(text.contains("kind=skill"), "{text}");

    // A named upstream the lock never recorded is not proof of ownership.
    let forked = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--upstream",
            "someone/else",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(forked.status.success());
    let text = String::from_utf8_lossy(&forked.stderr);
    assert!(text.contains("ownership: project-local"), "{text}");
    assert!(!text.contains("someone/else"), "{text}");

    // A subscription spells the upstream however it likes, and the report
    // still files at the one place gh accepts: `owner/repo`, never the URL.
    let spelled = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--skill",
            "size-ratchet",
            "--upstream",
            "git@github.com:vanillagreencom/kendex.git",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(spelled.status.success());
    let text = String::from_utf8_lossy(&spelled.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("target: vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(!text.contains("git@github.com"), "{text}");

    let rejected = kendex_in(
        home,
        &proj,
        &["report", "--title", "T", "--body", "B", "--scope", "all"],
        &[],
    );
    assert!(!rejected.status.success());
}

#[test]
#[allow(clippy::unwrap_used)]
fn report_files_through_a_stubbed_gh() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");

    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}/gh-args.txt\necho https://github.com/x/1\n",
            home.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    // Triage dates a report against the fix that already landed, so the
    // marker carries what the lock recorded. An installation the lock never
    // dated says so and still files.
    for (recorded, stamped) in [
        (
            r#","sourceCommit":"abc1234def5678","renderedHash":"9f8e7d6c5b4a""#,
            "source=vanillagreencom/kendex@abc1234 rendered=9f8e7d6",
        ),
        ("", "source=unlocked rendered=unlocked"),
    ] {
        fs::write(
            proj.join(".kendex-lock.json"),
            lock_of(
                &proj,
                &format!(
                    r#""hook:guard:claude":{{"name":"guard","kind":"hook","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x"{recorded},"enabled":true}}"#
                ),
            ),
        )
        .unwrap();

        let output = kendex_in(
            home,
            &proj,
            &[
                "report", "--hook", "guard", "--title", "Broken", "--body", "Details",
            ],
            &[("PATH", path.clone())],
        );
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("Issue filed: https://github.com/x/1")
        );
        let args = fs::read_to_string(home.join("gh-args.txt")).unwrap();
        assert!(args.contains("vanillagreencom/kendex"));
        assert!(args.contains("harness"));
        assert!(
            args.contains(&format!(
                "kendex-report:v1 asset=guard kind=hook ownership=kendex {stamped} -->"
            )),
            "{args}"
        );
    }
}

/// A release publishes what it built for this target beside its feed, and
/// signs it; a fixture feed publishes the document and cannot sign it.
/// That is the point: nothing here can produce a signature under the
/// release key, so the real binary driven end to end refuses and leaves
/// the command exactly as it was. The admitted arm — signatures that check
/// out, and the write that follows them — is covered in
/// `commands::update::tests`, which holds a keypair of its own.
#[allow(clippy::unwrap_used)]
fn a_release_that_cannot_be_verified(home: &Path, target: &str) {
    let name = format!("digests-{target}.json");
    fs::write(
        home.join(&name),
        format!(
            r#"{{"schema":1,"version":"9.9.9","target":"{target}","command":"{zero}","app":"{zero}"}}"#,
            zero = "0".repeat(64)
        ),
    )
    .unwrap();
    fs::write(
        home.join(format!("{name}.sig")),
        "not the release signature",
    )
    .unwrap();
}

/// A family update moves the app and the command to one release, and what
/// says the pair arrived together afterwards is that the app reports the
/// version `kendex --version` prints. The app bundle carries its version in
/// `crates/app/tauri.conf.json` and the command bakes its own, so the two
/// are one release only while this holds.
///
/// Read off the built binary rather than off `CARGO_PKG_VERSION`: what the
/// person sees after the update is what the command prints, and a build
/// that printed something else would pass a comparison of two constants.
#[test]
#[allow(clippy::unwrap_used)]
fn the_app_version_is_the_one_kendex_version_prints() {
    let conf: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../app/tauri.conf.json"))
            .unwrap(),
    )
    .unwrap();
    let app_version = conf["version"]
        .as_str()
        .expect("the app bundle names a version");

    // Through the file's own runner: `--version` bootstraps the installed
    // command record before clap answers, and that write belongs in this
    // test's fixture rather than in the account running the suite.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let said = kendex_in(&home, &home, &["--version"], &[]);

    assert_eq!(
        String::from_utf8_lossy(&said.stdout).trim(),
        format!("kendex {app_version}"),
        "the app ships {app_version} and the command answers otherwise"
    );
}

/// The feed is unsigned text naming a host, so what it offers has to be
/// held to the release key before it lands on the running command.
#[test]
#[allow(clippy::unwrap_used)]
fn update_over_a_local_feed_refuses_a_command_it_cannot_verify() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let me = bin.join("kendex");
    fs::copy(env!("CARGO_BIN_EXE_kendex"), &me).unwrap();
    fs::set_permissions(&me, fs::Permissions::from_mode(0o755)).unwrap();

    let installed = fs::read(&me).unwrap();
    fs::write(home.join("new-binary"), "#!/bin/sh\necho v9\n").unwrap();
    // A release publishes a signature beside every download, so the fixture
    // does too; this one is not the release's, which is what gets refused.
    fs::write(home.join("new-binary.sig"), "not the release signature").unwrap();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema": 1, "version": "9.9.9", "assets": {{"{target}": {}}}}}"#,
            serde_json::to_string(&file_url(&home.join("new-binary"))).unwrap()
        ),
    )
    .unwrap();
    a_release_that_cannot_be_verified(home, target);

    let output = kendex_copy(
        &me,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    let refused = stderr(&output);
    assert!(!output.status.success(), "{refused}");
    assert!(
        refused.contains("does not verify under the pinned release key"),
        "{refused}"
    );
    assert_eq!(
        fs::read(&me).unwrap(),
        installed,
        "the command moved anyway"
    );
    let said = String::from_utf8_lossy(&output.stdout);
    match publishes_an_app_image() {
        true => assert!(said.contains("no kendex desktop app here"), "{said}"),
        // Nothing here installs an app, so nothing here may claim one way
        // or the other about the app this platform does have.
        false => assert!(!said.contains("desktop app"), "{said}"),
    }

    // Same version → no-op without --force.
    let same = fs::read_to_string(home.join("feed.json"))
        .unwrap()
        .replace("9.9.9", env!("CARGO_PKG_VERSION"));
    fs::write(home.join("feed.json"), same).unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("already up to date"));

    let older = fs::read_to_string(home.join("feed.json"))
        .unwrap()
        .replace(env!("CARGO_PKG_VERSION"), "0.1.0");
    fs::write(home.join("feed.json"), older).unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("older than installed"));

    fs::write(
        home.join("feed.json"),
        r#"{"schema":1,"version":"99.0.0","assets":{}}"#,
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("releases/tag/v99.0.0"));

    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"version":"{}","assets":{{}}}}"#,
            env!("CARGO_PKG_VERSION")
        ),
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update", "--force"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    let current = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(current.contains("unchanged") && !current.contains("is available"));

    fs::write(
        home.join("feed.json"),
        r#"{"schema":1,"version":"0.1.0","assets":{}}"#,
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update", "--force"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    let older = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(older.contains("is newer") && !older.contains("is available"));
}

/// A half-updated machine is the one state this command must never leave,
/// because the command's own version is what the next run reads: a new
/// command beside an old app answers already-up-to-date forever. So the
/// app goes first and a refusal there stops the run with the old command
/// still on disk — which is what lets the next run try both halves again,
/// with no --force and nothing said about one.
///
/// Only a target whose release publishes an AppImage has an app half to
/// order against. Where none is published the command is the whole install
/// and what has to hold instead is that it leaves alone, and says nothing
/// about, an app it never installed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_desktop_app_that_cannot_be_replaced_leaves_the_command_alone() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let me = bin.join("kendex");
    fs::copy(env!("CARGO_BIN_EXE_kendex"), &me).unwrap();
    fs::set_permissions(&me, fs::Permissions::from_mode(0o755)).unwrap();

    let app_dir = home.join(".local/share/kendex");
    fs::create_dir_all(&app_dir).unwrap();
    fs::write(app_dir.join("kendex.AppImage"), "old app").unwrap();

    fs::write(home.join("new-binary"), "#!/bin/sh\necho v9\n").unwrap();
    fs::write(home.join("new-binary.sig"), "not the release signature").unwrap();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema":1,"version":"9.9.9","assets":{{"{target}":{}}}}}"#,
            serde_json::to_string(&file_url(&home.join("new-binary"))).unwrap()
        ),
    )
    .unwrap();
    a_release_that_cannot_be_verified(home, target);
    let update = || {
        kendex_copy(
            &me,
            home,
            &["update"],
            &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
        )
    };
    // Read as text: the real binary is not UTF-8, so only a command that
    // moved reads back as the replacement, and a failure prints that line
    // rather than a megabyte of ELF.
    let command_moved = || fs::read_to_string(&me).is_ok_and(|got| got == "#!/bin/sh\necho v9\n");
    let still_old_app = || fs::read_to_string(app_dir.join("kendex.AppImage")).unwrap();

    if !publishes_an_app_image() {
        let only = update();
        let said = format!("{}{}", stderr(&only), stdout(&only));
        // The command is the whole install here, and it is still held to
        // the release key: this fixture cannot sign under it, so the run
        // refuses and the command stays where it was.
        assert!(!only.status.success(), "{said}");
        assert!(
            !command_moved(),
            "an unverified command was written: {said}"
        );
        // An AppImage sitting here is not this platform's install, so the
        // command neither touches it nor mentions one.
        assert_eq!(still_old_app(), "old app", "{said}");
        assert!(
            !said.contains("desktop app"),
            "claimed something about an app it never installed: {said}"
        );
        return;
    }

    fs::set_permissions(&app_dir, fs::Permissions::from_mode(0o555)).unwrap();
    // Root writes through the mode bits, so the refusal this test needs
    // never happens there.
    if fs::write(app_dir.join("probe"), "").is_ok() {
        fs::set_permissions(&app_dir, fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }

    let first = update();
    // The second run is the whole point: with the command still on its old
    // version it reads the feed as newer and reaches the app again.
    let second = update();
    fs::set_permissions(&app_dir, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(
        !command_moved(),
        "the command moved before the app it depends on"
    );
    assert_eq!(still_old_app(), "old app");
    for (which, output) in [("first", &first), ("second", &second)] {
        let said = format!("{}{}", stderr(output), stdout(output));
        assert!(!output.status.success(), "{which}: {said}");
        assert!(
            said.contains("nothing was updated") && said.contains("refuses writes"),
            "{which}: {said}"
        );
        assert!(
            !said.contains("already up to date"),
            "{which} dead-ended instead of retrying: {said}"
        );
    }
}

/// A copy kendex cannot place is a copy it will not overwrite. The command
/// says so in the channel's own words rather than failing at the rename
/// with an io error, and a package-owned path on a distro it cannot name
/// reaches this the same way.
#[test]
#[allow(clippy::unwrap_used)]
fn update_refuses_a_copy_it_cannot_account_for() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let bin = home.join("sealed");
    fs::create_dir_all(&bin).unwrap();
    let me = bin.join("kendex");
    fs::copy(env!("CARGO_BIN_EXE_kendex"), &me).unwrap();
    fs::set_permissions(&me, fs::Permissions::from_mode(0o755)).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o555)).unwrap();
    // Root writes through the mode bits, so the channel this test needs
    // never comes back Unknown there.
    if fs::write(bin.join("probe"), "").is_ok() {
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }

    fs::write(home.join("new-binary"), "#!/bin/sh\necho v9\n").unwrap();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema":1,"version":"9.9.9","assets":{{"{target}":{}}}}}"#,
            serde_json::to_string(&file_url(&home.join("new-binary"))).unwrap()
        ),
    )
    .unwrap();

    let output = kendex_copy(
        &me,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "{stderr}");
    assert!(
        stderr.contains("cannot tell how this copy was installed"),
        "{stderr}"
    );
    assert_eq!(
        fs::read(&me).unwrap(),
        fs::read(env!("CARGO_BIN_EXE_kendex")).unwrap(),
        "the refused copy was left exactly as it was"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn update_refuses_an_asset_value_that_is_not_a_url() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema":1,"version":"99.0.0","assets":{{"{target}":"--output={}/owned"}}}}"#,
            home.display()
        ),
    )
    .unwrap();

    let output = kendex_in(
        home,
        home,
        &["update"],
        &[("KENDEX_UPDATE_FEED", file_url(&home.join("feed.json")))],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("URL must start"));
    assert!(!home.join("owned").exists());
}

#[test]
fn init_scaffolds_and_validates() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let output = kendex_in(
        home,
        &home.join("catalog"),
        &["init", "deploy", "--kind", "skill"],
        &[],
    );
    assert!(output.status.success());
    let skill_md = std::fs::read_to_string(home.join("catalog/skills/deploy/SKILL.md")).unwrap();
    assert!(
        skill_md.contains("commands to run, rules to follow"),
        "scaffold body lost the do-only directive: {skill_md}"
    );

    let usage = kendex_in(home, &home.join("catalog"), &["init"], &[]);
    assert!(usage.status.success());

    let bad = kendex_in(
        home,
        &home.join("catalog"),
        &["init", "x", "--kind", "wat"],
        &[],
    );
    assert!(!bad.status.success());
}
