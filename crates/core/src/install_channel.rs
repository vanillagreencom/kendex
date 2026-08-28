//! Who owns the running bytes: kendex, a system package manager, or nobody
//! this build can name. The app and the CLI resolve it the same way, each
//! passing its own running executable, so nothing is decided at build time —
//! the AUR package repackages the released AppImage byte for byte.

use std::path::{Path, PathBuf};

use serde::Serialize;
use specta::Type;

/// Homebrew's install prefixes on the platforms it supports.
const BREW_PREFIXES: [&str; 3] = [
    "/opt/homebrew/",
    "/usr/local/Cellar/",
    "/home/linuxbrew/.linuxbrew/",
];

/// Where the AUR `kendex-bin` package puts the desktop app.
const PACKAGED_APP_IMAGE: &str = "/usr/lib/kendex/kendex.AppImage";

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
    /// A system package manager owns these bytes; `command` brings them
    /// current and is the only thing to offer.
    Managed { command: String },
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
            Self::Managed { command } => Err(format!(
                "a package manager owns this install; update it with: {command}"
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
    /// Linux: the value of `APPIMAGE`, absent when the app was not launched
    /// from an AppImage.
    AppImage(Option<PathBuf>),
    /// macOS: the running executable inside the `.app` bundle.
    MacBundle(PathBuf),
    /// Windows: the installer is the only channel.
    WindowsInstaller,
}

/// Facts about the machine the resolver cannot compute from its inputs.
pub trait HostProbe {
    /// Whether a file at this path can be replaced — what a rename into its
    /// directory needs. Opening the file itself for write answers a
    /// different question: a running executable refuses that (`ETXTBSY`) on
    /// exactly the installs this must call [`InstallChannel::Direct`].
    fn replaceable(&self, path: &Path) -> bool;

    /// Whether a path is present on this machine.
    fn exists(&self, path: &Path) -> bool;

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

    fn exists(&self, path: &Path) -> bool {
        path.exists()
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
pub fn for_app(install: &AppInstall, probe: &dyn HostProbe) -> InstallChannel {
    match install {
        AppInstall::AppImage(None) => InstallChannel::Unknown,
        AppInstall::AppImage(Some(image)) => {
            let image = probe.resolve(image);
            if system_owned(&image) {
                return arch_channel(ArchPackage::Bin, probe);
            }
            replaceable_or_unknown(&image, probe)
        }
        AppInstall::MacBundle(exe) => {
            let exe = probe.resolve(exe);
            match bundle_root(&exe) {
                Some(root) => replaceable_or_unknown(root, probe),
                None => InstallChannel::Unknown,
            }
        }
        AppInstall::WindowsInstaller => InstallChannel::Direct,
    }
}

/// The channel the running `kendex` command installed through.
pub fn for_cli(exe: &Path, probe: &dyn HostProbe) -> InstallChannel {
    let exe = &probe.resolve(exe);
    if starts_with_any(exe, &BREW_PREFIXES) {
        return InstallChannel::Managed {
            command: "brew upgrade kendex-cli".to_owned(),
        };
    }
    if system_owned(exe) {
        let package = match probe.exists(Path::new(PACKAGED_APP_IMAGE)) {
            true => ArchPackage::Bin,
            false => ArchPackage::Cli,
        };
        return arch_channel(package, probe);
    }
    replaceable_or_unknown(exe, probe)
}

/// The two AUR packages that carry kendex. The name comes from where the
/// bytes are; no text kendex read anywhere ever reaches a command string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ArchPackage {
    /// Prebuilt: the desktop app and the command together.
    Bin,
    /// The command alone.
    Cli,
}

impl ArchPackage {
    fn name(self) -> &'static str {
        match self {
            Self::Bin => "kendex-bin",
            Self::Cli => "kendex",
        }
    }
}

/// A package-owned path is only actionable on a distro whose update command
/// this build knows. Anywhere else the honest answer is that we cannot say.
fn arch_channel(package: ArchPackage, probe: &dyn HostProbe) -> InstallChannel {
    if !probe.os_release().is_some_and(|text| is_arch(&text)) {
        return InstallChannel::Unknown;
    }
    let name = package.name();
    let command = if probe.on_path("paru") {
        format!("paru -S {name}")
    } else if probe.on_path("yay") {
        format!("yay -S {name}")
    } else {
        format!("update {name} with your AUR helper")
    };
    InstallChannel::Managed { command }
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
