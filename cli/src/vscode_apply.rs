#[cfg(test)]
use anyhow::Context;
use anyhow::{Result, bail};
#[cfg(test)]
use std::fs;
use std::path::{Path, PathBuf};

pub const COLOR_THEME_KEY: &str = "workbench.colorTheme";
pub const ICON_THEME_KEY: &str = "workbench.iconTheme";
pub const DEFAULT_ICON_THEME_ID: &str = "rose-pine-icons";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VscodeEditor {
    Vscode,
    Vscodium,
    Cursor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostOs {
    Linux,
    Macos,
}

impl VscodeEditor {
    fn app_dir(self) -> &'static str {
        match self {
            Self::Vscode => "Code",
            Self::Vscodium => "VSCodium",
            Self::Cursor => "Cursor",
        }
    }
}

pub fn current_host_os() -> HostOs {
    if cfg!(target_os = "macos") {
        HostOs::Macos
    } else {
        HostOs::Linux
    }
}

pub fn user_dir_for_os(
    editor: VscodeEditor,
    home_dir: &Path,
    config_dir: &Path,
    host_os: HostOs,
) -> PathBuf {
    match host_os {
        HostOs::Linux => config_dir.join(editor.app_dir()).join("User"),
        HostOs::Macos => home_dir
            .join("Library")
            .join("Application Support")
            .join(editor.app_dir())
            .join("User"),
    }
}

pub fn user_dir_for_current_os(
    editor: VscodeEditor,
    home_dir: &Path,
    config_dir: &Path,
) -> PathBuf {
    user_dir_for_os(editor, home_dir, config_dir, current_host_os())
}

#[cfg(test)]
pub fn settings_path_for_os(
    editor: VscodeEditor,
    home_dir: &Path,
    config_dir: &Path,
    host_os: HostOs,
) -> PathBuf {
    user_dir_for_os(editor, home_dir, config_dir, host_os).join("settings.json")
}

