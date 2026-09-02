#[cfg(unix)]
use kendex_core::install_channel::HostProbe as _;

use super::*;

#[cfg(unix)]
use crate::test_util::no_record_on_this_runner;

/// The card's check and the install have to be looking at one release,
/// or a candidate is offered an update the installer then cannot find.
/// Both read the running version, so this asserts they land on the same
/// channel and that the endpoint is a URL the plugin will take.
#[test]
fn the_notice_and_the_install_read_one_channel() {
    let version = env!("CARGO_PKG_VERSION");
    let endpoint = manifest_endpoint().expect("the manifest URL parses");
    assert_eq!(
        endpoint.as_str(),
        kendex_core::update_channel::manifest_url_for(version)
    );
    use kendex_core::update_channel::{PRERELEASE_FEED_URL, PRERELEASE_MANIFEST_URL};
    assert_eq!(
        kendex_core::update_channel::feed_url_for(version) == PRERELEASE_FEED_URL,
        endpoint.as_str() == PRERELEASE_MANIFEST_URL,
        "the feed and the manifest are on different channels for {version}"
    );
}

/// The document naming what this release published is read from beside
/// the manifest the install reads, so both come off the channel this
/// build follows. It is also the one place this build's own target has
/// to be a name the read will accept: a triple the rule refuses would
/// leave this platform unable to install anything.
#[test]
fn the_digests_document_sits_beside_the_manifest_the_install_reads() {
    let endpoint = manifest_endpoint().expect("the manifest URL parses");
    let target = env!("KENDEX_TARGET");
    let (directory, _) = endpoint
        .as_str()
        .rsplit_once('/')
        .expect("the manifest is served from a directory");
    assert_eq!(
        release_digests_url(manifest_url_for(env!("CARGO_PKG_VERSION")), target)
            .expect("this build's target names a document"),
        format!("{directory}/digests-{target}.json")
    );
}

/// A throwaway minisign keypair and the document it signed for a 9.9.9
/// Linux lane, so the install's own read runs the real check rather than a
/// stub standing in for it.
const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDc1RTYwNzZERUJFMDVFNTcKUldSWFh1RHJiUWZtZFdVSnJYQmd0QnhLVUdUQnN2MWNTR2N6SW9jZ1Z1Q0FoZmlzWDVIeFZJaUkK";
const TEST_TARGET: &str = "x86_64-unknown-linux-gnu";
const PUBLISHED: &str = r#"{
  "schema": 1,
  "version": "9.9.9",
  "target": "x86_64-unknown-linux-gnu",
  "command": "aae05017e20c96dd3cd26b1fd324365c2ab53512db82b53362e75f8f553ffaea",
  "app": "d489b792c3c3d6e9633ff28507f2c7da40a24eec743521842ebc283c2c3226ff"
}
"#;
const PUBLISHED_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSWFh1RHJiUWZtZFpxNkg5WFpISHVZL2xIMWR6eWxZN3djZUU2NXpERjVNMjRUMUJlcXlnS1V5dUpDNGsySlpHZkRBUEhiOFN3dFRhVElPaWltajA3RTNpNVk3NndJcXdZPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzg4MDQyMjM0CWZpbGU6ZGlnZXN0cy14ODZfNjQtdW5rbm93bi1saW51eC1nbnUuanNvbgpzSkg3dGJuMXVNSHIyRkE5enlISnVSRWRNS0xXcWxFVEJ1TkRaSXFsR0ZzZm5LbCtqNThBckYzb1JQVE9UeEk5WExEMXpKYTlSZnl0S2xQUXZxTk9Bdz09Cg==";
/// The app download that document names, and one it does not.
const PUBLISHED_APP: &[u8] = b"the linux appimage";
const ANOTHER_RELEASE_APP: &[u8] = b"an older kendex, signed when it shipped";

