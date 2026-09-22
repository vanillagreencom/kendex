use super::*;

const ARCH: &str = "NAME=\"Arch Linux\"\nID=arch\nPRETTY_NAME=\"Arch Linux\"\n";
const CACHYOS: &str = "NAME=\"CachyOS Linux\"\nID=cachyos\nID_LIKE=\"arch\"\n";
const DEBIAN: &str = "PRETTY_NAME=\"Debian GNU/Linux 12\"\nID=debian\n";

/// The packaged desktop app of each Arch package that installs one:
/// kendex-bin repackages the released AppImage, and the two built from
/// source install a plain binary.
const PACKAGED_IMAGE: &str = "/usr/lib/kendex/kendex.AppImage";
const PACKAGED_BINARY: &str = "/usr/lib/kendex/kendex-app";
const PACKAGED_COMMAND: &str = "/usr/bin/kendex";

/// Every host fact the resolver reads, stated up front.
#[derive(Default)]
struct Fake {
    replaceable: Vec<String>,
    owners: Vec<(String, String)>,
    on_path: Vec<String>,
    os_release: Option<String>,
    links: Vec<(String, String)>,
}

impl Fake {
    fn replaceable(mut self, path: &str) -> Self {
        self.replaceable.push(path.to_owned());
        self
    }

