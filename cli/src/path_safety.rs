use anyhow::{Context, Result, bail};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) fn validate_item_name(name: &str) -> Result<()> {
    if name.is_empty() {
        bail!("item name must not be empty");
    }
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        bail!("item name must not be empty");
    };
    if !first.is_ascii_alphanumeric() {
        bail!("item name {name:?} must start with an ASCII letter or digit");
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        bail!("item name {name:?} must contain only ASCII letters, digits, '.', '_', or '-'");
    }
    if name.eq_ignore_ascii_case(crate::project_config::SHARED_INSTRUCTIONS_KEY) {
        bail!(
            "item name {name:?} is reserved: `all` is the shared key in \
             [agent-launch-instructions], [agent-additional-instructions], and \
             [skill-instructions] that applies to every agent/skill"
        );
    }
    Ok(())
}

/// Write a generated file without following a symlink in the final path
/// component. Existing symlinks are rejected; normal files are replaced via a
/// same-directory temporary file and rename.
pub(crate) fn write_file_no_follow(path: &Path, contents: impl AsRef<[u8]>) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating parent directory {}", parent.display()))?;
    }
    ensure_file_write_target_safe(path)?;

    let tmp = temp_sibling_path(path)?;
    let write_result = (|| -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .with_context(|| format!("creating temporary file {}", tmp.display()))?;
        file.write_all(contents.as_ref())
            .with_context(|| format!("writing temporary file {}", tmp.display()))?;
        file.sync_all()
            .with_context(|| format!("syncing temporary file {}", tmp.display()))?;
        std::fs::rename(&tmp, path)
            .with_context(|| format!("renaming {} to {}", tmp.display(), path.display()))?;
        Ok(())
    })();

    if write_result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    write_result
}

pub(crate) fn ensure_file_write_target_safe(path: &Path) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            bail!("refusing to write through symlink: {}", path.display());
        }
        if meta.is_dir() {
            bail!("refusing to overwrite directory: {}", path.display());
        }
    }
    Ok(())
}

fn temp_sibling_path(path: &Path) -> Result<PathBuf> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow::anyhow!("path has no valid file name: {}", path.display()))?;
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(parent.join(format!(".{file_name}.{}.{}.tmp", std::process::id(), nanos)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_item_name_rejects_path_like_names() {
        for name in [
            "",
            ".",
            "-bad",
            "_bad",
            "../x",
            "a/b",
            "a\\b",
            "bad name",
            "has\nnewline",
            "bad`touch pwn`",
        ] {
            assert!(validate_item_name(name).is_err(), "accepted {name:?}");
        }
        assert!(validate_item_name("guard-hook").is_ok());
        assert!(validate_item_name("guard.hook_1").is_ok());
    }

    #[test]
    fn validate_item_name_rejects_reserved_shared_instruction_key() {
        for name in ["all", "All", "ALL"] {
            let err = validate_item_name(name).unwrap_err();
            assert!(
                err.to_string().contains("reserved"),
                "expected reserved-name error for {name:?}, got: {err}"
            );
        }
        // Names merely containing "all" stay valid.
        assert!(validate_item_name("allow").is_ok());
        assert!(validate_item_name("all-agents").is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn write_file_no_follow_rejects_final_symlink() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack-safe-write-symlink-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let outside = root.join("outside.txt");
        let link = root.join("link.txt");
        std::fs::write(&outside, "keep").unwrap();
        symlink(&outside, &link).unwrap();

        let err = write_file_no_follow(&link, "replace").unwrap_err();
        assert!(
            err.to_string()
                .contains("refusing to write through symlink")
        );
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep");

        let _ = std::fs::remove_dir_all(&root);
    }
}
