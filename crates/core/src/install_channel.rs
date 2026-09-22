//! Who owns the running bytes: kendex, a system package manager, or nobody
//! this build can name. The app and the CLI resolve it the same way, each
//! passing its own running executable, so nothing is decided at build time —
//! the same released bytes reach a machine through a package and through a
//! direct install, and the package manager is asked which of the two this
//! is rather than the layout being read for a guess.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use serde::Serialize;
use specta::Type;

/// Homebrew's install prefixes on the platforms it supports.
const BREW_PREFIXES: [&str; 3] = [
    "/opt/homebrew/",
    "/usr/local/Cellar/",
    "/home/linuxbrew/.linuxbrew/",
];

/// What to call the installer that owns a path. Fixed text, decided by
/// which branch of the detection ran, so no value read off the machine
/// ever reaches it — the rule the command string already lives under.
const HOMEBREW: &str = "Homebrew";
/// Every Arch arm gets the class, never the tool. `paru` sitting on `PATH`
/// today says nothing about what fetched the package, so naming it would
/// be inventing the one fact this build does not have.
const AUR_HELPER: &str = "an AUR helper";

/// How the running install may be brought up to date.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum InstallChannel {
    /// The running install is ours to replace.
    Direct,
    /// A system package manager owns these bytes. `manager` names it and
    /// `command` brings them current; both are decided where the manager
    /// is detected, so nothing downstream has to read a name back out of
    /// the command string and guess.
    ///
    /// `manager` is not optional. Every branch that reaches here knows
    /// which installer it found, and a detection that could not say who
    /// owns a path is [`InstallChannel::Unknown`] — which names nobody and
    /// offers nothing, and is where the honest degradation already lives.
    Managed { manager: String, command: String },
    /// Not recognised: say a release is out, never replace anything, never
    /// invent a command.
    Unknown,
}

impl InstallChannel {
    /// Whether replacing these bytes in place is ours to do. Both shells ask
    /// here, so a refusal reads the same wherever it is met.
    pub fn allow_replacement(&self) -> Result<(), String> {
        match self {
            Self::Direct => Ok(()),
            Self::Managed { manager, command } => Err(format!(
                "this install came from {manager}; update it with: {command}"
            )),
            Self::Unknown => Err(
                "kendex cannot tell how this copy was installed, so it will not replace it"
                    .to_owned(),
            ),
        }
    }
}

/// The running desktop build, as the shell that launched it knows. Each
/// variant carries only what its platform's rules read, so the `cfg` that
/// picks one lives at the single call site in the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppInstall {
    /// Linux: the AppImage this process runs from, absent when it was not
    /// launched from one, and the running executable. Both are needed
    /// because the Arch packages built from source install a plain binary:
    /// an image is a file kendex may be able to replace, where an
    /// executable only ever says which package owns these bytes.
    Linux {
        image: Option<PathBuf>,
        exe: Option<PathBuf>,
    },
    /// macOS: the running executable inside the `.app` bundle.
    MacBundle(PathBuf),
    /// Windows: the installer is the only channel.
    WindowsInstaller,
}

impl AppInstall {
    /// The path to hand whatever performs the replacement, so that the path
    /// [`for_app`] judged and the path acted on are one file. `None` where
    /// no path decides the install.
    ///
    /// On macOS this has to stay the executable: the consumer climbs from
    /// it to the surrounding bundle, and handed the bundle it climbs one
    /// level further, to the directory the bundle sits in.
    pub fn judged_path(&self) -> Option<&Path> {
        match self {
            // The image and not the executable: the updater downloads an
            // AppImage, so a desktop build that is not one is never a file
            // this app replaces, however writable it is.
            Self::Linux { image, .. } => image.as_deref(),
            Self::MacBundle(exe) => Some(exe),
            Self::WindowsInstaller => None,
        }
    }

    /// The macOS app, resolved: a Homebrew cask links `/Applications` at
    /// its Caskroom, and a process is handed the path it was launched
    /// under rather than the bundle behind it.
    pub fn mac_bundle(probe: &dyn HostProbe, exe: &Path) -> Self {
        Self::MacBundle(probe.resolve(exe))
    }

