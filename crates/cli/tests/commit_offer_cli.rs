//! The commit offer through the binary: every state the design's table
//! gives the CLI a detection for, driven by a real repository, a bare
//! `origin`, the repository's own hooks, and a fake `gh` on the child's
//! `PATH` whose answer is chosen by the `--repo` value every call is
//! bound to. The child has no terminal, so the interactive block is not
//! reachable here; its rows are pinned in `commands/commit_offer/tests.rs`.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", path_with_fake_gh(home))
        // The ssh `hosted_origin` writes; kendex's git keeps an inherited
        // ssh command, and no other fixture pushes over ssh.
        .env("GIT_SSH_COMMAND", home.join("dev/fake-ssh"))
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) -> String {
    let home = dir.to_str().unwrap();
    let out = Hardened::git(args, Some(dir))
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// A project installing one native Claude agent. Its rendered file,
/// record, inventory and ignore file form the initial commit offer.
#[allow(clippy::unwrap_used)]
fn project(tmp: &tempfile::TempDir) -> PathBuf {
    let home = rooted(tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("offer-catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/offer-file.md"),
        "---\nname: offer-file\ndescription: fixture\n---\nRead the project.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!("schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.offer]\n{}\n[agents.offer-file]\nsource = \"offer\"\n", test_util::source_path(&catalog)),
    )
    .unwrap();
    fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "user.email", "t@t"]);
    git(&project, &["config", "user.name", "t"]);
    git(&project, &["config", "commit.gpgsign", "false"]);
    git(&project, &["config", "core.hooksPath", ".git/hooks"]);
    git(&project, &["config", "status.showUntrackedFiles", "all"]);
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "files"]);
    project
}

/// A bare repository the project calls `origin`, under a name the fake
/// `gh` reads its answer from.
#[allow(clippy::unwrap_used)]
fn origin(project: &Path, name: &str) -> PathBuf {
    let bare = project.parent().unwrap().join(format!("{name}.git"));
    git(
        project,
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            &bare.to_string_lossy(),
        ],
    );
    git(
        project,
        &["remote", "add", "origin", &bare.to_string_lossy()],
    );
    git(project, &["push", "-q", "-u", "origin", "main"]);
    bare
}

/// The shipped package launcher, the one owner of the owned-region
/// grammar. A fixture renderer answers `region-bounds` by calling it, so no
/// fixture carries a second copy of the bounds rule.
const PACKAGE_LAUNCHER: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../skills/bot-instructions/scripts/bot-instructions"
);

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A `gh` whose answers are chosen by the repository it was bound to:
/// `--repo`, or `GH_REPO` for `gh api`, which has no `--repo`. The
/// directory holds nothing but `gh`, so git resolves as before.
#[allow(clippy::unwrap_used)]
fn path_with_fake_gh(home: &Path) -> String {
    let dir = home.join("fake-bin");
    executable(&dir.join("gh"), FAKE_GH);
    format!(
        "{}:{}",
        dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

const FAKE_GH: &str = r#"#!/bin/sh
if [ "$1" = api ]; then echo "GH_REPO=$GH_REPO $*" >> "$(dirname "$0")/calls"; else echo "$@" >> "$(dirname "$0")/calls"; fi
repo=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then repo="$a"; fi
  prev="$a"
done
if [ "$1" = api ]; then
  host=github.com
  endpoint=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--hostname" ]; then host="$a"; fi
    prev="$a"
    endpoint="$a"
  done
  # gh asks the host --hostname names about the path GH_REPO names, so a
  # repository on another host is one this host does not have.
  repo_host=$(printf '%s' "$GH_REPO" | sed -e 's#^[a-z]*://##' -e 's#^[^@/]*@##' -e 's#[:/].*##')
  if [ "$repo_host" = "$host" ]; then
    case "$GH_REPO $endpoint" in
      *bypass*/rulesets/7) echo '{"current_user_can_bypass":"always"}'; exit 0;;
      *ruled*/rulesets/7) echo '{"current_user_can_bypass":"never"}'; exit 0;;
      *ruled*/rules/branches/main) echo '[{"type":"deletion","ruleset_id":7},{"type":"pull_request","ruleset_id":7}]'; exit 0;;
      *fork*/rules/branches/main) echo '[{"type":"deletion","ruleset_id":7}]'; exit 0;;
    esac
  fi
  echo 'gh: Not Found (HTTP 404)' >&2; exit 1
fi
case "$1 $2" in
"pr list")
  case "$repo" in
    *notauth*) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4;;
    *open*) echo '[{"number":41,"url":"https://github.com/acme/site/pull/41"}]'; exit 0;;
    *) echo '[]'; exit 0;;
  esac;;
"pr create")
  case "$repo" in
    *refuse*) echo "GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)" >&2; exit 1;;
    *) echo "https://github.com/acme/site/pull/41"; exit 0;;
  esac;;
esac
exit 1
"#;

fn apply(home: &Path, project: &Path, flags: &[&str]) -> (Output, String) {
    let mut args = vec!["apply", "--yes"];
    args.extend_from_slice(flags);
    let output = kendex(home, project, &args);
    let text = said(&output);
    (output, text)
}

fn head_subject(project: &Path) -> String {
    git(project, &["log", "-1", "--format=%s"])
        .trim()
        .to_owned()
}

/// No terminal and no flag: one line naming the flags, and the run exits
/// as the verb would. A flag that leaves is the same success with no line.
#[test]
fn without_a_terminal_the_line_names_the_flags_and_leave_says_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &[]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains(
            "4 files kendex wrote are not committed; run again with --commit, --push, --pull-request or --leave"
        ),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");

    let (output, text) = apply(&home, &project, &["--leave"]);
    assert!(output.status.success(), "{text}");
    assert!(!text.contains("not committed"), "{text}");
    assert!(git(&project, &["status", "--porcelain"]).contains("?? .claude/agents/offer-file.md"));
}

