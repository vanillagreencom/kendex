use super::*;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;

fn child_env(hardened: &Hardened) -> HashMap<&OsStr, Option<&OsStr>> {
    hardened.command.get_envs().collect()
}

/// Every git call drops the variables that redirect it to another
/// repository, index or attribute source, never prompts, runs ssh in
/// batch mode, and settles `protocol.ext.allow=never` on its own command
/// line ahead of the caller's words. Named here setting by setting,
/// rather than read off the constants the constructor reads, so that a
/// setting dropped from a constant is a failure here and not a shorter
/// list that agrees with itself.
#[test]
fn git_runs_without_redirecting_environment_and_without_prompts() {
    let hardened = Hardened::git(&["status"], None);
    let env = child_env(&hardened);
    for variable in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_ATTR_SOURCE",
    ] {
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
    assert_eq!(
        &args[..3],
        [
            OsStr::new("-c"),
            OsStr::new("protocol.ext.allow=never"),
            OsStr::new("status")
        ]
    );
}

/// A repository holding `one\ntwo\n` that asks for CRLF in its working
/// tree, by the config `asked` sets and the `attributes` it ships. The host
/// that asks by default is Windows, but neither setting is Windows-only, so
/// the arrangement that host makes is built here, in a place that outranks
/// everything but the command line.
fn asking_repository(dir: &Path, attributes: Option<&str>, asked: &[&str]) {
    if let Some(attributes) = attributes {
        fs::write(dir.join(".gitattributes"), attributes).unwrap();
    }
    fs::write(dir.join("SKILL.md"), "one\ntwo\n").unwrap();
    for args in [
        vec!["init", "--quiet", "-b", "main"],
        asked.to_vec(),
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
        let run = Hardened::git(&args, Some(dir)).run().unwrap();
        assert!(run.status.success(), "git {args:?}");
    }
}

/// The three doors. `core.autocrlf=true` is what Git for Windows'
/// installer writes into the system config, and it decides for a
/// repository that says nothing about its own files; `core.eol` decides
/// for one that marks them as text; and a repository that commits the
/// whole rule itself needs no host configuration at all.
const ASKING: [(Option<&str>, &[&str]); 3] = [
    (None, &["config", "core.autocrlf", "true"]),
    (Some("* text\n"), &["config", "core.eol", "crlf"]),
    (
        Some("* text eol=crlf\n"),
        &["config", "core.autocrlf", "false"],
    ),
];

/// The empty tree, which is what `remote::store` hands the materialising
/// call as the tree to read `.gitattributes` from — the SHA-1 spelling,
/// because a repository `git init` makes here is SHA-1. `store` derives
/// this per mirror; a test that names one fixture's format can name the
/// constant.
const NO_ATTRIBUTES: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// Content is materialised the way `remote::store` materialises it, and
/// what lands is what was committed however the repository asks for it to
/// be written.
#[test]
fn catalog_content_is_written_as_committed_whatever_the_repository_asks() {
    for (attributes, asked) in ASKING {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("repo");
        let into = tmp.path().join("into");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir_all(&into).unwrap();
        asking_repository(&repo, attributes, asked);

        let git_dir = repo.join(".git");
        assert!(
            Hardened::git_bare(&git_dir, &["read-tree", "HEAD"])
                .run()
                .unwrap()
                .status
                .success()
        );
        let written = Hardened::git_into(
            &git_dir,
            &into,
            NO_ATTRIBUTES,
            &["checkout-index", "--all", "--force"],
        )
        .run()
        .unwrap();
        assert!(written.status.success(), "{asked:?}");
        assert_eq!(
            fs::read_to_string(into.join("SKILL.md")).unwrap(),
            "one\ntwo\n",
            "{asked:?} reached the content kendex reads"
        );
    }
}