    /// The package this machine's package manager says owns a path.
    fn owned_by(mut self, path: &str, package: &str) -> Self {
        self.owners.push((path.to_owned(), package.to_owned()));
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
    /// Nothing routed through this fake asks; `for_app` and `for_cli`
    /// judge a path they were handed rather than looking one up.
    fn is_command(&self, _: &Path) -> bool {
        false
    }

    fn replaceable(&self, path: &Path) -> bool {
        self.replaceable.iter().any(|p| Path::new(p) == path)
    }

    fn owning_package(&self, path: &Path) -> Option<String> {
        self.owners
            .iter()
            .find(|(owned, _)| Path::new(owned) == path)
            .map(|(_, package)| package.clone())
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

fn managed(manager: &str, command: &str) -> InstallChannel {
    InstallChannel::Managed {
        manager: manager.to_owned(),
        command: command.to_owned(),
    }
}

/// Every Arch arm names the class rather than the helper it found, so the
/// expectation is written once here and read at each site.
fn aur(command: &str) -> InstallChannel {
    managed(AUR_HELPER, command)
}

fn app_image(path: &str) -> AppInstall {
    AppInstall::Linux {
        image: Some(PathBuf::from(path)),
        exe: None,
    }
}

/// A desktop build that is not an AppImage: the plain binary the two Arch
/// packages built from source install.
fn app_binary(path: &str) -> AppInstall {
    AppInstall::Linux {
        image: None,
        exe: Some(PathBuf::from(path)),
    }
}

/// One row per Linux desktop build no package owns: the path it is judged
/// by, the host facts the probe answers, and whether replacing it in place
/// is this app's to do. An image the person can write updates itself, one
/// in a directory that refuses writes does not, and `/usr/local` is a hand
/// install whatever the distro. A plain binary is never replaced in place,
/// however writable it is, because the updater downloads AppImages; and a
/// process running from neither has nothing to judge.
#[test]
fn for_app_replaces_only_a_desktop_build_it_can_write() {
    let home = "/home/pat/.local/share/kendex/kendex.AppImage";
    let local = "/usr/local/lib/kendex/kendex.AppImage";
    let loose = "/home/pat/.local/lib/kendex/kendex-app";
    let rows: Vec<(&str, AppInstall, Fake, InstallChannel)> = vec![
        (
            "an image the person owns",
            app_image(home),
            Fake::default().replaceable(home),
            InstallChannel::Direct,
        ),
        (
            "an image in a directory that refuses writes",
            app_image("/opt/kendex/kendex.AppImage"),
            Fake::default(),
            InstallChannel::Unknown,
        ),
        (
            "a hand install under /usr/local",
            app_image(local),
            Fake::default().replaceable(local).os_release(ARCH),
            InstallChannel::Direct,
        ),
        (
            "a plain binary the person can write, which the updater still cannot carry",
            app_binary(loose),
            Fake::default().replaceable(loose),
            InstallChannel::Unknown,
        ),
        (
            "launched from neither an image nor a placeable executable",
            AppInstall::Linux {
                image: None,
                exe: None,
            },
            Fake::default(),
            InstallChannel::Unknown,
        ),
    ];
    for (label, install, probe, expected) in rows {
        assert_eq!(for_app(&install, &probe), expected, "{label}");
    }
}

/// One row per package-owned Linux desktop build. Each of the three Arch
/// packages that install the app is named as itself, by the package manager
/// and never by whether the file is an image: the repackaged release
/// installs an AppImage and the two built from source install a plain
/// binary, and all three would otherwise read the same. The name is offered
/// on every distro that reads as Arch (`ID` or `ID_LIKE`, unquoted and
/// whole) and nowhere else, even where a root-owned machine could write the
/// file; with two helpers on `PATH` paru wins and with none the command is
/// helper-neutral prose; and a file no package claims, or one a third party
/// repackaged under another name, names nobody.
#[test]
fn for_app_names_the_arch_package_that_owns_a_desktop_build() {
    let arch_owning = |path: &str, package: &str| {
        Fake::default()
            .os_release(ARCH)
            .on_path("paru")
            .owned_by(path, package)
    };
    let rows: Vec<(&str, AppInstall, Fake, InstallChannel)> = vec![
        (
            "the repackaged image on a root-writable machine",
            app_image(PACKAGED_IMAGE),
            arch_owning(PACKAGED_IMAGE, "kendex-bin").replaceable(PACKAGED_IMAGE),
            aur("paru -S kendex-bin"),
        ),
        (
            "the binary the release-source package installs",
            app_binary(PACKAGED_BINARY),
            arch_owning(PACKAGED_BINARY, "kendex"),
            aur("paru -S kendex"),
        ),
        (
            "the binary the main-source package installs",
            app_binary(PACKAGED_BINARY),
            arch_owning(PACKAGED_BINARY, "kendex-git"),
            aur("paru -S kendex-git"),
        ),
        (
            "a packaged binary on a machine that can write it",
            app_binary(PACKAGED_BINARY),
            arch_owning(PACKAGED_BINARY, "kendex-git").replaceable(PACKAGED_BINARY),
            aur("paru -S kendex-git"),
        ),
        (
            "a packaged image no package claims",
            app_image(PACKAGED_IMAGE),
            Fake::default().os_release(ARCH).on_path("paru"),
            InstallChannel::Unknown,
        ),
        (
            "a packaged image a third party repackaged under another name",
            app_image(PACKAGED_IMAGE),
            arch_owning(PACKAGED_IMAGE, "kendex-extra"),
            InstallChannel::Unknown,
        ),
        (
            "an Arch derivative naming arch in ID_LIKE",
            app_image(PACKAGED_IMAGE),
            Fake::default()
                .os_release(CACHYOS)
                .on_path("yay")
                .owned_by(PACKAGED_IMAGE, "kendex-bin"),
            aur("yay -S kendex-bin"),
        ),
        (
            "the packaged path on Debian",
            app_image(PACKAGED_IMAGE),
            Fake::default()
                .os_release(DEBIAN)
                .owned_by(PACKAGED_IMAGE, "kendex-bin"),
            InstallChannel::Unknown,
        ),
        (
            "the packaged path with no os-release",
            app_image(PACKAGED_IMAGE),
            Fake::default().owned_by(PACKAGED_IMAGE, "kendex-bin"),
            InstallChannel::Unknown,
        ),
        (
            "the packaged path where ID only starts with arch",
            app_image(PACKAGED_IMAGE),
            Fake::default()
                .os_release("ID=archlinux\n")
                .owned_by(PACKAGED_IMAGE, "kendex-bin"),
            InstallChannel::Unknown,
        ),
        (
            "Arch with no AUR helper on PATH",
            app_image(PACKAGED_IMAGE),
            Fake::default()
                .os_release(ARCH)
                .owned_by(PACKAGED_IMAGE, "kendex-bin"),
            aur("update kendex-bin with your AUR helper"),
        ),
        (
            "Arch with both helpers on PATH",
            app_image(PACKAGED_IMAGE),
            Fake::default()
                .os_release(ARCH)
                .on_path("yay")
                .on_path("paru")
                .owned_by(PACKAGED_IMAGE, "kendex-bin"),
            aur("paru -S kendex-bin"),
        ),
    ];
    for (label, install, probe, expected) in rows {
        assert_eq!(for_app(&install, &probe), expected, "{label}");
    }
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
        // Resolved by the caller, the way each shell resolves at its own
        // boundary; reached at either name, the answer cannot change.
        for reached in [linked, cellar] {
            assert_eq!(
                for_cli(&probe.resolve(Path::new(reached)), &probe),
                managed(HOMEBREW, "brew upgrade kendex-cli"),
                "{reached}"
            );
        }
    }
}

/// The same name reached through a link into a package's tree belongs to
/// that package, on the app side as much as the command's. The image is
/// resolved as the variant is built, so what reaches `for_app` is the file.
#[test]
fn an_appimage_reached_through_a_link_belongs_to_whatever_it_points_at() {
    let link = "/home/pat/.local/share/kendex/kendex.AppImage";
    let mounted = "/tmp/.mount_kendexAbc/usr/bin/kendex-app";
    let probe = Fake::default()
        .links(link, PACKAGED_IMAGE)
        .replaceable(link)
        .os_release(ARCH)
        .on_path("paru")
        .owned_by(PACKAGED_IMAGE, "kendex-bin");
    let install = AppInstall::linux(
        &probe,
        Some(OsStr::new(link)),
        Some(OsStr::new("/tmp/.mount_kendexAbc")),
        Some(Path::new(mounted)),
    );
    assert_eq!(
        install,
        AppInstall::Linux {
            image: Some(PathBuf::from(PACKAGED_IMAGE)),
            exe: Some(PathBuf::from(mounted)),
        }
    );
    assert_eq!(for_app(&install, &probe), aur("paru -S kendex-bin"));
}

/// One row per place the command can be found: a plain binary at the very
/// place Homebrew would have linked one is still ours (following the link is
/// what decides, not the prefix); a binary in a directory the person can
/// write updates itself and one they cannot is unknown; a package-owned one
/// names whichever Arch package the package manager says put it there, each
/// of the four as itself, and names nobody where the owner is a package
/// kendex does not publish or where no package claims the file.
#[test]
fn for_cli_names_the_channel_of_each_binary_layout() {
    let user = "/home/pat/.local/bin/kendex";
    let packaged = |package: &str| {
        Fake::default()
            .os_release(ARCH)
            .on_path("paru")
            .owned_by(PACKAGED_COMMAND, package)
    };
    let rows: Vec<(&str, &str, Fake, InstallChannel)> = vec![
        (
            "a plain binary in /usr/local/bin",
            "/usr/local/bin/kendex",
            Fake::default().replaceable("/usr/local/bin/kendex"),
            InstallChannel::Direct,
        ),
        (
            "a binary the person can replace",
            user,
            Fake::default().replaceable(user),
            InstallChannel::Direct,
        ),
        (
            "a binary the person cannot replace",
            user,
            Fake::default(),
            InstallChannel::Unknown,
        ),
        (
            "the command from the release-source package",
            PACKAGED_COMMAND,
            packaged("kendex"),
            aur("paru -S kendex"),
        ),
        (
            "the command from the main-source package",
            PACKAGED_COMMAND,
            packaged("kendex-git"),
            aur("paru -S kendex-git"),
        ),
        (
            "the command from the prebuilt package",
            PACKAGED_COMMAND,
            packaged("kendex-bin"),
            aur("paru -S kendex-bin"),
        ),
        (
            "the command from the CLI-only main-source package",
            PACKAGED_COMMAND,
            packaged("kendex-cli-git"),
            aur("paru -S kendex-cli-git"),
        ),
        (
            "a packaged command beside a packaged image, which decides nothing",
            PACKAGED_COMMAND,
            packaged("kendex-cli-git").owned_by(PACKAGED_IMAGE, "kendex-bin"),
            aur("paru -S kendex-cli-git"),
        ),
        (
            "a packaged command a third party repackaged under another name",
            PACKAGED_COMMAND,
            packaged("kendex-extra"),
            InstallChannel::Unknown,
        ),
        (
            "a packaged command no package claims",
            PACKAGED_COMMAND,
            Fake::default().os_release(ARCH).on_path("paru"),
            InstallChannel::Unknown,
        ),
    ];
    for (label, exe, probe, expected) in rows {
        assert_eq!(for_cli(Path::new(exe), &probe), expected, "{label}");
    }
}

/// Anything a resolver read off the machine — a distro name, an os-release
/// line, the path itself — stays out of the string a person is told to run,
/// and out of the manager named beside it. Both are fixed text picked by
/// which branch of the detection ran.
#[test]
fn nothing_read_from_the_machine_reaches_a_command_string() {
    let hostile = "ID=arch\nPRETTY_NAME=\"; rm -rf /\"\nID_LIKE=\"arch $(whoami)\"\n";
    let exe = Path::new("/usr/bin/kendex; rm -rf /");
    let probe = Fake::default()
        .os_release(hostile)
        .on_path("paru")
        .owned_by("/usr/bin/kendex; rm -rf /", "kendex");
    let InstallChannel::Managed { manager, command } = for_cli(exe, &probe) else {
        panic!("a package-owned path on Arch is Managed");
    };
    assert_eq!(command, "paru -S kendex");
    assert_eq!(manager, AUR_HELPER);

    // The owning package's name is read off the machine too. A name that
    // is not one of the four selects nothing, so no bytes a package
    // manager printed can reach the string a person is told to run.
    for printed in [
        "kendex; rm -rf /",
        "kendex-git\nkendex",
        " kendex ",
        "KENDEX",
        "",
    ] {
        assert_eq!(
            for_cli(
                Path::new("/usr/bin/kendex"),
                &Fake::default()
                    .os_release(ARCH)
                    .on_path("paru")
                    .owned_by("/usr/bin/kendex", printed)
            ),
            InstallChannel::Unknown,
            "{printed:?}"
        );
    }
}

/// Every Arch package this build can name, and nothing else. The four names
/// come from the enum itself rather than from a second list here, so a
/// variant added without a name, or named twice, fails on the spot.
#[test]
fn each_arch_package_is_named_once_and_selected_by_that_name() {
    let mut names: Vec<&str> = ArchPackage::ALL.iter().map(|p| p.name()).collect();
    let listed = names.len();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), listed, "two variants share a name: {names:?}");
    for package in ArchPackage::ALL {
        assert_eq!(ArchPackage::named(package.name()), Some(package));
    }
    assert_eq!(
        names,
        ["kendex", "kendex-bin", "kendex-cli-git", "kendex-git"]
    );
    assert_eq!(ArchPackage::named("kendex-cli"), None);
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
        aur("paru -S kendex-bin").allow_replacement(),
        Err(format!(
            "this install came from {AUR_HELPER}; update it with: paru -S kendex-bin"
        ))
    );
    assert_eq!(
        InstallChannel::Unknown.allow_replacement(),
        Err("kendex cannot tell how this copy was installed, so it will not replace it".to_owned())
    );
}

