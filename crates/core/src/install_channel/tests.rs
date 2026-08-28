use super::*;

const ARCH: &str = "NAME=\"Arch Linux\"\nID=arch\nPRETTY_NAME=\"Arch Linux\"\n";
const CACHYOS: &str = "NAME=\"CachyOS Linux\"\nID=cachyos\nID_LIKE=\"arch\"\n";
const DEBIAN: &str = "PRETTY_NAME=\"Debian GNU/Linux 12\"\nID=debian\n";

/// Every host fact the resolver reads, stated up front.
#[derive(Default)]
struct Fake {
    replaceable: Vec<String>,
    present: Vec<String>,
    on_path: Vec<String>,
    os_release: Option<String>,
    links: Vec<(String, String)>,
}

impl Fake {
    fn replaceable(mut self, path: &str) -> Self {
        self.replaceable.push(path.to_owned());
        self
    }

    fn present(mut self, path: &str) -> Self {
        self.present.push(path.to_owned());
        self
    }

    fn on_path(mut self, command: &str) -> Self {
        self.on_path.push(command.to_owned());
        self
    }

    fn os_release(mut self, text: &str) -> Self {
        self.os_release = Some(text.to_owned());
        self
    }

    fn links(mut self, from: &str, to: &str) -> Self {
        self.links.push((from.to_owned(), to.to_owned()));
        self
    }
}

impl HostProbe for Fake {
    fn replaceable(&self, path: &Path) -> bool {
        self.replaceable.iter().any(|p| Path::new(p) == path)
    }

    fn exists(&self, path: &Path) -> bool {
        self.present.iter().any(|p| Path::new(p) == path)
    }

    fn on_path(&self, command: &str) -> bool {
        self.on_path.iter().any(|c| c == command)
    }

    fn os_release(&self) -> Option<String> {
        self.os_release.clone()
    }

    fn resolve(&self, path: &Path) -> PathBuf {
        self.links
            .iter()
            .find(|(from, _)| Path::new(from) == path)
            .map_or_else(|| path.to_owned(), |(_, to)| PathBuf::from(to))
    }
}

fn managed(command: &str) -> InstallChannel {
    InstallChannel::Managed {
        command: command.to_owned(),
    }
}

fn app_image(path: &str) -> AppInstall {
    AppInstall::AppImage(Some(PathBuf::from(path)))
}

#[test]
fn an_appimage_the_person_owns_updates_in_place() {
    let home = "/home/pat/.local/share/kendex/kendex.AppImage";
    let probe = Fake::default().replaceable(home);
    assert_eq!(for_app(&app_image(home), &probe), InstallChannel::Direct);
}

#[test]
fn an_appimage_in_a_directory_that_refuses_writes_is_unknown() {
    let elsewhere = "/opt/kendex/kendex.AppImage";
    assert_eq!(
        for_app(&app_image(elsewhere), &Fake::default()),
        InstallChannel::Unknown
    );
}

#[test]
fn a_linux_app_launched_outside_an_appimage_is_unknown() {
    assert_eq!(
        for_app(&AppInstall::AppImage(None), &Fake::default()),
        InstallChannel::Unknown
    );
}

/// A root-owned machine can write anywhere; the package still owns the file.
#[test]
fn a_packaged_appimage_names_its_package_even_where_the_file_is_writable() {
    let probe = Fake::default()
        .replaceable(PACKAGED_APP_IMAGE)
        .os_release(ARCH)
        .on_path("paru");
    assert_eq!(
        for_app(&app_image(PACKAGED_APP_IMAGE), &probe),
        managed("paru -S kendex-bin")
    );
}

#[test]
fn usr_local_is_a_hand_install_not_a_package() {
    let local = "/usr/local/lib/kendex/kendex.AppImage";
    let probe = Fake::default().replaceable(local).os_release(ARCH);
    assert_eq!(for_app(&app_image(local), &probe), InstallChannel::Direct);
}

#[test]
fn an_arch_derivative_naming_arch_in_id_like_is_recognised() {
    let probe = Fake::default().os_release(CACHYOS).on_path("yay");
    assert_eq!(
        for_app(&app_image(PACKAGED_APP_IMAGE), &probe),
        managed("yay -S kendex-bin")
    );
}

