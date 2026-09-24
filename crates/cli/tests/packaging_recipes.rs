//! The Homebrew and AUR recipes under packaging/ point at per-architecture
//! release assets by hand. CI has neither brew nor makepkg, so this checks
//! the text: every non-Windows lane in release.yml must be selectable from
//! each recipe, and a lane the workflow gains fails here until the recipes
//! catch up.

use std::fs;
use std::path::{Path, PathBuf};

fn repo(rel: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel)
}

#[allow(clippy::unwrap_used)]
fn read(rel: &str) -> String {
    fs::read_to_string(repo(rel)).unwrap()
}

/// A checksum entry as the recipes write it: 64 hex chars, quotes and a
/// trailing comma allowed, placeholder zeros included.
fn is_sha256(entry: &str) -> bool {
    let hex = entry
        .trim()
        .trim_end_matches(',')
        .trim_matches(|c| c == '"' || c == '\'');
    hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit())
}

/// A release lane split the way the recipes select it.
struct Lane {
    triple: String,
    os: &'static str,
    arch: &'static str,
}

#[allow(clippy::unwrap_used)]
fn unix_lanes() -> Vec<Lane> {
    let workflow = read(".github/workflows/release.yml");
    let lanes: Vec<Lane> = workflow
        .lines()
        .filter_map(|l| l.trim().strip_prefix("target: "))
        .filter(|t| !t.contains("windows"))
        .map(|t| Lane {
            triple: t.to_owned(),
            os: if t.contains("apple-darwin") {
                "macos"
            } else {
                "linux"
            },
            arch: if t.starts_with("aarch64") {
                "arm"
            } else {
                "intel"
            },
        })
        .collect();
    assert!(lanes.len() >= 4, "release.yml lost its unix lanes");
    lanes
}

/// Formula blocks nest as `on_<os> do` / `on_<arch> do`; the triple's url
/// must sit inside the pair that matches it, with its own sha256 beside it.
#[test]
fn homebrew_formula_places_each_lane_under_its_os_and_arch_block() {
    let formula = read("packaging/homebrew/kendex-cli.rb");
    let mut os = "";
    let mut arch = "";
    let mut placed: Vec<(String, &str, &str)> = Vec::new();
    let mut shas: Vec<Option<String>> = Vec::new();
    for line in formula.lines().map(str::trim) {
        match line {
            "on_macos do" => os = "macos",
            "on_linux do" => os = "linux",
            "on_arm do" => arch = "arm",
            "on_intel do" => arch = "intel",
            _ if line.starts_with("url ") => {
                let triple = line
                    .rsplit("/kendex-")
                    .next()
                    .unwrap()
                    .trim_end_matches('"');
                placed.push((triple.to_owned(), os, arch));
                shas.push(None);
            }
            _ if line.starts_with("sha256 ") => {
                let slot = shas.last_mut().expect("sha256 before any url");
                assert!(
                    slot.is_none(),
                    "two sha256 lines for {}",
                    placed[placed.len() - 1].0
                );
                *slot = Some(line.trim_start_matches("sha256 ").to_owned());
            }
            _ => {}
        }
    }
    for (lane, sha) in placed.iter().zip(&shas) {
        assert!(
            sha.as_deref().is_some_and(is_sha256),
            "kendex-cli.rb lane {} has no 64-hex sha256 beside its url (got {sha:?})",
            lane.0
        );
    }
    for lane in unix_lanes() {
        assert!(
            placed.contains(&(lane.triple.clone(), lane.os, lane.arch)),
            "kendex-cli.rb has no url for {} under on_{}/on_{}",
            lane.triple,
            lane.os,
            lane.arch
        );
    }
    assert_eq!(
        placed.len(),
        unix_lanes().len(),
        "formula names a target the release does not build"
    );
}