/// One row per environment the AppImage runtime can leave behind. Both
/// `APPIMAGE` and `APPDIR` are exported into the environment every child
/// gets, so a deb launched from a terminal that came out of an image
/// carries a stranger's pair; only an executable living inside `APPDIR`
/// says this process is the bundle. With no executable to place, a bare
/// variable keeps a genuine bundle from being demoted. An exported-but-empty
/// `APPDIR` is every path's prefix and reads as unset, blank as much as
/// empty and with no executable to place as much as with one, and a
/// prefix that matches as a string but not as a path is no prefix.
#[test]
fn in_appimage_reads_the_pair_against_where_this_process_runs() {
    let mounted = "/tmp/.mount_kendexAbc/usr/bin/kendex-app";
    let installed = "/usr/bin/kendex-app";
    let extracted = "/home/me/kendex.AppDir";
    type Row = (
        &'static str,
        Option<&'static str>,
        Option<&'static str>,
        Option<&'static str>,
        bool,
    );
    let rows: [Row; 13] = [
        (
            "running from the mount",
            Some("/home/me/kendex.AppImage"),
            Some("/tmp/.mount_kendexAbc"),
            Some(mounted),
            true,
        ),
        (
            "no variables, an installed binary",
            None,
            None,
            Some(installed),
            false,
        ),
        (
            "a stray image, no dir",
            Some("/home/me/other.AppImage"),
            None,
            Some(installed),
            false,
        ),
        (
            "a stray pair around an installed binary",
            Some("/home/me/other.AppImage"),
            Some("/tmp/.mount_otherXyz"),
            Some(installed),
            false,
        ),
        (
            "an image and no executable to place",
            Some("/home/me/kendex.AppImage"),
            None,
            None,
            true,
        ),
        (
            "a dir and no executable to place",
            None,
            Some(extracted),
            None,
            true,
        ),
        ("nothing at all", None, None, None, false),
        ("an empty dir", None, Some(""), Some(installed), false),
        ("a blank dir", None, Some("   "), Some(installed), false),
        (
            "running inside the extracted dir",
            None,
            Some(extracted),
            Some("/home/me/kendex.AppDir/usr/bin/kendex-app"),
            true,
        ),
        (
            "a stray dir around an installed binary",
            None,
            Some(extracted),
            Some(installed),
            false,
        ),
        (
            "a dir that is only a string prefix",
            None,
            Some(extracted),
            Some("/home/me/kendex.AppDirectory/usr/bin/kendex-app"),
            false,
        ),
        (
            "a blank dir and no executable to place",
            None,
            Some("   "),
            None,
            false,
        ),
    ];
    for (label, appimage, appdir, exe, expected) in rows {
        assert_eq!(
            in_appimage(
                appimage.map(OsStr::new),
                appdir.map(OsStr::new),
                exe.map(Path::new)
            ),
            expected,
            "{label}"
        );
    }
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
            AppInstall::linux(&Fake::default(), Some(stranger), appdir, Some(installed)),
            AppInstall::Linux {
                image: None,
                exe: Some(installed.to_owned()),
            },
            "{appdir:?}"
        );
    }
    assert_eq!(
        for_app(
            &AppInstall::linux(&Fake::default(), Some(stranger), None, Some(installed)),
            &Fake::default().replaceable("/home/pat/other.AppImage")
        ),
        InstallChannel::Unknown
    );
}