/// The commit route: the set is committed with the command's message, or
/// the one `--message` gives, and the ledger carries the part.
#[test]
fn the_commit_flag_commits_the_set_with_the_commands_message() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 4 files as "), "{text}");
    assert!(
        text.contains(" · committed 4 files"),
        "no ledger part: {text}"
    );
    assert!(
        !home.join("fake-bin/calls").exists(),
        "a commit that takes no pull request asked gh"
    );
    assert_eq!(head_subject(&project), "chore: kendex apply");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        files.contains(".claude/agents/offer-file.md") && files.contains(".kendex-generated.json"),
        "{files}"
    );
    assert!(!files.contains("kendex.toml"), "{files}");

    // A fresh checkout, the person's own edit beside the renders: the
    // message given is the one used, and the edit is never swept in.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    fs::write(project.join("AGENTS.md"), "# app\n\nmore\n").unwrap();
    let (output, text) = apply(&home, &project, &["--commit", "--message", "docs: renders"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 4 files as "), "{text}");
    assert_eq!(head_subject(&project), "docs: renders");
    assert!(
        git(&project, &["status", "--porcelain"]).contains(" M AGENTS.md"),
        "the person's own change was swept into the commit"
    );
}

/// Where something is installed, the record is in the set beside the
/// renders and the inventory, and this machine's half of it is not: the
/// commit that lands a render lands what says which package it is, and a
/// clone reads the render as that package. The must-fail control for the
/// lock being a companion of the render set: without it the record stays
/// an untracked file the offer never names.
#[test]
#[allow(clippy::unwrap_used)]
fn the_install_record_is_committed_with_the_renders() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::create_dir_all(project.join("catalog/skills/deploy")).unwrap();
    fs::write(
        project.join("catalog/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.deploy]\nsource = \"cat\"\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "declare"]);

    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert_eq!(head_subject(&project), "chore: kendex apply");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    for carried in [
        ".kendex-lock.json",
        ".kendex-generated.json",
        ".agents/skills/deploy/SKILL.md",
    ] {
        assert!(
            files.lines().any(|line| line == carried),
            "{carried}: {files}"
        );
    }
    assert!(!files.contains("lock-local.json"), "{files}");
    assert!(project.join(".cache/kendex/lock-local.json").is_file());
    // The ignore file the run wrote where none stood is carried with the
    // rest, and the machine half is under it, so nothing is left pending.
    assert!(files.lines().any(|line| line == ".gitignore"), "{files}");
    assert_eq!(git(&project, &["status", "--porcelain"]), "");
}

/// A catalog declaring kendex's layout, offering the agent `scout` and the
/// hook `guard`, whose registration lands in Claude Code's settings file.
#[allow(clippy::unwrap_used)]
fn scout_and_guard(home: &Path) -> PathBuf {
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(
        catalog.join("agents/scout.md"),
        "---\nname: scout\ndescription: look around\n---\nLook.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: block dangerous commands\n# ---\nexit 0\n",
    )
    .unwrap();
    // Hooks are offered only by a catalog that declares kendex's layout.
    fs::write(catalog.join("kendex.toml"), "[catalog]\n").unwrap();
    catalog
}

/// `add --commit` commits every file the run wrote that held no change
/// before it: the manifest, the ignore file, and the shared settings file a
/// hook registers in, written where none stood. A file the run wrote into
/// that already held a change of the person's is left out, since git
/// commits whole files, stays pending, and the offer names it. The same add
/// with nobody to ask prints the count of that same commit in its head.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: each row an add with nobody to ask and an add that commits, in projects of their own"
)]
fn an_add_commits_every_file_it_wrote_and_names_one_that_held_a_change() {
    const MANIFEST: &str = "kendex.toml";
    const SETTINGS: &str = ".claude/settings.json";
    struct Row {
        what: &'static str,
        add: [&'static str; 2],
        /// A file committed before the add, then edited and left pending.
        edited: Option<(&'static str, &'static str, &'static str)>,
        carried: &'static [&'static str],
        left: Option<&'static str>,
    }
    let rows = [
        Row {
            what: "an agent in a clean checkout",
            add: ["--agent", "scout"],
            edited: None,
            carried: &[
                ".kendex-lock.json",
                ".gitignore",
                ".claude/agents/scout.md",
                MANIFEST,
            ],
            left: None,
        },
        Row {
            what: "an agent over a manifest holding a hand edit",
            add: ["--agent", "scout"],
            edited: Some((
                MANIFEST,
                "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
                "# mine\nschema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
            )),
            carried: &[".kendex-lock.json", ".gitignore", ".claude/agents/scout.md"],
            left: Some(MANIFEST),
        },
        Row {
            what: "a hook in a clean checkout",
            add: ["--hook", "guard"],
            edited: None,
            carried: &[".kendex-lock.json", ".gitignore", MANIFEST, SETTINGS],
            left: None,
        },
        Row {
            what: "a hook over a settings file holding a hand edit",
            add: ["--hook", "guard"],
            edited: Some((SETTINGS, "{\"mine\": 1}\n", "{\"mine\": 2}\n")),
            carried: &[".kendex-lock.json", ".gitignore", MANIFEST],
            left: Some(SETTINGS),
        },
    ];
    for row in rows {
        let what = row.what;
        // The add, run in a project of its own with `answer` added.
        let add = |answer: Option<&str>| {
            let tmp = tempfile::tempdir().unwrap();
            let home = rooted(&tmp);
            let project = project(&tmp);
            let catalog = scout_and_guard(&home);
            if let Some((path, committed, edit)) = row.edited {
                fs::write(project.join(path), committed).unwrap();
                git(&project, &["add", "-A"]);
                git(&project, &["commit", "-q", "--allow-empty", "-m", "mine"]);
                fs::write(project.join(path), edit).unwrap();
            }
            let mut args = vec!["add", "--yes", "--throwaway"];
            args.extend(answer);
            let source = catalog.to_string_lossy().into_owned();
            args.push(&source);
            args.extend(row.add);
            let output = kendex(&home, &project, &args);
            let text = said(&output);
            assert!(output.status.success(), "{what}: {text}");
            (tmp, project, text)
        };
        let (_unasked, _, asked) = add(None);
        let (_tmp, project, text) = add(Some("--commit"));
        let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
        let status = git(&project, &["status", "--porcelain"]);
        let count = files.lines().count();
        assert!(
            asked.contains(&format!(
                ": {count} files kendex wrote are not committed; run again"
            )),
            "{what}: the head did not count the {count} files committed:\n{asked}"
        );
        assert!(
            text.contains(&format!("committed {count} files as ")),
            "{what}: {text}"
        );
        for carried in row.carried {
            assert!(
                files.lines().any(|line| line == *carried),
                "{what}: {carried} is not in the commit: {files}"
            );
        }
        match row.left {
            None => {
                assert_eq!(status, "", "{what}: {text}");
                assert!(
                    !text.contains("held changes before this run"),
                    "{what}: {text}"
                );
            }
            Some(left) => {
                assert!(!files.lines().any(|line| line == left), "{what}: {files}");
                assert_eq!(status, format!(" M {left}\n"), "{what}: {text}");
                assert!(
                    text.contains(&format!(
                        "{left} held changes before this run, so the commit leaves it out"
                    )),
                    "{what}: {text}"
                );
            }
        }
    }
}

/// `remove --commit` commits the deletion of a render the person edited
/// after the add committed it. The removal's plan names that render among
/// the paths it touches, and a deleted render the committed inventory
/// names is kendex's whole whatever touched it, so the commit carries its
/// deletion beside the manifest, the lock and the inventory, and nothing is
/// left pending.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remove_commits_the_deletion_of_a_render_the_person_edited() {
    const RENDER: &str = ".claude/agents/scout.md";
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let source = scout_and_guard(&home).to_string_lossy().into_owned();
    let add = kendex(
        &home,
        &project,
        &[
            "add",
            "--yes",
            "--throwaway",
            "--commit",
            &source,
            "--agent",
            "scout",
        ],
    );
    assert!(add.status.success(), "{}", said(&add));
    let render = project.join(RENDER);
    let text = fs::read_to_string(&render).unwrap();
    fs::write(&render, format!("{text}mine\n")).unwrap();

    let output = kendex(
        &home,
        &project,
        &["remove", "--commit", "--no-sweep", "scout"],
    );
    let text = said(&output);

    assert!(output.status.success(), "{text}");
    assert!(!render.exists(), "{text}");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    for carried in [RENDER, "kendex.toml", ".kendex-lock.json"] {
        assert!(
            files.lines().any(|line| line == carried),
            "{carried} is not in the commit: {files}\n{text}"
        );
    }
    assert_eq!(git(&project, &["status", "--porcelain"]), "", "{text}");
}

