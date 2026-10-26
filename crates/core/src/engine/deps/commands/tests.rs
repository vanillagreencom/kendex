use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn declarations_keep_the_publisher_fields_and_reject_invalid_rows() {
    let valid = crate::frontmatter::parse_tolerant("dependencies:\n  commands:\n    - command: tool\n      purpose: Read accounts\n      floor: '1.2'\n      packages: {brew: tool-cli, npm: tool}\n    - command: extra\n      purpose: Read credentials\n      optional: true\n").unwrap();
    let commands = declared(&valid.map).unwrap();
    assert_eq!(
        commands,
        vec![
            CommandDependency {
                command: "tool".into(),
                purpose: "Read accounts".into(),
                optional: false,
                floor: Some("1.2".into()),
                packages: BTreeMap::from([
                    ("brew".into(), "tool-cli".into()),
                    ("npm".into(), "tool".into())
                ])
            },
            CommandDependency {
                command: "extra".into(),
                purpose: "Read credentials".into(),
                optional: true,
                floor: None,
                packages: BTreeMap::new()
            },
        ]
    );
    // Each malformed publisher input is a must-fail control for its field.
    for (row, field, index) in [
        ("commands: tool", "commands", 0),
        ("commands: [tool]", "row", 1),
        ("commands: [{purpose: Read accounts}]", "command", 1),
        ("commands: [{command: tool}]", "purpose", 1),
        (
            "commands: [{command: '', purpose: Read accounts}]",
            "command",
            1,
        ),
        ("commands: [{command: tool, purpose: ''}]", "purpose", 1),
        (
            "commands: [{command: /bin/tool, purpose: Read accounts}]",
            "command",
            1,
        ),
        (
            "commands: [{command: 'tool arg', purpose: Read accounts}]",
            "command",
            1,
        ),
        (
            "commands: [{command: tool, purpose: Read accounts, optional: yes}]",
            "optional",
            1,
        ),
        (
            "commands: [{command: tool, purpose: Read accounts, floor: newest}]",
            "floor",
            1,
        ),
        (
            "commands: [{command: tool, purpose: Read accounts, packages: [tool]}]",
            "packages",
            1,
        ),
        (
            "commands: [{command: tool, purpose: Read accounts, packages: {brew: []}}]",
            "packages",
            1,
        ),
    ] {
        let parsed =
            crate::frontmatter::parse_tolerant(&format!("dependencies:\n  {row}\n")).unwrap();
        assert_eq!(
            declared(&parsed.map),
            Err(DeclarationProblem { row: index, field })
        );
    }
    for text in [
        "name: tool\n",
        "dependencies: {required: [shared]}\n",
        "dependencies: {commands: []}\n",
    ] {
        assert_eq!(
            declared(&crate::frontmatter::parse_tolerant(text).unwrap().map),
            Ok(Vec::new())
        );
    }
}