    /// The Linux app, judged by where this executable is rather than by a
    /// variable every child of an AppImage-launched terminal inherits. A
    /// process that only inherited the pair has no AppImage of its own,
    /// and the image it does have is resolved to the file it names.
    pub fn linux(
        probe: &dyn HostProbe,
        appimage: Option<&OsStr>,
        appdir: Option<&OsStr>,
        exe: Option<&Path>,
    ) -> Self {
        let image = match in_appimage(appimage, appdir, exe) {
            true => appimage.map(|image| probe.resolve(Path::new(image))),
            false => None,
        };
        Self::Linux {
            image,
            exe: exe.map(|exe| probe.resolve(exe)),
        }
    }
}

/// Whether this process is running from inside an AppImage bundle.
///
/// Neither variable answers this on its own. An AppImage's AppRun exports
/// both `APPIMAGE` and `APPDIR`, and every process it starts inherits both,
/// so a terminal opened from one hands a stranger's pair to every `.deb`
/// and source build launched from it. What separates those cases is where
/// this executable lives: `APPDIR` is the directory a bundle unpacks to —
/// the mount point of a running AppImage, or the tree a hand-extracted one
/// sits in — and a process inside it really is inside that bundle.
///
/// Only when there is no executable to place does a bare variable get the
/// last word, so a genuine bundle that cannot read its own path is not
/// quietly demoted.
pub fn in_appimage(appimage: Option<&OsStr>, appdir: Option<&OsStr>, exe: Option<&Path>) -> bool {
    let appdir = said_dir(appdir);
    let Some(exe) = exe else {
        return appimage.is_some() || appdir.is_some();
    };
    appdir.is_some_and(|dir| exe.starts_with(dir))
}

/// A directory-valued variable's bytes need not be UTF-8. An
/// exported-but-empty one matters here: a `Path` built from `""` has no components,
/// so every path starts with it.
fn said_dir(value: Option<&OsStr>) -> Option<&Path> {
    let dir = value?;
    if dir.is_empty() || dir.to_str().is_some_and(|dir| dir.trim().is_empty()) {
        return None;
    }
    Some(Path::new(dir))
}

/// Facts about the machine the resolver cannot compute from its inputs.
pub trait HostProbe {
    /// Whether a file at this path can be replaced — what a rename into its
    /// directory needs. Opening the file itself for write answers a
    /// different question: a running executable refuses that (`ETXTBSY`) on
    /// exactly the installs this must call [`InstallChannel::Direct`].
    fn replaceable(&self, path: &Path) -> bool;

    /// The installed package that owns a path, as `pacman -Qoq` names it.
    /// pacman is the only package manager asked — named here rather than
    /// left as "this machine's package manager", because a dpkg or rpm
    /// machine answers `None` with an owner sitting in its own database.
    /// The one caller asks only where `os_release` already reads as Arch.
    ///
    /// `None` also covers a path no package owns, a machine with no pacman,
    /// and a question that could not be answered. Each leaves the caller
    /// naming nobody, which is honest, in place of naming a package that
    /// would move a person to another channel.
    fn pacman_owner(&self, path: &Path) -> Option<String>;

    /// Whether a path is a command this machine would run: a regular file
    /// with an execute bit. Presence is a weaker question — a directory, or
    /// a data file, can carry a command's name and still never run — and
    /// answering the weaker one is how a search settles on a path a shell
    /// would have passed over.
    fn is_command(&self, path: &Path) -> bool;

    /// The path with every symlink followed, or the path itself where it
    /// cannot be resolved. Which install owns a file is a fact about the
    /// file, never about the name it was reached by: a Homebrew formula
    /// links its prefix's `bin/` at the Cellar, and macOS hands a process
    /// the path it was exec'd with, symlinks intact.
    fn resolve(&self, path: &Path) -> PathBuf;

    /// Whether a command is on `PATH`.
    fn on_path(&self, command: &str) -> bool;

    /// The contents of `/etc/os-release`, absent where there is none.
    fn os_release(&self) -> Option<String>;
}

/// The machine this process runs on.
pub struct Host;

