//! What the installer writes into a menu item's Exec value. A menu item
//! that runs the wrong thing says nothing about it, so the encoding is
//! held to the bytes the Desktop Entry spec calls for, character by
//! character, rather than to a reader of the grammar written here.

use crate::{CURL, ICONS, installer_output, posix_shell, repo_root};

/// The encoder itself, run out of `install.sh` rather than copied here: the
/// function is sliced out of the shipped script and handed one argument, so
/// renaming or moving it fails this instead of quietly testing nothing.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn desktop_arg(path: &str) -> String {
    let script = std::fs::read_to_string(repo_root().join("install.sh")).expect("install.sh");
    let body = script
        .split_once("\ndesktop_arg() {\n")
        .and_then(|(_, rest)| rest.split_once("\n}\n"))
        .map(|(body, _)| body.to_owned())
        .expect("install.sh defines desktop_arg");
    let run = std::process::Command::new(posix_shell())
        .arg("-c")
        .arg(format!("desktop_arg() {{\n{body}\n}}\ndesktop_arg \"$1\""))
        .arg("sh")
        .arg(path)
        .output()
        .expect("the encoder runs");
    assert!(
        run.status.success(),
        "desktop_arg failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    String::from_utf8(run.stdout).expect("the encoder answers in utf-8")
}

/// Every character the spec reserves, plus the percent that introduces a
/// field code — one case each, because an encoder built from the characters
/// someone thought of is how the same defect arrives twice.
///
/// Held to the bytes on disk rather than to a round trip through a reader
/// written here. A reader is the Desktop Entry grammar spelled a second
/// time, and a writer and a reader that drift together still agree with
/// each other; these spellings come off the spec, so drifting away from
/// them is what fails.
///
/// The value goes inside double quotes, so the three passes a launcher
/// makes decide each row. The file's own escaping doubles a backslash and
/// spells the whitespace characters `\t`, `\r` and `\n`. Inside the quotes
/// only `"`, `` ` ``, `$` and `\` need a backslash of their own, and that
/// backslash is itself doubled by the file escaping. A percent introduces a
/// field code and is written `%%`. Every other reserved character is
/// carried by the quotes alone and appears as itself.
#[test]
fn the_encoder_carries_every_character_the_spec_reserves() {
    for (name, character, encoded) in RESERVED {
        let path = format!("/home/me/a{character}b/kendex/kendex.AppImage");
        assert_eq!(
            desktop_arg(&path),
            format!("/home/me/a{encoded}b/kendex/kendex.AppImage"),
            "{name}"
        );
    }
}

/// Each character a Desktop Entry value reserves, and what the encoder has
/// to write it as inside the quotes.
const RESERVED: [(&str, char, &str); 21] = [
    ("space", ' ', " "),
    ("tab", '\t', "\\t"),
    ("newline", '\n', "\\n"),
    ("carriage return", '\r', "\\r"),
    ("double quote", '"', "\\\\\""),
    ("single quote", '\'', "'"),
    ("backslash", '\\', "\\\\\\\\"),
    ("greater-than", '>', ">"),
    ("less-than", '<', "<"),
    ("tilde", '~', "~"),
    ("vertical bar", '|', "|"),
    ("ampersand", '&', "&"),
    ("semicolon", ';', ";"),
    ("dollar", '$', "\\\\$"),
    ("asterisk", '*', "*"),
    ("question mark", '?', "?"),
    ("hash", '#', "#"),
    ("open parenthesis", '(', "("),
    ("close parenthesis", ')', ")"),
    ("backtick", '`', "\\\\`"),
    ("percent", '%', "%%"),
];

/// A data directory that reserves characters — a percent in a folder name,
/// a space, the punctuation people put in one — is where this breaks, and
/// it breaks quietly: the install succeeds, and the menu entry then runs
/// some truncated path and reports nothing to anyone.
#[test]
fn the_entry_names_one_path_when_the_data_directory_is_awkward() {
    let data = "my data 100% & $x (y) 'z'";
    let (tmp, output) = installer_output(&repo_root(), CURL, data, |_| {});
    assert!(
        output.status.success(),
        "install.sh failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let installed = tmp.path().join(data).join("kendex/kendex.AppImage");
    assert!(installed.is_file(), "{}", installed.display());
    // The icon slots are built out of the same directory and handed to a
    // function as an argument, and the shell the published command really
    // runs splits an unquoted assignment where bash does not — so a space
    // there loses the icons rather than the app, and the entry draws blank.
    for (size, _) in ICONS {
        let slot = tmp
            .path()
            .join(data)
            .join(format!("icons/hicolor/{size}/apps/kendex.png"));
        assert!(slot.is_file(), "{}", slot.display());
    }

    let entry = std::fs::read_to_string(tmp.path().join(data).join("applications/kendex.desktop"))
        .expect("desktop entry");
    let exec = entry
        .lines()
        .find_map(|line| line.strip_prefix("Exec="))
        .expect("the entry has an Exec key");
    let plain = installed.display().to_string();
    assert_eq!(
        exec,
        format!("\"{}\"", desktop_arg(&plain)),
        "the entry does not carry the encoding the installer built"
    );
    // Worth only what it refuses. A data directory reserving nothing would
    // encode to itself, and the line above would pass on an installer that
    // wrote the path plainly.
    assert_ne!(
        desktop_arg(&plain),
        plain,
        "the directory under test reserves nothing, so nothing is being proved"
    );
}