#[cfg(test)]
pub fn patch_settings_file(path: &Path, theme_name: &str) -> Result<bool> {
    let original = if path.exists() {
        fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?
    } else {
        "{}\n".to_string()
    };
    let patched = patch_settings_text(&original, theme_name)
        .with_context(|| format!("patching {}", path.display()))?;
    if patched == original && path.exists() {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, patched).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

pub fn patch_settings_text(original: &str, theme_name: &str) -> Result<String> {
    let text = if original.trim().is_empty() {
        "{}\n"
    } else {
        original
    };

    // VS Code-family settings.json is JSONC in practice. Preserve comments,
    // trailing commas, and user formatting by doing targeted top-level edits
    // instead of serde round-tripping.
    root_object_bounds(text)?;

    let patched = upsert_top_level_string_key(text, COLOR_THEME_KEY, theme_name)?;
    upsert_top_level_string_key(&patched, ICON_THEME_KEY, DEFAULT_ICON_THEME_ID)
}

fn upsert_top_level_string_key(text: &str, key: &str, value: &str) -> Result<String> {
    let replacement = serde_json::to_string(value)?;
    if let Some((start, end)) = find_top_level_key_value_span(text, key)? {
        if text[start..end].trim() == replacement {
            return Ok(text.to_string());
        }
        let mut patched = text.to_string();
        patched.replace_range(start..end, &replacement);
        return Ok(patched);
    }

    insert_top_level_string_key(text, key, &replacement)
}

fn insert_top_level_string_key(text: &str, key: &str, replacement: &str) -> Result<String> {
    let (open, close) = root_object_bounds(text)?;
    let newline = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let closing_indent = line_indent_at(text, close);
    let object_is_empty = root_object_is_empty(text)?;
    let key_indent = first_property_indent(text).unwrap_or_else(|| format!("{closing_indent}  "));
    let quoted_key = serde_json::to_string(key)?;

    if object_is_empty {
        let mut patched = String::new();
        patched.push_str(&text[..open + 1]);
        patched.push_str(newline);
        patched.push_str(&key_indent);
        patched.push_str(&quoted_key);
        patched.push_str(": ");
        patched.push_str(replacement);
        patched.push_str(newline);
        patched.push_str(&closing_indent);
        patched.push_str(&text[close..]);
        return Ok(patched);
    }

    let mut insert_pos = close;
    while insert_pos > open + 1 && is_json_ws(text.as_bytes()[insert_pos - 1]) {
        insert_pos -= 1;
    }

    let mut patched = String::new();
    patched.push_str(&text[..insert_pos]);
    let has_trailing_comma = insert_pos > open + 1 && text.as_bytes()[insert_pos - 1] == b',';
    if !has_trailing_comma {
        patched.push(',');
    }
    patched.push_str(newline);
    patched.push_str(&key_indent);
    patched.push_str(&quoted_key);
    patched.push_str(": ");
    patched.push_str(replacement);
    patched.push_str(newline);
    patched.push_str(&closing_indent);
    patched.push_str(&text[close..]);
    Ok(patched)
}

fn find_top_level_key_value_span(text: &str, key: &str) -> Result<Option<(usize, usize)>> {
    let bytes = text.as_bytes();
    let mut index = skip_ws(bytes, 0);
    if index >= bytes.len() || bytes[index] != b'{' {
        bail!("settings.json root must be a JSON object");
    }
    index += 1;

    loop {
        index = skip_ws(bytes, index);
        if index >= bytes.len() {
            bail!("unexpected end while scanning settings.json object");
        }
        if bytes[index] == b'}' {
            return Ok(None);
        }
        if bytes[index] != b'"' {
            bail!("expected JSON object key while scanning settings.json");
        }

        let key_end = string_span_end(text, index)?;
        let decoded_key: String = serde_json::from_str(&text[index..key_end])?;
        index = skip_ws(bytes, key_end);
        if index >= bytes.len() || bytes[index] != b':' {
            bail!("expected ':' after JSON object key while scanning settings.json");
        }
        index += 1;
        let value_start = skip_ws(bytes, index);
        let value_end = json_value_end(text, value_start)?;
        if decoded_key == key {
            return Ok(Some((value_start, value_end)));
        }

        index = skip_ws(bytes, value_end);
        if index >= bytes.len() {
            bail!("unexpected end after JSON object value while scanning settings.json");
        }
        match bytes[index] {
            b',' => index += 1,
            b'}' => return Ok(None),
            _ => bail!("expected ',' or '}}' after JSON object value while scanning settings.json"),
        }
    }
}

fn json_value_end(text: &str, start: usize) -> Result<usize> {
    let bytes = text.as_bytes();
    let mut index = start;
    let mut depth = 0usize;

    while index < bytes.len() {
        match bytes[index] {
            b'"' => index = string_span_end(text, index)?,
            b'/' if index + 1 < bytes.len() && bytes[index + 1] == b'/' => {
                index += 2;
                while index < bytes.len() && !matches!(bytes[index], b'\n' | b'\r') {
                    index += 1;
                }
            }
            b'/' if index + 1 < bytes.len() && bytes[index + 1] == b'*' => {
                index += 2;
                while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/')
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
            }
            b'{' | b'[' => {
                depth += 1;
                index += 1;
            }
            b'}' if depth == 0 => return Ok(trim_json_ws_end(bytes, start, index)),
            b',' if depth == 0 => return Ok(trim_json_ws_end(bytes, start, index)),
            b'}' | b']' => {
                if depth == 0 {
                    bail!("unexpected closing delimiter while scanning JSON value");
                }
                depth -= 1;
                index += 1;
            }
            _ => index += 1,
        }
    }

    bail!("unexpected end while scanning JSON value")
}

fn root_object_bounds(text: &str) -> Result<(usize, usize)> {
    let bytes = text.as_bytes();
    let open = skip_ws(bytes, 0);
    if open >= bytes.len() || bytes[open] != b'{' {
        bail!("settings.json root must be a JSON object");
    }

    let mut index = open;
    let mut depth = 0usize;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => index = string_span_end(text, index)?,
            b'/' if index + 1 < bytes.len() && bytes[index + 1] == b'/' => {
                index += 2;
                while index < bytes.len() && !matches!(bytes[index], b'\n' | b'\r') {
                    index += 1;
                }
            }
            b'/' if index + 1 < bytes.len() && bytes[index + 1] == b'*' => {
                index += 2;
                while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/')
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
            }
            b'{' => {
                depth += 1;
                index += 1;
            }
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    let tail = skip_ws(bytes, index + 1);
                    if tail != bytes.len() {
                        bail!("settings.json has non-whitespace content after root object");
                    }
                    return Ok((open, index));
                }
                index += 1;
            }
            _ => index += 1,
        }
    }

    bail!("settings.json root object is not closed")
}