/// `remove --commit` over the shared settings file a committed hook added
/// its key to beside the person's own. Where the person's key stays, the
/// removal edits the file from a clean state and the commit carries it.
/// Where the person took their key out, removing the last hook empties
/// the file and the removal deletes it: that deletion carries the person's
/// change, though the committed inventory names the file, so the commit
/// leaves it out and names it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remove_commits_a_shared_file_it_edits_and_leaves_out_one_the_person_emptied() {
    const SETTINGS: &str = ".claude/settings.json";
    for took_key_out in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        fs::write(project.join(SETTINGS), "{\"mine\": 1}\n").unwrap();
        git(&project, &["add", "-A"]);
        git(&project, &["commit", "-q", "-m", "mine"]);
        let source = scout_and_guard(&home).to_string_lossy().into_owned();
        let args = [
            "add",
            "--yes",
            "--throwaway",
            "--commit",
            &source,
            "--hook",
            "guard",
        ];
        let add = kendex(&home, &project, &args);
        assert!(add.status.success(), "{}", said(&add));
        assert_eq!(
            git(&project, &["status", "--porcelain"]),
            "",
            "{}",
            said(&add)
        );
        let settings = project.join(SETTINGS);
        if took_key_out {
            let mut held: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
            assert!(
                held.as_object_mut().unwrap().remove("mine").is_some(),
                "{held}"
            );
            fs::write(&settings, serde_json::to_string_pretty(&held).unwrap()).unwrap();
        }

        let output = kendex(
            &home,
            &project,
            &["remove", "--commit", "--no-sweep", "guard"],
        );
        let text = said(&output);

        assert!(output.status.success(), "{took_key_out}: {text}");
        assert_eq!(settings.exists(), !took_key_out, "{took_key_out}: {text}");
        let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
        assert_eq!(
            files.lines().any(|line| line == SETTINGS),
            !took_key_out,
            "{took_key_out}: {files}\n{text}"
        );
        assert_eq!(
            text.contains(&format!(
                "{SETTINGS} held changes before this run, so the commit leaves it out"
            )),
            took_key_out,
            "{text}"
        );
        let left = match took_key_out {
            true => format!(" D {SETTINGS}\n"),
            false => String::new(),
        };
        assert_eq!(git(&project, &["status", "--porcelain"]), left, "{text}");
    }
}

/// How the last commit holds the install record when the remove runs.
#[derive(Debug, Clone, Copy)]
enum RecordAtHead {
    /// As the add committed it: the record says the hook writes a key in
    /// the settings file.
    AsAdded,
    /// Taken out of the last commit and left on disk: the inventory there
    /// still lists paths, and nothing at `HEAD` says which are shared.
    Absent,
    /// An older format this build does not read.
    OlderFormat,
}

/// A remove left uncommitted takes away the shared settings file the
/// committed hook was the last key in. The passive reading after it, which
/// no action reads for, still finds the file in the committed inventory,
/// but a shared file's deletion is never kendex's whole: it is not among
/// the files a commit or a restore takes whole. Where the record at `HEAD`
/// cannot say which files are shared, the reading claims no deletion the
/// record on disk does not name as a render, so the removed script is
/// left out with the settings file rather than taken on the inventory's
/// word.
#[test]
#[allow(clippy::unwrap_used)]
fn a_passive_reading_keeps_a_deleted_shared_file_out_of_the_renders() {
    const SETTINGS: &str = ".claude/settings.json";
    const LOCK: &str = ".kendex-lock.json";
    const SCRIPT: &str = ".claude/hooks/guard.sh";
    for (record, script_claimed) in [
        (RecordAtHead::AsAdded, true),
        (RecordAtHead::Absent, false),
        (RecordAtHead::OlderFormat, false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let source = scout_and_guard(&home).to_string_lossy().into_owned();
        let add = kendex(
            &home,
            &project,
            &[
                "add",
                "--yes",
                "--throwaway",
                "--commit",
                &source,
                "--hook",
                "guard",
            ],
        );
        assert!(add.status.success(), "{record:?}: {}", said(&add));
        let committed = git(
            &project,
            &["show", &format!("HEAD:{}", ".kendex-generated.json")],
        );
        assert!(committed.contains(SETTINGS), "{record:?}: {committed}");
        assert!(committed.contains(SCRIPT), "{record:?}: {committed}");
        match record {
            RecordAtHead::AsAdded => {}
            RecordAtHead::Absent => {
                git(&project, &["rm", "-q", "--cached", LOCK]);
                git(&project, &["commit", "-q", "-m", "drop record"]);
            }
            RecordAtHead::OlderFormat => {
                let valid = fs::read_to_string(project.join(LOCK)).unwrap();
                let current = format!("\"version\": {}", kendex_core::lock::LOCK_VERSION);
                assert_eq!(valid.matches(&current).count(), 1, "{valid}");
                fs::write(
                    project.join(LOCK),
                    valid.replace(&current, "\"version\": 10"),
                )
                .unwrap();
                git(&project, &["commit", "-q", "-am", "older record"]);
                fs::write(project.join(LOCK), &valid).unwrap();
            }
        }

        let remove = kendex(&home, &project, &["remove", "--no-sweep", "guard"]);
        assert!(remove.status.success(), "{record:?}: {}", said(&remove));
        assert!(
            !project.join(SETTINGS).exists(),
            "{record:?}: {}",
            said(&remove)
        );
        assert!(
            !project.join(SCRIPT).exists(),
            "{record:?}: {}",
            said(&remove)
        );

        let passive = kendex(&home, &project, &["generated-paths"]);
        let owned: Vec<String> = serde_json::from_slice(&passive.stdout)
            .unwrap_or_else(|error| panic!("{record:?}: {error}: {}", said(&passive)));
        assert!(
            !owned.iter().any(|path| path == SETTINGS),
            "{record:?}: {owned:?}"
        );
        assert_eq!(
            owned.iter().any(|path| path == SCRIPT),
            script_claimed,
            "{record:?}: {owned:?}"
        );
    }
}

/// A project whose root `AGENTS.md` carries a managed region the installed
/// bot-instructions fixture renders, with the package armed and locked so
/// an apply runs it: the body the last commit holds, then the body the
/// person left in the worktree.
///
/// The fixture answers `region-bounds` by calling the shipped launcher, so
/// no fixture carries a second copy of the bounds rule. Its `check` says the
/// files are current, and it is declared as the staged checker too: the
/// offer asks it over the commit before it offers the commit.
#[allow(clippy::unwrap_used)]
fn region_project(tmp: &tempfile::TempDir, committed: &str, working: &str) -> PathBuf {
    let home = rooted(tmp);
    let project = project(tmp);
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    executable(
        &script,
        &format!(
            "#!/bin/sh\nif [ \"$1\" = region-bounds ]; then\n  exec '{PACKAGE_LAUNCHER}' \"$@\"\nfi\nif [ \"$1\" = check ]; then\n  exit 0\nfi\nmkdir -p .github\nprintf 'updated review rules\\n' > .github/copilot-instructions.md\nif ! grep -q 'old generated rules' AGENTS.md; then\n  echo 'fixture-render: AGENTS.md has no generated rules' >&2\n  exit 1\nfi\nsed 's/old generated rules/new generated rules/' AGENTS.md > AGENTS.md.rendered && mv AGENTS.md.rendered AGENTS.md || exit 1\necho 'wrote .github/copilot-instructions.md'\nprintf 'wrote region AGENTS.md\\t## Code Review Rules\\n'\n"
        ),
    );
    fs::write(project.join("AGENTS.md"), committed).unwrap();
    fs::write(
        project.join(".agents/skills/bot-instructions/SKILL.md"),
        "---\nname: bot-instructions\ndescription: fixture\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n  staged-checker: scripts/bot-instructions check --staged\n---\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    fs::write(project.join("AGENTS.md"), working).unwrap();
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let env = kendex_core::env::Env::fake(&home, kendex_core::env::FakeOs::Linux);
    let mut lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..kendex_core::lock::Lock::default()
    };
    lock.entries.insert(
        kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::Skill,
            "bot-instructions",
            kendex_core::model::HarnessId::Codex,
        ),
        kendex_core::lock::LockEntry {
            name: "bot-instructions".to_owned(),
            kind: kendex_core::model::ItemKind::Skill,
            harness: kendex_core::model::HarnessId::Codex,
            source: "local".to_owned(),
            source_repo: "local".to_owned(),
            machine: Some(kendex_core::lock::MachineRecord {
                method: kendex_core::manifest::Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".to_owned(),
            }),
            source_hash: "fixture".to_owned(),
            source_commit: None,
            rendered_hash: Some("fixture".to_owned()),
            enabled: true,
            upstream_skills: None,
            emitted: Some(kendex_core::lock::EmittedArtifact {
                kind: kendex_core::model::ItemKind::Skill,
                name: "bot-instructions".to_owned(),
                paths: vec![project.join(".agents/skills/bot-instructions")],
            }),
            registration: None,
            output_style: None,
            reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
        },
    );
    kendex_core::lock::save(&kendex_core::lock::lock_path(&env, &scope), &lock).unwrap();
    let repo = kendex_core::guard::Repo::at(&project).unwrap();
    kendex_core::repo_effects::armed::arm(
        kendex_core::repo_effects::armed::record_dir(&repo, false),
        "bot-instructions",
    )
    .unwrap();
    project
}

