//! Comparing an installed Pi package against the source it was copied from,
//! byte for byte. Every other kind is translated per harness on the way in and
//! has no byte-level answer to give — [`super::install_gap`] asks the presence
//! question for those.

use crate::config;
use std::path::{Path, PathBuf};

/// Byte comparison of an installed Pi package against its source. Presence is
/// [`missing_install`]'s job; this runs only once the install dir exists.
pub(super) fn verify_pi_bytes(name: &str, global: bool) -> (Option<bool>, Option<String>) {
    let install_dir = config::pi_packages_dir(global).join(name);
    // Locate source dir for this package by reading the source-index sidecar.
    let source_dir = match locate_pi_source(name, global) {
        Some(p) => p,
        None => return (None, Some("source path unresolvable".into())),
    };
    let src_hash = hash_dir_walk(&source_dir);
    let install_hash = hash_dir_walk(&install_dir);
    let ok = src_hash == install_hash;
    let note = if ok {
        None
    } else {
        Some(format!(
            "install drift: src {} vs install {}",
            short_hash(src_hash),
            short_hash(install_hash)
        ))
    };
    (Some(ok), note)
}

/// Walk a directory and compute an order-stable hash of (relative path, content).
/// Mirrors `config::hash_dir_bytes` so the two are directly comparable.
fn hash_dir_walk(dir: &Path) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x00000100000001B3;
    let mut state = FNV_OFFSET;
    let mut walker = walkdir::WalkDir::new(dir)
        .min_depth(1)
        .sort_by_file_name()
        .into_iter();
    while let Some(entry) = walker.next() {
        let Ok(entry) = entry else { continue };
        if entry.file_type().is_dir()
            && should_skip_hash_dir(entry.file_name().to_string_lossy().as_ref())
        {
            walker.skip_current_dir();
            continue;
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry.path().strip_prefix(dir).unwrap_or(entry.path());
        for &b in rel.to_string_lossy().as_bytes() {
            state ^= b as u64;
            state = state.wrapping_mul(FNV_PRIME);
        }
        if let Ok(content) = std::fs::read(entry.path()) {
            for &b in &content {
                state ^= b as u64;
                state = state.wrapping_mul(FNV_PRIME);
            }
        }
    }
    state
}

fn should_skip_hash_dir(name: &str) -> bool {
    // Keep in sync with config::should_skip_hash_dir. `.test-output` is a
    // pi-claude-bridge integration-test artifact dir; running its tests
    // creates symlinks/logs that are gitignored and never part of the
    // distributed package, so they must not influence install drift.
    matches!(
        name,
        "node_modules"
            | ".git"
            | ".turbo"
            | ".next"
            | ".cache"
            | "build"
            | "out"
            | "coverage"
            | ".pi"
            | ".test-output"
    )
}

fn short_hash(h: u64) -> String {
    format!("{h:016x}").chars().take(8).collect()
}

/// Walk the per-scope `.vstack-source.json` to find the source path for a
/// Pi package. Falls back to None if not recorded.
fn locate_pi_source(name: &str, global: bool) -> Option<PathBuf> {
    let index_path = if global {
        crate::config::pi_global_dir().join(".vstack-source.json")
    } else {
        crate::config::pi_project_dir().join(".vstack-source.json")
    };
    let raw = std::fs::read_to_string(&index_path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let entry = json.get(name)?;
    let source_path = entry.get("sourcePath").and_then(|v| v.as_str())?;
    let p = PathBuf::from(source_path);
    if p.is_dir() { Some(p) } else { None }
}
