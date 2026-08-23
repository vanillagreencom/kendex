//! The second scoring path: what is on disk right now, rather than what a
//! plan would write. Same rules, a different set of bytes.
//!
//! An installed item is not the same thing as a desired one. It may predate
//! the declaration, it may have been edited by hand, and it may not be
//! declared at all — that is exactly what an audit is for. Where the bytes
//! cannot be reached from an observation alone (an MCP server that lives as
//! one entry inside a shared config file, a plugin whose own directory the
//! scanner never visits), the input says so and every rule that would have
//! read them reports itself not applicable.

use std::path::{Path, PathBuf};

use crate::model::{ItemKind, ObservedItem};

use super::{
    AuditInput, AuditResult, Content, McpEntry, PluginSources, TreeFile, UNREAD_MCP_ENTRY,
    UNREADABLE_PLUGIN,
};

/// One tree's in-memory files as audit input, in the order the observed
/// walk uses. The gate reads a plan's rendered bytes through this so both
/// scoring paths hash one construction — an override granted against the
/// plan must still recognise the install when the audit reads it back off
/// disk.
///
/// Every file, to its last byte. A prefix would score a package on the part
/// of it a reader happened to reach first, and report the rest as nothing
/// anybody objected to.
pub fn tree_files_from_bytes(files: &[(PathBuf, Vec<u8>)]) -> Vec<TreeFile> {
    let mut sorted: Vec<&(PathBuf, Vec<u8>)> = files.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    sorted
        .into_iter()
        .map(|(path, bytes)| TreeFile::read(path.clone(), bytes))
        .collect()
}

/// What this observation carries, read as an audit input.
pub fn input_for(item: &ObservedItem) -> AuditInput {
    let location = item.path.display().to_string();
    let content = match item.kind {
        ItemKind::Skill => read_tree(&item.path),
        ItemKind::Agent | ItemKind::Command | ItemKind::PiExtension => read_document(&item.path),
        ItemKind::Hook => read_hook(&item.path),
        ItemKind::McpServer => read_mcp(&item.path, &item.name),
        ItemKind::Plugin => read_plugin(&item.path),
    };
    AuditInput {
        kind: item.kind,
        name: item.name.clone(),
        harness: Some(item.harness),
        location,
        content,
    }
}

/// What decides an observation's score, and so which observations are one
/// reading.
///
/// One skill installed for two harnesses is two observations of the same
/// directory, and a scope with eighty of them would spend most of an audit
/// scoring each tree twice. No rule reads the harness — every one of them
/// judges the bytes — so the key is everything that decides the outcome:
/// kind, path and name. Two observations that agree here score the same by
/// construction, never by guess.
pub fn same_reading(item: &ObservedItem) -> (ItemKind, PathBuf, String) {
    (item.kind, item.path.clone(), item.name.clone())
}

/// One observation's two hashes and what the rules made of it. The hashes
/// answer different questions: `content` names the reduced input the
/// findings came from, `review` names the complete bytes a decision binds
/// to.
#[derive(Clone)]
pub struct Scored {
    pub content: String,
    pub review: Option<String>,
    pub result: AuditResult,
}

/// Read what this observation points at and score it. Pure over the bytes
/// on disk, so it can run on any thread and in any order.
pub fn score(
    item: &ObservedItem,
    hash: impl Fn(&AuditInput) -> String,
    review: impl Fn(&ObservedItem) -> Option<String>,
) -> Scored {
    let input = input_for(item);
    Scored {
        content: hash(&input),
        review: review(item),
        result: super::audit(input),
    }
}

const UNREADABLE_FILE: &str = "the installed file could not be read from disk";
const NOT_A_TREE: &str = "the installed skill is not a directory on disk";
const TREE_TOO_BIG: &str =
    "the installed tree is larger than kendex reads into memory, so none of it was scored";

/// Decoded the same way a plan's own bytes are: lossily, so one byte that
/// is not text cannot make a whole file invisible to every rule. What had to
/// be replaced is reported by `undecodable-content`.
fn read_document(path: &Path) -> Content {
    match std::fs::read(path) {
        Ok(bytes) => Content::Document {
            text: String::from_utf8_lossy(&bytes).into_owned(),
        },
        Err(_) => Content::Unread {
            why: UNREADABLE_FILE,
        },
    }
}

fn read_hook(path: &Path) -> Content {
    let Content::Document { text } = read_document(path) else {
        return Content::Unread {
            why: UNREADABLE_FILE,
        };
    };
    Content::Hook {
        event: String::new(),
        matcher: None,
        command: path.display().to_string(),
        script: Some(text),
    }
}

