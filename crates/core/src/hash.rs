use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind};

/// Deeper than any rendered tree goes; a link that loops back into its own
/// tree hits this instead of the stack limit.
const MAX_DEPTH: usize = 32;

/// SHA-256 over a file's bytes, or over a directory tree as sorted
/// relative-path + content pairs. Symlinks hash their resolved content.
/// Anything that is neither file nor directory (a pipe, a device) is an
/// error, not a read that never returns — the caller reports it uncompared.
pub fn hash_tree(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hash_into(&mut hasher, path, Path::new(""), 0)?;
    Ok(hex(&hasher.finalize()))
}

fn hash_into(hasher: &mut Sha256, path: &Path, rel: &Path, depth: usize) -> Result<()> {
    let refuse = |why: &str| CoreError::io(path, std::io::Error::other(why.to_owned()));
    if depth > MAX_DEPTH {
        return Err(refuse(
            "nested too deep — a link pointing back into its own tree?",
        ));
    }
    let meta = fs::metadata(path).map_err(|e| CoreError::io(path, e))?;
    if meta.is_dir() {
        let mut entries: Vec<_> = fs::read_dir(path)
            .map_err(|e| CoreError::io(path, e))?
            .flatten()
            .map(|e| e.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            hash_into(hasher, &entry, &rel.join(name), depth + 1)?;
        }
    } else if meta.is_file() {
        let bytes = fs::read(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(&bytes);
        hasher.update([0]);
    } else {
        return Err(refuse("not a regular file or directory"));
    }
    Ok(())
}

/// SHA-256 over a tree as it sits, never following a link: a plain file
/// by relative path and bytes, a link by relative path and target,
/// dangling or not, a directory by relative path before its entries, so
/// an empty one added or removed is a change. What a directory move
/// binds to — a rename carries
/// the entries themselves, a dangling link included, so the precondition
/// names exactly those and never the bytes a link points at. The byte
/// after the path says which kind wrote the record, so a file whose
/// bytes spell a target never hashes like a link to it. Anything else (a
/// pipe, a socket, a device) is an error naming the entry, as in
/// `hash_tree`: the journal snapshots a moved directory by copying it,
/// and a copy of a reader-less pipe never returns.
pub fn hash_tree_as_is(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hash_as_is_into(&mut hasher, path, Path::new(""))?;
    Ok(hex(&hasher.finalize()))
}

fn hash_as_is_into(hasher: &mut Sha256, path: &Path, rel: &Path) -> Result<()> {
    let refuse = |why: &str| CoreError::io(path, std::io::Error::other(why.to_owned()));
    let kind = fs::symlink_metadata(path)
        .map_err(|e| CoreError::io(path, e))?
        .file_type();
    if kind.is_symlink() {
        let target = fs::read_link(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([1]);
        hasher.update(target.to_string_lossy().as_bytes());
        hasher.update([0]);
    } else if kind.is_dir() {
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([2]);
        hasher.update([0]);
        let mut entries: Vec<_> = fs::read_dir(path)
            .map_err(|e| CoreError::io(path, e))?
            .flatten()
            .map(|e| e.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            hash_as_is_into(hasher, &entry, &rel.join(name))?;
        }
    } else if kind.is_file() {
        let bytes = fs::read(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(&bytes);
        hasher.update([0]);
    } else {
        return Err(refuse("not a regular file, directory or link"));
    }
    Ok(())
}

/// The hash a single-file artifact will have once written — mirrors
/// `hash_tree` applied to a lone file.
pub fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"");
    hasher.update([0]);
    hasher.update(bytes);
    hasher.update([0]);
    hex(&hasher.finalize())
}

/// The hash an in-memory rendered tree will have once written — mirrors
/// `hash_tree` so plans can compare desired vs. disk without materializing.
pub fn hash_files(files: &[(std::path::PathBuf, Vec<u8>)]) -> String {
    let mut sorted: Vec<_> = files.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut hasher = Sha256::new();
    for (rel, bytes) in sorted {
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(bytes);
        hasher.update([0]);
    }
    hex(&hasher.finalize())
}

/// The full installation hash: source bytes plus the manifest sections that
/// shape this artifact (invariant 3) — editing a shared key invalidates
/// dependents because the serialized sections change. Source bytes come
/// through the sealed reader: a symlinked catalog must not feed host bytes
/// into an installation hash.
pub fn installation_hash(
    sealed: &crate::source_read::SealedSource,
    source_tree: &Path,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(sealed.hash_tree(source_tree)?.as_bytes());
    hasher.update(relevant_sections(manifest, kind, name, harness).as_bytes());
    Ok(hex(&hasher.finalize()))
}

/// Deterministic serialization of every manifest value that shapes the
/// rendered artifact, shared `all`/`*` keys included.
pub fn relevant_sections(
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> String {
    let mut out = String::new();
    let mut push = |section: &str, key: &str, value: &str| {
        let _ = writeln!(out, "{section}.{key}={value}");
    };
    let shared_keys = [name, "all", "*"];
    match kind {
        ItemKind::Skill => {
            for key in shared_keys {
                if let Some(text) = manifest.skill_instructions.get(key) {
                    push("skill-instructions", key, text);
                }
            }
        }
        ItemKind::Agent => {
            if let Some(skills) = manifest.agent_skills.get(name) {
                push("agent-skills", name, &skills.join(","));
            }
            for key in shared_keys {
                if let Some(text) = manifest.agent_launch_instructions.get(key) {
                    push("agent-launch-instructions", key, text);
                }
                if let Some(text) = manifest.agent_additional_instructions.get(key) {
                    push("agent-additional-instructions", key, text);
                }
            }
            if let Some(overrides) = manifest
                .agent_frontmatter
                .get(harness.name())
                .and_then(|by_agent| by_agent.get(name))
            {
                push(
                    "agent-frontmatter",
                    name,
                    &toml::to_string(overrides).unwrap_or_default(),
                );
            }
            for (index, hook) in manifest.custom_hooks.iter().enumerate() {
                push(
                    "custom-hooks",
                    &index.to_string(),
                    &format!(
                        "{}:{}:{}",
                        hook.event,
                        hook.matcher.as_deref().unwrap_or(""),
                        hook.command
                    ),
                );
            }
        }
        _ => {}
    }
    out
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// 64-bit FNV-1a as a 16-hex-digit string — the one implementation behind
/// the scope-lock keys, the repo cache keys, and the settings-seed ledger.
/// v1 used the same constants, which is what lets imported ledgers verify.
pub fn fnv1a_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::MANIFEST_SCHEMA;

    #[cfg(unix)]
    #[test]
    fn a_link_looping_into_its_own_tree_is_an_error_not_a_crash() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("skill");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("SKILL.md"), "hello").unwrap();
        std::os::unix::fs::symlink(&root, root.join("loop")).unwrap();
        assert!(hash_tree(&root).is_err());
    }

    /// The as-is hash names the entries a move carries: a dangling link
    /// is one of them, by its target, where the content hash has nothing
    /// to read and refuses the tree.
    #[cfg(unix)]
    #[test]
    fn as_is_hash_names_a_link_by_its_target_and_never_follows_it() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("dir");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a"), "bytes").unwrap();
        std::os::unix::fs::symlink("nowhere", root.join("gone")).unwrap();
        assert!(hash_tree(&root).is_err());

        let dangling = hash_tree_as_is(&root).unwrap();
        std::fs::remove_file(root.join("gone")).unwrap();
        std::os::unix::fs::symlink("a", root.join("gone")).unwrap();
        let resolving = hash_tree_as_is(&root).unwrap();
        assert_ne!(dangling, resolving, "the target is part of the record");

        std::fs::remove_file(root.join("gone")).unwrap();
        std::fs::write(root.join("gone"), "a").unwrap();
        let file = hash_tree_as_is(&root).unwrap();
        assert_ne!(
            resolving, file,
            "a file spelling the target is not the link"
        );

        std::fs::create_dir(root.join("empty")).unwrap();
        let with_dir = hash_tree_as_is(&root).unwrap();
        assert_ne!(
            file, with_dir,
            "an empty directory is an entry the move carries"
        );
    }

    #[test]
    fn tree_hash_is_content_and_layout_sensitive() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a");
        std::fs::create_dir_all(a.join("sub")).unwrap();
        std::fs::write(a.join("SKILL.md"), "hello").unwrap();
        std::fs::write(a.join("sub/x.sh"), "x").unwrap();
        let first = hash_tree(&a).unwrap();
        assert_eq!(first, hash_tree(&a).unwrap());

        std::fs::write(a.join("sub/x.sh"), "y").unwrap();
        assert_ne!(first, hash_tree(&a).unwrap());
    }

    #[test]
    fn editing_a_shared_key_invalidates_dependents() {
        let tmp = tempfile::tempdir().unwrap();
        let skill = tmp.path().join("skill");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "content").unwrap();

        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        let sealed = crate::source_read::SealedSource::open(tmp.path()).unwrap();
        let skill = sealed.root().join("skill");
        let before = installation_hash(
            &sealed,
            &skill,
            &manifest,
            ItemKind::Skill,
            "github",
            HarnessId::Claude,
        )
        .unwrap();

        manifest
            .skill_instructions
            .insert("all".into(), "shared instruction".into());
        let after = installation_hash(
            &sealed,
            &skill,
            &manifest,
            ItemKind::Skill,
            "github",
            HarnessId::Claude,
        )
        .unwrap();
        assert_ne!(before, after);

        let unrelated = installation_hash(
            &sealed,
            &skill,
            &manifest,
            ItemKind::Command,
            "github",
            HarnessId::Claude,
        )
        .unwrap();
        let unrelated_before = {
            let clean = Manifest {
                schema: MANIFEST_SCHEMA,
                ..Manifest::default()
            };
            installation_hash(
                &sealed,
                &skill,
                &clean,
                ItemKind::Command,
                "github",
                HarnessId::Claude,
            )
            .unwrap()
        };
        assert_eq!(unrelated, unrelated_before);
    }
}