/// The CLI apply door runs the installed bot renderer before it builds the
/// commit offer, so the same commit carries the engine and package outputs.
#[test]
fn apply_renders_and_commits_the_bot_instruction_surface() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = region_project(
        &tmp,
        "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
        "# App\n\nworking user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nworking note\n",
    );

    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        files
            .lines()
            .any(|path| path == ".github/copilot-instructions.md"),
        "the bot surface was absent from the CLI commit:\n{files}"
    );
    assert_eq!(
        git(&project, &["show", "HEAD:./AGENTS.md"]),
        "# App\n\nbase user text\n\n## Code Review Rules\n\nnew generated rules\n\n## Notes\n\nbase note\n"
    );
    assert_eq!(
        fs::read_to_string(project.join("AGENTS.md")).unwrap(),
        "# App\n\nworking user text\n\n## Code Review Rules\n\nnew generated rules\n\n## Notes\n\nworking note\n"
    );
}

/// The CLI prints the setup step after a successful unarmed apply. The
/// package script leaves a sentinel if it runs, so this also proves that the
/// output did not come from executing untrusted package code.
#[test]
fn an_unarmed_cli_apply_succeeds_names_setup_and_runs_no_package_code() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    executable(
        &script,
        "#!/bin/sh\nprintf ran > .bot-instructions-ran\necho 'wrote .github/copilot-instructions.md'\n",
    );
    fs::write(
        project.join(".agents/skills/bot-instructions/SKILL.md"),
        "---\nname: bot-instructions\ndescription: fixture\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n---\n",
    )
    .unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let env = kendex_core::env::Env::fake(&home, kendex_core::env::FakeOs::Linux);
    let package = project.join(".agents/skills/bot-instructions");
    let mut lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..kendex_core::lock::Lock::default()
    };
    lock.entries.insert(
        kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::Skill,
            "bot-instructions",
            kendex_core::model::HarnessId::Codex,
        ),
        kendex_core::lock::LockEntry {
            name: "bot-instructions".to_owned(),
            kind: kendex_core::model::ItemKind::Skill,
            harness: kendex_core::model::HarnessId::Codex,
            source: "local".to_owned(),
            source_repo: "local".to_owned(),
            machine: Some(kendex_core::lock::MachineRecord {
                method: kendex_core::manifest::Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".to_owned(),
            }),
            source_hash: "fixture".to_owned(),
            source_commit: None,
            rendered_hash: Some("fixture".to_owned()),
            enabled: true,
            upstream_skills: None,
            emitted: Some(kendex_core::lock::EmittedArtifact {
                kind: kendex_core::model::ItemKind::Skill,
                name: "bot-instructions".to_owned(),
                paths: vec![package],
            }),
            registration: None,
            output_style: None,
            reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
        },
    );
    kendex_core::lock::save(&kendex_core::lock::lock_path(&env, &scope), &lock).unwrap();

    let (output, text) = apply(&home, &project, &["--leave"]);

    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("use Set up on the bot-instructions package page"),
        "the CLI dropped the setup guidance: {text}"
    );
    assert!(
        !project.join(".bot-instructions-ran").exists(),
        "the unarmed CLI apply executed package code"
    );
}

/// A package whose check says its files are out of date holds the offer:
/// the commit is not offered, a flag naming it is refused with the
/// package's own words and exits 1, and a run with nobody to ask names the
/// setup rather than the flags that would commit. A project each, since
/// the fixture's render runs once.
#[test]
fn a_package_whose_check_fails_holds_the_commit() {
    for (flags, code, said) in [
        (
            &["--commit"][..],
            Some(1),
            &[
                "bot-instructions says its files in this repository are out of date:",
                "drift: .github/copilot-instructions.md differs from a fresh render",
                "committing now would carry those files out of date, so kendex does not offer the commit",
                "set it up here first",
                " · not committed",
            ][..],
        ),
        (&[][..], Some(0), &["set it up here first"][..]),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = held_project(&tmp);

        let (output, text) = apply(&home, &project, flags);

        assert_eq!(output.status.code(), code, "{flags:?}: {text}");
        for line in said {
            assert!(text.contains(line), "{flags:?}: missing {line:?}:\n{text}");
        }
        assert!(!text.contains("the commit was refused"), "{text}");
        assert!(!text.contains("run again with --commit"), "{text}");
        assert_eq!(head_subject(&project), "bot package", "{flags:?}");
    }
}

