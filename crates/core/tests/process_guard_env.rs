//! What the two delegated-script constructors do with git's environment.
//!
//! `guard_hook` is the one child this crate launches that must NOT be
//! scrubbed. It is a git hook body: `git commit` exports `GIT_INDEX_FILE`
//! naming the temporary index of the commit being made, and a chain that
//! could not see it would judge the wrong snapshot and pass a commit nobody
//! checked.
//!
//! `package_script` is its opposite and runs a package's management scripts
//! — arming, disarming, reporting. Those run git themselves against the
//! repository they were pointed at, and an inherited redirect outranks that
//! on the command line: it would write hooks into one repository while
//! reporting about another. The two are pinned side by side, because the
//! only thing separating them is which constructor a call site picked.
use kendex_core::process::Hardened;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use crate::test_util;
use test_util::rooted;

#[cfg(unix)]
const INNER: &str = "KENDEX_TEST_GUARD_ENV_INNER";
#[cfg(unix)]
const INNER_PROOF: &str = "KENDEX_TEST_GUARD_ENV_PROOF";

/// The redirect has to come from the parent's environment. The outer run
/// re-enters this test binary with the variables set and judges the inner
/// run before writing and executing the verdict fixture.
#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn guard_hook_preserves_hook_env_and_relays_verdict() {
    if std::env::var_os(INNER).is_some() {
        // The inner run only proves anything if the redirect is really set
        // on this side of the spawn.
        assert!(std::env::var_os("GIT_INDEX_FILE").is_some());

        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let script = root.join("pre-commit");
        std::fs::write(&script, "#!/bin/sh\nenv > env.log\n").unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let output = Hardened::guard_hook(&script, Vec::new(), &root)
            .run()
            .unwrap();
        assert!(output.status.success());
        let env = std::fs::read_to_string(root.join("env.log")).unwrap();
        for variable in [
            "GIT_DIR=/nowhere/.git",
            "GIT_WORK_TREE=/nowhere",
            "GIT_INDEX_FILE=/nowhere/index.tmp",
        ] {
            assert!(
                env.contains(variable),
                "{variable} did not reach the hook body:\n{env}"
            );
        }

        // The management scripts are not hook bodies and get the scrub, so an
        // inherited redirect cannot send an installer at another repository.
        std::fs::remove_file(root.join("env.log")).unwrap();
        let output = Hardened::package_script(
            &script,
            Vec::new(),
            &root,
            kendex_core::process::ScriptEnvironment::Installed,
        )
        .unwrap()
        .run()
        .unwrap();
        assert!(output.status.success());
        let env = std::fs::read_to_string(root.join("env.log")).unwrap();
        for variable in ["GIT_DIR=", "GIT_WORK_TREE=", "GIT_INDEX_FILE="] {
            assert!(
                !env.contains(variable),
                "{variable} reached the management script:\n{env}"
            );
        }
        let proof = std::env::var_os(INNER_PROOF).unwrap();
        std::fs::write(proof, "verified").unwrap();
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let proof = root.join("inner-proof");
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .arg("--exact")
        .arg(test_util::exact_test(
            module_path!(),
            "guard_hook_preserves_hook_env_and_relays_verdict",
        ))
        .arg("--nocapture")
        .env(INNER, "1")
        .env(INNER_PROOF, &proof)
        .env("GIT_DIR", "/nowhere/.git")
        .env("GIT_WORK_TREE", "/nowhere")
        .env("GIT_INDEX_FILE", "/nowhere/index.tmp")
        .status()
        .unwrap();
    assert!(
        status.success(),
        "the inner run failed; see its output above"
    );
    assert_eq!(
        std::fs::read_to_string(&proof).unwrap_or_default(),
        "verified",
        "the exact inner test did not run to completion"
    );

    // The chain's own words come back whole, on both streams, with the
    // package's exit status relayed rather than reinterpreted.
    let script = root.join("pre-commit");
    std::fs::write(
        &script,
        "#!/bin/sh\necho 'todo-ban FAIL'\necho 'note on stderr' >&2\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let output = Hardened::guard_hook(&script, Vec::new(), &root)
        .run()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stdout).contains("todo-ban FAIL"));
    assert!(String::from_utf8_lossy(&output.stderr).contains("note on stderr"));
}