#[test]
fn a_package_owned_path_on_an_unrecognised_distro_is_unknown() {
    for probe in [
        Fake::default().os_release(DEBIAN),
        Fake::default(),
        Fake::default().os_release("ID=archlinux\n"),
    ] {
        assert_eq!(
            for_app(&app_image(PACKAGED_APP_IMAGE), &probe),
            InstallChannel::Unknown
        );
    }
}

#[test]
fn with_no_aur_helper_the_command_is_helper_neutral_prose() {
    let probe = Fake::default().os_release(ARCH);
    assert_eq!(
        for_app(&app_image(PACKAGED_APP_IMAGE), &probe),
        managed("update kendex-bin with your AUR helper")
    );
}

#[test]
fn paru_wins_over_yay_when_both_are_installed() {
    let probe = Fake::default()
        .os_release(ARCH)
        .on_path("yay")
        .on_path("paru");
    assert_eq!(
        for_app(&app_image(PACKAGED_APP_IMAGE), &probe),
        managed("paru -S kendex-bin")
    );
}

#[test]
fn a_mac_bundle_is_direct_when_the_directory_holding_it_takes_writes() {
    let exe = Path::new("/Applications/kendex.app/Contents/MacOS/kendex");
    let probe = Fake::default().replaceable("/Applications/kendex.app");
    assert_eq!(
        for_app(&AppInstall::MacBundle(exe.to_owned()), &probe),
        InstallChannel::Direct
    );
    assert_eq!(
        for_app(&AppInstall::MacBundle(exe.to_owned()), &Fake::default()),
        InstallChannel::Unknown
    );
}

#[test]
fn an_executable_outside_a_bundle_layout_is_never_read_as_one() {
    for loose in [
        "/Applications/kendex.app/Contents/Resources/kendex",
        "/Applications/kendex.app/Frameworks/MacOS/kendex",
        "/Applications/kendex/Contents/MacOS/kendex",
        "/usr/local/bin/kendex",
    ] {
        let probe = Fake::default()
            .replaceable("/Applications/kendex.app")
            .replaceable("/Applications");
        assert_eq!(
            for_app(&AppInstall::MacBundle(PathBuf::from(loose)), &probe),
            InstallChannel::Unknown,
            "{loose}"
        );
    }
}

#[test]
fn the_windows_installer_is_the_only_windows_channel() {
    assert_eq!(
        for_app(&AppInstall::WindowsInstaller, &Fake::default()),
        InstallChannel::Direct
    );
}

/// Homebrew runs the command through a link in its prefix's `bin/`, and
/// macOS hands a process that link's own path rather than the Cellar file
/// behind it. Prefix-matching what the process was handed calls an Intel
/// mac's `/usr/local/bin/kendex` a direct install and renames a download
/// over Homebrew's link.
#[test]
fn a_brew_linked_cli_is_brews_to_upgrade_however_it_was_reached() {
    for (linked, cellar) in [
        (
            "/opt/homebrew/bin/kendex",
            "/opt/homebrew/Cellar/kendex-cli/5.0.1/bin/kendex",
        ),
        (
            "/usr/local/bin/kendex",
            "/usr/local/Cellar/kendex-cli/5.0.1/bin/kendex",
        ),
        (
            "/home/linuxbrew/.linuxbrew/bin/kendex",
            "/home/linuxbrew/.linuxbrew/Cellar/kendex-cli/5.0.1/bin/kendex",
        ),
    ] {
        let probe = Fake::default()
            .links(linked, cellar)
            .replaceable(linked)
            .replaceable(cellar)
            .os_release(ARCH);
        assert_eq!(
            for_cli(Path::new(linked), &probe),
            managed("brew upgrade kendex-cli"),
            "{linked}"
        );
        // Reached at the Cellar path directly, the answer cannot change.
        assert_eq!(
            for_cli(Path::new(cellar), &probe),
            managed("brew upgrade kendex-cli"),
            "{cellar}"
        );
    }
}

