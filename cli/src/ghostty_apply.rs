use anyhow::{Context, Result, bail};
use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GhosttyPlatform {
    Linux,
    Macos,
    Other,
}

impl GhosttyPlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::Macos
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Other
        }
    }
}

#[derive(Debug, Clone)]
pub struct GhosttyPathContext {
    pub home_dir: PathBuf,
    pub xdg_config_home: Option<PathBuf>,
    pub platform: GhosttyPlatform,
}

impl GhosttyPathContext {
    fn xdg_config_dir(&self) -> PathBuf {
        self.xdg_config_home
            .clone()
            .unwrap_or_else(|| self.home_dir.join(".config"))
    }
}

pub fn resolve_config_dir(ctx: &GhosttyPathContext) -> PathBuf {
    let xdg_ghostty = ctx.xdg_config_dir().join("ghostty");
    if ctx.platform == GhosttyPlatform::Macos {
        if has_existing_config(&xdg_ghostty) {
            return xdg_ghostty;
        }
        return ctx
            .home_dir
            .join("Library")
            .join("Application Support")
            .join("com.mitchellh.ghostty");
    }
    xdg_ghostty
}

pub fn resolve_config_file(config_dir: &Path) -> PathBuf {
    let config = config_dir.join("config");
    if config.exists() {
        return config;
    }
    let config_ghostty = config_dir.join("config.ghostty");
    if config_ghostty.exists() {
        return config_ghostty;
    }
    config
}

fn has_existing_config(config_dir: &Path) -> bool {
    config_dir.join("config").exists() || config_dir.join("config.ghostty").exists()
}

pub fn managed_block(extra_name: &str, theme_id: &str, shader_file_names: &[String]) -> String {
    let mut lines = vec![
        format!("# vstack:begin {extra_name}"),
        "# Managed by vstack. Edit source extras or remove this block to opt out.".to_string(),
        // Ghostty rejects slash-containing `theme` values unless absolute; `config-file`
        // supports paths relative to the selected config file and validates across live
        // and isolated XDG_CONFIG_HOME smoke tests.
        format!("config-file = themes/vstack/{theme_id}"),
    ];
    for file_name in shader_file_names {
        lines.push(format!("custom-shader = shaders/vstack/{file_name}"));
    }
    if !shader_file_names.is_empty() {
        lines.push("custom-shader-animation = always".to_string());
    }
    lines.push(format!("# vstack:end {extra_name}"));
    lines.join("\n")
}

pub fn insert_or_replace_managed_block(input: &str, extra_name: &str, block: &str) -> String {
    if let Some(range) = find_managed_block_range(input, extra_name) {
        let mut out = String::with_capacity(input.len() + block.len());
        out.push_str(&input[..range.start]);
        out.push_str(block);
        out.push('\n');
        out.push_str(&input[range.end..]);
        return out;
    }

    if input.is_empty() {
        return format!("{block}\n");
    }

    let mut out = input.to_string();
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out.push('\n');
    out.push_str(block);
    out.push('\n');
    out
}

pub fn remove_managed_block(input: &str, extra_name: &str) -> String {
    let Some(range) = find_managed_block_range(input, extra_name) else {
        return input.to_string();
    };
    let mut out = String::with_capacity(input.len().saturating_sub(range.len()));
    out.push_str(&input[..range.start]);
    out.push_str(&input[range.end..]);
    out
}

fn find_managed_block_range(input: &str, extra_name: &str) -> Option<Range<usize>> {
    let begin_marker = format!("# vstack:begin {extra_name}");
    let end_marker = format!("# vstack:end {extra_name}");
    let mut offset = 0usize;
    let mut begin = None;

    for line in input.split_inclusive('\n') {
        let line_without_newline = line.trim_end_matches(['\r', '\n']);
        if line_without_newline == begin_marker {
            begin = Some(offset);
        }
        if begin.is_some() && line_without_newline == end_marker {
            return begin.map(|start| start..offset + line.len());
        }
        offset += line.len();
    }

    None
}

pub fn backup_path(path: &Path, timestamp: &str) -> PathBuf {
    let mut raw = path.as_os_str().to_os_string();
    raw.push(format!(".vstack-backup.{timestamp}"));
    PathBuf::from(raw)
}

pub fn write_backup(config_file: &Path, backup_file: &Path) -> Result<Vec<u8>> {
    let original = if config_file.exists() {
        fs::read(config_file).with_context(|| format!("reading {}", config_file.display()))?
    } else {
        Vec::new()
    };
    if let Some(parent) = backup_file.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(backup_file, &original)
        .with_context(|| format!("writing backup {}", backup_file.display()))?;
    Ok(original)
}

pub fn restore_backup(backup_file: &Path, config_file: &Path) -> Result<()> {
    if let Some(parent) = config_file.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::copy(backup_file, config_file).with_context(|| {
        format!(
            "restoring {} from {}",
            config_file.display(),
            backup_file.display()
        )
    })?;
    Ok(())
}

pub fn validate_managed_block_syntax(input: &str, extra_name: &str) -> Result<()> {
    let range = find_managed_block_range(input, extra_name)
        .ok_or_else(|| anyhow::anyhow!("Ghostty managed block for `{extra_name}` not found"))?;
    let block = &input[range];
    for line in block.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            bail!("Ghostty config line `{line}` is missing `=`");
        };
        if key.trim().is_empty() || value.trim().is_empty() {
            bail!("Ghostty config line `{line}` must have non-empty key and value");
        }
    }
    Ok(())
}

