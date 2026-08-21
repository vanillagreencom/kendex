//! What a launcher makes of the entry the installer writes. A menu item
//! that runs the wrong thing says nothing about it, so the Exec value is
//! read back here the way a launcher reads it.

use crate::{CURL, ICONS, installer_output, posix_shell, repo_root};

/// The encoder itself, run out of `install.sh` rather than copied here: the
/// function is sliced out of the shipped script and handed one argument, so
/// renaming or moving it fails this instead of quietly testing nothing.
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

/// Field codes come out of every argument before it is run: `%%` stands for
/// a literal percent, and a percent before a letter is a code the launcher
/// fills in or drops. A percent that arrives any other way is not part of a
/// path.
fn without_field_codes(argument: &str) -> Result<String, String> {
    let mut literal = String::new();
    let mut argument = argument.chars();
    while let Some(character) = argument.next() {
        if character != '%' {
            literal.push(character);
            continue;
        }
        match argument.next() {
            Some('%') => literal.push('%'),
            Some(code) => return Err(format!("%{code} is a field code, not part of the path")),
            None => return Err("the argument ends on a percent".to_owned()),
        }
    }
    Ok(literal)
}

/// The arguments a launcher makes of an Exec value, or why it makes none.
/// Three passes, the way the Desktop Entry spec has them: the file's own
/// escapes come off first — `\\` is one backslash, and anything else behind
/// a backslash costs the whole key — then the result is split into
/// arguments, where a double-quoted run is one argument and a backslash
/// inside it stands for the character after it, and finally each argument
/// gives up its field codes.
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
            ' ' | '\t' | '\n' if !quoted => {
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
    arguments.iter().map(|a| without_field_codes(a)).collect()
}

/// Every character the spec reserves, plus the percent that introduces a
/// field code — one case each, because an encoder built from the characters
/// someone thought of is how the same defect arrives twice.
#[test]
fn the_encoder_carries_every_character_the_spec_reserves() {
    let reserved = [
        ("space", ' '),
        ("tab", '\t'),
        ("newline", '\n'),
        ("carriage return", '\r'),
        ("double quote", '"'),
        ("single quote", '\''),
        ("backslash", '\\'),
        ("greater-than", '>'),
        ("less-than", '<'),
        ("tilde", '~'),
        ("vertical bar", '|'),
        ("ampersand", '&'),
        ("semicolon", ';'),
        ("dollar", '$'),
        ("asterisk", '*'),
        ("question mark", '?'),
        ("hash", '#'),
        ("open parenthesis", '('),
        ("close parenthesis", ')'),
        ("backtick", '`'),
        ("percent", '%'),
    ];
    for (name, character) in reserved {
        let path = format!("/home/me/a{character}b/kendex/kendex.AppImage");
        let value = format!("\"{}\"", desktop_arg(&path));
        assert_eq!(
            launcher_arguments(&value),
            Ok(vec![path.clone()]),
            "{name}: Exec={value}"
        );
    }

    // The text on disk, not only the round trip: a writer and a reader that
    // drift together still agree with each other. These are the sequences a
    // launcher was measured against.
    for (path, written) in [
        ("a b", "a b"),
        ("a\\b", "a\\\\\\\\b"),
        ("a$b", "a\\\\$b"),
        ("a`b", "a\\\\`b"),
        ("a\"b", "a\\\\\"b"),
        ("a%b", "a%%b"),
        ("a\tb", "a\\tb"),
        ("a\rb", "a\\rb"),
        ("a\nb", "a\\nb"),
    ] {
        assert_eq!(desktop_arg(path), written, "{path:?}");
    }
}

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
    assert_eq!(
        launcher_arguments(exec),
        Ok(vec![installed.display().to_string()]),
        "Exec={exec}"
    );
    // The reading above is worth only what it refuses. The same path
    // written plainly is what an unquoted Exec holds, and a launcher does
    // not read that back as one path — so this asserts the encoding, not
    // the reader agreeing with itself.
    assert_ne!(
        launcher_arguments(&installed.display().to_string()),
        Ok(vec![installed.display().to_string()]),
        "the directory under test reserves nothing, so nothing is being proved"
    );
}