/// The Linux command links libdbus-1; macOS uses the native keyring.
#[test]
fn homebrew_formula_declares_dbus_and_build_only_patchelf_only_for_linux() {
    let formula = read("packaging/homebrew/kendex-cli.rb");
    let mut blocks = Vec::new();
    let mut dependencies = Vec::new();
    for line in formula.lines().map(str::trim) {
        match line {
            "end" => {
                blocks.pop();
            }
            _ if line.starts_with("depends_on ")
                && (line.contains(r#""dbus""#) || line.contains(r#""patchelf""#)) =>
            {
                dependencies.push((line, blocks.clone()));
            }
            _ if line.ends_with(" do") => blocks.push(line),
            _ => {}
        }
    }
    assert_eq!(
        dependencies,
        [
            (r#"depends_on "dbus""#, vec!["on_linux do"]),
            (r#"depends_on "patchelf" => :build"#, vec!["on_linux do"]),
        ]
    );
}

/// Patching the staged Linux command leaves macOS and child environments alone.
#[test]
fn homebrew_formula_patches_the_linux_command_before_installing_it() {
    let formula = read("packaging/homebrew/kendex-cli.rb");
    let install: Vec<_> = formula
        .lines()
        .map(str::trim)
        .skip_while(|line| *line != "def install")
        .skip(1)
        .take_while(|line| *line != "end")
        .collect();
    assert_eq!(
        install,
        [
            r#"executable = Dir["*"].first"#,
            r#"system "patchelf", "--set-rpath", Formula["dbus"].opt_lib, executable if OS.linux?"#,
            r#"bin.install executable => "kendex""#,
        ]
    );
}

/// Tauri names the disk image by `aarch64` / `x64`; the cask selects one
/// through its `arch` stanza and needs a checksum for each.
#[test]
fn homebrew_cask_selects_a_dmg_and_checksum_per_mac_arch() {
    let cask = read("packaging/homebrew/kendex-cask.rb");
    let mac_arches: Vec<&str> = unix_lanes()
        .into_iter()
        .filter(|l| l.os == "macos")
        .map(|l| l.arch)
        .collect();
    assert_eq!(
        mac_arches.len(),
        2,
        "cask test assumes one arm and one intel mac lane"
    );
    assert!(
        cask.contains(r#"arch arm: "aarch64", intel: "x64""#),
        "{cask}"
    );
    assert!(cask.contains("_#{arch}.dmg"), "{cask}");
    // The `arch arm:/intel:` stanza also says `intel:`, so the checksum
    // check reads only the sha256 declaration and its continuation line.
    let sha_lines: Vec<&str> = cask
        .lines()
        .skip_while(|l| !l.trim().starts_with("sha256 arm:"))
        .take(2)
        .collect();
    assert_eq!(
        sha_lines.len(),
        2,
        "cask has no two-line sha256 map:\n{cask}"
    );
    let arm = sha_lines[0].split("arm:").nth(1).unwrap_or_default();
    assert!(
        is_sha256(arm),
        "cask arm sha256 is not 64 hex chars: {}",
        sha_lines[0]
    );
    let intel = sha_lines[1].split("intel:").nth(1).unwrap_or_default();
    assert!(
        sha_lines[1].trim().starts_with("intel:") && is_sha256(intel),
        "cask sha256 map has no intel entry: {}",
        sha_lines[1]
    );
    assert!(
        !cask.contains("depends_on arch"),
        "cask still pins one architecture"
    );
}

/// The app calls a cask install `Direct` and offers to replace itself.
/// Without this stanza Homebrew treats that replacement as drift and
/// reinstalls the old version over it on the next `brew upgrade`.
#[test]
fn homebrew_cask_hands_the_upgrade_to_the_app() {
    let cask = read("packaging/homebrew/kendex-cask.rb");
    assert!(
        cask.lines().any(|l| l.trim() == "auto_updates true"),
        "{cask}"
    );
}

/// Pacman arch names: `x86_64` and `aarch64`, each with its own source
/// array, mirrored into .SRCINFO. Only the prebuilt package selects a
/// download per architecture; the other three build from source.
#[test]
fn the_prebuilt_package_carries_a_source_array_per_linux_arch() {
    let linux: Vec<Lane> = unix_lanes()
        .into_iter()
        .filter(|l| l.os == "linux")
        .collect();
    assert_eq!(
        linux.len(),
        2,
        "AUR test assumes one x86_64 and one aarch64 linux lane"
    );
    let pkg = "kendex-bin";
    let pkgbuild = read(&format!("packaging/arch/{pkg}/PKGBUILD"));
    let srcinfo = read(&format!("packaging/arch/{pkg}/.SRCINFO"));
    assert!(
        pkgbuild.contains("arch=('x86_64' 'aarch64')"),
        "{pkg}: arch array"
    );
    for lane in &linux {
        let pacman_arch = lane.triple.split('-').next().unwrap_or_default();
        let source_line = pkgbuild
            .split(&format!("source_{pacman_arch}=("))
            .nth(1)
            .and_then(|rest| rest.split(')').next())
            .unwrap_or_else(|| panic!("{pkg}: no source_{pacman_arch} array"));
        assert!(
            source_line.contains(&format!("kendex-{}", lane.triple)),
            "{pkg}: source_{pacman_arch} does not fetch kendex-{}",
            lane.triple
        );
        let debian_word = if pacman_arch == "x86_64" {
            "amd64"
        } else {
            pacman_arch
        };
        assert!(
            source_line.contains(&format!("_{debian_word}.AppImage")),
            "{pkg}: source_{pacman_arch} does not fetch the {debian_word} AppImage"
        );
        assert!(
            srcinfo.lines().any(|l| {
                l.trim().starts_with(&format!("source_{pacman_arch} = "))
                    && l.contains(&format!("kendex-{}", lane.triple))
            }),
            "{pkg}: .SRCINFO is stale for source_{pacman_arch}"
        );
        let sources = source_line.matches("::").count();
        let sums = pkgbuild
            .split(&format!("sha256sums_{pacman_arch}=("))
            .nth(1)
            .and_then(|rest| rest.split(')').next())
            .unwrap_or_else(|| panic!("{pkg}: no sha256sums_{pacman_arch} array"));
        let valid = sums.split_whitespace().filter(|e| is_sha256(e)).count();
        assert_eq!(
            valid, sources,
            "{pkg}: sha256sums_{pacman_arch} has {valid} 64-hex entries for {sources} sources"
        );
        let srcinfo_sums = srcinfo
            .lines()
            .filter(|l| {
                l.trim()
                    .starts_with(&format!("sha256sums_{pacman_arch} = "))
            })
            .filter(|l| is_sha256(l.rsplit(" = ").next().unwrap_or_default()))
            .count();
        assert_eq!(
            srcinfo_sums, sources,
            "{pkg}: .SRCINFO is stale for sha256sums_{pacman_arch}"
        );
    }
}

/// The Arch packages this repository publishes, and what each one installs.
/// The three desktop packages are separated from the CLI-only one here
/// because almost every rule below runs over one group or the other.
const DESKTOP_PACKAGES: [&str; 3] = ["kendex", "kendex-git", "kendex-bin"];
const CLI_ONLY_PACKAGE: &str = "kendex-cli-git";
/// The one package that repackages the release instead of building it, so the
/// source-build rules below reach the other two without naming them.
const PREBUILT_PACKAGE: &str = "kendex-bin";

fn arch_packages() -> Vec<&'static str> {
    let mut all = DESKTOP_PACKAGES.to_vec();
    all.push(CLI_ONLY_PACKAGE);
    all
}

/// The values a PKGBUILD assigns to `name`: the words of an array, quotes
/// stripped, or the one word of a scalar. Empty where the recipe assigns
/// nothing.
///
/// Comment lines go before the closing paren is looked for, not after. These
/// recipes explain their dependencies inline, and one of those comments names
/// `(desktop-file-utils)`: cutting the array at the first paren in the text
/// would end it mid-array and silently drop every value below the comment.
fn pkgbuild_field(pkgbuild: &str, name: &str) -> Vec<String> {
    let assignment = format!("\n{name}=");
    let Some(rest) = pkgbuild.split(&assignment).nth(1) else {
        return Vec::new();
    };
    let code: String = rest
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .collect::<Vec<&str>>()
        .join("\n");
    let body = match code.strip_prefix('(') {
        Some(array) => array.split(')').next().unwrap_or_default(),
        None => code.lines().next().unwrap_or_default(),
    };
    body.split_whitespace()
        .map(|word| word.trim_matches(|c| c == '\'' || c == '"').to_owned())
        .filter(|word| !word.is_empty())
        .collect()
}

/// The extractor reads a whole array whose values are commented between, and
/// a scalar past the comment that follows it. Without this every assertion
/// over a `depends` array below would pass on a recipe that dropped half of
/// it, which is how a desktop dependency reached the CLI-only package
/// unnoticed.
#[test]
fn pkgbuild_field_reads_past_a_comment_that_carries_a_paren() {
    let recipe = "\npkgname=demo\n# a comment line of its own\ndepends=(\n  'git'\n  # through `update-desktop-database` (desktop-file-utils)\n  'xdg-utils'\n)\nmakedepends=('cargo')\n";
    assert_eq!(
        pkgbuild_field(recipe, "depends"),
        vec!["git".to_owned(), "xdg-utils".to_owned()],
        "the comment's paren ended the array"
    );
    assert_eq!(
        pkgbuild_field(recipe, "makedepends"),
        vec!["cargo".to_owned()]
    );
    assert_eq!(pkgbuild_field(recipe, "pkgname"), vec!["demo".to_owned()]);
    assert!(pkgbuild_field(recipe, "epoch").is_empty());
}

fn pkgbuild(package: &str) -> String {
    read(&format!("packaging/arch/{package}/PKGBUILD"))
}

fn srcinfo(package: &str) -> String {
    read(&format!("packaging/arch/{package}/.SRCINFO"))
}

/// The values a `.SRCINFO` records for a field, one per `<field> = ` line.
/// makepkg generates these from the PKGBUILD, and `tools/check-aur-sync`
/// holds the pair in agreement, so they are the same array read a second way.
fn srcinfo_field(srcinfo: &str, name: &str) -> Vec<String> {
    let prefix = format!("{name} = ");
    srcinfo
        .lines()
        .map(str::trim)
        .filter_map(|line| line.strip_prefix(prefix.as_str()))
        .map(str::to_owned)
        .collect()
}

/// The extractor above reads the same dependencies makepkg recorded, per
/// package. This is what catches it stopping early: a comment carrying a
/// paren inside an array used to end it, and the values below the comment
/// went missing with nothing to notice. Written against the generated file
/// rather than a count in this file, so an ordinary dependency added to or
/// dropped from a recipe needs no edit here.
#[test]
fn the_extractor_reads_the_same_depends_the_srcinfo_records() {
    for package in arch_packages() {
        let from_recipe = pkgbuild_field(&pkgbuild(package), "depends");
        let recorded = srcinfo_field(&srcinfo(package), "depends");
        assert!(
            !recorded.is_empty(),
            "{package}: .SRCINFO records no depends, so this comparison proves nothing"
        );
        assert_eq!(from_recipe, recorded, "{package}: depends");
        // makedepends too: the npm entry the source packages need is one of
        // these, and the two arrays are read by the same extractor.
        assert_eq!(
            pkgbuild_field(&pkgbuild(package), "makedepends"),
            srcinfo_field(&srcinfo(package), "makedepends"),
            "{package}: makedepends"
        );
    }
}

/// Every package carries a recipe pair, and every one of them carries the
/// same epoch. kendex 1.0.0 follows 5.0.1, so the version number goes
/// backwards: without an epoch pacman reads the new release as older than
/// the 5.x a machine already holds and never offers the upgrade.
#[test]
fn every_arch_package_ships_a_recipe_pair_under_one_epoch() {
    for package in arch_packages() {
        let recipe = pkgbuild(package);
        assert_eq!(
            pkgbuild_field(&recipe, "pkgname"),
            vec![package.to_owned()],
            "{package}: pkgname"
        );
        assert_eq!(
            pkgbuild_field(&recipe, "epoch"),
            vec!["1".to_owned()],
            "{package}: the 5.x-to-1.0 transition needs an epoch on every package"
        );
        let srcinfo = read(&format!("packaging/arch/{package}/.SRCINFO"));
        assert!(
            srcinfo.lines().any(|l| l.trim() == "epoch = 1"),
            "{package}: .SRCINFO is stale for epoch"
        );
    }
}

/// makepkg LTO makes ring's C objects fail to link with rust-lld. Every
/// package that compiles kendex disables LTO, and records the option in the
/// generated metadata that AUR clients read.
#[test]
fn every_source_arch_package_disables_makepkg_lto() {
    for package in arch_packages()
        .into_iter()
        .filter(|package| *package != PREBUILT_PACKAGE)
    {
        let options = pkgbuild_field(&pkgbuild(package), "options");
        assert!(
            options.iter().any(|option| option == "!lto"),
            "{package}: builds from source without disabling makepkg LTO"
        );
        assert_eq!(
            options,
            srcinfo_field(&srcinfo(package), "options"),
            "{package}: .SRCINFO is stale for options"
        );
    }
}

/// brew compares a formula's `version_scheme` before its version, so the
/// bump is what makes 1.0.0 outrank an installed 5.x, which sits on scheme
/// 0, in `brew outdated` and `brew upgrade`. This is the formula's side of
/// the transition the Arch epoch covers above; the cask has no equivalent.
#[test]
fn the_formula_declares_the_restart_as_a_new_version_scheme() {
    let formula = read("packaging/homebrew/kendex-cli.rb");
    assert!(
        formula.lines().any(|l| l.trim() == "version_scheme 1"),
        "kendex-cli.rb: no `version_scheme 1`, so a 5.x install never shows \
         as outdated:\n{formula}"
    );
}

/// The body of the cask's `caveats <<~EOS` heredoc. Read as a block rather
/// than searched for over the whole file because the header comment already
/// spells out the install command the caveat has to name.
fn homebrew_cask_caveats() -> String {
    const RECIPE: &str = "packaging/homebrew/kendex-cask.rb";
    const OPENER: &str = "caveats <<~EOS";
    let text = read(RECIPE);
    let lines: Vec<&str> = text.lines().collect();
    let opener = lines
        .iter()
        .position(|l| l.trim() == OPENER)
        .unwrap_or_else(|| panic!("{RECIPE}: no `{OPENER}` stanza"));
    let body = &lines[opener + 1..];
    let end = body
        .iter()
        .position(|l| l.trim() == "EOS")
        .unwrap_or_else(|| panic!("{RECIPE}: the caveats heredoc never closes"));
    assert!(end > 0, "{RECIPE}: the caveats block is empty");
    body[..end].join("\n")
}

/// A cask has no `version_scheme`, and `auto_updates true` defers to an app
/// that renders no notice for a feed older than itself, so a 5.x install is
/// reached by telling the person to uninstall and install again. Uninstalling
/// the cask leaves its kendex-cli formula dependency installed, so the
/// command is removed as its own step before the install pulls it back at
/// 1.0.0; the order is the instruction.
#[test]
fn the_cask_tells_a_5_x_install_to_reinstall_the_app_and_its_cli() {
    let caveats = homebrew_cask_caveats();
    let steps: Vec<&str> = caveats
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("brew "))
        .collect();
    assert_eq!(
        steps,
        [
            "brew uninstall kendex",
            "brew uninstall kendex-cli",
            "brew install vanillagreencom/kendex/kendex",
        ],
        "kendex-cask.rb: the caveats' brew steps are not the reinstall of the \
         app and its command:\n{caveats}"
    );
}

/// All four install `/usr/bin/kendex`, so no two may be installed together.
/// Each names the other three, in both directions: a one-sided declaration
/// is enough for pacman and leaves the reader of the other recipe with no
/// sign that the pair collide.
#[test]
fn each_arch_package_conflicts_with_every_other_one() {
    for package in arch_packages() {
        let conflicts = pkgbuild_field(&pkgbuild(package), "conflicts");
        let others: Vec<&str> = arch_packages()
            .into_iter()
            .filter(|other| *other != package)
            .collect();
        for other in others {
            assert!(
                conflicts.iter().any(|name| name == other),
                "{package}: conflicts {conflicts:?} does not name {other}, \
                 so the two could be installed over each other"
            );
        }
        assert!(
            !conflicts.iter().any(|name| name == package),
            "{package}: conflicts with itself"
        );
    }
}

/// `kendex` is the package that installs the desktop app and the command
/// together, so the two other packages that install both provide that name
/// and the CLI-only one does not: a dependency on `kendex` satisfied by the
/// command alone would leave a person without the app they asked for.
#[test]
fn only_the_packages_installing_both_halves_provide_the_kendex_name() {
    for package in DESKTOP_PACKAGES.into_iter().filter(|p| *p != "kendex") {
        assert!(
            pkgbuild_field(&pkgbuild(package), "provides")
                .iter()
                .any(|name| name == "kendex"),
            "{package}: installs the app and the command but does not provide kendex"
        );
    }
    assert!(
        !pkgbuild_field(&pkgbuild(CLI_ONLY_PACKAGE), "provides")
            .iter()
            .any(|name| name == "kendex"),
        "{CLI_ONLY_PACKAGE}: provides kendex while installing the command alone"
    );
}

/// The dependencies every package carries because the installed command needs
/// them, whichever half of kendex the package ships. They are matched as name
/// prefixes, so a version bound such as `git>=2.41` is one of them. The
/// comparison below excuses these and no other name.
const SHARED_DEPENDENCIES: [&str; 2] = ["git", "dbus"];

/// The CLI-only package pulls no desktop build or runtime dependency. The set
/// it must stay clear of is the union of what the three desktop packages
/// declare, built without consulting the CLI-only package: consulting it
/// first would drop a leaked dependency out of the union and leave the
/// comparison below unable to fail.
///
/// `SHARED_DEPENDENCIES` names what the two sides legitimately share, each
/// asserted present here as well as excused below. That the arrays are read
/// whole is `the_extractor_reads_the_same_depends_the_srcinfo_records`.
#[test]
fn the_cli_only_package_carries_no_desktop_dependency() {
    let cli_depends = pkgbuild_field(&pkgbuild(CLI_ONLY_PACKAGE), "depends");
    for shared in SHARED_DEPENDENCIES {
        assert!(
            cli_depends.iter().any(|d| d.starts_with(shared)),
            "{CLI_ONLY_PACKAGE}: depends {cli_depends:?} drops {shared}, which the \
             installed command needs"
        );
    }
    let mut desktop: Vec<String> = Vec::new();
    for package in DESKTOP_PACKAGES {
        for dependency in pkgbuild_field(&pkgbuild(package), "depends") {
            if !desktop.contains(&dependency) {
                desktop.push(dependency);
            }
        }
    }
    // The one the reader would look for by name, so a comparison that read
    // no array at all still fails here.
    assert!(
        desktop.iter().any(|d| d.starts_with("webkit2gtk")),
        "no desktop package depends on webkit2gtk: {desktop:?}"
    );
    for dependency in &desktop {
        if SHARED_DEPENDENCIES
            .iter()
            .any(|shared| dependency.starts_with(shared))
        {
            continue;
        }
        assert!(
            !cli_depends.contains(dependency),
            "{CLI_ONLY_PACKAGE}: depends on {dependency}, which only the desktop packages need"
        );
    }
}

/// Every package installs the `kendex` command, and that command links
/// libdbus-1 directly: `kendex-core` depends on `keyring` unconditionally and
/// the workspace enables its `sync-secret-service` backend, which reaches
/// `libdbus-sys`. Arch ships the shared library, the headers and `dbus-1.pc`
/// in the one `dbus` package, so that name covers both needs.
///
/// Without it the three source packages fail inside the `libdbus-sys` build
/// script, which probes `dbus-1.pc` with pkg-config and panics, before any
/// Rust code compiles; kendex-bin installs a command the dynamic loader
/// cannot start. `SHARED_DEPENDENCIES` excuses the name where the CLI-only
/// package meets the desktop ones, so it is asserted here rather than left to
/// that comparison.
#[test]
fn every_package_declares_the_dbus_the_command_links() {
    for package in arch_packages() {
        let depends = pkgbuild_field(&pkgbuild(package), "depends");
        assert!(
            depends.iter().any(|entry| entry == "dbus"),
            "{package}: depends {depends:?} drops dbus, which the installed command links"
        );
    }
}

/// The desktop app embeds `ui/dist` through tauri's context macro, and only
/// `cargo tauri build` would build the frontend on its own. These recipes run
/// plain `cargo build`, so each one builds the frontend itself first or ships
/// an app with an empty window: a green repository and a broken menu item.
/// Nothing else reads a recipe's build function, so this is where those two
/// lines and the `npm` makedepend live.
///
/// The CLI-only package is on the negative side, which is what
/// `packaging/README.md` § The four Arch packages states, and so is the
/// prebuilt package, which builds nothing.
#[test]
fn the_desktop_source_packages_build_the_frontend_before_the_app() {
    let source_desktop: Vec<&str> = DESKTOP_PACKAGES
        .into_iter()
        .filter(|package| *package != PREBUILT_PACKAGE)
        .collect();
    assert_eq!(
        source_desktop.len(),
        DESKTOP_PACKAGES.len() - 1,
        "every desktop package is the prebuilt one, so nothing is checked"
    );
    for package in source_desktop {
        let recipe = pkgbuild(package);
        let at = |needle: &str| {
            recipe
                .find(needle)
                .unwrap_or_else(|| panic!("{package}: the recipe never runs {needle}"))
        };
        let install = at("npm ci --prefix ui");
        let frontend = at("npm run --prefix ui build");
        let app = at("cargo build --release --locked");
        assert!(
            install < app && frontend < app,
            "{package}: the frontend is built after cargo, so the app embeds an empty ui/dist"
        );
        let build = recipe[app..].lines().next().unwrap_or_default();
        assert!(
            build.contains("--features tauri/custom-protocol"),
            "{package}: cargo builds the app without tauri/custom-protocol, so it loads devUrl"
        );
        assert!(
            pkgbuild_field(&recipe, "makedepends")
                .iter()
                .any(|entry| entry == "npm"),
            "{package}: runs npm without declaring it as a makedepend"
        );
    }
    for package in [CLI_ONLY_PACKAGE, PREBUILT_PACKAGE] {
        let recipe = pkgbuild(package);
        assert!(
            !recipe.contains("npm"),
            "{package}: reaches for npm, and installs no app to need it"
        );
    }
}

/// Each desktop package installs the app off `PATH`, a menu entry pointing
/// at it, and the icon sizes a launcher picks from; the CLI-only package
/// installs none of that. `StartupWMClass` is what ties a running window to
/// the entry, and `install.sh` writes the same one.
#[test]
fn only_the_desktop_packages_install_a_launcher() {
    for package in DESKTOP_PACKAGES {
        let recipe = pkgbuild(package);
        assert!(
            recipe.contains("/usr/share/applications/kendex.desktop"),
            "{package}: no desktop entry"
        );
        assert!(
            recipe.contains("StartupWMClass=kendex-app"),
            "{package}: the desktop entry does not tie the window to itself"
        );
        assert!(
            !recipe.contains("Exec=/usr/bin/kendex\n"),
            "{package}: the menu entry launches the command rather than the app"
        );
        for size in ["32x32", "128x128", "256x256", "512x512"] {
            assert!(
                recipe.contains(&format!("/usr/share/icons/hicolor/{size}/apps/kendex.png")),
                "{package}: no {size} icon"
            );
        }
        assert!(
            recipe.contains("\"$pkgdir/usr/bin/kendex\""),
            "{package}: does not install the command"
        );
    }
    let cli = pkgbuild(CLI_ONLY_PACKAGE);
    assert!(
        !cli.contains("/usr/share/applications/"),
        "{CLI_ONLY_PACKAGE}: installs a desktop entry"
    );
    assert!(
        !cli.contains("/usr/share/icons/"),
        "{CLI_ONLY_PACKAGE}: installs icons"
    );
    assert!(
        !cli.contains("kendex-app"),
        "{CLI_ONLY_PACKAGE}: builds or installs the desktop app"
    );
}