fn first_property_indent(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut index = skip_ws(bytes, 0);
    if index >= bytes.len() || bytes[index] != b'{' {
        return None;
    }
    index = skip_ws(bytes, index + 1);
    if index >= bytes.len() || bytes[index] != b'"' {
        return None;
    }
    let line_start = text[..index].rfind('\n').map(|pos| pos + 1)?;
    if text[line_start..index]
        .bytes()
        .all(|byte| matches!(byte, b' ' | b'\t'))
    {
        Some(text[line_start..index].to_string())
    } else {
        None
    }
}

fn line_indent_at(text: &str, index: usize) -> String {
    let line_start = text[..index].rfind('\n').map(|pos| pos + 1).unwrap_or(0);
    let mut end = line_start;
    let bytes = text.as_bytes();
    while end < index && matches!(bytes[end], b' ' | b'\t') {
        end += 1;
    }
    text[line_start..end].to_string()
}

fn string_span_end(text: &str, start: usize) -> Result<usize> {
    let bytes = text.as_bytes();
    if start >= bytes.len() || bytes[start] != b'"' {
        bail!("expected JSON string");
    }
    let mut index = start + 1;
    let mut escape = false;
    while index < bytes.len() {
        let byte = bytes[index];
        if escape {
            escape = false;
        } else if byte == b'\\' {
            escape = true;
        } else if byte == b'"' {
            return Ok(index + 1);
        }
        index += 1;
    }
    bail!("unterminated JSON string")
}

fn root_object_is_empty(text: &str) -> Result<bool> {
    let bytes = text.as_bytes();
    let (open, _) = root_object_bounds(text)?;
    let index = skip_ws(bytes, open + 1);
    Ok(index < bytes.len() && bytes[index] == b'}')
}

fn skip_ws(bytes: &[u8], mut index: usize) -> usize {
    loop {
        while index < bytes.len() && is_json_ws(bytes[index]) {
            index += 1;
        }
        if index + 1 < bytes.len() && bytes[index] == b'/' && bytes[index + 1] == b'/' {
            index += 2;
            while index < bytes.len() && !matches!(bytes[index], b'\n' | b'\r') {
                index += 1;
            }
            continue;
        }
        if index + 1 < bytes.len() && bytes[index] == b'/' && bytes[index + 1] == b'*' {
            index += 2;
            while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/') {
                index += 1;
            }
            index = (index + 2).min(bytes.len());
            continue;
        }
        return index;
    }
}

fn trim_json_ws_end(bytes: &[u8], start: usize, mut end: usize) -> usize {
    while end > start && is_json_ws(bytes[end - 1]) {
        end -= 1;
    }
    end
}