/// The host can supply attributes as well as configuration, and attributes
/// outrank it. A global attributes file converts the checkout with the
/// line-ending settings already in place, so it is taken out of the
/// materialising call too — and this repository commits none of its own,
/// so the rule under test is the host's alone.
///
/// Both places a host keeps one. `core.attributesFile` names a file, and
/// the same setting emptied is what displaces it; the default path is
/// `git/attributes` under the config directory, reached here by giving the
/// child a home of its own. Both `HOME` and `XDG_CONFIG_HOME` are set,
/// because git resolves the default through the second where it is
/// present and a suite that set only the first would be reading whatever
/// the machine running it happens to have. The third source, the
/// system-wide file, has no path a test host can write, so what is
/// asserted for it is that the switch git offers reaches the child.
#[test]
fn a_host_attributes_file_does_not_reach_the_content_kendex_reads() {
    for named in [true, false] {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("repo");
        let into = tmp.path().join("into");
        let home = tmp.path().join("home");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir_all(&into).unwrap();
        fs::create_dir_all(home.join("git")).unwrap();
        let attributes = match named {
            true => tmp.path().join("host-attributes"),
            false => home.join("git/attributes"),
        };
        fs::write(&attributes, "* text eol=crlf\n").unwrap();
        asking_repository(&repo, None, &["config", "core.autocrlf", "false"]);
        if named {
            let set = Hardened::git(
                &[
                    "config",
                    "core.attributesFile",
                    &attributes.display().to_string(),
                ],
                Some(&repo),
            )
            .run()
            .unwrap();
            assert!(set.status.success());
        }

        let git_dir = repo.join(".git");
        assert!(
            Hardened::git_bare(&git_dir, &["read-tree", "HEAD"])
                .run()
                .unwrap()
                .status
                .success()
        );
        let written = Hardened::git_into(
            &git_dir,
            &into,
            NO_ATTRIBUTES,
            &["checkout-index", "--all", "--force"],
        )
        .env("HOME", home.to_str().unwrap())
        .env("XDG_CONFIG_HOME", home.to_str().unwrap())
        .run()
        .unwrap();
        assert!(written.status.success(), "named={named}");
        assert_eq!(
            fs::read_to_string(into.join("SKILL.md")).unwrap(),
            "one\ntwo\n",
            "named={named}: a host attributes file reached the checkout"
        );
    }

    assert_eq!(
        child_env(&Hardened::git_into(
            Path::new("/nowhere/.git"),
            Path::new("/nowhere/into"),
            NO_ATTRIBUTES,
            &["checkout-index", "--all"],
        ))[OsStr::new("GIT_ATTR_NOSYSTEM")],
        Some(OsStr::new("1"))
    );
}