pub fn utc_timestamp_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    utc_timestamp_from_unix_seconds(seconds)
}

pub fn utc_timestamp_from_unix_seconds(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64;
    let seconds_of_day = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}{month:02}{day:02}T{hour:02}{minute:02}{second:02}Z")
}

fn civil_from_days(days_since_unix_epoch: i64) -> (i64, u64, u64) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m as u64, d as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack_ghostty_apply_{label}_{}_{}",
            std::process::id(),
            unique
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn managed_block_insert_into_config_without_prior_block() {
        let block = managed_block(
            "vanillagreen-themes",
            "ghibli-serene-nature",
            &["ghibli-serene-nature-ambient.glsl".to_string()],
        );
        let out =
            insert_or_replace_managed_block("font-size = 14\n", "vanillagreen-themes", &block);

        assert_eq!(
            out,
            "font-size = 14\n\n# vstack:begin vanillagreen-themes\n# Managed by vstack. Edit source extras or remove this block to opt out.\nconfig-file = themes/vstack/ghibli-serene-nature\ncustom-shader = shaders/vstack/ghibli-serene-nature-ambient.glsl\ncustom-shader-animation = always\n# vstack:end vanillagreen-themes\n"
        );
    }

    #[test]
    fn managed_block_replace_existing_block() {
        let old = "font-size = 14\n\n# vstack:begin vanillagreen-themes\ntheme = old\n# vstack:end vanillagreen-themes\nwindow-padding-x = 8\n";
        let block = managed_block("vanillagreen-themes", "new-theme", &[]);
        let out = insert_or_replace_managed_block(old, "vanillagreen-themes", &block);

        assert_eq!(
            out,
            "font-size = 14\n\n# vstack:begin vanillagreen-themes\n# Managed by vstack. Edit source extras or remove this block to opt out.\nconfig-file = themes/vstack/new-theme\n# vstack:end vanillagreen-themes\nwindow-padding-x = 8\n"
        );
    }

    #[test]
    fn managed_block_remove_existing_block() {
        let input = "font-size = 14\n# vstack:begin vanillagreen-themes\ntheme = old\n# vstack:end vanillagreen-themes\nwindow-padding-x = 8\n";
        let out = remove_managed_block(input, "vanillagreen-themes");

        assert_eq!(out, "font-size = 14\nwindow-padding-x = 8\n");
    }

    #[test]
    fn linux_config_dir_uses_xdg_when_set() {
        let root = sandbox("linux_xdg");
        let ctx = GhosttyPathContext {
            home_dir: root.join("home"),
            xdg_config_home: Some(root.join("xdg")),
            platform: GhosttyPlatform::Linux,
        };

        assert_eq!(resolve_config_dir(&ctx), root.join("xdg/ghostty"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn linux_config_dir_uses_home_config_when_xdg_unset() {
        let root = sandbox("linux_home_config");
        let ctx = GhosttyPathContext {
            home_dir: root.join("home"),
            xdg_config_home: None,
            platform: GhosttyPlatform::Linux,
        };

        assert_eq!(resolve_config_dir(&ctx), root.join("home/.config/ghostty"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn macos_config_dir_prefers_library_path() {
        let root = sandbox("macos_library");
        let ctx = GhosttyPathContext {
            home_dir: root.join("home"),
            xdg_config_home: Some(root.join("xdg")),
            platform: GhosttyPlatform::Macos,
        };

        assert_eq!(
            resolve_config_dir(&ctx),
            root.join("home/Library/Application Support/com.mitchellh.ghostty")
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn macos_config_dir_falls_back_to_existing_xdg_config() {
        let root = sandbox("macos_xdg_fallback");
        let xdg_ghostty = root.join("xdg/ghostty");
        fs::create_dir_all(&xdg_ghostty).unwrap();
        fs::write(xdg_ghostty.join("config.ghostty"), "font-size = 14\n").unwrap();
        let ctx = GhosttyPathContext {
            home_dir: root.join("home"),
            xdg_config_home: Some(root.join("xdg")),
            platform: GhosttyPlatform::Macos,
        };

        assert_eq!(resolve_config_dir(&ctx), xdg_ghostty);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn config_file_detection_prefers_config_then_config_ghostty_then_config() {
        let root = sandbox("config_file_order");
        let dir = root.join("ghostty");
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(resolve_config_file(&dir), dir.join("config"));
        fs::write(dir.join("config.ghostty"), "a = b\n").unwrap();
        assert_eq!(resolve_config_file(&dir), dir.join("config.ghostty"));
        fs::write(dir.join("config"), "a = c\n").unwrap();
        assert_eq!(resolve_config_file(&dir), dir.join("config"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn backup_path_format_and_content_match_original_bytes() {
        let root = sandbox("backup_content");
        let config = root.join("ghostty/config");
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        let original = b"font-size = 14\n\x00raw-byte\n";
        fs::write(&config, original).unwrap();
        let backup = backup_path(&config, "20260522T120000Z");

        let captured = write_backup(&config, &backup).unwrap();

        assert_eq!(
            backup,
            root.join("ghostty/config.vstack-backup.20260522T120000Z")
        );
        assert_eq!(captured, original);
        assert_eq!(fs::read(backup).unwrap(), original);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn utc_timestamp_has_expected_format() {
        assert_eq!(utc_timestamp_from_unix_seconds(0), "19700101T000000Z");
        assert_eq!(
            utc_timestamp_from_unix_seconds(1_700_000_000),
            "20231114T221320Z"
        );
    }
}
