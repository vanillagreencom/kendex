//! Verify the live install matches its source on disk.
//!
//! Two checks per item:
//!
//! 1. **Source vs lock hash.** Compares the current source hash against the
//!    hash recorded in the lock at install time. A mismatch means the
//!    source dir has been edited since the last `add`/`refresh` — the lock
//!    is stale.
//!
//! 2. **Install vs source bytes** (Pi packages only). Walks both the source
//!    package dir and the installed package dir, hashing identical
//!    relative-path/content pairs. A mismatch means refresh didn't fully
//!    copy, or something modified the install. Skills, agents, and hooks
//!    have per-harness translation, so they aren't directly byte-comparable
//!    — we just confirm the expected install path exists for each harness
//!    the lock claims it was installed into.
//!
//! This command is the answer to "did my last refresh actually take?" — a
//! gap that previously required `md5sum` plumbing by hand.
//!
//! Exit code is non-zero if any item fails verification, so this composes
//! with shell pipelines (`vstack verify -g && pi`).

use crate::config::{self, ItemKind, LockEntry};
use crate::scope::ScopeFilter;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Per-item verification result.
struct VerifyRow {
    kind: &'static str,
    name: String,
    /// Matches lock hash?
    source_ok: bool,
    /// Install matches source on disk? `None` for items we don't byte-compare.
    install_ok: Option<bool>,
    /// Human-readable note (e.g. "install path missing").
    note: Option<String>,
}

pub fn run(scope: ScopeFilter, names: &[String]) -> Result<()> {
    let mut total_failed = 0usize;
    let mut total_checked = 0usize;
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        if !lock_path.exists() {
            continue;
        }
        let lock = config::LockFile::load(&lock_path)?;
        if lock.entries.is_empty() {
            continue;
        }
        let scope_label = if global { "GLOBAL" } else { "PROJECT" };
        eprintln!("\n─ verify ({scope_label}) ─");

        let mut rows: Vec<VerifyRow> = Vec::new();
        for (entry_name, entry) in &lock.entries {
            if !names.is_empty() && !names.iter().any(|n| n == entry_name) {
                continue;
            }
            rows.push(verify_entry(entry, global));
        }
        rows.sort_by(|a, b| a.name.cmp(&b.name));

        let kind_w = rows.iter().map(|r| r.kind.len()).max().unwrap_or(0);
        let name_w = rows.iter().map(|r| r.name.len()).max().unwrap_or(0);
        for row in &rows {
            total_checked += 1;
            let source_mark = if row.source_ok { "✓" } else { "!" };
            let install_mark = match row.install_ok {
                Some(true) => "✓",
                Some(false) => "!",
                None => "·",
            };
            let ok = row.source_ok && row.install_ok.unwrap_or(true) && row.note.is_none();
            if !ok {
                total_failed += 1;
            }
            let note = row
                .note
                .as_deref()
                .map(|s| format!("  ({s})"))
                .unwrap_or_default();
            eprintln!(
                "  src:{} install:{}  {:kw$}  {:nw$}{}",
                source_mark,
                install_mark,
                row.kind,
                row.name,
                note,
                kw = kind_w,
                nw = name_w,
            );
        }
    }

    if total_checked == 0 {
        eprintln!("Nothing installed in selected scope(s).");
        return Ok(());
    }

    eprintln!(
        "\n{} checked, {} OK, {} failed",
        total_checked,
        total_checked - total_failed,
        total_failed
    );
    if total_failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}

fn verify_entry(entry: &LockEntry, global: bool) -> VerifyRow {
    let kind = entry.kind.label_short();
    let name = entry.name.clone();

    // Source hash check (covers all kinds).
    let current = config::compute_source_hash(entry);
    let source_ok = if entry.source_hash.is_empty() {
        // Legacy lock without recorded hash — best effort: just confirm
        // we could resolve a source at all.
        !current.is_empty()
    } else {
        current == entry.source_hash
    };

    // Per-kind install check.
    let (install_ok, note) = match entry.kind {
        ItemKind::PiExtension => verify_pi_install(&entry.name, global),
        ItemKind::Skill => verify_skill_install(&entry.name, &entry.harnesses, global),
        ItemKind::Agent => verify_agent_install(&entry.name, &entry.harnesses, global),
        ItemKind::Hook => verify_hook_install(&entry.name, &entry.harnesses, global),
        ItemKind::Extra => (None, None),
    };

    VerifyRow {
        kind,
        name,
        source_ok,
        install_ok,
        note,
    }
}

