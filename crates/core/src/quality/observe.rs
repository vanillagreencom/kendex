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

use crate::model::{FileState, HarnessId, ItemKind, ObservedItem};
use crate::source_read::{TREE_BOUND, TreeBound};

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
///
/// The memory bound is asked here too, because rendering can make a tree
/// larger than the catalog's own copy: a body past a tool's cap is split
/// into `references/`, one file more than the publisher wrote. A tree that
/// crosses the bound only once rendered has to read as unread everywhere,
/// or the surfaces that never walk a directory score a package the audit
/// over the install of it cannot read at all.
pub fn tree_content_from_bytes(files: &[(PathBuf, Vec<u8>)]) -> Content {
    let total: u64 = files.iter().map(|(_, bytes)| bytes.len() as u64).sum();
    if TREE_BOUND.past(files.len(), total) {
        return Content::Unread { why: TREE_TOO_BIG };
    }
    let mut sorted: Vec<&(PathBuf, Vec<u8>)> = files.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    Content::SkillTree {
        files: sorted
            .into_iter()
            .map(|(path, bytes)| TreeFile::read(path.clone(), bytes))
            .collect(),
    }
}

/// What this observation carries, read as an audit input.
pub fn input_for(item: &ObservedItem) -> AuditInput {
    let location = item.path.display().to_string();
    let content = match item.kind {
        ItemKind::Skill => read_tree(&item.path),
        ItemKind::Agent | ItemKind::Command | ItemKind::PiExtension => read_document(&item.path),
        ItemKind::Hook => read_hook(item),
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
/// A package bigger than kendex can hold. Nothing on the reader's machine
/// changes that, so the size is what they are told.
const TREE_TOO_BIG: &str =
    "this skill's tree is larger than kendex reads into memory, so none of it was scored";
/// A package kendex was not allowed to open all of — a permission, not a
/// size, and a different thing to do about it. Kept apart from the reason
/// above for exactly that: one is the package's nature, the other is
/// something the reader can fix.
const TREE_UNREADABLE: &str =
    "part of this skill's tree could not be read from disk, so none of it was scored";

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

/// A hook found inside a shared config file whose registration is not in
/// the file any more.
const UNREAD_HOOK_ENTRY: &str =
    "this hook's registration was not found in the config file that was scanned for it";
/// A registry file that would not parse holds no entry to dig out.
const HOOK_REGISTRY_UNPARSED: &str = "the config file holding this hook's registration could not be parsed, so none of it was scored";

/// A hook, read as the rules should see it.
///
/// A hook that is its own file — opencode's instruction carrier — is the
/// file, and all of it is scored. A hook observed inside a shared config
/// file is scored on its own registration: the command text of every entry
/// the file holds under this observation's name, and nothing beside it.
/// Sibling entries and the `permissions.ask`/`permissions.deny` lists are
/// not this hook's content — an ask-list entry is a guard *against* a
/// dangerous command, and reading the whole file as every hook's script
/// turned one `mkfs` guard into a high-severity finding on all fifteen
/// hooks registered in the same settings.json (KEN-558). The file is
/// parsed by the reader the scan chose for its harness and matched by the
/// same name construction the scan listed it under, so the entry the scan
/// found is the entry scored here.
fn read_hook(item: &ObservedItem) -> Content {
    let Content::Document { text } = read_document(&item.path) else {
        return Content::Unread {
            why: UNREADABLE_FILE,
        };
    };
    if item.file_state != FileState::ConfigEntry {
        return Content::Hook {
            event: String::new(),
            matcher: None,
            command: item.path.display().to_string(),
            script: Some(text),
        };
    }
    let parsed = match item.harness {
        HarnessId::Copilot => crate::scan::copilot::registrations_text(&text),
        _ => crate::scan::hooks::registrations_text(&text),
    };
    let Ok(mut registrations) = parsed else {
        return Content::Unread {
            why: HOOK_REGISTRY_UNPARSED,
        };
    };
    registrations.retain(|reg| reg.name() == item.name);
    let Some(first) = registrations.first() else {
        return Content::Unread {
            why: UNREAD_HOOK_ENTRY,
        };
    };
    // Names collide only when event, matcher and command stem all agree,
    // so the one observation the scan lists stands for every registration
    // under that name, and every one of them is scored.
    Content::Hook {
        event: first.event.clone(),
        matcher: Some(first.matcher.clone()).filter(|m| m != crate::scan::hooks::ANY_MATCHER),
        command: registrations
            .iter()
            .map(|reg| reg.command.as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        script: None,
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
    match tree_files(root, TREE_BOUND) {
        Ok(files) => Content::SkillTree { files },
        Err(why) => Content::Unread { why },
    }
}

/// Every file under an installed tree, or the one reason there is no
/// reading of it. `bound` is [`TREE_BOUND`] in every caller — a test drives
/// a small one so the byte half of the bound can be proved without a 64 MB
/// fixture.
fn tree_files(root: &Path, bound: TreeBound) -> Result<Vec<TreeFile>, &'static str> {
    if !root.is_dir() {
        return Err(NOT_A_TREE);
    }
    let mut files = Vec::new();
    let mut total = 0;
    walk(root, Path::new(""), &mut files, &mut total, bound)?;
    files.sort_by(|a: &TreeFile, b: &TreeFile| a.path.cmp(&b.path));
    Ok(files)
}

/// Depth-first and never through a symlink: the canonical tree is the one
/// kendex wrote, and following a link out of it would audit somebody else's
/// files under this item's name.
///
/// Every failure is the whole tree's, because siblings are already
/// collected by the time one arrives. A tree past the memory bound and a
/// tree with a directory or a file this process cannot open both end the
/// read with no reading at all: every rule then reports itself not
/// applicable, instead of finding nothing in a part it never saw. "kendex
/// could not read this" is an answer a person can act on; "clean" over the
/// files that happened to open is not.
fn walk(
    dir: &Path,
    rel: &Path,
    files: &mut Vec<TreeFile>,
    total: &mut u64,
    bound: TreeBound,
) -> Result<(), &'static str> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Err(TREE_UNREADABLE);
    };
    let mut names: Vec<std::ffi::OsString> = Vec::new();
    for entry in entries {
        let Ok(entry) = entry else {
            return Err(TREE_UNREADABLE);
        };
        names.push(entry.file_name());
    }
    names.sort();
    for name in names {
        let path = dir.join(&name);
        let rel = rel.join(&name);
        if path.is_symlink() {
            continue;
        }
        if path.is_dir() {
            walk(&path, &rel, files, total, bound)?;
            continue;
        }
        // The size is taken from the directory entry rather than from what
        // was read, so a file too large to hold is refused before it is
        // held: reading first and measuring after asks for the allocation
        // the bound exists to refuse.
        let Ok(len) = std::fs::metadata(&path).map(|at| at.len()) else {
            return Err(TREE_UNREADABLE);
        };
        *total += len;
        if bound.past(files.len() + 1, *total) {
            return Err(TREE_TOO_BIG);
        }
        let Ok(bytes) = std::fs::read(&path) else {
            return Err(TREE_UNREADABLE);
        };
        files.push(TreeFile::read(rel, &bytes));
    }
    Ok(())
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
    // A tree that could not be read says which way it failed; the plugin's
    // own reason is for a path that is no tree to begin with.
    let files = match tree_files(root, TREE_BOUND) {
        Ok(files) => files,
        Err(why) => return Content::Unread { why },
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
