//! Thin wrappers over OS-native pickers and file browsers. Neither plugin's
//! own IPC commands are exposed to the frontend — these wrap the plugins'
//! Rust APIs behind kendex's own typed commands instead, the same way
//! `window.rs` wraps the frameless titlebar's OS calls.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use kendex_core::fs::is_executable;
use tauri_plugin_dialog::DialogExt;

/// Native folder picker. Blocking, so this must not run on the main thread
/// — an async command already runs off it, which is what the plugin's own
/// docs call for.
#[tauri::command]
#[specta::specta]
pub async fn pick_folder(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let picked = app.dialog().file().blocking_pick_folder();
    let Some(path) = picked else {
        return Ok(None);
    };
    path.into_path()
        .map(|p| Some(p.display().to_string()))
        .map_err(|e| e.to_string())
}

/// Shows `path` in the system file browser. Only ever reveals a path that
/// is actually there — the plain-word error is the fix, not a stack trace
/// from the OS call that would have failed instead.
#[tauri::command(async)]
#[specta::specta]
pub fn reveal_path(path: String) -> Result<(), String> {
    if !Path::new(&path).exists() {
        return Err(format!("{path} does not exist"));
    }
    tauri_plugin_opener::reveal_item_in_dir(&path).map_err(|e| e.to_string())
}

/// Opens a web page in the person's browser. https only — the one thing
/// this is for is kendex.ai and GitHub pages, and a file: or custom-scheme
/// URL through the system opener is an execution vector, not a page.
/// Plain http is allowed only when the host is exactly the local machine:
/// a prefix check would wave through `http://localhost.evil.example`.
#[tauri::command(async)]
#[specta::specta]
pub fn open_url(url: String) -> Result<(), String> {
    if !openable(&url) {
        return Err("only web pages can be opened".to_owned());
    }
    tauri_plugin_opener::open_url(&url, None::<String>).map_err(|e| e.to_string())
}

fn openable(url: &str) -> bool {
    if url.starts_with("https://") {
        return true;
    }
    let Some(rest) = url.strip_prefix("http://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    // Credentials in the authority relocate the real host past the `@`.
    if authority.contains('@') {
        return false;
    }
    let host = authority.split(':').next().unwrap_or_default();
    matches!(host, "localhost" | "127.0.0.1" | "[::1]")
}

#[cfg(test)]
mod url_tests {
    use super::openable;

    #[test]
    fn only_https_or_the_local_machine_opens() {
        assert!(openable("https://kendex.ai/submit"));
        assert!(openable("http://localhost:5173/x"));
        assert!(openable("http://127.0.0.1:8080/"));
        assert!(!openable("http://localhost.evil.example/"));
        assert!(!openable("http://localhost@evil.example/"));
        assert!(!openable("file:///etc/passwd"));
        assert!(!openable("javascript:alert(1)"));
        assert!(!openable("http://evil.example/"));
    }
}

/// Editors kendex looks for, in preference order, after `KENDEX_EDITOR`.
const EDITOR_CANDIDATES: [&str; 5] = ["codium", "code", "cursor", "zed", "subl"];

/// Ordered list of editor names or paths to try: the `KENDEX_EDITOR`
/// override first when set, then the built-in candidates.
fn editor_candidates(editor_override: Option<&str>) -> Vec<&str> {
    editor_override
        .into_iter()
        .chain(EDITOR_CANDIDATES)
        .collect()
}

/// The file names a bare command may resolve to: the name itself, and on
/// Windows the name under each `PATHEXT` extension — `code` is installed
/// as `code.cmd`, and a lookup by the bare name alone finds nothing.
fn spellings(candidate: &str, pathext: Option<&str>) -> Vec<String> {
    let mut names = vec![candidate.to_owned()];
    names.extend(
        pathext
            .unwrap_or_default()
            .split(';')
            .filter(|ext| !ext.is_empty())
            .map(|ext| format!("{candidate}{}", ext.to_ascii_lowercase())),
    );
    names
}

fn pathext() -> Option<String> {
    cfg!(windows)
        .then(|| std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned()))
}

