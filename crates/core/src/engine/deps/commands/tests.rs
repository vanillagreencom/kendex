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
