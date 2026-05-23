use anyhow::{Context, Result, bail};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

pub const COLOR_THEME_KEY: &str = "workbench.colorTheme";

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

pub fn settings_path_for_os(
    editor: VscodeEditor,
    home_dir: &Path,
    config_dir: &Path,
    host_os: HostOs,
) -> PathBuf {
    user_dir_for_os(editor, home_dir, config_dir, host_os).join("settings.json")
}

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

    if has_comment_outside_string(text) {
        bail!(
            "settings.json appears to be JSONC with comments; vstack will not rewrite it because comment preservation is not implemented"
        );
    }

    let parsed: Value = serde_json::from_str(text).context(
        "settings.json must be valid JSON; JSONC/trailing commas are not rewritten to avoid destructive formatting loss",
    )?;
    let object = parsed
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("settings.json root must be a JSON object"))?;

    let replacement = serde_json::to_string(theme_name)?;
    if let Some((start, end)) = find_top_level_key_value_span(text, COLOR_THEME_KEY)? {
        if text[start..end].trim() == replacement {
            return Ok(text.to_string());
        }
        let mut patched = text.to_string();
        patched.replace_range(start..end, &replacement);
        return Ok(patched);
    }

    insert_color_theme_key(text, object.is_empty(), &replacement)
}

fn insert_color_theme_key(text: &str, object_is_empty: bool, replacement: &str) -> Result<String> {
    let (open, close) = root_object_bounds(text)?;
    let newline = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let closing_indent = line_indent_at(text, close);
    let key_indent = first_property_indent(text).unwrap_or_else(|| format!("{closing_indent}  "));
    let quoted_key = serde_json::to_string(COLOR_THEME_KEY)?;

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
    patched.push(',');
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

fn has_comment_outside_string(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut index = 0usize;
    let mut in_string = false;
    let mut escape = false;
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            if escape {
                escape = false;
            } else if byte == b'\\' {
                escape = true;
            } else if byte == b'"' {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if byte == b'"' {
            in_string = true;
            index += 1;
            continue;
        }
        if byte == b'/' && index + 1 < bytes.len() {
            let next = bytes[index + 1];
            if next == b'/' || next == b'*' {
                return true;
            }
        }
        index += 1;
    }
    false
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

fn skip_ws(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && is_json_ws(bytes[index]) {
        index += 1;
    }
    index
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
    fn settings_patcher_changes_only_workbench_color_theme_value() {
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
        let actual: Value = serde_json::from_str(&patched).unwrap();

        assert_eq!(actual, expected);
        assert!(patched.contains("\"workbench.colorTheme\": \"Ghibli Serene Nature\""));
        assert!(patched.contains("\"editor.fontFamily\": \"JetBrains Mono\""));
        assert!(patched.contains("\"terminal.integrated.fontFamily\": \"CommitMono\""));
        assert!(patched.contains("\"nested\": { \"keep\": true }"));
        assert!(patched.contains("\"array\": [1, 2, 3]"));
        assert!(!patched.contains("Old Theme"));
    }

    #[test]
    fn settings_patcher_inserts_color_theme_when_missing() {
        let input = r#"{
  "editor.fontFamily": "JetBrains Mono"
}
"#;

        let patched = patch_settings_text(input, "Forest").unwrap();
        let parsed: Value = serde_json::from_str(&patched).unwrap();

        assert_eq!(parsed["editor.fontFamily"], "JetBrains Mono");
        assert_eq!(parsed[COLOR_THEME_KEY], "Forest");
        assert!(patched.contains("\"editor.fontFamily\": \"JetBrains Mono\","));
    }

    #[test]
    fn settings_patcher_on_jsonc_comments_fails_without_writing() {
        let root = sandbox("jsonc");
        let settings = root.join("settings.json");
        let original = r#"{
  // keep this comment
  "editor.fontFamily": "JetBrains Mono"
}
"#;
        fs::write(&settings, original).unwrap();

        let err = patch_settings_file(&settings, "Forest").unwrap_err();
        let msg = format!("{err:#}");

        assert!(msg.contains("JSONC with comments"), "{msg}");
        assert_eq!(fs::read_to_string(&settings).unwrap(), original);
        let _ = fs::remove_dir_all(root);
    }
}