/// `GIT_ATTR_SOURCE` names a treeish to read `.gitattributes` from instead
/// of the tree in hand, so a host exporting one that says `* text eol=crlf`
/// converts a checkout past every setting there is. It is scrubbed from
/// every git call rather than answered on the materialising one, because
/// what it does is redirect git's input: on a read it would have `status`
/// judge a working tree against some other commit's rules, and only
/// scrubbing everywhere prevents that.
///
/// Two halves, and they prove different things. That the variable really
/// does convert is shown end to end, by handing it to the child on purpose.
/// That it never gets there is a named assertion on the command, which is
/// the same shape the rest of `GIT_REDIRECTS` is held to — and it has to
/// name the variable rather than loop over the list, or removing the entry
/// would take the check with it.
#[test]
fn an_attribute_source_from_the_environment_reaches_no_git_call() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    let into = tmp.path().join("into");
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(&into).unwrap();
    asking_repository(&repo, None, &["config", "core.autocrlf", "false"]);

    // A second tree holding nothing but the rule, so the attributes come
    // from somewhere other than the commit being written out.
    fs::remove_file(repo.join("SKILL.md")).unwrap();
    fs::write(repo.join(".gitattributes"), "* text eol=crlf\n").unwrap();
    for args in [
        vec!["checkout", "--quiet", "-b", "attrs"],
        vec!["add", "-A"],
        vec![
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            "attrs",
        ],
    ] {
        let run = Hardened::git(&args, Some(&repo)).run().unwrap();
        assert!(run.status.success(), "git {args:?}");
    }

    let git_dir = repo.join(".git");
    let materialise = |call: Hardened| {
        assert!(
            Hardened::git_bare(&git_dir, &["read-tree", "main"])
                .run()
                .unwrap()
                .status
                .success()
        );
        assert!(call.run().unwrap().status.success());
        fs::read_to_string(into.join("SKILL.md")).unwrap()
    };
    let unpinned = || {
        Hardened::git(
            &[
                "--git-dir",
                &git_dir.display().to_string(),
                "--work-tree",
                &into.display().to_string(),
                "checkout-index",
                "--all",
                "--force",
            ],
            None,
        )
        .env("GIT_ATTR_SOURCE", "attrs")
    };

    // The threat is real: handed the variable, git reads the other tree's
    // rule and converts. This is what the scrub exists to stop, and it is
    // shown on a call that pins no attribute source of its own, because
    // that is every call kendex makes but the write.
    assert_eq!(materialise(unpinned()), "one\r\ntwo\r\n");

    // The write is answered twice over: the source it pins on the command
    // line outranks the variable even when the variable arrives.
    assert_eq!(
        materialise(
            Hardened::git_into(
                &git_dir,
                &into,
                NO_ATTRIBUTES,
                &["checkout-index", "--all", "--force"],
            )
            .env("GIT_ATTR_SOURCE", "attrs"),
        ),
        "one\ntwo\n"
    );

    // And it never arrives on its own: an exported one is dropped from
    // every call, the write and the reads alike.
    for hardened in [
        Hardened::git(&["status"], None),
        Hardened::git_in(Path::new("/nowhere"), &["status"]),
        Hardened::git_bare(Path::new("/nowhere/.git"), &["for-each-ref"]),
        Hardened::git_into(
            Path::new("/nowhere/.git"),
            Path::new("/nowhere/into"),
            NO_ATTRIBUTES,
            &["checkout-index", "--all"],
        ),
    ] {
        assert_eq!(
            child_env(&hardened).get(OsStr::new("GIT_ATTR_SOURCE")),
            Some(&None),
            "{} keeps an inherited attribute source",
            hardened.label()
        );
    }
}

/// The settings go no further than that. A call that inspects a repository
/// somebody owns asks what that repository thinks, and its own line-ending
/// rule is part of the answer.
///
/// The working copy here is the one that rule produces, written by an
/// ordinary checkout rather than by hand, and then touched so the index's
/// stat cache does not vouch for it and `status` has to hash the file
/// again. Reading it under the repository's own rule finds no change.
/// Reading it with the conversion forced off finds a modification nobody
/// made, and `author::preflight` then refuses to submit a tree that is in
/// fact clean. `--no-optional-locks` is what `author::status` passes, so
/// the read cannot quietly refresh the index and hide the question.
///
/// Only the `core.autocrlf` door is exercised, and that is the whole of
/// it: a repository that marks its files as text is normalised on the way
/// in whatever the configuration says, so the conversion settings cannot
/// change what `status` sees there. Where they can is a repository that
/// ships no attributes and leans on `core.autocrlf`, which is the Git for
/// Windows default and what an author's own checkout looks like.
#[test]
fn a_status_read_honours_the_line_endings_the_repository_asked_for() {
    let (attributes, asked) = ASKING[0];
    {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        asking_repository(repo, attributes, asked);
        let file = repo.join("SKILL.md");

        fs::remove_file(&file).unwrap();
        let restored = Hardened::git(&["checkout", "--", "SKILL.md"], Some(repo))
            .run()
            .unwrap();
        assert!(restored.status.success(), "{asked:?}");
        assert_eq!(
            fs::read(&file).unwrap(),
            b"one\r\ntwo\r\n",
            "{asked:?}: the rule was ignored"
        );
        // The index's stat cache vouches for the file git just wrote, and a
        // read that trusts it never looks at the bytes. Moving the
        // modification time off what the index recorded is what makes
        // `status` hash the file again, which is the moment the conversion
        // rule decides the answer.
        let handle = fs::OpenOptions::new().write(true).open(&file).unwrap();
        handle
            .set_times(fs::FileTimes::new().set_modified(std::time::UNIX_EPOCH))
            .unwrap();

        let status = Hardened::git_in(repo, &["--no-optional-locks", "status", "--porcelain"])
            .run()
            .unwrap();
        assert!(status.status.success());
        assert_eq!(
            String::from_utf8_lossy(&status.stdout),
            "",
            "{asked:?}: a working copy the repository itself wrote reads as modified"
        );
    }
}