#[test]
fn version_floors_compare_numbers_and_keep_unreadable_answers_as_notices() {
    for (floor, output, expected) in [
        (
            "1.2",
            "tool 1.1.9",
            Some(CommandProblem::BelowFloor {
                found: "1.1.9".into(),
            }),
        ),
        ("1.2", "v1.2.0", None),
        ("1.2.0", "tool 1.10.0", None),
        ("20", "tool 20.1.0", None),
        ("137.0.7151.118", "Chromium 137.0.7151.119", None),
        (
            "137.0.7151.120",
            "Chromium 137.0.7151.119",
            Some(CommandProblem::BelowFloor {
                found: "137.0.7151.119".into(),
            }),
        ),
        ("1.2.0.0", "tool 1.2", None),
        (
            "1.2.0",
            "1.2.0-beta.1",
            Some(CommandProblem::BelowFloor {
                found: "1.2.0-beta.1".into(),
            }),
        ),
        ("1.2.0+publisher", "1.2.0+host", None),
        (
            "4",
            "GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin)\nCopyright (C) 2007 Free Software Foundation",
            Some(CommandProblem::VersionUnreadable),
        ),
        (
            "5.30",
            "\nThis is perl 5, version 34, subversion 1 (v5.34.1)",
            None,
        ),
        (
            "5.40",
            "\n\nThis is perl 5, version 38, subversion 2 (v5.38.2)\nCopyright 2023",
            Some(CommandProblem::BelowFloor {
                found: "5.38.2".into(),
            }),
        ),
        (
            "2",
            "tool 1.2.3, build 2022",
            Some(CommandProblem::BelowFloor {
                found: "1.2.3".into(),
            }),
        ),
        (
            "2",
            "tool version unreadable\nCopyright 2022\nreference 9.0.0",
            Some(CommandProblem::VersionUnreadable),
        ),
        ("2", "tool 2022", Some(CommandProblem::VersionUnreadable)),
        (
            "1.2.0",
            "version unavailable",
            Some(CommandProblem::VersionUnreadable),
        ),
    ] {
        let problem = judge_version(floor, reported_version(output));
        assert_eq!(problem, expected);
        if let Some(problem) = problem {
            for optional in [false, true] {
                let issue = CommandIssue {
                    dependency: CommandDependency {
                        command: "tool".into(),
                        purpose: "Read accounts".into(),
                        optional,
                        floor: Some(floor.into()),
                        packages: BTreeMap::new(),
                    },
                    problem: match &problem {
                        CommandProblem::Missing => CommandProblem::Missing,
                        CommandProblem::BelowFloor { found } => CommandProblem::BelowFloor {
                            found: found.clone(),
                        },
                        CommandProblem::VersionUnreadable => CommandProblem::VersionUnreadable,
                    },
                };
                assert_eq!(
                    issue.is_notice(),
                    optional || matches!(problem, CommandProblem::VersionUnreadable)
                );
            }
        }
    }
}

#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn path_lookup_requires_an_executable_and_accepts_windows_suffixes() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let first = root.join("first");
    let second = root.join("second");
    std::fs::create_dir_all(&first).unwrap();
    std::fs::create_dir_all(&second).unwrap();
    std::fs::write(first.join("tool"), "data").unwrap();
    std::fs::write(second.join("tool"), "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(second.join("tool"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::join_paths([&first, &second]).unwrap();
    assert_eq!(
        command_path("tool", &path, false, ""),
        Some(second.join("tool"))
    );
    assert_eq!(command_path("absent", &path, false, ""), None);
    std::fs::rename(second.join("tool"), second.join("tool.EXE")).unwrap();
    assert_eq!(command_path("tool", &path, false, ""), None);
    assert_eq!(
        command_path("tool", &path, true, ".COM;.EXE"),
        Some(second.join("tool.EXE"))
    );
}

/// A toolchain proxy answers for the name it was invoked by: rustup's
/// `cargo` is a link to `rustup`, which prints its own version when run
/// as itself. The probe runs the command at the path the search path
/// spells, so the proxy sees `cargo` and reports cargo's version.
#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn the_version_probe_runs_a_proxied_command_under_its_own_name() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(
        bin.join("proxy"),
        "#!/bin/sh\ncase \"$0\" in *cargo) echo 'cargo 9.9';; *) echo 'proxy 1.0';; esac\n",
    )
    .unwrap();
    std::fs::set_permissions(bin.join("proxy"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::os::unix::fs::symlink("proxy", bin.join("cargo")).unwrap();
    let path = std::env::join_paths([&bin]).unwrap();
    let declared = |floor: &str| CommandDependency {
        command: "cargo".into(),
        purpose: "Build the runtime".into(),
        optional: false,
        floor: Some(floor.into()),
        packages: BTreeMap::new(),
    };
    assert_eq!(check_on(&[declared("9.0")], None, &path, false, ""), []);
    assert_eq!(
        check_on(&[declared("10")], None, &path, false, ""),
        [CommandIssue {
            dependency: declared("10"),
            problem: CommandProblem::BelowFloor {
                found: "9.9.0".into()
            },
        }]
    );
}