/// The image this process really does run from is still its own to replace.
#[test]
fn the_image_this_process_runs_from_is_its_own_install() {
    let ours = OsStr::new("/home/pat/.local/share/kendex/kendex.AppImage");
    let mounted = "/tmp/.mount_kendexAbc/usr/bin/kendex-app";
    assert_eq!(
        AppInstall::linux(
            &Fake::default(),
            Some(ours),
            Some(OsStr::new("/tmp/.mount_kendexAbc")),
            Some(Path::new(mounted))
        ),
        AppInstall::Linux {
            image: Some(PathBuf::from(ours)),
            exe: Some(PathBuf::from(mounted)),
        }
    );
}

/// The boundary primitive both shells call before they classify anything.
/// Reached through a link, it must answer with the file: on macOS a
/// process is handed the path it was launched under, so without this the
/// path that decides is not the path that gets written.
#[test]
#[allow(clippy::unwrap_used)]
fn resolve_answers_with_the_file_a_link_points_at() {
    let dir = tempfile::tempdir().unwrap();
    // Resolving through a link needs a link, and a test can only make one
    // where the platform does not put a privilege in front of it.
    #[cfg(unix)]
    {
        let real = dir.path().join("kendex");
        std::fs::write(&real, "binary").unwrap();
        let link = dir.path().join("linked-kendex");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(Host.resolve(&link), std::fs::canonicalize(&real).unwrap());
    }

    // A path that resolves to nothing is answered with itself rather than
    // dropped, so a caller always has something to classify and to write.
    let missing = dir.path().join("absent");
    assert_eq!(Host.resolve(&missing), missing);
}

