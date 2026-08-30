use super::*;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;

fn child_env(hardened: &Hardened) -> HashMap<&OsStr, Option<&OsStr>> {
    hardened.command.get_envs().collect()
}

#[test]
fn git_runs_without_redirecting_environment_and_without_prompts() {
    let hardened = Hardened::git(&["status"], None);
    let env = child_env(&hardened);
    for variable in GIT_REDIRECTS {
        assert_eq!(
            env.get(OsStr::new(variable)),
            Some(&None),
            "{variable} must be removed from the child"
        );
    }
    assert_eq!(
        env[OsStr::new("GIT_TERMINAL_PROMPT")],
        Some(OsStr::new("0"))
    );
    assert!(
        env[OsStr::new("GIT_SSH_COMMAND")]
            .unwrap_or_default()
            .to_string_lossy()
            .ends_with("-oBatchMode=yes")
    );
    let args: Vec<_> = hardened.command.get_args().collect();
    let settled: Vec<_> = PINNED
        .iter()
        .flat_map(|setting| [OsStr::new("-c"), OsStr::new(setting)])
        .collect();
    assert_eq!(&args[..settled.len()], settled.as_slice());
}

/// Git converts line endings on checkout when the config it reads says to,
/// and a converted file is no longer the content the catalog offered. The
/// host that asks for this by default is Windows, but neither setting is
/// Windows-only, so the arrangement that host makes is built here instead
/// — a repository whose own config asks for the conversion, which outranks
/// everything but the command line.
#[test]
fn a_repository_asking_for_line_ending_conversion_is_still_checked_out_as_committed() {
    for asked in [
        // What Git for Windows writes into the system config.
        vec!["config", "core.autocrlf", "true"],
        // The other door: `core.eol` decides for a repository that marks
        // its own files as text.
        vec!["config", "core.eol", "crlf"],
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        let file = repo.join("SKILL.md");
        fs::write(repo.join(".gitattributes"), "* text\n").unwrap();
        fs::write(&file, "one\ntwo\n").unwrap();
        for args in [
            vec!["init", "--quiet", "-b", "main"],
            asked.clone(),
            vec!["add", "-A"],
            vec![
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "--quiet",
                "-m",
                "one",
            ],
        ] {
            let run = Hardened::git(&args, Some(repo)).run().unwrap();
            assert!(run.status.success(), "git {args:?}");
        }
        fs::remove_file(&file).unwrap();

        let reset = Hardened::git(&["reset", "--hard", "HEAD", "--quiet"], Some(repo))
            .run()
            .unwrap();
        assert!(reset.status.success());
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "one\ntwo\n",
            "{asked:?} reached the checkout"
        );
    }
}

/// A user whose catalog needs a specific key sets `GIT_SSH_COMMAND`.
/// Replacing it defeats that setup — and defeats the `core.sshCommand`
/// workaround too, since the variable outranks the config.
#[test]
fn an_inherited_ssh_command_keeps_its_options() {
    assert_eq!(ssh_command(None), "ssh -oBatchMode=yes");
    assert_eq!(ssh_command(Some("  ")), "ssh -oBatchMode=yes");
    assert_eq!(
        ssh_command(Some("ssh -i /home/me/.ssh/work")),
        "ssh -i /home/me/.ssh/work -oBatchMode=yes"
    );
}

/// A hung `ssh` under `git` is a grandchild. Killing only the process we
/// hold leaves it running long past the deadline, with a reader thread
/// blocked on the pipe it still owns.
#[cfg(unix)]
#[test]
fn a_timeout_takes_the_whole_process_tree_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let marker = tmp.path().join("grandchild-ran");
    let script = format!("(sleep 1; : > {}) & wait", marker.display());
    let error = Hardened::program("/bin/sh", &["-c", &script])
        .timeout(Duration::from_millis(200))
        .run()
        .unwrap_err();
    let CoreError::Io { source, .. } = error else {
        panic!("timeout must report as an io error");
    };
    assert_eq!(source.kind(), io::ErrorKind::TimedOut);

    std::thread::sleep(Duration::from_millis(1500));
    assert!(!marker.exists(), "a grandchild outlived the timeout");
}

#[test]
fn errors_name_the_call_the_caller_asked_for_not_the_pinning() {
    let repo = Path::new("/nowhere/cache");
    assert_eq!(
        Hardened::git_in(repo, &["fetch", "origin"]).label(),
        "git fetch origin"
    );
}

/// A cached repository whose own config points its working tree at a
/// sibling directory. Un-pinned, `git reset --hard` here overwrites the
/// sibling's files with the repository's; pinned, it cannot see them.
#[test]
fn a_hostile_core_worktree_cannot_reach_outside_the_cache() {
    let tmp = tempfile::tempdir().unwrap();
    let cache = tmp.path().join("cache");
    let victim = tmp.path().join("victim");
    fs::create_dir_all(cache.join("skills/gh")).unwrap();
    fs::create_dir_all(victim.join("skills/gh")).unwrap();
    fs::write(cache.join("skills/gh/SKILL.md"), "from the catalog\n").unwrap();
    for args in [
        vec!["init", "--quiet", "-b", "main"],
        vec!["add", "."],
        vec![
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            "one",
        ],
        vec!["config", "core.worktree", &victim.display().to_string()],
    ] {
        assert!(
            Hardened::git(&args, Some(&cache))
                .run()
                .unwrap()
                .status
                .success()
        );
    }
    let precious = victim.join("skills/gh/SKILL.md");
    fs::write(&precious, "the user's own work\n").unwrap();
    fs::write(cache.join("skills/gh/SKILL.md"), "locally edited\n").unwrap();

    let reset = Hardened::git_in(&cache, &["reset", "--hard", "HEAD", "--quiet"])
        .run()
        .unwrap();

    assert!(reset.status.success());
    assert_eq!(
        fs::read_to_string(&precious).unwrap(),
        "the user's own work\n"
    );
    assert_eq!(
        fs::read_to_string(cache.join("skills/gh/SKILL.md")).unwrap(),
        "from the catalog\n"
    );
}

#[cfg(unix)]
#[test]
fn a_call_that_outlives_its_timeout_is_killed() {
    let started = Instant::now();
    let error = Hardened::program("/bin/sleep", &["5"])
        .timeout(Duration::from_millis(200))
        .run()
        .unwrap_err();
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "waited too long"
    );
    let CoreError::Io { source, .. } = error else {
        panic!("timeout must report as an io error");
    };
    assert_eq!(source.kind(), io::ErrorKind::TimedOut);
}

#[cfg(unix)]
#[test]
fn a_child_reading_stdin_gets_nothing_instead_of_waiting() {
    let output = Hardened::program("/bin/cat", &[])
        .timeout(Duration::from_secs(5))
        .run()
        .unwrap();
    assert!(output.status.success());
    assert!(output.stdout.is_empty());
}

#[cfg(unix)]
#[test]
fn output_past_the_cap_is_an_error_not_a_memory_hole() {
    let output = Hardened::program("/bin/sh", &["-c", "head -c 100000 /dev/zero"])
        .timeout(Duration::from_secs(10))
        .max_output(10_000)
        .run();
    assert!(output.is_err(), "a capped read refuses, never truncates");

    let under = Hardened::program("/bin/sh", &["-c", "printf hello"])
        .timeout(Duration::from_secs(10))
        .max_output(10_000)
        .run()
        .unwrap();
    assert_eq!(under.stdout, b"hello");
}
