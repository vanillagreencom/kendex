//! The Linux registration of the `kendex://` scheme, written here rather
//! than by the deep-link plugin. The plugin quotes the executable in the
//! `Exec=` line it writes, and `xdg-open` on a desktop with no opener of
//! its own (Hyprland, sway, whatever its detection calls generic) reads
//! the first word of `Exec=` quotes and all, finds no program by that
//! name, and hands the link to `$BROWSER` instead. A bare path is what
//! every opener runs, so the path is quoted only where the desktop entry
//! specification leaves no choice.

use std::path::{Path, PathBuf};

use tauri::Manager;

use super::SCHEME;

/// The file's name under `applications/`. A fixed name rather than one
/// derived from the binary: the debug build and the installed app are the
/// same handler as far as the desktop is concerned, and the last one
/// launched is the one a link opens.
const HANDLER_FILE: &str = "kendex-url-handler.desktop";

/// The characters the desktop entry specification reserves in an `Exec=`
/// argument. A path holding none of them goes in bare; one holding any is
/// quoted, which the specification requires and `xdg-open` cannot run.
const RESERVED: &[char] = &[
    ' ', '\t', '\n', '"', '\'', '\\', '>', '<', '~', '|', '&', ';', '$', '*', '?', '#', '(', ')',
    '`',
];

/// One `Exec=` argument for `exe`: bare where it can be, quoted with the
/// specification's escapes where it must be. A literal `%` is doubled
/// either way, since a lone one starts a field code.
fn exec_argument(exe: &str) -> String {
    let exe = exe.replace('%', "%%");
    if !exe.contains(RESERVED) {
        return exe;
    }
    let mut quoted = String::from("\"");
    for ch in exe.chars() {
        if matches!(ch, '"' | '`' | '$' | '\\') {
            quoted.push('\\');
        }
        quoted.push(ch);
    }
    quoted.push('"');
    quoted
}

/// The whole file, for `exe`.
fn desktop_entry(exe: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=kendex\nExec={} %u\nTerminal=false\nMimeType=x-scheme-handler/{SCHEME}\nNoDisplay=true\n",
        exec_argument(exe)
    )
}

/// The path a link must launch: the AppImage when running as one, since
/// the binary inside it is unpacked to a mount that is gone by the time a
/// link arrives, and the binary itself otherwise.
fn launch_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    if let Some(appimage) = app.env().appimage {
        return Ok(PathBuf::from(appimage));
    }
    std::env::current_exe().map_err(|error| format!("the app's own path is unknown: {error}"))
}

/// Make this binary the handler for `kendex://` on this desktop. The file
/// is rewritten only when it does not already name this binary, and the
/// desktop is told only then: a person who has since pointed the scheme
/// somewhere else on purpose keeps that choice until the binary moves. A
/// registration the desktop could not be told about leaves no file, so
/// the next launch tries again rather than reading the file as done.
pub fn register(app: &tauri::AppHandle) -> Result<(), String> {
    let exe = launch_path(app)?;
    let exe = exe
        .to_str()
        .ok_or_else(|| format!("the app's path is not UTF-8: {}", exe.display()))?;
    let applications = app
        .path()
        .data_dir()
        .map_err(|error| format!("no data directory: {error}"))?
        .join("applications");
    let file = applications.join(HANDLER_FILE);
    let wanted = desktop_entry(exe);
    if std::fs::read_to_string(&file).is_ok_and(|current| current == wanted) {
        return Ok(());
    }
    std::fs::create_dir_all(&applications)
        .and_then(|()| std::fs::write(&file, wanted))
        .map_err(|error| format!("{} not written: {error}", file.display()))?;
    if let Err(error) = tell_the_desktop(&applications) {
        let _ = std::fs::remove_file(&file);
        return Err(error);
    }
    Ok(())
}

/// The two commands that make a written file the default handler.
fn tell_the_desktop(applications: &Path) -> Result<(), String> {
    let mime = format!("x-scheme-handler/{SCHEME}");
    for hardened in [
        kendex_core::process::Hardened::update_desktop_database(applications),
        kendex_core::process::Hardened::xdg_mime(&["default", HANDLER_FILE, &mime]),
    ] {
        let label = hardened.label().to_string();
        let output = hardened.run().map_err(|error| error.to_string())?;
        if !output.status.success() {
            return Err(format!(
                "{label} failed ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What `xdg-open` runs: the first whitespace-separated word of the
    /// `Exec=` line, taken as a program name. A bare path is that word; a
    /// quoted one is not a program.
    fn first_word_of_exec(entry: &str) -> String {
        entry
            .lines()
            .find_map(|line| line.strip_prefix("Exec="))
            .and_then(|exec| exec.split_whitespace().next())
            .map(str::to_string)
            .unwrap_or_default()
    }

    #[test]
    fn a_plain_path_is_the_program_xdg_open_reads() {
        let entry = desktop_entry("/opt/kendex/kendex-app");
        assert_eq!(first_word_of_exec(&entry), "/opt/kendex/kendex-app");
        assert!(entry.contains("MimeType=x-scheme-handler/kendex\n"));
        assert!(entry.contains("Exec=/opt/kendex/kendex-app %u\n"));
    }

    #[test]
    fn a_path_the_specification_reserves_is_quoted_and_escaped() {
        let cases = [
            ("/home/a b/kendex-app", "\"/home/a b/kendex-app\""),
            ("/home/a$b/kendex-app", "\"/home/a\\$b/kendex-app\""),
            ("/home/a\"b/kendex-app", "\"/home/a\\\"b/kendex-app\""),
            // Doubled, not quoted: a lone `%` starts a field code, and the
            // specification reserves no quoting for it.
            ("/home/a%b/kendex-app", "/home/a%%b/kendex-app"),
        ];
        for (exe, argument) in cases {
            assert_eq!(exec_argument(exe), argument, "{exe}");
        }
    }
}