fn verify_pi_install(name: &str, global: bool) -> (Option<bool>, Option<String>) {
    let install_dir = config::pi_packages_dir(global).join(name);
    if !install_dir.is_dir() {
        return (Some(false), Some("install path missing".into()));
    }
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

fn verify_skill_install(
    name: &str,
    _harnesses: &[String],
    global: bool,
) -> (Option<bool>, Option<String>) {
    let canonical = if global {
        config::global_state_dir().join("skills").join(name)
    } else {
        config::project_root()
            .join(".agents")
            .join("skills")
            .join(name)
    };
    if canonical.exists() {
        (Some(true), None)
    } else {
        (Some(false), Some("install path missing".into()))
    }
}

fn verify_agent_install(
    name: &str,
    harnesses: &[String],
    global: bool,
) -> (Option<bool>, Option<String>) {
    let mut missing = Vec::new();
    for h in harnesses {
        let Some(harness) = crate::harness::Harness::from_id(h) else {
            continue;
        };
        let path = harness
            .agents_dir(global)
            .join(harness.agent_filename(name));
        if !path.exists() {
            missing.push(h.clone());
        }
    }
    if missing.is_empty() {
        (Some(true), None)
    } else {
        (
            Some(false),
            Some(format!("missing in: {}", missing.join(", "))),
        )
    }
}

fn verify_hook_install(
    name: &str,
    harnesses: &[String],
    global: bool,
) -> (Option<bool>, Option<String>) {
    let mut missing = Vec::new();
    for h in harnesses {
        let Some(harness) = crate::harness::Harness::from_id(h) else {
            continue;
        };
        match harness {
            crate::harness::Harness::ClaudeCode => {
                let path = harness
                    .hooks_dir(global)
                    .map(|d| d.join(format!("{name}.sh")));
                if path.is_none_or(|p| !p.exists()) {
                    missing.push(format!("{h}: script missing"));
                }
            }
            crate::harness::Harness::Cursor => {
                let path = harness
                    .agents_dir(global)
                    .join(format!("safety-{name}.mdc"));
                if !path.exists() {
                    missing.push(format!("{h}: rule missing"));
                }
            }
            crate::harness::Harness::OpenCode => {
                let dir = if global {
                    config::opencode_global_dir().join("instructions")
                } else {
                    config::project_root()
                        .join(".opencode")
                        .join("instructions")
                };
                let path = dir.join(format!("vstack-hook-{name}.md"));
                if !path.exists() {
                    missing.push(format!("{h}: instruction missing"));
                }
            }
            crate::harness::Harness::Codex => {
                // Native install: script under <root>/.codex/hooks/.
                // Prose-fallback: `## Safety: <name>` block in some agent toml.
                let root = if global {
                    config::codex_home_dir()
                } else {
                    config::project_root().join(".codex")
                };
                let script = root.join("hooks").join(format!("{name}.sh"));
                let has_script = script.exists();
                let has_prose = !has_script && codex_agent_has_prose(&root, name);
                if !has_script && !has_prose {
                    missing.push(format!("{h}: no script and no prose"));
                }
            }
            crate::harness::Harness::Pi => {
                // Pi has no script-based per-hook install path — the safety
                // hooks ship as the @vanillagreen/pi-hooks extension instead,
                // which is verified separately as a Pi package. Nothing to
                // check here.
            }
        }
    }
    if missing.is_empty() {
        (Some(true), None)
    } else {
        (Some(false), Some(missing.join("; ")))
    }
}

fn codex_agent_has_prose(codex_root: &Path, hook_name: &str) -> bool {
    let agents_dir = codex_root.join("agents");
    let Ok(entries) = std::fs::read_dir(&agents_dir) else {
        return false;
    };
    let marker = format!("## Safety: {hook_name}");
    entries.flatten().any(|entry| {
        let path = entry.path();
        path.extension().is_some_and(|ex| ex == "toml")
            && std::fs::read_to_string(&path)
                .map(|c| c.contains(&marker))
                .unwrap_or(false)
    })
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
