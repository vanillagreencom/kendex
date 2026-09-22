use std::fs;

use super::is_executable;

/// A directory and an absent path are never commands, on every platform.
/// This is the guard a command search leans on hardest: a directory named
/// `kendex` in a writable place answers yes to being present, and a search
/// that read presence would settle on it and hand a release binary to
/// whatever writes over it. `crates/core/src/command_update/` is that
/// search, and this is where the answer comes from.
#[test]
#[allow(clippy::unwrap_used)]
fn neither_a_directory_nor_an_absent_path_is_a_command() {
    let tmp = tempfile::tempdir().unwrap();
    let directory = tmp.path().join("kendex");
    fs::create_dir(&directory).unwrap();
    assert!(!is_executable(&directory), "a directory named kendex");

    assert!(
        !is_executable(&tmp.path().join("absent")),
        "nothing at the path"
    );

    // The row that proves the two above are answering about what is there
    // rather than saying no to everything.
    let command = tmp.path().join("real");
    fs::write(&command, "#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(&command, fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert!(is_executable(&command), "a file a shell would run");
}

/// One row per mode a regular file can carry: the mode, and whether a shell
/// would run it. Any of the three execute bits is enough, since the answer
/// cannot know which of user, group or other this process is; none of them
/// is a data file, which is what a downloaded release or a config sitting
/// under a command's name looks like. Unix only: the fallback has no mode to
/// read and answers on being a regular file alone.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_regular_file_is_a_command_only_with_an_execute_bit() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let rows: [(u32, bool); 6] = [
        (0o755, true),
        (0o700, true),
        (0o010, true),
        (0o001, true),
        (0o644, false),
        (0o000, false),
    ];
    for (mode, expected) in rows {
        let path = tmp.path().join(format!("mode-{mode:o}"));
        fs::write(&path, "data").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(is_executable(&path), expected, "mode {mode:o}");
    }
}