/// A user whose catalog needs a specific key sets `GIT_SSH_COMMAND`.
/// Replacing it defeats that setup and `core.sshCommand`, since the
/// variable outranks the config.
#[test]
fn an_inherited_ssh_command_keeps_its_options() {
    assert_eq!(ssh_command(None), "ssh -oBatchMode=yes");
    assert_eq!(ssh_command(Some("  ")), "ssh -oBatchMode=yes");
    assert_eq!(
        ssh_command(Some("ssh -i /home/me/.ssh/work")),
        "ssh -i /home/me/.ssh/work -oBatchMode=yes"
    );
}

/// One row per shape a run can outlive its timeout in, every one ended
/// inside the bound with nothing it spawned left running: a program with
/// no children at all; a direct child that hangs; a hung grandchild under a waiting child, which is a hung
/// `ssh` under `git`, where killing only the process we hold leaves it
/// running long past the deadline with a reader thread blocked on the
/// pipe it still owns; and a grandchild holding the pipes behind a child
/// that returned its status at once, where waiting on the child alone
/// declared the run over and then blocked in collection for the
/// grandchild's whole run, with no deadline anywhere near it. Every
/// script but the first writes a marker after a second the timeout does
/// not allow, so a marker on disk afterwards is a process that outlived
/// the kill.
#[cfg(unix)]
#[test]
fn a_run_that_outlives_its_timeout_is_ended_with_everything_it_spawned() {
    let rows = [
        ("a program with no children", "/bin/sleep", None),
        ("a hung child", "/bin/sh", Some("sleep 1; : > MARKER")),
        (
            "a hung grandchild under a waiting child",
            "/bin/sh",
            Some("(sleep 1; : > MARKER) & wait"),
        ),
        (
            "a grandchild holding the pipes",
            "/bin/sh",
            Some("(sleep 1; : > MARKER) & exit 0"),
        ),
    ];
    for (label, program, script) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let marker = tmp.path().join("outlived");
        let script = script.map(|script| script.replace("MARKER", &marker.display().to_string()));
        let args: Vec<&str> = match &script {
            Some(script) => vec!["-c", script],
            None => vec!["5"],
        };
        let started = Instant::now();
        let error = Hardened::program(program, &args)
            .timeout(Duration::from_millis(200))
            .run()
            .unwrap_err();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{label}: collection ran past the bound: {:?}",
            started.elapsed()
        );
        let CoreError::Io { source, .. } = error else {
            panic!("{label}: a timeout must report as an io error, got {error:?}");
        };
        assert_eq!(source.kind(), io::ErrorKind::TimedOut, "{label}");

        std::thread::sleep(Duration::from_millis(1500));
        assert!(!marker.exists(), "{label}: a process outlived the timeout");
    }
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
///
/// `reset --hard` writes a working tree, so the host's line-ending
/// configuration reaches it — this is not the call that settles that, and
/// widening the settings to cover it would put them back on every
/// inspection. The fixture answers for its own line endings instead, which
/// is what a test about containment should be holding constant.
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
        vec!["config", "core.autocrlf", "false"],
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

/// The producer `registry/client.rs` reads to tell a request that never
/// went out from one the directory did not answer. A real spawn failure
/// rather than a hand-built error: the classification is only worth
/// anything if the shipped path raises the name the seam matches on.
#[test]
fn a_program_that_cannot_be_spawned_says_it_never_started() {
    let error = Hardened::program("/nonexistent/kendex-not-a-program", &[])
        .timeout(Duration::from_secs(5))
        .run()
        .unwrap_err();
    let CoreError::CommandNotStarted { label, why } = error else {
        panic!("a command that never ran must say so, not report as a run that failed");
    };
    assert!(label.contains("kendex-not-a-program"), "{label}");
    assert!(!why.is_empty(), "the reason it could not start is empty");
}
