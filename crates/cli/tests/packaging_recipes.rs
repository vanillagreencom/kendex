//! The Homebrew and AUR recipes under packaging/ point at per-architecture
//! release assets by hand. CI has neither brew nor makepkg, so this checks
//! the text: every non-Windows lane in release.yml must be selectable from
//! each recipe, and a lane added to the workflow fails here until the
//! recipes catch up.

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

/// Pacman arch names: `x86_64` and `aarch64`, each with its own source
/// array, mirrored into .SRCINFO.
#[test]
fn aur_packages_carry_a_source_array_per_linux_arch() {
    let linux: Vec<Lane> = unix_lanes()
        .into_iter()
        .filter(|l| l.os == "linux")
        .collect();
    assert_eq!(
        linux.len(),
        2,
        "AUR test assumes one x86_64 and one aarch64 linux lane"
    );
    for pkg in ["kendex", "kendex-bin"] {
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
            if pkg == "kendex-bin" {
                let debian_word = if pacman_arch == "x86_64" {
                    "amd64"
                } else {
                    pacman_arch
                };
                assert!(
                    source_line.contains(&format!("_{debian_word}.AppImage")),
                    "{pkg}: source_{pacman_arch} does not fetch the {debian_word} AppImage"
                );
            }
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
}