impl HostProbe for Host {
    fn replaceable(&self, path: &Path) -> bool {
        let Some(parent) = path.parent() else {
            return false;
        };
        let probe = parent.join(format!(".kendex-replace-probe-{}", std::process::id()));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&probe)
        {
            Ok(_) => {
                let _ = std::fs::remove_file(&probe);
                true
            }
            Err(_) => false,
        }
    }

    fn pacman_owner(&self, path: &Path) -> Option<String> {
        let output = crate::process::Hardened::pacman_owner(path)
            .timeout(crate::process::INTERACTIVE_TIMEOUT)
            .run()
            .ok()?;
        printed_owner(output.status.success(), &output.stdout)
    }

    fn is_command(&self, path: &Path) -> bool {
        crate::fs::is_executable(path)
    }

    fn resolve(&self, path: &Path) -> PathBuf {
        std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned())
    }

    fn on_path(&self, command: &str) -> bool {
        let Some(path) = std::env::var_os("PATH") else {
            return false;
        };
        std::env::split_paths(&path).any(|dir| dir.join(command).is_file())
    }

    fn os_release(&self) -> Option<String> {
        std::fs::read_to_string("/etc/os-release").ok()
    }
}

/// The channel the running desktop app installed through.
///
/// The paths inside `install` are already resolved — [`HostProbe::resolve`]
/// is the shell's to call before it builds one. Resolving here instead
/// would answer about one path while the caller still holds another.
pub fn for_app(install: &AppInstall, probe: &dyn HostProbe) -> InstallChannel {
    match install {
        AppInstall::Linux {
            image: Some(image), ..
        } => system_channel(image, probe).unwrap_or_else(|| replaceable_or_unknown(image, probe)),
        // No image, so nothing here is this app's to replace whatever its
        // permissions say — the updater downloads AppImages. Who owns the
        // bytes is still worth saying: the two Arch packages built from
        // source install a plain binary, and a person running one needs the
        // command for their own package, not silence.
        AppInstall::Linux { image: None, exe } => exe
            .as_deref()
            .and_then(|exe| system_channel(exe, probe))
            .unwrap_or(InstallChannel::Unknown),
        AppInstall::MacBundle(exe) => match bundle_root(exe) {
            Some(root) => replaceable_or_unknown(root, probe),
            None => InstallChannel::Unknown,
        },
        AppInstall::WindowsInstaller => InstallChannel::Direct,
    }
}

/// The channel the running `kendex` command installed through.
///
/// `exe` is already resolved — [`HostProbe::resolve`] is the caller's to
/// call, once, on the path it will also write to. Resolving here instead
/// would decide about the file while the caller still held the link.
pub fn for_cli(exe: &Path, probe: &dyn HostProbe) -> InstallChannel {
    package_owner(exe, probe).unwrap_or_else(|| replaceable_or_unknown(exe, probe))
}

/// The package manager whose prefix `exe` sits under, where one does.
///
/// Split from [`for_cli`], whose `Unknown` is both "a manager this build
/// cannot name owns it" and "nobody owns it and we cannot write it" —
/// opposites, to a caller holding proof the file is kendex's.
pub fn package_owner(exe: &Path, probe: &dyn HostProbe) -> Option<InstallChannel> {
    if starts_with_any(exe, &BREW_PREFIXES) {
        return Some(InstallChannel::Managed {
            manager: HOMEBREW.to_owned(),
            command: "brew upgrade kendex-cli".to_owned(),
        });
    }
    system_channel(exe, probe)
}

/// The channel for bytes sitting where the distro's package manager keeps
/// them, and `None` where the path is not one of those, which leaves the
/// caller to judge the file on its own.
fn system_channel(path: &Path, probe: &dyn HostProbe) -> Option<InstallChannel> {
    system_owned(path).then(|| arch_channel(path, probe))
}

/// The Arch packages that carry kendex. A name printed by the machine
/// selects one of these or nothing, so every command string is still this
/// build's own text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ArchPackage {
    /// The tagged release, built from source: the desktop app and the command.
    Release,
    /// Remote main, built from source: the desktop app and the command.
    Git,
    /// The released binaries, repackaged: the desktop app and the command.
    Bin,
    /// Remote main, built from source: the command alone.
    CliGit,
}

impl ArchPackage {
    const ALL: [Self; 4] = [Self::Release, Self::Git, Self::Bin, Self::CliGit];

