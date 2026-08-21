//! What a launcher makes of the entry the installer writes. A menu item
//! that runs the wrong thing says nothing about it, so the Exec value is
//! read back here the way a launcher reads it.

use crate::{CURL, ICONS, installer_output, repo_root};

/// The arguments a launcher makes of an Exec value, or why it makes none.
/// Two passes, the way the Desktop Entry spec has them: the file's own
/// escapes come off first — `\\` is one backslash, and anything else behind
/// a backslash costs the whole key — and only then is the result split into
/// arguments, where a double-quoted run is one argument and a backslash
/// inside it stands for the character after it.
fn launcher_arguments(value: &str) -> Result<Vec<String>, String> {
    let mut unescaped = String::new();
    let mut file = value.chars();
    while let Some(character) = file.next() {
        if character != '\\' {
            unescaped.push(character);
            continue;
        }
        match file.next() {
            Some('\\') => unescaped.push('\\'),
            Some('s') => unescaped.push(' '),
            Some('n') => unescaped.push('\n'),
            Some('t') => unescaped.push('\t'),
            Some('r') => unescaped.push('\r'),
            Some(other) => return Err(format!("a launcher refuses the key over \\{other}")),
            None => return Err("the value ends on a backslash".to_owned()),
        }
    }

    let mut arguments = Vec::new();
    let mut argument = String::new();
    let mut started = false;
    let mut quoted = false;
    let mut value = unescaped.chars();
    while let Some(character) = value.next() {
        match character {
            ' ' | '\t' if !quoted => {
                if started {
                    arguments.push(std::mem::take(&mut argument));
                    started = false;
                }
            }
            '"' => {
                quoted = !quoted;
                started = true;
            }
            '\\' if quoted => match value.next() {
                Some(escaped) => argument.push(escaped),
                None => return Err("a quoted argument ends on a backslash".to_owned()),
            },
            _ => {
                argument.push(character);
                started = true;
            }
        }
    }
    if quoted {
        return Err("the value never closes its quote".to_owned());
    }
    if started {
        arguments.push(argument);
    }
    Ok(arguments)
}

/// A data directory with a space in its name — an external disk, a synced
/// folder — is where this breaks, and it breaks quietly: the install
/// succeeds, and the menu entry then runs the first word of the path and
/// reports nothing to anyone.
#[test]
fn the_entry_names_one_path_when_the_data_directory_has_a_space() {
    let data = "my data";
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

    assert_eq!(
        launcher_arguments(exec),
        Ok(vec![installed.display().to_string()]),
        "Exec={exec}"
    );
    // The reading above is worth only what it refuses. The same path
    // written plainly is what an unquoted Exec holds, and it is several
    // arguments — so this asserts the quoting, not the parser agreeing with
    // itself.
    assert!(
        launcher_arguments(&installed.display().to_string())
            .expect("a plain path has no escapes to refuse")
            .len()
            > 1,
        "the directory under test has no space in it, so nothing is being proved"
    );
}