/// A set-up package that cannot be asked about the commit, because the
/// commit cannot be built for its check, refuses a flag's request and
/// leaves a run without one at its one line. The git directory the
/// candidate index is written under is made unwritable.
#[test]
fn a_commit_the_packages_cannot_be_asked_about_refuses_a_flag() {
    // Root writes through a mode bit, so the candidate is built and the
    // state this case is about is never reached on such a runner.
    if rustix::process::geteuid().is_root() {
        eprintln!("skipped: root writes through the unwritable git directory this case needs");
        return;
    }
    for (flags, code, refused) in [
        (&["--commit"][..], Some(1), true),
        (&[][..], Some(0), false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = region_project(
            &tmp,
            "# App\n\n## Code Review Rules\n\nold generated rules\n",
            "# App\n\n## Code Review Rules\n\nold generated rules\n",
        );
        let git_dir = project.join(".git");
        fs::set_permissions(&git_dir, fs::Permissions::from_mode(0o555)).unwrap();

        let (output, text) = apply(&home, &project, flags);
        // Writable again before any assertion can fail: a directory left
        // 0555 is one the temp dir cannot clean up.
        fs::set_permissions(&git_dir, fs::Permissions::from_mode(0o755)).unwrap();

        assert_eq!(output.status.code(), code, "{flags:?}: {text}");
        assert!(
            text.contains("the files kendex wrote could not be checked"),
            "{flags:?}: {text}"
        );
        assert!(text.contains(".git/kendex-candidate-"), "{flags:?}: {text}");
        assert_eq!(
            text.contains(" · not committed"),
            refused,
            "{flags:?}: {text}"
        );
        assert_eq!(head_subject(&project), "bot package", "{flags:?}");
    }
}

/// A [`region_project`] whose package's check says its files are out of
/// date.
#[allow(clippy::unwrap_used)]
fn held_project(tmp: &tempfile::TempDir) -> PathBuf {
    let project = region_project(
        tmp,
        "# App\n\n## Code Review Rules\n\nold generated rules\n",
        "# App\n\n## Code Review Rules\n\nold generated rules\n",
    );
    let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
    let renders = fs::read_to_string(&script).unwrap();
    executable(
        &script,
        &renders.replacen(
            "#!/bin/sh\n",
            "#!/bin/sh\nif [ \"$1\" = check ]; then\n  echo 'bot-instructions: findings=1' >&2\n  echo 'drift: .github/copilot-instructions.md differs from a fresh render' >&2\n  exit 1\nfi\n",
            1,
        ),
    );
    project
}

/// A checkout that installed bot-instructions from a catalog and committed
/// it, with no setup record, as a lane's fresh work tree is. The package
/// then changes in the catalog, so the next apply rewrites its tree. Its
/// render writes the review file, and its check passes once that file is
/// there.
#[allow(clippy::unwrap_used)]
fn unarmed_consumer(tmp: &tempfile::TempDir) -> PathBuf {
    let home = rooted(tmp);
    let project = home.join("dev/app");
    let package = project.join("catalog/skills/bot-instructions");
    let declaration = |description: &str| {
        format!(
            "---\nname: bot-instructions\ndescription: {description}\nrepo-effects:\n  summary: fixture render\n  writes: ['.github/copilot-instructions.md']\n  installer: scripts/bot-instructions render\n  checker: scripts/bot-instructions check\n---\n"
        )
    };
    fs::create_dir_all(&package).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.bot-instructions]\nsource = \"cat\"\n",
    )
    .unwrap();
    fs::write(package.join("SKILL.md"), declaration("first rules")).unwrap();
    executable(
        &package.join("scripts/bot-instructions"),
        "#!/bin/sh\nif [ \"$1\" = check ]; then\n  test -f .github/copilot-instructions.md\n  exit\nfi\nif [ \"$2\" = --dry-run ]; then\n  echo 'would write .github/copilot-instructions.md'\n  exit 0\nfi\nmkdir -p .github\necho rules >.github/copilot-instructions.md\necho 'wrote .github/copilot-instructions.md'\n",
    );
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "user.email", "t@t"]);
    git(&project, &["config", "user.name", "t"]);
    git(&project, &["config", "commit.gpgsign", "false"]);
    let (output, text) = apply(&home, &project, &["--leave"]);
    assert!(output.status.success(), "{text}");
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "bot package"]);
    fs::write(package.join("SKILL.md"), declaration("second rules")).unwrap();
    git(&project, &["commit", "-q", "-am", "catalog"]);
    project
}

/// A run that rewrites a package nobody set up in this checkout is held
/// at the commit. `--allow-repo-effects` on a run that commits sets the
/// package up there, so the one command commits the package with its
/// render. Without a commit choice the flag sets nothing up, and on a verb
/// that does not carry it nothing is set up. Which verbs carry the flag is
/// `the_flags_are_read_off_the_verb_the_person_ran`.
#[test]
#[allow(clippy::unwrap_used)]
fn allow_repo_effects_sets_up_a_held_package_and_commits_its_render() {
    for (args, code, set_up) in [
        (
            &["apply", "--yes", "--commit", "--allow-repo-effects"][..],
            Some(0),
            true,
        ),
        (&["apply", "--yes", "--commit"][..], Some(1), false),
        (
            &["apply", "--yes", "--allow-repo-effects"][..],
            Some(0),
            false,
        ),
        (
            &["refresh", "--yes", "--scope", "project", "--commit"][..],
            Some(1),
            false,
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = unarmed_consumer(&tmp);

        let output = kendex(&home, &project, args);
        let text = said(&output);

        assert_eq!(output.status.code(), code, "{args:?}: {text}");
        let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
        let carried = |path: &str| files.lines().any(|line| line == path);
        assert_eq!(
            carried(".github/copilot-instructions.md"),
            set_up,
            "{args:?}: {files}\n{text}"
        );
        assert_eq!(
            carried(".claude/skills/bot-instructions/SKILL.md"),
            set_up,
            "{args:?}: {files}\n{text}"
        );
        assert_eq!(head_subject(&project) != "catalog", set_up, "{args:?}");
        assert_eq!(
            project.join(".git/kendex/armed").exists(),
            set_up,
            "{args:?}: {text}"
        );
        assert_eq!(
            project.join(".github/copilot-instructions.md").exists(),
            set_up,
            "{args:?}: {text}"
        );
    }
}

/// A manifest edit, which kendex never commits, holds the commit only
/// where the package's check over that commit reads it: its declared
/// staged checker, `check --staged`, run against the index the commit
/// hands its hooks, where the manifest is the last commit's. One row whose check compares the staged
/// manifest with the working one, held with the manifest and the check's
/// words named and no setup offered; one whose check does not read it,
/// committed.
#[test]
fn a_manifest_edit_holds_the_commit_only_where_the_check_over_it_reads_it() {
    let reads = "if [ \"$1\" = check ]; then\n  if [ \"$2\" = --staged ] && [ \"$(git show :kendex.toml)\" != \"$(cat kendex.toml)\" ]; then\n    echo 'bot-instructions: findings=1' >&2\n    echo 'drift: kendex.toml' >&2\n    exit 1\n  fi\n  exit 0\nfi\n";
    for (what, check, code, said) in [
        (
            "the check reads the manifest",
            Some(reads),
            Some(1),
            &[
                "the commit would carry some of bot-instructions's changed files and leave these out:",
                "    kendex.toml",
                "bot-instructions's check over the commit says:",
                "    drift: kendex.toml",
                "they are left as diffs; commit them together yourself",
            ][..],
        ),
        ("the check does not read it", None, Some(0), &[][..]),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = region_project(
            &tmp,
            "# App\n\n## Code Review Rules\n\nold generated rules\n",
            "# App\n\n## Code Review Rules\n\nold generated rules\n",
        );
        if let Some(check) = check {
            let script = project.join(".agents/skills/bot-instructions/scripts/bot-instructions");
            let text = fs::read_to_string(&script).unwrap();
            let passes = "if [ \"$1\" = check ]; then\n  exit 0\nfi\n";
            assert_eq!(
                text.matches(passes).count(),
                1,
                "{what}: the fixture's check"
            );
            executable(&script, &text.replacen(passes, check, 1));
        }
        let manifest = project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        fs::write(
            &manifest,
            format!("{text}\n[bot-instructions]\nschema = 1\n"),
        )
        .unwrap();

        let (output, text) = apply(&home, &project, &["--commit"]);

        assert_eq!(output.status.code(), code, "{what}: {text}");
        for line in said {
            assert!(text.contains(line), "{what}: missing {line:?}:\n{text}");
        }
        assert!(!text.contains("set it up here first"), "{what}: {text}");
        assert_eq!(
            head_subject(&project) == "bot package",
            check.is_some(),
            "{what}: {text}"
        );
    }
}

/// A pre-commit chain that refuses prints every lane it ran, and git hands
/// back its stdout before its stderr. The refusal leads with the findings
/// block, then the rest of what git said for the log.
#[test]
fn a_commit_refusal_leads_with_its_findings_block() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    executable(
        &project.join(".git/hooks/pre-commit"),
        "#!/bin/sh\necho 'commit-guards: step=doc-limits'\necho '  === pre-commit: doc-limits'\necho 'commit-guards: result=1'\necho 'bot-instructions: findings=1' >&2\necho 'drift: AGENTS.md differs from a fresh render' >&2\nexit 1\n",
    );
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    let at = |line: &str| {
        text.find(line)
            .unwrap_or_else(|| panic!("missing {line:?}:\n{text}"))
    };
    assert!(
        at("the repository's commit check found problems:") < at("bot-instructions: findings=1"),
        "{text}"
    );
    assert!(
        at("drift: AGENTS.md differs from a fresh render") < at("the rest of what git said:"),
        "{text}"
    );
    assert!(
        at("the rest of what git said:") < at("commit-guards: step=doc-limits"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
}

/// An add that skipped the agent it named, in a run with no terminal,
/// ends on the skip's own status; where the repository's pre-commit hook
/// also refused the commit the run asked for, the refused commit's 1 is
/// the status, as for any run whose commit was refused.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_commit_keeps_its_status_over_a_skip() {
    for (refusing, status) in [(false, 3), (true, 1)] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let catalog = scout_and_guard(&home);
        fs::create_dir_all(project.join(".claude/agents")).unwrap();
        fs::write(
            project.join(".claude/agents/scout.md"),
            "---\nname: scout\ndescription: mine\n---\nWritten by hand.\n",
        )
        .unwrap();
        if refusing {
            executable(
                &project.join(".git/hooks/pre-commit"),
                "#!/bin/sh\necho 'commit-msg: no' >&2\nexit 1\n",
            );
        }
        let source = catalog.to_string_lossy().into_owned();
        let args = [
            "add",
            "--yes",
            "--throwaway",
            "--commit",
            &source,
            "--agent",
            "scout",
        ];
        let output = kendex(&home, &project, &args);
        let text = said(&output);
        assert_eq!(
            output.status.code(),
            Some(status),
            "refusing={refusing}: {text}"
        );
        assert!(
            text.lines()
                .any(|line| line == "skipped-on-conflict=agent scout"),
            "refusing={refusing}: {text}"
        );
    }
}