    fn name(self) -> &'static str {
        match self {
            Self::Release => "kendex",
            Self::Git => "kendex-git",
            Self::Bin => "kendex-bin",
            Self::CliGit => "kendex-cli-git",
        }
    }

    /// The package this name is, or `None` for a name kendex does not
    /// publish — a third party's repackaging, whose update command is not
    /// this build's to invent.
    fn named(package: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.name() == package)
    }
}

/// A package-owned path is only actionable on a distro whose update command
/// this build knows, and only once the package manager has named the owner.
/// Anywhere else the honest answer is that we cannot say.
///
/// The owner is asked for by path rather than read off the layout: the four
/// packages install the same `kendex` command, two of them track main where
/// the other two track a release, and naming the wrong one moves a person
/// to a channel they did not choose.
fn arch_channel(path: &Path, probe: &dyn HostProbe) -> InstallChannel {
    if !probe.os_release().is_some_and(|text| is_arch(&text)) {
        return InstallChannel::Unknown;
    }
    let Some(package) = probe
        .pacman_owner(path)
        .as_deref()
        .and_then(ArchPackage::named)
    else {
        return InstallChannel::Unknown;
    };
    let name = package.name();
    let command = if probe.on_path("paru") {
        format!("paru -S {name}")
    } else if probe.on_path("yay") {
        format!("yay -S {name}")
    } else {
        format!("update {name} with your AUR helper")
    };
    InstallChannel::Managed {
        manager: AUR_HELPER.to_owned(),
        command,
    }
}

/// The package name in `pacman -Qoq`'s output, or `None` where the run said
/// nothing this build can use. Split from the spawn so every branch of it is
/// reachable without a pacman on the machine; a spawn that never ran is the
/// remaining way to reach `None`, and it is the `ok()?` at the call site.
///
/// A nonzero status is pacman saying no package owns the path, and its
/// stdout is not read at all: the diagnostic goes to stderr today, and a
/// spelling that printed a name beside a refusal must not be read as
/// ownership. One name is expected, so the first line is the whole answer,
/// trimmed because a name is compared against fixed text.
fn printed_owner(success: bool, stdout: &[u8]) -> Option<String> {
    if !success {
        return None;
    }
    let printed = std::str::from_utf8(stdout).ok()?;
    let name = printed.lines().next()?.trim();
    (!name.is_empty()).then(|| name.to_owned())
}

fn replaceable_or_unknown(path: &Path, probe: &dyn HostProbe) -> InstallChannel {
    match probe.replaceable(path) {
        true => InstallChannel::Direct,
        false => InstallChannel::Unknown,
    }
}

/// `/usr/local/` is where a person installs by hand; the rest of `/usr/`
/// belongs to the distro's package manager.
fn system_owned(path: &Path) -> bool {
    let path = path.to_string_lossy();
    path.starts_with("/usr/") && !path.starts_with("/usr/local/")
}

fn starts_with_any(path: &Path, prefixes: &[&str]) -> bool {
    let path = path.to_string_lossy();
    prefixes.iter().any(|prefix| path.starts_with(prefix))
}

/// The `.app` directory holding an executable at `Contents/MacOS/`.
fn bundle_root(exe: &Path) -> Option<&Path> {
    let macos = exe.parent()?;
    let contents = macos.parent()?;
    let root = contents.parent()?;
    let named = |dir: &Path, name: &str| dir.file_name().is_some_and(|got| got == name);
    let is_bundle = named(macos, "MacOS")
        && named(contents, "Contents")
        && root
            .file_name()
            .is_some_and(|name| name.to_string_lossy().ends_with(".app"));
    is_bundle.then_some(root)
}

/// Arch by `ID`, or a derivative naming it in `ID_LIKE`.
fn is_arch(os_release: &str) -> bool {
    os_release.lines().any(|line| {
        let Some((key, value)) = line.split_once('=') else {
            return false;
        };
        let value = unquote(value.trim());
        match key.trim() {
            "ID" => value == "arch",
            "ID_LIKE" => value.split_whitespace().any(|word| word == "arch"),
            _ => false,
        }
    })
}

fn unquote(value: &str) -> &str {
    for quote in ['"', '\''] {
        if let Some(inner) = value
            .strip_prefix(quote)
            .and_then(|v| v.strip_suffix(quote))
        {
            return inner;
        }
    }
    value
}

#[cfg(test)]
mod tests;
