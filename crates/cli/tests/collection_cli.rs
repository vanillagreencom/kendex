//! The collection form of the add verb end to end against an isolated
//! home: a fresh subscription rides in the members' own plan, so a
//! collection the install refuses leaves the scope subscribed to nothing.
//! The collection resolver is a local HTTP responder and the repository a
//! local git upstream, reached through `KENDEX_API` and `KENDEX_GIT_BASE`.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, api: &str, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_API", api)
        .env("KENDEX_GIT_BASE", format!("file://{}/git", home.display()))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

/// git with the caller's environment dropped: run from a commit hook,
/// `GIT_DIR` and friends point at the repository being committed to.
#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A git upstream at `<home>/git/acme/kit` holding one skill, answering
/// with the commit the collection pins.
#[allow(clippy::unwrap_used)]
fn upstream(home: &Path) -> String {
    let dir = home.join("git/acme/kit");
    fs::create_dir_all(dir.join("skills/gh")).unwrap();
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\n\nBody.\n",
    )
    .unwrap();
    git(&dir, &["init", "--quiet", "-b", "main"]);
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "--quiet", "-m", "one"]);
    git(&dir, &["rev-parse", "HEAD"])
}

const COLLECTION_ID: &str = "aB3-_dEf12345678";

/// A resolver that answers one request with the collection and then goes
/// away: the base URL the binary reads as `KENDEX_API`.
#[allow(clippy::unwrap_used)]
fn resolver(commit: &str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let body = format!(
        r#"{{"schema":1,"id":"{COLLECTION_ID}","name":"starter","description":null,"members":[{{"repo":"acme/kit","kind":"skill","name":"gh","commit":"{commit}"}}]}}"#
    );
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = Vec::new();
        let mut byte = [0u8; 1];
        while !request.ends_with(b"\r\n\r\n") && stream.read(&mut byte).unwrap() == 1 {
            request.push(byte[0]);
        }
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
    });
    base
}

/// A home holding the upstream and a project to install into. The tool is
/// the case's own to put on the machine.
///
/// The project carries a harness marker and is proven to be what the walk
/// up resolves before the binary runs: a temporary directory under a
/// checkout sits inside somebody's project, and a project the walk does
/// not stop at is an install into a stranger's home.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, PathBuf, PathBuf, String) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let commit = upstream(&home);
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
    assert_eq!(
        kendex_core::discover::project_root_from(&project, &home).as_deref(),
        Some(project.as_path()),
        "the walk up must resolve the fixture project and nothing above it"
    );
    (tmp, home, project, commit)
}

/// The one write a refused step could leave behind is its subscription.
/// No tool on the machine refuses the member before the manifest gains
/// one; the same collection with a tool subscribes and installs in one
/// plan.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_no_tool_can_take_leaves_the_scope_unsubscribed() {
    for tool in [false, true] {
        let (_tmp, home, project, commit) = world();
        if tool {
            fs::create_dir_all(home.join(".claude")).unwrap();
        }
        let link = format!("https://kendex.ai/c/{COLLECTION_ID}");

        let run = kendex(&home, &project, &resolver(&commit), &["add", &link, "-y"]);
        let text = said(&run);
        let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();

        assert_eq!(run.status.success(), tool, "{text}");
        match tool {
            false => {
                assert!(text.contains("no tool is on this machine"), "{text}");
                assert_eq!(manifest, "schema = 6\n", "the refused step subscribed");
                assert!(!project.join(".claude/skills").exists(), "{text}");
            }
            true => {
                assert!(manifest.contains("[sources.kit]"), "{manifest}");
                assert!(manifest.contains("[skills.gh]"), "{manifest}");
                assert!(
                    project.join(".claude/skills/gh/SKILL.md").is_file(),
                    "{text}"
                );
                assert!(text.contains("subscribed to 'kit'"), "{text}");
            }
        }
    }
}
