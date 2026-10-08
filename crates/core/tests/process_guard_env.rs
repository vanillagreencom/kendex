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
#![cfg(unix)]

use kendex_core::process::Hardened;
use std::os::unix::fs::PermissionsExt;

use crate::test_util;
use test_util::rooted;

const INNER: &str = "KENDEX_TEST_GUARD_ENV_INNER";
const INNER_PROOF: &str = "KENDEX_TEST_GUARD_ENV_PROOF";

/// The redirect has to come from the parent's environment. The outer run
/// re-enters this test binary with the variables set and judges the inner
/// run before writing and executing the verdict fixture.
#[test]
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

/// A trusted checker uses the same outside-project PATH for its env shebang
/// and the tools its shell starts. Installed management scripts keep PATH.
#[test]
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
    #[derive(Clone, Copy)]
    enum Expected {
        Trusted,
        Installed,
        Refused,
    }

    const MODE: &str = "KENDEX_TEST_LOOKUP_MODE";
    const PROGRAM: &str = "KENDEX_TEST_LOOKUP_PROGRAM";
    if let Some(root) = std::env::var_os(ROOT) {
        let root = PathBuf::from(root);
        let base = root.parent().unwrap();
        let expected = match std::env::var(MODE).unwrap().as_str() {
            "trusted" => Expected::Trusted,
            "installed" => Expected::Installed,
            "refused" => Expected::Refused,
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
                    base,
                )),
            ),
            Expected::Refused => (ScriptEnvironment::Trusted, None),
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
            None => assert!(matches!(launch, Err(CoreError::CommandNotStarted { .. }))),
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
    std::fs::create_dir_all(&project_tools).unwrap();
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
        for script in [interpreter, tool] {
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
        ]);
    for (case, path, expected, program) in rows {
        let mut environment = vec![(ROOT, root.as_os_str().to_owned())];
        if let Some(path) = path {
            environment.push(("PATH", path));
        }
        let mode = match expected {
            Expected::Trusted => "trusted",
            Expected::Installed => "installed",
            Expected::Refused => "refused",
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