/// A flag naming a choice a precondition removed refuses with that
/// precondition's reason, commits nothing, and exits 1; the verb's writes
/// still stand.
#[test]
fn a_flag_naming_a_choice_not_on_offer_is_refused_with_the_reason() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--push"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no push: this repository has no remote"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
    assert!(
        project.join(".claude/agents/offer-file.md").exists(),
        "the write did not stand"
    );

    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no pull request: this repository has no remote"),
        "{text}"
    );

    origin(&project, "open-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(
        text.contains("no pull request: pull request #41 is already open for this branch"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
}

/// The push route lands on the chosen remote, and a remote that refuses
/// is quoted whole with the commit named and left where it is.
#[test]
fn the_push_flag_pushes_or_reports_the_remotes_refusal() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let bare = origin(&project, "plain-origin");
    let (output, text) = apply(&home, &project, &["--push"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 4 files as "), "{text}");
    assert!(text.contains("pushed to origin/main"), "{text}");
    assert!(
        text.contains(" · committed and pushed 4 files"),
        "no ledger part: {text}"
    );
    assert_eq!(
        git(&project, &["rev-parse", "HEAD"]),
        git(&project, &["rev-parse", "origin/main"])
    );

    drop(bare);
    // A fresh checkout whose remote refuses the push: the commit stands
    // and the remote's words are quoted.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    let bare = origin(&project, "plain-origin");
    executable(
        &bare.join("hooks/pre-receive"),
        "#!/bin/sh\necho 'GH006: Protected branch update failed for refs/heads/main.' >&2\nexit 1\n",
    );
    let before = git(&project, &["rev-parse", "HEAD"]);
    let (output, text) = apply(&home, &project, &["--push"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("committed 4 files as "), "{text}");
    assert!(text.contains("the push was refused"), "{text}");
    assert!(text.contains("git said:"), "{text}");
    assert!(
        text.contains("GH006: Protected branch update failed"),
        "{text}"
    );
    assert!(
        text.contains("the commit is on main in this checkout; kendex did not undo it"),
        "{text}"
    );
    assert!(
        text.contains(" · committed, not pushed"),
        "no ledger part: {text}"
    );
    assert_ne!(
        git(&project, &["rev-parse", "HEAD"]),
        before,
        "the commit was undone"
    );
}

/// A bare repository the project calls `origin`, fetched from `url` and
/// pushed to at `push`, an `ssh://` URL. `url` is what every `gh` call but
/// the rules read is bound to, and `push` is what the rules read is bound
/// to; kendex's git runs the push through a fake ssh, handed to it as
/// `GIT_SSH_COMMAND`, that serves the host's `/acme/<name>.git` from the
/// bare repository beside the project.
#[allow(clippy::unwrap_used)]
fn hosted_origin(project: &Path, url: &str, push: &str) -> PathBuf {
    let dir = project.parent().unwrap();
    let bare = dir.join(push.rsplit('/').next().unwrap());
    git(
        project,
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            &bare.to_string_lossy(),
        ],
    );
    let ssh = dir.join("fake-ssh");
    executable(
        &ssh,
        &format!(
            "#!/bin/sh\nfor a in \"$@\"; do last=\"$a\"; done\nexec sh -c \"$(printf '%s' \"$last\" | sed \"s#'/acme/#'{}/#\")\"\n",
            dir.display()
        ),
    );
    git(project, &["config", "ssh.variant", "simple"]);
    git(project, &["remote", "add", "origin", url]);
    git(project, &["config", "remote.origin.pushurl", push]);
    git(project, &["push", "-q", &bare.to_string_lossy(), "main"]);
    bare
}

/// One run of the rules test: the remote and the refusal it answers with,
/// the flag, and what the run must and must not say.
struct RulesRow {
    what: &'static str,
    remote: &'static str,
    /// Where the push goes, and what the branch-rules read is bound to.
    push: &'static str,
    /// A pre-receive hook on the remote, refusing the way GitHub does.
    refuses: &'static str,
    flag: &'static str,
    exit: i32,
    committed: bool,
    says: &'static [&'static str],
    not: &'static [&'static str],
}

const PR_RULE: &str = "echo 'error: GH013: Repository rule violations found for refs/heads/main.' >&2\necho '- Changes must be made through a pull request.' >&2\nexit 1\n";
const PUSH_PROTECTION: &str = "echo 'error: GH013: Repository rule violations found for refs/heads/main.' >&2\necho '- GITHUB PUSH PROTECTION' >&2\necho '  - Push cannot contain secrets' >&2\nexit 1\n";
const HINT: &str = "run again with --pull-request to commit on a new branch and open one";
const RULES_LINE: &str = "main on origin accepts changes only through a pull request";