/// A real binary at the same place Homebrew would have linked one stays
/// ours to replace: following the link is what decides, not the prefix.
#[test]
fn a_plain_binary_in_usr_local_bin_is_still_a_direct_install() {
    let exe = "/usr/local/bin/kendex";
    let probe = Fake::default().replaceable(exe);
    assert_eq!(for_cli(Path::new(exe), &probe), InstallChannel::Direct);
}

/// The same name reached through a link into a package's tree belongs to
/// that package, on the app side as much as the command's.
#[test]
fn an_appimage_reached_through_a_link_belongs_to_whatever_it_points_at() {
    let link = "/home/pat/.local/share/kendex/kendex.AppImage";
    let probe = Fake::default()
        .links(link, PACKAGED_APP_IMAGE)
        .replaceable(link)
        .os_release(ARCH)
        .on_path("paru");
    assert_eq!(
        for_app(&app_image(link), &probe),
        managed("paru -S kendex-bin")
    );
}

#[test]
fn a_cli_in_a_writable_user_directory_updates_itself() {
    let exe = "/home/pat/.local/bin/kendex";
    let probe = Fake::default().replaceable(exe);
    assert_eq!(for_cli(Path::new(exe), &probe), InstallChannel::Direct);
    assert_eq!(
        for_cli(Path::new(exe), &Fake::default()),
        InstallChannel::Unknown
    );
}

/// The prebuilt package ships both halves, so a machine carrying its
/// AppImage is told to update that package rather than the CLI-only one.
#[test]
fn the_packaged_cli_names_whichever_package_put_it_there() {
    let exe = Path::new("/usr/bin/kendex");
    let both = Fake::default()
        .os_release(ARCH)
        .on_path("paru")
        .present(PACKAGED_APP_IMAGE);
    assert_eq!(for_cli(exe, &both), managed("paru -S kendex-bin"));
    let cli_only = Fake::default().os_release(ARCH).on_path("paru");
    assert_eq!(for_cli(exe, &cli_only), managed("paru -S kendex"));
}

/// Anything a resolver read off the machine — a distro name, an os-release
/// line, the path itself — stays out of the string a person is told to run.
#[test]
fn nothing_read_from_the_machine_reaches_a_command_string() {
    let hostile = "ID=arch\nPRETTY_NAME=\"; rm -rf /\"\nID_LIKE=\"arch $(whoami)\"\n";
    let exe = Path::new("/usr/bin/kendex; rm -rf /");
    let probe = Fake::default().os_release(hostile).on_path("paru");
    let InstallChannel::Managed { command } = for_cli(exe, &probe) else {
        panic!("a package-owned path on Arch is Managed");
    };
    assert_eq!(command, "paru -S kendex");
}

#[test]
fn an_os_release_value_is_read_unquoted_and_whole() {
    assert!(is_arch("ID='arch'\n"));
    assert!(is_arch("ID=\"arch\"\n"));
    assert!(is_arch("ID_LIKE=\"debian arch\"\n"));
    assert!(!is_arch("ID=archlinux\n"));
    assert!(!is_arch("ID_LIKE=\"archlinux\"\n"));
    assert!(!is_arch("BUILD_ID=arch\n"));
    assert!(!is_arch("no equals sign here\n"));
}

/// The one question that gates writing over an install answers for both
/// shells, so neither can decide it differently. Every channel but the one
/// kendex owns is refused, and a managed one says what to run instead.
#[test]
fn in_place_replacement_is_refused_off_a_direct_install() {
    assert_eq!(InstallChannel::Direct.allow_replacement(), Ok(()));
    assert_eq!(
        managed("paru -S kendex-bin").allow_replacement(),
        Err("a package manager owns this install; update it with: paru -S kendex-bin".to_owned())
    );
    assert!(InstallChannel::Unknown.allow_replacement().is_err());
}