/// Resolves the first candidate that exists and is executable. A candidate
/// given as an absolute path is checked directly; a bare name is walked
/// across `path_var` the way a shell resolves PATH, so tests can fabricate
/// both instead of touching the real environment.
fn resolve_editor_at(path_var: &str, editor_override: Option<&str>) -> Option<PathBuf> {
    for candidate in editor_candidates(editor_override) {
        let candidate_path = Path::new(candidate);
        if candidate_path.is_absolute() {
            if is_executable(candidate_path) {
                return Some(candidate_path.to_path_buf());
            }
            continue;
        }
        for dir in std::env::split_paths(path_var) {
            for name in spellings(candidate, pathext().as_deref()) {
                let full = dir.join(name);
                if is_executable(&full) {
                    return Some(full);
                }
            }
        }
    }
    None
}

/// Opens `path` (file or directory — every candidate editor accepts both)
/// in the user's code editor. Not routed through `process::Hardened`: that
/// constructor hardens tool invocations core makes with captured output
/// and a timeout, but this is an app-shell concern with a different shape
/// — no shell, nothing to capture, and no timeout, because the editor is
/// the user's own long-lived GUI app and is meant to outlive us.
#[tauri::command(async)]
#[specta::specta]
pub fn open_in_editor(path: String) -> Result<(), String> {
    if !Path::new(&path).exists() {
        return Err(format!("{path} does not exist"));
    }
    let path_var = std::env::var("PATH").unwrap_or_default();
    let editor_override = std::env::var("KENDEX_EDITOR").ok();
    let editor = resolve_editor_at(&path_var, editor_override.as_deref()).ok_or_else(|| {
        "No code editor found — install one (VSCodium, VS Code, Cursor, Zed, Sublime) or set KENDEX_EDITOR".to_string()
    })?;
    Command::new(editor)
        .arg(&path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_child| ())
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn write_executable(dir: &Path, name: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    fn write_non_executable(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, "not a program").unwrap();
        path
    }

    /// Which editor a `PATH` resolves to: the first candidate of the
    /// built-in list that is executable there, or the override when one is
    /// named, whether by name on that `PATH` or by an absolute path. One row
    /// per shape of directory and override; `Named` is what the row expects
    /// back, by the name it was written under.
    #[cfg(unix)]
    #[test]
    fn the_editor_is_the_first_executable_candidate_or_the_override() {
        enum Override {
            None,
            Name(&'static str),
            AbsolutePathOf(&'static str),
        }
        type Row<'a> = (
            &'a str,
            &'a [&'a str],
            &'a [&'a str],
            Override,
            Option<&'a str>,
        );
        let rows: [Row; 5] = [
            (
                "the first candidate present and executable wins",
                &["code"],
                &["codium"],
                Override::None,
                Some("code"),
            ),
            (
                "a candidate that is not executable is skipped",
                &[],
                &["codium", "code"],
                Override::None,
                None,
            ),
            (
                "an override by name wins over the built-in list",
                &["code", "hx"],
                &[],
                Override::Name("hx"),
                Some("hx"),
            ),
            (
                "an override by absolute path needs no PATH",
                &["hx"],
                &[],
                Override::AbsolutePathOf("hx"),
                Some("hx"),
            ),
            (
                "no candidate on the PATH is none",
                &[],
                &[],
                Override::None,
                None,
            ),
        ];
        for (what, executables, non_executables, override_, expected) in rows {
            let tmp = tempfile::tempdir().unwrap();
            let mut written = std::collections::BTreeMap::new();
            for name in executables {
                written.insert(*name, write_executable(tmp.path(), name));
            }
            for name in non_executables {
                write_non_executable(tmp.path(), name);
            }
            let on_path = tmp.path().to_str().unwrap().to_owned();
            let (path_var, override_) = match override_ {
                Override::None => (on_path, None),
                Override::Name(name) => (on_path, Some(name.to_owned())),
                Override::AbsolutePathOf(name) => (
                    String::new(),
                    Some(written[name].to_str().unwrap().to_owned()),
                ),
            };
            assert_eq!(
                resolve_editor_at(&path_var, override_.as_deref()),
                expected.map(|name| written[name].clone()),
                "{what}"
            );
        }
    }

    #[test]
    fn windows_spellings_carry_each_pathext_extension() {
        assert_eq!(
            spellings("code", Some(".COM;.EXE;;.CMD")),
            ["code", "code.com", "code.exe", "code.cmd"]
        );
        assert_eq!(spellings("code", None), ["code"]);
    }
}