/// The server entry a harness would launch, dug back out of the config file
/// that holds it.
///
/// The scan reaches this file to learn the server's *name*; reading it again
/// for the command line is what lets the MCP rules run at all. Every layout
/// kendex writes nests the servers under one key and each server under its
/// own name, so the same walk covers JSON, JSONC and TOML. Where the entry
/// cannot be found the input says so and the rules report themselves not
/// applicable, which is the honest answer and never a pass.
fn read_mcp(path: &Path, name: &str) -> Content {
    match mcp_entry(path, name) {
        Some(value) => Content::Mcp(McpEntry::from_json(&value)),
        None => Content::Unread {
            why: UNREAD_MCP_ENTRY,
        },
    }
}

/// The server entry itself, before anything reduces it. Every layout kendex
/// writes nests the servers under one key and each server under its own
/// name, so the same walk covers JSON, JSONC and TOML.
pub fn mcp_entry(path: &Path, name: &str) -> Option<serde_json::Value> {
    const NESTS: &[&str] = &["mcpServers", "mcp_servers", "servers", "mcp"];
    let root = config_json(path)?;
    NESTS
        .iter()
        .filter_map(|nest| root.get(nest))
        .find_map(|table| table.get(name))
        .cloned()
}

/// A config file as JSON, whichever of the two syntaxes it is written in.
pub fn config_json(path: &Path) -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(path).ok()?;
    match path.extension().and_then(|e| e.to_str()) {
        Some("toml") => toml::from_str::<serde_json::Value>(&text).ok(),
        _ => serde_json::from_str(&crate::scan::jsonc::to_json(&text)).ok(),
    }
}

fn read_tree(root: &Path) -> Content {
    if !root.is_dir() {
        return Content::Unread { why: NOT_A_TREE };
    }
    let mut files = Vec::new();
    let mut total = 0;
    if !walk(root, root, &mut files, &mut total) {
        return Content::Unread { why: TREE_TOO_BIG };
    }
    files.sort_by(|a: &TreeFile, b: &TreeFile| a.path.cmp(&b.path));
    Content::SkillTree { files }
}

/// Depth-first and never through a symlink: the canonical tree is the one
/// kendex wrote, and following a link out of it would audit somebody else's
/// files under this item's name.
///
/// `false` where the tree is past what any reader of a skill's bytes holds
/// in memory — the same bound the sealed catalog walk refuses at, so the
/// gate and this audit stop at one place. A tree past it has no reading at
/// all rather than a truncated one, because every rule then reports itself
/// not applicable instead of finding nothing in a tail it never saw.
fn walk(root: &Path, dir: &Path, files: &mut Vec<TreeFile>, total: &mut u64) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return true;
    };
    let mut paths: Vec<std::path::PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
    paths.sort();
    for path in paths {
        if path.is_symlink() {
            continue;
        }
        if path.is_dir() {
            if !walk(root, &path, files, total) {
                return false;
            }
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        *total += bytes.len() as u64;
        if files.len() >= crate::source_read::MAX_TREE_FILES
            || *total > crate::source_read::MAX_TREE_BYTES
        {
            return false;
        }
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        files.push(TreeFile::read(relative.to_path_buf(), &bytes));
    }
    true
}

/// A plugin directory, when the observation points at one. The scanner
/// reads plugins out of registries and settings files, so most of the time
/// the path is a config file and the plugin's own sources are elsewhere.
fn read_plugin(path: &Path) -> Content {
    let root = match path.is_dir() {
        true => path,
        false => {
            return Content::Unread {
                why: UNREADABLE_PLUGIN,
            };
        }
    };
    const MANIFESTS: &[&str] = &[
        "plugin.json",
        "package.json",
        ".cursor-plugin/plugin.json",
        ".codex-plugin/plugin.json",
    ];
    let manifests: Vec<String> = MANIFESTS
        .iter()
        .filter(|name| root.join(name).is_file())
        .map(|name| (*name).to_owned())
        .collect();
    let Content::SkillTree { files } = read_tree(root) else {
        return Content::Unread {
            why: UNREADABLE_PLUGIN,
        };
    };
    Content::Plugin(PluginSources {
        package_json: std::fs::read_to_string(root.join("package.json")).ok(),
        git_origin: root
            .join(".git")
            .exists()
            .then(|| root.display().to_string()),
        scripts: files
            .into_iter()
            .filter(|file| is_source(&file.path))
            .collect(),
        manifests,
    })
}

fn is_source(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("js" | "ts" | "mjs" | "cjs" | "py" | "sh" | "bash")
    )
}

#[cfg(test)]
mod tests;