/// A trusted checker uses the same outside-branch PATH for its env shebang
/// and the tools its shell starts. Installed management scripts keep PATH.
#[test]
#[cfg(unix)]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one isolated fixture drives the launch environment table and judges initial and descendant tool execution"
)]
fn package_script_tool_lookup_is_selected_before_changing_directory() {
    use kendex_core::error::CoreError;
    use kendex_core::process::ScriptEnvironment;
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};

    const ROOT: &str = "KENDEX_TEST_LOOKUP_ROOT";
    const BASE: &str = "KENDEX_TEST_LOOKUP_BASE";
    #[derive(Clone, Copy)]
    enum Expected {
        Trusted,
        Installed,
        Refused,
        BoundaryUnavailable,
    }

    const MODE: &str = "KENDEX_TEST_LOOKUP_MODE";
    const PROGRAM: &str = "KENDEX_TEST_LOOKUP_PROGRAM";
    if let Some(root) = std::env::var_os(ROOT) {
        let root = PathBuf::from(root);
        let base = PathBuf::from(std::env::var_os(BASE).unwrap());
        let expected = match std::env::var(MODE).unwrap().as_str() {
            "trusted" => Expected::Trusted,
            "installed" => Expected::Installed,
            "refused" => Expected::Refused,
            "boundary-unavailable" => Expected::BoundaryUnavailable,
            _ => panic!("invalid fixture mode"),
        };
        let (environment, result) = match expected {
            Expected::Installed => (
                ScriptEnvironment::Installed,
                Some((
                    b"project\n".as_slice(),
                    std::env::var_os("PATH").unwrap(),
                    root.as_path(),
                )),
            ),
            Expected::Trusted => (
                ScriptEnvironment::Trusted,
                Some((
                    b"trusted\n".as_slice(),
                    base.join("safe-tools").into_os_string(),
                    base.as_path(),
                )),
            ),
            Expected::Refused => (ScriptEnvironment::Trusted, None),
            Expected::BoundaryUnavailable => (ScriptEnvironment::Trusted, None),
        };
        let program = std::env::var_os(PROGRAM)
            .map(PathBuf::from)
            .unwrap_or_else(|| base.join("checker"));
        let launch = Hardened::package_script(
            &program,
            vec![
                "--repo".into(),
                root.as_os_str().to_owned(),
                base.join("child-path").into_os_string(),
                base.join("child-cwd").into_os_string(),
            ],
            &root,
            environment,
        );
        match result {
            None => match expected {
                Expected::Refused => {
                    assert!(matches!(launch, Err(CoreError::CommandNotStarted { .. })));
                }
                Expected::BoundaryUnavailable => {
                    assert!(matches!(launch, Err(CoreError::Io { .. })))
                }
                Expected::Trusted | Expected::Installed => panic!("missing launch result"),
            },
            Some((stdout, path, cwd)) => {
                let output = launch.unwrap().run().unwrap();
                assert!(output.status.success());
                assert_eq!(output.stdout, stdout);
                assert_eq!(
                    std::fs::read(base.join("child-path")).unwrap(),
                    path.as_encoded_bytes()
                );
                assert_eq!(
                    std::fs::read(base.join("child-cwd")).unwrap(),
                    cwd.as_os_str().as_encoded_bytes()
                );
            }
        }
        std::fs::write(base.join("lookup-proof"), "verified").unwrap();
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let base = rooted(&tmp);
    let root = base.join("project");
    let safe = base.join("safe-tools");
    let project_tools = root.join("tools");
    let repo = base.join("repo");
    let nested = repo.join("app");
    let sibling_tools = repo.join("tools");
    let linked = base.join("linked");
    let linked_project = linked.join("app");
    let linked_tools = linked.join("tools");
    let unavailable = base.join("unavailable");
    std::fs::create_dir_all(&project_tools).unwrap();
    for directory in [
        &sibling_tools,
        &nested,
        &linked_tools,
        &linked_project,
        &unavailable,
    ] {
        std::fs::create_dir_all(directory).unwrap();
    }
    // Git produces both marker forms. The nested project marker matches the
    // layout project_hook_root exercises and must not stop branch discovery.
    test_util::git(&repo, &["init", "--quiet"]);
    test_util::git(
        &linked,
        &[
            "init",
            "--quiet",
            "--separate-git-dir",
            base.join("linked-metadata").to_str().unwrap(),
        ],
    );
    for project in [&nested, &linked_project] {
        std::fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
    }
    std::os::unix::fs::symlink(base.join("absent-metadata"), unavailable.join(".git")).unwrap();
    std::fs::create_dir(&safe).unwrap();
    let inherited = std::env::var_os("PATH").unwrap();
    let bash = std::env::split_paths(&inherited)
        .map(|directory| directory.join("bash"))
        .find(|candidate| kendex_core::fs::is_executable(candidate))
        .unwrap();
    let bash = kendex_core::paths::canonical(&bash).unwrap();
    for (directory, answer, marker) in [
        (&safe, "trusted", "safe-interpreter"),
        (&project_tools, "project", "project-interpreter"),
        (&root, "project", "project-interpreter"),
        (&sibling_tools, "project", "project-interpreter"),
        (&linked_tools, "project", "project-interpreter"),
    ] {
        let interpreter = directory.join("bash");
        std::fs::write(
            &interpreter,
            format!(
                "#!/bin/sh\nprintf invoked > {marker:?}\nexec {bash:?} \"$@\"\n",
                marker = base.join(marker),
            ),
        )
        .unwrap();
        let tool = directory.join("kendex-lookup-tool");
        std::fs::write(&tool, format!("#!/bin/sh\nprintf '{answer}\\n'\n")).unwrap();
        let git = directory.join("git");
        std::fs::write(
            &git,
            format!(
                "#!/bin/sh\nprintf invoked > {:?}\nexit 9\n",
                base.join("unchecked-git")
            ),
        )
        .unwrap();
        for script in [interpreter, tool, git] {
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
    let checker = base.join("checker");
    std::fs::write(
        &checker,
        "#!/usr/bin/env bash\n[[ \"$1\" == --repo && -d \"$2\" ]] || exit 3\nkendex-lookup-tool\nprintf '%s' \"$PATH\" > \"$3\"\nprintf '%s' \"$PWD\" > \"$4\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&checker, std::fs::Permissions::from_mode(0o755)).unwrap();
    let project_link = base.join("project-link");
    std::os::unix::fs::symlink(&project_tools, &project_link).unwrap();
    let safe_link = base.join("safe-link");
    std::os::unix::fs::symlink(&safe, &safe_link).unwrap();
    let project_checker = root.join("checker");
    std::fs::copy(&checker, &project_checker).unwrap();
    let checker_link = base.join("checker-link");
    std::os::unix::fs::symlink(&project_checker, &checker_link).unwrap();
    let sibling_checker = repo.join("skills/bot-instructions/scripts/checker");
    std::fs::create_dir_all(sibling_checker.parent().unwrap()).unwrap();
    std::fs::copy(&checker, &sibling_checker).unwrap();
    let sibling_checker_link = base.join("sibling-checker-link");
    std::os::unix::fs::symlink(&sibling_checker, &sibling_checker_link).unwrap();
    let sibling_tools_link = base.join("sibling-tools-link");
    std::os::unix::fs::symlink(&sibling_tools, &sibling_tools_link).unwrap();
    let safe_path = std::env::join_paths([&safe]).unwrap();
    let with_safe = |directory: &Path| std::env::join_paths([directory, &safe]).unwrap();
    let rows = [
        ("safe", Some(safe_path), Expected::Trusted),
        (
            "relative",
            Some(with_safe(Path::new("tools"))),
            Expected::Trusted,
        ),
        (
            "relative-caller-cwd",
            Some(with_safe(Path::new("."))),
            Expected::Trusted,
        ),
        (
            "empty-entry",
            Some(with_safe(Path::new(""))),
            Expected::Trusted,
        ),
        (
            "project",
            Some(with_safe(&project_tools)),
            Expected::Trusted,
        ),
        (
            "project-link",
            Some(with_safe(&project_link)),
            Expected::Trusted,
        ),
        (
            "safe-link",
            Some(std::env::join_paths([&safe_link]).unwrap()),
            Expected::Trusted,
        ),
        ("empty-path", Some(OsString::new()), Expected::Refused),
        ("missing-path", None, Expected::Refused),
        (
            "only-relative",
            Some(OsString::from("tools")),
            Expected::Refused,
        ),
        (
            "only-project",
            Some(std::env::join_paths([&project_tools]).unwrap()),
            Expected::Refused,
        ),
        (
            "only-project-link",
            Some(std::env::join_paths([&project_link]).unwrap()),
            Expected::Refused,
        ),
        (
            "installed-relative",
            Some(with_safe(Path::new("tools"))),
            Expected::Installed,
        ),
    ];
    let rows = rows
        .into_iter()
        .map(|(case, path, expected)| (case, path, expected, None))
        .chain([
            (
                "project-checker",
                Some(std::env::join_paths([&safe]).unwrap()),
                Expected::Refused,
                Some(project_checker),
            ),
            (
                "project-checker-link",
                Some(std::env::join_paths([&safe]).unwrap()),
                Expected::Refused,
                Some(checker_link),
            ),
        ])
        .map(|(case, path, expected, program)| (case, path, expected, program, &root))
        .chain([
            (
                "nested-sibling-tools",
                Some(with_safe(&sibling_tools)),
                Expected::Trusted,
                None,
                &nested,
            ),
            (
                "nested-sibling-tools-link",
                Some(with_safe(&sibling_tools_link)),
                Expected::Trusted,
                None,
                &nested,
            ),
            (
                "nested-only-sibling-tools",
                Some(std::env::join_paths([&sibling_tools]).unwrap()),
                Expected::Refused,
                None,
                &nested,
            ),
            (
                "nested-sibling-checker",
                Some(with_safe(&safe)),
                Expected::Refused,
                Some(sibling_checker),
                &nested,
            ),
            (
                "nested-sibling-checker-link",
                Some(with_safe(&safe)),
                Expected::Refused,
                Some(sibling_checker_link),
                &nested,
            ),
            (
                "linked-sibling-tools",
                Some(with_safe(&linked_tools)),
                Expected::Trusted,
                None,
                &linked_project,
            ),
            (
                "unavailable-boundary",
                Some(with_safe(&safe)),
                Expected::BoundaryUnavailable,
                None,
                &unavailable,
            ),
        ]);
    for (case, path, expected, program, project) in rows {
        let mut environment = vec![
            (ROOT, project.as_os_str().to_owned()),
            (BASE, base.as_os_str().to_owned()),
        ];
        if let Some(path) = path {
            environment.push(("PATH", path));
        }
        let mode = match expected {
            Expected::Trusted => "trusted",
            Expected::Installed => "installed",
            Expected::Refused => "refused",
            Expected::BoundaryUnavailable => "boundary-unavailable",
        };
        environment.push((MODE, OsString::from(mode)));
        if let Some(program) = program {
            environment.push((PROGRAM, program.into_os_string()));
        }
        environment.extend(test_util::fixture_env(&base.join("home")));
        let output = test_util::reexecute_test(
            module_path!(),
            "package_script_tool_lookup_is_selected_before_changing_directory",
            &environment,
        )
        .unwrap();
        assert!(
            output.status.success(),
            "{case}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        assert_eq!(
            std::fs::read(base.join("lookup-proof")).unwrap(),
            b"verified",
            "{case}"
        );
        assert_eq!(
            base.join("project-interpreter").exists(),
            matches!(expected, Expected::Installed),
            "{case}"
        );
        assert_eq!(
            base.join("safe-interpreter").exists(),
            matches!(expected, Expected::Trusted),
            "{case}"
        );
        assert!(!base.join("unchecked-git").exists(), "{case}");
        for marker in [
            "lookup-proof",
            "project-interpreter",
            "safe-interpreter",
            "child-path",
            "child-cwd",
        ] {
            match std::fs::remove_file(base.join(marker)) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => panic!("{case}: cannot remove {marker}: {error}"),
            }
        }
    }
}

/// Construction excludes branch-owned checkers and tools before interpreter
/// lookup. Windows runs also exercise its differing long and short prefixes.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one isolated construction table covers checker, tool and discovery-ceiling comparisons"
)]
fn trusted_scripts_exclude_enclosing_worktrees() {
    use kendex_core::error::CoreError;
    use kendex_core::process::ScriptEnvironment;
    use std::path::PathBuf;

    const ROOT: &str = "KENDEX_TEST_PORTABLE_BOUNDARY_ROOT";
    const PROJECT: &str = "KENDEX_TEST_PORTABLE_BOUNDARY_PROJECT";
    const PROGRAM: &str = "KENDEX_TEST_PORTABLE_BOUNDARY_PROGRAM";
    const EXPECTED: &str = "KENDEX_TEST_PORTABLE_BOUNDARY_EXPECTED";
    if let Some(base) = std::env::var_os(ROOT) {
        let project = PathBuf::from(std::env::var_os(PROJECT).unwrap());
        let program = PathBuf::from(std::env::var_os(PROGRAM).unwrap());
        let launch =
            Hardened::package_script(&program, Vec::new(), &project, ScriptEnvironment::Trusted);
        match std::env::var(EXPECTED).unwrap().as_str() {
            "accepted" => assert!(launch.is_ok()),
            "refused" => assert!(matches!(launch, Err(CoreError::CommandNotStarted { .. }))),
            _ => panic!("invalid fixture expectation"),
        }
        std::fs::write(PathBuf::from(base).join("portable-proof"), "verified").unwrap();
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = rooted(&tmp);
    let safe = base.join("safe-tools");
    let external = base.join("external/checker");
    std::fs::create_dir_all(external.parent().unwrap()).unwrap();
    std::fs::write(&external, "checker").unwrap();
    let component = "nested-project".repeat(8);
    for (marker, gitfile) in [("checkout", false), ("linked", true)] {
        let repo = base.join(marker);
        let project = repo.join("app");
        let long = repo.join(&component).join(&component).join(&component);
        let short_checker = repo.join("skills/checker");
        let long_checker = long.join("skills/checker");
        let tools = repo.join("tools");
        let long_tools = long.join("tools");
        let ceiling = repo.join("ceiling");
        let ceiling_project = ceiling.join(&component).join(&component).join(&component);
        for directory in [
            &project,
            &long,
            &ceiling_project,
            &safe,
            &tools,
            &long_tools,
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }
        for checker in [&short_checker, &long_checker] {
            std::fs::create_dir_all(checker.parent().unwrap()).unwrap();
            std::fs::write(checker, "checker").unwrap();
        }
        // Construction selects a Windows interpreter but never executes it.
        for directory in [&safe, &tools, &long_tools] {
            std::fs::write(directory.join("sh.exe"), "interpreter").unwrap();
        }
        if gitfile {
            std::fs::write(repo.join(".git"), "gitdir: ../metadata\n").unwrap();
        } else {
            std::fs::create_dir(repo.join(".git")).unwrap();
        }
        #[cfg(windows)]
        {
            // Scope and discovery produce these reduced paths. The fixture
            // must cross the prefix boundary for the regression to be reached.
            assert_ne!(
                kendex_core::paths::canonical(&short_checker).unwrap(),
                std::fs::canonicalize(&short_checker).unwrap()
            );
            assert_eq!(
                kendex_core::paths::canonical(&long_checker).unwrap(),
                std::fs::canonicalize(&long_checker).unwrap()
            );
        }
        for (case, project, checker, path, ceiling, expected) in [
            (
                "sibling-checker",
                &project,
                &short_checker,
                &safe,
                None,
                "refused",
            ),
            (
                "external-checker",
                &project,
                &external,
                &safe,
                None,
                "accepted",
            ),
            (
                "long-project-short-checker",
                &long,
                &short_checker,
                &safe,
                None,
                "refused",
            ),
            (
                "short-project-long-checker",
                &project,
                &long_checker,
                &safe,
                None,
                "refused",
            ),
            (
                "long-project-short-tools",
                &long,
                &external,
                &tools,
                None,
                "refused",
            ),
            (
                "short-project-long-tools",
                &project,
                &external,
                &long_tools,
                None,
                "refused",
            ),
            (
                "long-project-external-tools",
                &long,
                &external,
                &safe,
                None,
                "accepted",
            ),
            (
                "long-project-short-ceiling",
                &ceiling_project,
                &short_checker,
                &tools,
                Some(&ceiling),
                "accepted",
            ),
        ] {
            let mut environment = test_util::fixture_env(&base.join("home")).to_vec();
            environment.extend([
                (ROOT, base.as_os_str().to_owned()),
                (PROJECT, project.as_os_str().to_owned()),
                (PROGRAM, checker.as_os_str().to_owned()),
                (EXPECTED, expected.into()),
                ("PATH", path.as_os_str().to_owned()),
            ]);
            if let Some(ceiling) = ceiling {
                environment.push(("GIT_CEILING_DIRECTORIES", ceiling.as_os_str().to_owned()));
            }
            let output = test_util::reexecute_test(
                module_path!(),
                "trusted_scripts_exclude_enclosing_worktrees",
                &environment,
            )
            .unwrap();
            assert!(
                output.status.success(),
                "{marker}: {case}: {}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(
                std::fs::read(base.join("portable-proof")).unwrap(),
                b"verified"
            );
            std::fs::remove_file(base.join("portable-proof")).unwrap();
        }
    }
}
