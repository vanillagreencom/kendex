//! `kendex project list --json`: the document a consumer such as Jarvis
//! routes a write by, which gives each registered folder, its state and a
//! worktree's main checkout as separate values.
//!
//! Unix only: a folder name holding a newline is the case under test, and
//! Windows refuses one.
#![cfg(unix)]

use crate::test_util::{self, git, rooted};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::{Value, json};

#[allow(clippy::expect_used, reason = "fixture precondition")]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("TMPDIR", std::env::temp_dir())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn register(home: &Path, folder: &Path) {
    let added = kendex(home, &["project", "add", folder.to_str().unwrap()]);
    assert!(
        added.status.success(),
        "{}",
        String::from_utf8_lossy(&added.stderr)
    );
}

/// A repository with one commit at `main` and a linked worktree of it at
/// `linked`.
#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn repository_with_worktree(main: &Path, linked: &Path) {
    fs::create_dir_all(main).unwrap();
    git(main, &["init", "--quiet", "-b", "main"]);
    fs::write(main.join("README.md"), "main\n").unwrap();
    git(main, &["add", "-A"]);
    git(main, &["commit", "--quiet", "-m", "one"]);
    git(
        main,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "lane",
            linked.to_str().unwrap(),
        ],
    );
}

/// Every registered folder is one entry whose `folder` is the registered
/// path byte for byte, whatever the human row would make of its name:
/// a real newline and a backslash followed by `n` are two folders, and a
/// folder named like a worktree note is a plain folder. The worktree and
/// each state that is not `ok` are read from the field, not the name, and
/// a main checkout whose name holds a newline is named whole, not as the
/// folder its first line names. A bare repository is no checkout, so a
/// worktree added from one has no main to name.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn each_registered_folder_is_one_exact_entry() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let dev = home.join("dev");
    let main = dev.join("app");
    let linked = dev.join("lane");
    repository_with_worktree(&main, &linked);
    let split_main = dev.join("split\nmain");
    let split_linked = dev.join("split-lane");
    repository_with_worktree(&split_main, &split_linked);
    fs::create_dir_all(dev.join("split")).unwrap();
    let bare = dev.join("bare.git");
    let bare_linked = dev.join("bare-lane");
    git(
        &dev,
        &[
            "clone",
            "--quiet",
            "--bare",
            main.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    git(
        &bare,
        &[
            "worktree",
            "add",
            "--quiet",
            bare_linked.to_str().unwrap(),
            "main",
        ],
    );

    let ok = |folder: PathBuf| (folder, "ok", Value::Null);
    let rows: Vec<(PathBuf, &str, Value)> = vec![
        ok(dev.join("line\nbreak")),
        ok(dev.join("line\\nbreak")),
        ok(dev.join("plain  (worktree of app)")),
        (main.clone(), "ok", Value::Null),
        (
            split_linked.clone(),
            "ok",
            json!({ "main": split_main.to_str().unwrap() }),
        ),
        (
            linked.clone(),
            "ok",
            json!({ "main": main.to_str().unwrap() }),
        ),
        (bare_linked.clone(), "ok", json!({ "main": null })),
        (dev.join("gone"), "folder-not-found", Value::Null),
        (dev.join("now-a-file"), "not-a-folder", Value::Null),
    ];
    for (folder, _, _) in &rows {
        fs::create_dir_all(folder).unwrap();
        register(&home, folder);
    }
    fs::remove_dir(dev.join("gone")).unwrap();
    fs::remove_dir(dev.join("now-a-file")).unwrap();
    fs::write(dev.join("now-a-file"), "").unwrap();

    let listed = kendex(&home, &["project", "list", "--json"]);
    assert!(
        listed.status.success(),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    let mut entries: Vec<Value> = serde_json::from_slice(&listed.stdout).unwrap();
    let mut expected: Vec<Value> = rows
        .into_iter()
        .map(|(folder, state, worktree)| {
            json!({
                "folder": folder.to_str().unwrap(),
                "state": state,
                "worktree": worktree,
            })
        })
        .collect();
    let by_folder = |entry: &Value| entry["folder"].as_str().unwrap().to_owned();
    entries.sort_by_key(by_folder);
    expected.sort_by_key(by_folder);
    assert_eq!(entries, expected);
}

/// Where git cannot say whether a registered folder is in a linked
/// worktree, the document is refused naming that folder rather than
/// printed with `worktree: null`, which a consumer would read as "not a
/// worktree" and route a write to the folder itself. The key leads the
/// refusal because a program reads it; the cause after it is git's.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn a_folder_git_cannot_answer_for_refuses_the_document() {
    type Break = fn(&Path);
    let cases: [(&str, Break); 2] = [
        ("malformed config", |folder| {
            git(folder, &["init", "--quiet"]);
            let config = folder.join(".git/config");
            let mut text = fs::read_to_string(&config).unwrap();
            text.push_str("[\n");
            fs::write(config, text).unwrap();
        }),
        ("worktree whose main checkout is gone", |folder| {
            let gone = folder.parent().unwrap().join("moved/.git/worktrees/lane");
            fs::write(folder.join(".git"), format!("gitdir: {}\n", gone.display())).unwrap();
        }),
    ];
    for (case, break_it) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let folder = home.join("dev/app");
        fs::create_dir_all(&folder).unwrap();
        register(&home, &folder);
        break_it(&folder);

        let listed = kendex(&home, &["project", "list", "--json"]);
        let stderr = String::from_utf8_lossy(&listed.stderr);
        assert!(!listed.status.success(), "{case}: {stderr}");
        assert!(listed.stdout.is_empty(), "{case}: {listed:?}");
        let key = format!("Error: project-list-unread={}\n", folder.display());
        assert!(stderr.starts_with(&key), "{case}: {stderr}");
    }
}