fn is_json_ws(byte: u8) -> bool {
    matches!(byte, b' ' | b'\n' | b'\r' | b'\t')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack_vscode_apply_{label}_{}_{}",
            std::process::id(),
            unique
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn settings_path_resolver_returns_linux_paths() {
        let home = Path::new("/home/alice");
        let config = Path::new("/home/alice/.config");

        assert_eq!(
            settings_path_for_os(VscodeEditor::Vscode, home, config, HostOs::Linux),
            PathBuf::from("/home/alice/.config/Code/User/settings.json")
        );
        assert_eq!(
            settings_path_for_os(VscodeEditor::Vscodium, home, config, HostOs::Linux),
            PathBuf::from("/home/alice/.config/VSCodium/User/settings.json")
        );
        assert_eq!(
            settings_path_for_os(VscodeEditor::Cursor, home, config, HostOs::Linux),
            PathBuf::from("/home/alice/.config/Cursor/User/settings.json")
        );
    }

    #[test]
    fn settings_path_resolver_returns_macos_paths() {
        let home = Path::new("/Users/alice");
        let config = Path::new("/Users/alice/.config");

        assert_eq!(
            settings_path_for_os(VscodeEditor::Vscode, home, config, HostOs::Macos),
            PathBuf::from("/Users/alice/Library/Application Support/Code/User/settings.json")
        );
        assert_eq!(
            settings_path_for_os(VscodeEditor::Vscodium, home, config, HostOs::Macos),
            PathBuf::from("/Users/alice/Library/Application Support/VSCodium/User/settings.json")
        );
        assert_eq!(
            settings_path_for_os(VscodeEditor::Cursor, home, config, HostOs::Macos),
            PathBuf::from("/Users/alice/Library/Application Support/Cursor/User/settings.json")
        );
    }

    #[test]
    fn settings_patcher_changes_color_theme_and_icon_theme_values() {
        let input = r#"{
  "editor.fontFamily": "JetBrains Mono",
  "workbench.colorTheme": "Old Theme",
  "terminal.integrated.fontFamily": "CommitMono",
  "nested": { "keep": true },
  "array": [1, 2, 3]
}
"#;

        let patched = patch_settings_text(input, "Ghibli Serene Nature").unwrap();
        let mut expected: Value = serde_json::from_str(input).unwrap();
        expected[COLOR_THEME_KEY] = Value::String("Ghibli Serene Nature".to_string());
        expected[ICON_THEME_KEY] = Value::String(DEFAULT_ICON_THEME_ID.to_string());
        let actual: Value = serde_json::from_str(&patched).unwrap();

        assert_eq!(actual, expected);
        assert!(patched.contains("\"workbench.colorTheme\": \"Ghibli Serene Nature\""));
        assert!(patched.contains("\"workbench.iconTheme\": \"rose-pine-icons\""));
        assert!(patched.contains("\"editor.fontFamily\": \"JetBrains Mono\""));
        assert!(patched.contains("\"terminal.integrated.fontFamily\": \"CommitMono\""));
        assert!(patched.contains("\"nested\": { \"keep\": true }"));
        assert!(patched.contains("\"array\": [1, 2, 3]"));
        assert!(!patched.contains("Old Theme"));
    }

    #[test]
    fn settings_patcher_inserts_color_theme_and_icon_theme_when_missing() {
        let input = r#"{
  "editor.fontFamily": "JetBrains Mono"
}
"#;

        let patched = patch_settings_text(input, "Forest").unwrap();
        let parsed: Value = serde_json::from_str(&patched).unwrap();

        assert_eq!(parsed["editor.fontFamily"], "JetBrains Mono");
        assert_eq!(parsed[COLOR_THEME_KEY], "Forest");
        assert_eq!(parsed[ICON_THEME_KEY], DEFAULT_ICON_THEME_ID);
        assert!(patched.contains("\"editor.fontFamily\": \"JetBrains Mono\","));
    }

    #[test]
    fn settings_patcher_replaces_existing_color_and_icon_theme() {
        let input = r#"{
  // editor theme
  "workbench.colorTheme": "Old Theme",
  "workbench.iconTheme": "old-icons",
}
"#;

        let patched = patch_settings_text(input, "Forest").unwrap();

        assert!(patched.contains("// editor theme"));
        assert!(patched.contains("\"workbench.colorTheme\": \"Forest\""));
        assert!(patched.contains("\"workbench.iconTheme\": \"rose-pine-icons\""));
        assert!(!patched.contains("Old Theme"));
        assert!(!patched.contains("old-icons"));
    }

    #[test]
    fn settings_patcher_preserves_jsonc_comments_while_writing() {
        let root = sandbox("jsonc");
        let settings = root.join("settings.json");
        let original = r#"{
  // keep this comment
  "editor.fontFamily": "JetBrains Mono",
}
"#;
        fs::write(&settings, original).unwrap();

        let changed = patch_settings_file(&settings, "Forest").unwrap();
        let patched = fs::read_to_string(&settings).unwrap();

        assert!(changed);
        assert!(patched.contains("// keep this comment"));
        assert!(patched.contains("\"workbench.colorTheme\": \"Forest\""));
        assert!(patched.contains("\"workbench.iconTheme\": \"rose-pine-icons\""));
        assert!(patched.contains("\"editor.fontFamily\": \"JetBrains Mono\","));
        let _ = fs::remove_dir_all(root);
    }
}