const RULES_ROWS: [RulesRow; 9] = [
    RulesRow {
        what: "rules that take a pull request",
        remote: "https://github.com/acme/ruled-origin.git",
        push: "ssh://git@github.com/acme/ruled-origin.git",
        refuses: "",
        flag: "--push",
        exit: 1,
        committed: false,
        says: &[
            "no push: this branch's rules on GitHub accept changes only through a pull request",
            HINT,
        ],
        not: &[],
    },
    RulesRow {
        what: "the same rules with a pull request already open",
        remote: "https://github.com/acme/open-ruled-origin.git",
        push: "ssh://git@github.com/acme/open-ruled-origin.git",
        refuses: "",
        flag: "--push",
        exit: 1,
        committed: false,
        says: &[
            "no push: this branch's rules on GitHub accept changes only through a pull request",
        ],
        not: &[HINT],
    },
    RulesRow {
        what: "the route those rules allow",
        remote: "https://github.com/acme/ruled-origin.git",
        push: "ssh://git@github.com/acme/ruled-origin.git",
        refuses: "",
        flag: "--pull-request",
        exit: 0,
        committed: true,
        says: &["opened https://github.com/acme/site/pull/41"],
        not: &[],
    },
    RulesRow {
        what: "rules on an Enterprise host",
        remote: "https://ghe.example.test/acme/ruled-origin.git",
        push: "ssh://git@ghe.example.test/acme/ruled-origin.git",
        refuses: "",
        flag: "--push",
        exit: 1,
        committed: false,
        says: &[
            "no push: this branch's rules on GitHub accept changes only through a pull request",
        ],
        not: &[],
    },
    RulesRow {
        what: "a push to a fork whose upstream takes a pull request",
        remote: "https://github.com/acme/ruled-origin.git",
        push: "ssh://git@github.com/acme/fork-origin.git",
        refuses: "",
        flag: "--push",
        exit: 0,
        committed: true,
        says: &["pushed to origin/main"],
        not: &["no push:"],
    },
    RulesRow {
        what: "a person the ruleset lets past",
        remote: "https://github.com/acme/bypass-ruled-origin.git",
        push: "ssh://git@github.com/acme/bypass-ruled-origin.git",
        refuses: "",
        flag: "--push",
        exit: 0,
        committed: true,
        says: &["pushed to origin/main"],
        not: &[],
    },
    RulesRow {
        what: "rules that cannot be read",
        remote: "https://github.com/acme/plain-origin.git",
        push: "ssh://git@github.com/acme/plain-origin.git",
        refuses: "",
        flag: "--push",
        exit: 0,
        committed: true,
        says: &["pushed to origin/main"],
        not: &[],
    },
    RulesRow {
        what: "GitHub refusing the push for want of a pull request",
        remote: "https://u:secret@github.com/acme/plain-origin.git",
        push: "ssh://git@github.com/acme/plain-origin.git",
        refuses: PR_RULE,
        flag: "--push",
        exit: 1,
        committed: true,
        says: &[
            "remote: error: GH013: Repository rule violations found for refs/heads/main.",
            "the commit is on main in this checkout; kendex did not undo it",
            RULES_LINE,
            "to open one from this commit yourself:",
            "'push' 'origin' 'HEAD:refs/heads/kendex/renders'",
            "'--repo' 'https://github.com/acme/plain-origin.git' '--head' 'kendex/renders' '--base' 'main' '--title' 'chore: kendex apply'",
        ],
        not: &["secret"],
    },
    RulesRow {
        what: "GitHub refusing the push for another rule",
        remote: "https://github.com/acme/plain-origin.git",
        push: "ssh://git@github.com/acme/plain-origin.git",
        refuses: PUSH_PROTECTION,
        flag: "--push",
        exit: 1,
        committed: true,
        says: &["GITHUB PUSH PROTECTION"],
        not: &[RULES_LINE, "'push' 'origin'"],
    },
];

/// The branch's rules decide the push before anything is committed. Rules
/// that take changes only through a pull request refuse `--push`, naming
/// the flag for the route they allow where it is on offer, and that route
/// opens one; a person the ruleset lets past pushes; rules that cannot be
/// read leave the push as it was. The read is bound to where the push
/// goes, its host included, so a fork's rules decide a push to the fork.
/// A push GitHub then refuses for want of a pull request prints the
/// commands that open one from the commit, without the remote's
/// credentials; any other refusal prints neither.
#[test]
fn the_branch_rules_are_read_before_a_push_and_a_refusal_under_them_names_the_way_on() {
    for row in RULES_ROWS {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let bare = hosted_origin(&project, row.remote, row.push);
        if !row.refuses.is_empty() {
            executable(
                &bare.join("hooks/pre-receive"),
                &format!("#!/bin/sh\n{}", row.refuses),
            );
        }
        let (output, text) = apply(&home, &project, &[row.flag]);
        assert_eq!(output.status.code(), Some(row.exit), "{}: {text}", row.what);
        for line in row.says {
            assert!(text.contains(line), "{}: {line}: {text}", row.what);
        }
        for line in row.not {
            assert!(!text.contains(line), "{}: {line}: {text}", row.what);
        }
        // The printed push names the project it pushes from, so a line
        // pasted into a terminal standing elsewhere pushes this commit.
        if row.refuses == PR_RULE {
            let from = format!("    git '-C' '{}' 'push' 'origin'", project.display());
            assert!(text.contains(&from), "{}: {from}: {text}", row.what);
        }
        assert_eq!(
            head_subject(&project) != "files",
            row.committed,
            "{}: {text}",
            row.what
        );
        let host = row
            .push
            .rsplit('@')
            .next()
            .unwrap()
            .split('/')
            .next()
            .unwrap();
        let asked = fs::read_to_string(home.join("fake-bin/calls")).unwrap_or_default();
        assert!(
            asked.contains(&format!(
                "GH_REPO={} api --hostname {host} repos/{{owner}}/{{repo}}/rules/branches/main",
                row.push
            )),
            "{}: the rules were not read from {host}: {asked}",
            row.what
        );
    }
}

/// The pull-request route: a branch of its own, the commit, the push, the
/// pull request, and the checkout left on the branch; a `gh` that refuses
/// is quoted and the branch named for the person to open it themselves.
#[test]
fn the_pull_request_flag_opens_one_or_names_the_branch_gh_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    origin(&project, "plain-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 4 files as "), "{text}");
    assert!(text.contains(" on kendex/renders"), "{text}");
    assert!(text.contains("pushed to origin/kendex/renders"), "{text}");
    assert!(
        text.contains("opened https://github.com/acme/site/pull/41"),
        "{text}"
    );
    assert!(
        text.contains("this checkout is now on kendex/renders"),
        "{text}"
    );
    assert!(
        text.contains(" · committed 4 files, pull request open"),
        "no ledger part: {text}"
    );
    assert!(home.join("fake-bin/calls").exists(), "gh was never asked");
    assert_eq!(
        git(&project, &["symbolic-ref", "--short", "HEAD"]).trim(),
        "kendex/renders"
    );
    assert_eq!(
        git(&project, &["rev-parse", "main"]),
        git(&project, &["rev-parse", "origin/main"]),
        "main gained the commit"
    );

    let refusing = tempfile::tempdir().unwrap();
    let home = rooted(&refusing);
    let project = self::project(&refusing);
    origin(&project, "refuse-origin");
    let (output, text) = apply(&home, &project, &["--pull-request"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("pushed to origin/kendex/renders"), "{text}");
    assert!(text.contains("the pull request was refused"), "{text}");
    assert!(text.contains("gh said:"), "{text}");
    assert!(
        text.contains("GitHub Actions is not permitted to create or approve pull requests"),
        "{text}"
    );
    assert!(
        text.contains("the branch kendex/renders is on origin; open the pull request yourself"),
        "{text}"
    );
    assert!(
        text.contains(" · committed and pushed, no pull request"),
        "no ledger part: {text}"
    );
}