/// A running AppImage: the runtime mounts it and both variables point at
/// that mount, which is where the executable is.
#[test]
fn a_mounted_appimage_is_recognised_by_where_it_runs_from() {
    assert!(in_appimage(
        Some(OsStr::new("/home/me/kendex.AppImage")),
        Some(OsStr::new("/tmp/.mount_kendexAbc")),
        Some(Path::new("/tmp/.mount_kendexAbc/usr/bin/kendex-app"))
    ));
    assert!(!in_appimage(
        None,
        None,
        Some(Path::new("/usr/bin/kendex-app"))
    ));
}

/// The other half of the inherited-variable problem: the runtime exports
/// APPIMAGE into the same environment every child gets, so it says no more
/// about this process than APPDIR does.
#[test]
fn a_stray_appimage_does_not_make_this_an_appimage() {
    let installed = Path::new("/usr/bin/kendex-app");
    assert!(!in_appimage(
        Some(OsStr::new("/home/me/other.AppImage")),
        None,
        Some(installed)
    ));
    assert!(!in_appimage(
        Some(OsStr::new("/home/me/other.AppImage")),
        Some(OsStr::new("/tmp/.mount_otherXyz")),
        Some(installed)
    ));
}

/// Neither variable can be measured against a path we do not have, and a
/// genuine bundle is not worth demoting to half size over it.
#[test]
fn a_bundle_that_cannot_read_its_own_path_is_still_a_bundle() {
    assert!(in_appimage(
        Some(OsStr::new("/home/me/kendex.AppImage")),
        None,
        None
    ));
    assert!(in_appimage(
        None,
        Some(OsStr::new("/home/me/kendex.AppDir")),
        None
    ));
    assert!(!in_appimage(None, None, None));
}

/// An exported-but-empty APPDIR is every path's prefix, so it has to be
/// read as unset rather than as a directory containing everything.
#[test]
fn an_empty_appdir_is_not_a_directory_this_lives_in() {
    for empty in ["", "   "] {
        assert!(
            !in_appimage(
                None,
                Some(OsStr::new(empty)),
                Some(Path::new("/usr/bin/kendex-app"))
            ),
            "{empty:?}"
        );
    }
}

/// Every AppImage's AppRun exports APPDIR and everything it starts
/// inherits it, so a deb launched from a terminal that came out of one
/// carries a stranger's APPDIR. It only speaks for this process when
/// this process lives inside it.
#[test]
fn a_stray_appdir_does_not_make_this_an_appimage() {
    let extracted = OsStr::new("/home/me/kendex.AppDir");
    assert!(in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/home/me/kendex.AppDir/usr/bin/kendex-app"))
    ));
    assert!(!in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/usr/bin/kendex-app"))
    ));
    // A prefix that only matches as a string, not as a path.
    assert!(!in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/home/me/kendex.AppDirectory/usr/bin/kendex-app"))
    ));
}

/// The variable alone never names this process's own install: a deb or a
/// source build launched from a terminal that came out of an AppImage
/// inherits a stranger's pair, and offering to replace that image would
/// overwrite somebody else's app.
#[test]
fn an_inherited_appimage_variable_is_not_this_process_install() {
    let stranger = OsStr::new("/home/pat/other.AppImage");
    let installed = Path::new("/usr/bin/kendex-app");
    for appdir in [None, Some(OsStr::new("/tmp/.mount_otherXyz"))] {
        assert_eq!(
            AppInstall::from_appimage_env(Some(stranger), appdir, Some(installed)),
            AppInstall::AppImage(None),
            "{appdir:?}"
        );
    }
    assert_eq!(
        for_app(
            &AppInstall::from_appimage_env(Some(stranger), None, Some(installed)),
            &Fake::default().replaceable("/home/pat/other.AppImage")
        ),
        InstallChannel::Unknown
    );
}

/// The image this process really does run from is still its own to replace.
#[test]
fn the_image_this_process_runs_from_is_its_own_install() {
    let ours = OsStr::new("/home/pat/.local/share/kendex/kendex.AppImage");
    assert_eq!(
        AppInstall::from_appimage_env(
            Some(ours),
            Some(OsStr::new("/tmp/.mount_kendexAbc")),
            Some(Path::new("/tmp/.mount_kendexAbc/usr/bin/kendex-app"))
        ),
        AppInstall::AppImage(Some(PathBuf::from(ours)))
    );
}