/// What the install does before it hands the plugin's download back to be
/// written: read the release's own document off the channel and hold the
/// bytes to it. The transport answers only at the two URLs this read is
/// supposed to ask for, so a read that looked anywhere else finds nothing.
#[test]
fn the_install_holds_its_download_to_what_this_release_published() {
    let published = published();
    published
        .verify_app(PUBLISHED_APP)
        .expect("the download this release published");
    assert!(published.verify_app(ANOTHER_RELEASE_APP).is_err());

    // The manifest is unsigned, so the version it offers is whoever wrote
    // it to choose; the document is what that claim is held to.
    let claimed = read_published(TEST_KEY, TEST_TARGET, "9.9.8", serve).unwrap_err();
    assert!(claimed.contains("the feed offers 9.9.8"), "{claimed}");
}

/// A channel serving what this release published, and answering at exactly
/// the two URLs the install's read is supposed to ask for: a read that
/// looked anywhere else finds nothing.
fn serve(asked: &str) -> Result<Vec<u8>, String> {
    let document = release_digests_url(manifest_url_for(env!("CARGO_PKG_VERSION")), TEST_TARGET)
        .expect("the channel names a document");
    if asked == document {
        return Ok(PUBLISHED.as_bytes().to_vec());
    }
    if asked == signature_url(&document) {
        return Ok(PUBLISHED_SIGNATURE.as_bytes().to_vec());
    }
    Err(format!("this release published nothing at {asked}"))
}

/// The release's own document, read the way the install reads it.
fn published() -> ReleaseDigests {
    read_published(TEST_KEY, TEST_TARGET, "9.9.9", serve).expect("the release signed this")
}

/// Stands in for the plugin's installer. What reaches it is what would
/// have been written over this install.
#[derive(Default)]
struct Placed(std::cell::RefCell<Option<Vec<u8>>>);

impl Installer for Placed {
    fn place(&self, bytes: Vec<u8>) -> Result<(), String> {
        *self.0.borrow_mut() = Some(bytes);
        Ok(())
    }
}

/// The boundary itself, driven through the step the install takes rather
/// than through its halves. Everything else about this change can be right
/// while the check never runs on the way to the installer, which is the
/// whole defect: the plugin's signature check admits any kendex release's
/// bytes, so what this release published for this target is the only thing
/// between an older signed download and the disk.
#[test]
fn only_the_download_this_release_published_reaches_the_installer() {
    let digests = published();

    let landed = Placed::default();
    install_published(&digests, PUBLISHED_APP.to_vec(), &landed).expect("the published download");
    assert_eq!(landed.0.borrow().as_deref(), Some(PUBLISHED_APP));

    let refused = Placed::default();
    let error = install_published(&digests, ANOTHER_RELEASE_APP.to_vec(), &refused)
        .expect_err("a download this release never published");
    assert!(
        error.contains("the desktop app download hashes to"),
        "{error}"
    );
    assert!(
        refused.0.borrow().is_none(),
        "a download this release never published reached the installer"
    );
}

/// Stands in for the updater builder, which keeps what it was handed
/// private. What reaches it is what the plugin would have been given.
#[derive(Default)]
struct Recorder(Option<std::path::PathBuf>);

impl ReplacementTarget for Recorder {
    fn replace_at(self, path: &std::path::Path) -> Self {
        Self(Some(path.to_owned()))
    }
}

/// The handoff itself. Everything else about this change can be right
/// while the approved path never leaves `app_update_install`, and the
/// plugin then falls back to rebuilding its own from the launch
/// environment, which is the whole defect.
#[test]
fn the_approved_path_reaches_whatever_will_replace_it() {
    for install in [
        AppInstall::AppImage(Some("/home/pat/Apps/kendex.AppImage".into())),
        AppInstall::MacBundle("/Applications/kendex.app/Contents/MacOS/kendex".into()),
    ] {
        assert_eq!(
            aim_at_install(Recorder::default(), &install).0.as_deref(),
            install.judged_path(),
            "{install:?}"
        );
    }

    // Nothing to hand over, so the target keeps its own fallback.
    for install in [AppInstall::WindowsInstaller, AppInstall::AppImage(None)] {
        assert_eq!(
            aim_at_install(Recorder::default(), &install).0,
            None,
            "{install:?}"
        );
    }
}