/// A hook's refusal reaches the person whole, nothing is committed, and
/// the index ends as it began.
#[test]
fn a_hooks_refusal_is_quoted_whole_and_nothing_is_committed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    executable(
        &project.join(".git/hooks/pre-commit"),
        "#!/bin/sh\necho 'commit-msg: crates/ changed without a changelog entry' >&2\necho '  write one of: changelog.d/*/*.md' >&2\nexit 1\n",
    );
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("the commit was refused"), "{text}");
    assert!(text.contains("git said:"), "{text}");
    assert!(
        text.contains("commit-msg: crates/ changed without a changelog entry"),
        "{text}"
    );
    assert!(text.contains("write one of: changelog.d/*/*.md"), "{text}");
    assert_eq!(head_subject(&project), "files");
    assert!(text.contains(" · not committed"), "no ledger part: {text}");
    let status = git(&project, &["status", "--porcelain"]);
    assert!(
        status.contains("?? .claude/agents/offer-file.md"),
        "still staged: {status}"
    );

    // The same refusal through the other verb that closes on a ledger, in
    // a checkout that still has the agent to write: its own failure line, the
    // scope's ledger still closed, and never counted as a failure of the
    // verb.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = self::project(&tmp);
    executable(
        &project.join(".git/hooks/pre-commit"),
        "#!/bin/sh\necho 'commit-msg: no' >&2\nexit 1\n",
    );
    let output = kendex(&home, &project, &["refresh", "--yes", "--commit"]);
    let text = said(&output);
    assert_eq!(output.status.code(), Some(1), "{text}");
    assert!(text.contains("the commit was refused"), "{text}");
    assert!(text.contains(" · not committed"), "no ledger line: {text}");
    assert!(!text.contains("refresh failed:"), "{text}");
    assert!(!text.contains("already said"), "{text}");
}

/// The two states the offer cannot be made in print one line each, and a
/// flag does not change that.
#[test]
fn a_detached_head_or_an_operation_in_progress_prints_one_line() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(project.join(".git/MERGE_HEAD"), "").unwrap();
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("4 files kendex wrote are not committed; a merge is in progress"),
        "{text}"
    );
    fs::remove_file(project.join(".git/MERGE_HEAD")).unwrap();

    let head = git(&project, &["rev-parse", "HEAD"]);
    git(&project, &["checkout", "-q", "--detach", head.trim()]);
    // The ignore file the first run wrote is pending from before this one,
    // which writes nothing, so only the renders are counted.
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("3 files kendex wrote are not committed; this checkout is on no branch"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "files");
}

/// A read the offer is built from that will not run leaves the offer
/// unbuildable: one line, git's words, and the verb's own exit.
#[test]
fn a_repository_git_cannot_read_says_the_files_could_not_be_checked() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(project.join(".git/HEAD"), "not a ref\n").unwrap();
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("the files kendex wrote could not be checked"),
        "{text}"
    );
    assert!(text.contains("git said:"), "{text}");
    assert!(text.contains("fatal:"), "{text}");
}

/// `commit-offer = "off"` turns off the asking, not the choices: no line
/// without a flag, and a flag still answers.
#[test]
fn the_setting_turns_off_the_asking_and_not_the_flags() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let settings = kendex_core::env::Env::host_rooted(&home).settings_file();
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "schema = 1\ncommit-offer = \"off\"\n").unwrap();
    let (output, text) = apply(&home, &project, &[]);
    assert!(output.status.success(), "{text}");
    assert!(!text.contains("not committed"), "{text}");
    // The first run wrote the ignore file and left it pending; this run
    // writes nothing, so it carries the renders alone.
    let (output, text) = apply(&home, &project, &["--commit"]);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("committed 3 files as "), "{text}");
}

/// Two of the group together is refused before the verb writes anything.
#[test]
fn two_answers_at_once_are_refused_before_the_write() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let (output, text) = apply(&home, &project, &["--commit", "--leave"]);
    assert!(!output.status.success(), "{text}");
    assert!(
        !project.join(".claude/agents/offer-file.md").exists(),
        "the verb wrote before refusing"
    );
}

/// A verb that applies more than one report into the project: the first
/// report has nothing kendex owns changed and records no answer, so the
/// report that renders the hook still reaches the offer.
#[test]
fn a_verbs_later_report_still_reaches_the_offer() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let output = kendex(&home, &project, &["drift-hook", "--yes", "--commit"]);
    let text = said(&output);
    assert!(output.status.success(), "{text}");
    assert!(
        text.contains("committed "),
        "the hook's render was not offered: {text}"
    );
    assert_ne!(
        head_subject(&project),
        "files",
        "nothing was committed: {text}"
    );
}

/// The hosted close helper asks through the hidden machine command, so the
/// answer must be the same whole-file set the commit offer owns. A deletion
/// remains owned through the inventory committed before the current plan.
#[test]
fn generated_paths_reports_changed_and_removed_whole_file_renders() {
    for case in ["changed", "removed"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let (output, text) = apply(&home, &project, &["--leave"]);
        assert!(output.status.success(), "{case}: {text}");
        let rendered = fs::read(project.join(".claude/agents/offer-file.md")).unwrap();
        git(
            &project,
            &[
                "add",
                ".claude/agents/offer-file.md",
                ".kendex-generated.json",
                ".kendex-lock.json",
            ],
        );
        git(&project, &["commit", "-q", "-m", "renders"]);
        match case {
            "changed" => {
                fs::write(
                    project.join(".claude/agents/offer-file.md"),
                    "stale committed render\n",
                )
                .unwrap();
                git(&project, &["add", ".claude/agents/offer-file.md"]);
                git(&project, &["commit", "-q", "-m", "stale render"]);
                fs::write(project.join(".claude/agents/offer-file.md"), rendered).unwrap();
            }
            "removed" => fs::remove_file(project.join(".claude/agents/offer-file.md")).unwrap(),
            _ => unreachable!(),
        }
        let result = kendex(&home, &project, &["generated-paths"]);
        assert!(result.status.success(), "{case}: {}", said(&result));
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&result.stdout).unwrap(),
            [".claude/agents/offer-file.md"],
            "{case}"
        );
    }
}

/// `generated-paths` names only what kendex owns whole. Its consumer
/// restores every name it is given whole, and a file kendex owns one
/// region of carries the person's own bytes outside that region.
///
/// The region is a real one: the installed package renders it and the
/// apply commits it region-wise. The verb's set comes from the engine's
/// plan, which carries no region, so the row holds whether the region
/// alone changed or the person also edited around it.
#[test]
#[allow(clippy::unwrap_used)]
fn generated_paths_omits_a_file_kendex_owns_only_a_region_of() {
    for case in ["mixed", "region-only"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = region_project(
            &tmp,
            "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
            "# App\n\nbase user text\n\n## Code Review Rules\n\nold generated rules\n\n## Notes\n\nbase note\n",
        );
        let (output, text) = apply(&home, &project, &["--commit"]);
        assert!(output.status.success(), "{case}: {text}");
        // The whole-file render this row expects to see reported: the
        // commit is given stale bytes while the worktree keeps the
        // rendered ones, so git calls the path changed and the agent itself
        // stays in sync.
        let rendered = fs::read(project.join(".claude/agents/offer-file.md")).unwrap();
        fs::write(
            project.join(".claude/agents/offer-file.md"),
            "stale committed render\n",
        )
        .unwrap();
        git(&project, &["add", ".claude/agents/offer-file.md"]);
        git(&project, &["commit", "-q", "-m", "stale render"]);
        fs::write(project.join(".claude/agents/offer-file.md"), rendered).unwrap();
        // The region differs from the commit in both rows; the mixed row
        // also carries a user edit outside it, which is the case a
        // whole-file restore would throw away.
        let edited = match case {
            "mixed" => {
                "# App\n\nworking user text\n\n## Code Review Rules\n\nhand-edited rules\n\n## Notes\n\nbase note\n"
            }
            _ => {
                "# App\n\nbase user text\n\n## Code Review Rules\n\nhand-edited rules\n\n## Notes\n\nbase note\n"
            }
        };
        fs::write(project.join("AGENTS.md"), edited).unwrap();
        let result = kendex(&home, &project, &["generated-paths"]);
        assert!(result.status.success(), "{case}: {}", said(&result));
        assert_eq!(
            serde_json::from_slice::<Vec<String>>(&result.stdout).unwrap(),
            [".claude/agents/offer-file.md"],
            "{case}"
        );
    }
}