/// A cask puts the bundle in its Caskroom and links `/Applications` at it,
/// so the launched name and the bundle are different paths. Both name the
/// same install, and it is the one kendex may replace.
#[test]
fn a_mac_bundle_is_the_one_behind_the_name_it_was_launched_under() {
    let linked = "/Applications/kendex.app/Contents/MacOS/kendex";
    let caskroom = "/Users/pat/Library/Caskroom/kendex/5.0.1/kendex.app/Contents/MacOS/kendex";
    let probe = Fake::default()
        .links(linked, caskroom)
        .replaceable("/Users/pat/Library/Caskroom/kendex/5.0.1/kendex.app");
    let install = AppInstall::mac_bundle(&probe, Path::new(linked));
    assert_eq!(install, AppInstall::MacBundle(PathBuf::from(caskroom)));
    assert_eq!(for_app(&install, &probe), InstallChannel::Direct);
}

/// What `judged_path` hands over. The resolving behind these values is
/// pinned above by the two link tests,
/// `an_appimage_reached_through_a_link_belongs_to_whatever_it_points_at`
/// and `a_mac_bundle_is_the_one_behind_the_name_it_was_launched_under`.
/// What this pins is the accessor, and on macOS that it stays the executable:
/// `for_app` reaches the bundle from it by the same `bundle_root` asserted
/// here. Whether the updater plugin derives that same bundle is the app
/// crate's test, not this one's.
#[test]
fn judged_path_hands_over_the_file_for_app_approved() {
    let image = "/home/pat/Apps/kendex-5.0.1.AppImage";
    assert_eq!(app_image(image).judged_path(), Some(Path::new(image)));

    let exe = "/Users/pat/Library/Caskroom/kendex/5.0.1/kendex.app/Contents/MacOS/kendex";
    let bundle = "/Users/pat/Library/Caskroom/kendex/5.0.1/kendex.app";
    let install = AppInstall::MacBundle(PathBuf::from(exe));
    assert_eq!(install.judged_path(), Some(Path::new(exe)));
    assert_eq!(
        install.judged_path().and_then(bundle_root),
        Some(Path::new(bundle))
    );

    assert_eq!(AppInstall::WindowsInstaller.judged_path(), None);
    // A desktop build that is not an AppImage hands over nothing: the
    // updater downloads images, so its executable is not a file to replace
    // even though the resolver reads it to name a package.
    assert_eq!(app_binary("/usr/lib/kendex/kendex-app").judged_path(), None);
    assert_eq!(
        AppInstall::Linux {
            image: None,
            exe: None
        }
        .judged_path(),
        None
    );
}

/// The manager names are what a person reads on the card, so they are
/// pinned by value here rather than through the constants every per-branch
/// test compares against. Two managers sharing one name pass all of those
/// and still send a Homebrew user to an AUR helper.
#[test]
fn each_installer_is_named_as_itself() {
    let named = |channel| match channel {
        InstallChannel::Managed { manager, .. } => manager,
        other => panic!("expected a managed channel, got {other:?}"),
    };
    let brew = Path::new("/opt/homebrew/Cellar/kendex-cli/5.0.1/bin/kendex");
    let arch = Fake::default()
        .os_release(ARCH)
        .on_path("paru")
        .owned_by(PACKAGED_COMMAND, "kendex");

    assert_eq!(named(for_cli(brew, &Fake::default())), "Homebrew");
    assert_eq!(
        named(for_cli(Path::new(PACKAGED_COMMAND), &arch)),
        "an AUR helper"
    );
    assert_ne!(HOMEBREW, AUR_HELPER);
}