/// Only the bundle is writable, so `for_app` can approve nothing else.
struct OnlyWritable(&'static str);

impl kendex_core::install_channel::HostProbe for OnlyWritable {
    /// Nothing routed through this fake asks; `for_app` and `for_cli`
    /// judge a path they were handed rather than looking one up.
    fn is_command(&self, path: &Path) -> bool {
        self.exists(path)
    }

    fn replaceable(&self, path: &std::path::Path) -> bool {
        path == std::path::Path::new(self.0)
    }

    fn exists(&self, _: &std::path::Path) -> bool {
        false
    }

    fn resolve(&self, path: &std::path::Path) -> std::path::PathBuf {
        path.to_owned()
    }

    fn on_path(&self, _: &str) -> bool {
        false
    }

    fn os_release(&self) -> Option<String> {
        None
    }
}

/// The plugin decides for itself what to replace, deriving it from the
/// path it is handed, so nothing kendex asserts about that path proves
/// the two agree. This asks the plugin.
///
/// Getting it wrong is not a failed update. The derived path is what the
/// macOS installer removes before moving the new bundle in, escalating a
/// permission error to a shell `rm -rf` under `with administrator
/// privileges`. Hand over the bundle instead of the executable inside it
/// and the plugin climbs one level further, to the directory holding
/// every other app on the machine. The dependency is a caret range, so a
/// minor bump can move this derivation under an unchanged kendex.
#[test]
fn the_plugin_derives_the_unit_for_app_approved() {
    let exe = "/Applications/kendex.app/Contents/MacOS/kendex";
    let bundle = "/Applications/kendex.app";
    let probe = OnlyWritable(bundle);
    let install = AppInstall::mac_bundle(&probe, std::path::Path::new(exe));
    assert_eq!(
        kendex_core::install_channel::for_app(&install, &probe),
        InstallChannel::Direct
    );

    let handed = install.judged_path().expect("a mac bundle carries a path");
    let derived = tauri_plugin_updater::extract_path_from_executable(handed)
        .expect("the plugin derives a path from an executable inside a bundle");
    // True on every platform the function compiles for, and the property
    // that matters: what the plugin acts on never escapes what kendex
    // approved.
    assert!(
        derived.starts_with(bundle),
        "plugin derived {} from {handed}, outside the approved {bundle}",
        derived.display(),
        handed = handed.display()
    );
    // Where the derivation runs for real it lands on the bundle exactly.
    #[cfg(target_os = "macos")]
    assert_eq!(derived, std::path::Path::new(bundle));
}

/// The two sentences a failed app half gets, and the difference between
/// them. A command already across has to be named — the machine is split,
/// and the card is the only place that can say so — while a command that
/// never moved leaves nothing to report but the app's own failure.
#[test]
fn a_failed_app_half_says_whether_the_command_went_ahead_of_it() {
    let split = app_half_failed("5.1.0", CommandHalf::Moved, "permission denied");
    assert!(split.contains("the kendex command is on 5.1.0"), "{split}");
    assert!(split.contains("permission denied"), "{split}");
    assert!(split.contains("press Update now again"), "{split}");

    let neither = app_half_failed("5.1.0", CommandHalf::Untouched, "permission denied");
    assert!(!neither.contains("kendex command"), "{neither}");
    assert!(neither.contains("permission denied"), "{neither}");
}

/// The command this app would carry across is looked for beside the app,
/// never inside it. Read as a difference rather than an absolute, because
/// the candidate list ends with a system path this machine may well have a
/// kendex in.
///
/// Unix only, because there is no command beside the app on Windows: the
/// installer carries the app alone, so the name there only ever fails to
/// exist and every lookup below would answer `Absent` — which the first
/// assertion, a difference, would pass without reaching the exclusion it
/// is about.
#[cfg(unix)]
#[test]
fn the_app_s_own_image_is_never_the_command_it_carries() {
    if no_record_on_this_runner() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let image = bin.join("kendex");
    std::fs::write(&image, b"the running AppImage").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&image, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let env = Env::host_rooted(dir.path());
    let path_var = std::ffi::OsString::from(&bin);
    let ours = CommandBeside::Ours(Host.resolve(&image));

    assert_ne!(
        command_beside(
            &env,
            &AppInstall::AppImage(Some(image.clone())),
            Some(&path_var)
        ),
        ours
    );

    // The same file with nothing claiming it as the app, and an installer's
    // record behind it: the exclusion above is what answered, and not a
    // search that never reached it or a command nothing vouched for.
    // `AppImage(None)` rather than `WindowsInstaller`, because on Windows
    // this process's own executable is excluded too and a test binary is
    // not the app.
    kendex_core::command_update::record_command(&env, &image).unwrap();
    assert_eq!(
        command_beside(&env, &AppInstall::AppImage(None), Some(&path_var)),
        ours
    );
}

/// The two paths a family update must never write over, and why naming one
/// is not enough. An AppImage's executable lives inside a mount that is not
/// the image the updater judged, so the judged path is needed; the Windows
/// installer judges no path at all while the desktop executable carries the
/// command's own name, so the running executable is needed. Excluded by the
/// judged path alone, a Windows install on `PATH` would replace itself with
/// the CLI binary.
#[test]
fn the_running_executable_is_excluded_where_the_updater_names_no_path() {
    let exe = PathBuf::from("C:/Program Files/kendex/kendex.exe");
    assert_eq!(
        not_the_command(&AppInstall::WindowsInstaller, Some(exe.clone())),
        vec![exe.clone()],
        "the updater judges no path on Windows, so nothing else excludes the app"
    );

    let image = PathBuf::from("/home/pat/Apps/kendex.AppImage");
    let inside = PathBuf::from("/tmp/.mount_kendex/usr/bin/kendex-app");
    assert_eq!(
        not_the_command(
            &AppInstall::AppImage(Some(image.clone())),
            Some(inside.clone())
        ),
        vec![inside, image],
        "neither the mounted executable nor the image it came from is the command"
    );
}

/// One machine with a `kendex` command an installer recorded, and the
/// notice the card would have drawn for it.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn a_recorded_command(dir: &tempfile::TempDir) -> (Env, std::ffi::OsString, PathBuf) {
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let command = bin.join("kendex");
    std::fs::write(&command, b"the kendex command an installer put here").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&command, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let env = Env::host_rooted(dir.path());
    kendex_core::command_update::record_command(&env, &command).unwrap();
    (env, std::ffi::OsString::from(&bin), command)
}

/// A card is on screen for as long as a person leaves it there, and what
/// is beside the app in that time is not this app's to control. The lookup
/// runs again when Update now is pressed, so it can answer differently
/// from the card — which is what [`CommandNotice::not_as_shown`] is handed,
/// and what the notice tests then hold each sentence against.
///
/// Driven through the real lookup rather than a described state: a second
/// install records its own `kendex` between the two reads, and the command
/// beside this app is one nothing vouches for any more.
///
/// Unix only, for the same reason: the second answer is a command found by
/// name on `PATH` and vouched for by nobody, and Windows has no command
/// beside the app to find.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_that_changed_under_the_card_answers_differently() {
    if no_record_on_this_runner() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (env, path_var, _) = a_recorded_command(&dir);
    let install = AppInstall::AppImage(None);
    let card = CommandNotice::for_card(&command_beside(&env, &install, Some(&path_var)));
    assert_eq!(card, None, "a recorded command is the app's to carry");

    kendex_core::command_update::record_command(&env, &dir.path().join("other/kendex")).unwrap();

    assert_eq!(
        CommandNotice::for_card(&command_beside(&env, &install, Some(&path_var))),
        Some(CommandNotice::Unknown),
        "a second install recorded its own kendex and this one still reads as ours"
    );
}
