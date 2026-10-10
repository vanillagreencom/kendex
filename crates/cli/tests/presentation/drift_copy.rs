//! The session report a person reads: what they must act on or know, with
//! the git command, the hash and what git printed behind `--verbose` and
//! `--json`. The fixture is the 2026-09-29 one: a comparison that failed
//! on a cached copy missing a commit, which the next fetch repairs.

use super::*;
use kendex_core::drift::snapshot::{SNAPSHOT_SCHEMA, ScopeSnapshot, UnreadableSnapshot};
use kendex_core::drift::stamps;
use kendex_core::model::{ItemKind, Scope};

const HASH: &str = "f7db7e89c3a1d04b5e6f7a8b9c0d1e2f3a4b5c6d";

/// A project whose last comparison could not read one package's history,
/// with the source's fetch last done `fetched_ago` seconds back.
#[allow(clippy::unwrap_used)]
fn failed_comparison(home: &Path, fetched_ago: u64) -> PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 7\n\n[sources.cat]\nrepo = \"owner/repo\"\n",
    )
    .unwrap();
    let env = Env::host_rooted(home);
    let scope = Scope::Project {
        root: kendex_core::paths::canonical(&project).unwrap(),
    };
    let now = kendex_core::clock::unix_now();
    let key = kendex_core::remote::cache_key(&env, "owner/repo");
    stamps::record_success(&env, &key, Some("refs".into()), now - fetched_ago).unwrap();
    kendex_core::drift::snapshot::store(
        &env,
        &scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at: now,
            scope: scope.label(),
            packages: vec![],
            unreadable: vec![UnreadableSnapshot {
                kind: ItemKind::Skill,
                name: "gh".into(),
                message: "kendex could not find the installed version in its source; the next source refresh tries again".into(),
                detail: Some(format!(
                    "git log --first-parent --format=%H {HASH} -- :(literal)skills/gh failed: fatal: bad object {HASH}"
                )),
                repo: "owner/repo".into(),
                refs_state: Some("refs".into()),
            }],
        },
    )
    .unwrap();
    project
}

fn check(home: &Path, project: &Path, extra: &[&str]) -> (Option<i32>, String) {
    let mut args = vec!["check", "--report-only", "--scope", "project"];
    args.extend(extra);
    let output = kendex(home, project, "plain", &args);
    (
        output.status.code(),
        String::from_utf8_lossy(&output.stdout).into_owned(),
    )
}

/// What the default text may never carry: the command, the hash, a path,
/// what git printed.
fn technical(text: &str) -> Vec<&'static str> {
    ["git ", HASH, "fatal:", ":(literal)", "skills/gh"]
        .into_iter()
        .filter(|word| text.contains(word))
        .collect()
}

/// Rows: how long ago the source was fetched, and whether the background
/// refresh this check starts settles the failure. A fetch that is due
/// settles it, so the default report says nothing and exits clean; a fetch
/// that just ran did not, so the default report says what failed, in
/// words, and exits could-not-check. Either way `--verbose` and `--json`
/// keep the git command and its output verbatim.
#[test]
#[allow(clippy::unwrap_used)]
fn a_failed_comparison_says_only_what_the_person_needs() {
    for (fetched_ago, settles) in [(2 * stamps::TTL.as_secs(), true), (0, false)] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = failed_comparison(&home, fetched_ago);

        for quiet in [true, false] {
            let flags: &[&str] = if quiet { &["--quiet"] } else { &[] };
            let (code, text) = check(&home, &project, flags);
            let label = format!("settles={settles} quiet={quiet}");
            match settles {
                true => {
                    assert_eq!(code, Some(0), "{label}: {text}");
                    assert!(!text.contains("gh"), "{label}: {text}");
                }
                false => {
                    assert_eq!(code, Some(2), "{label}: {text}");
                    assert!(text.contains("skill 'gh'"), "{label}: {text}");
                }
            }
            assert_eq!(technical(&text), Vec::<&str>::new(), "{label}: {text}");

            let verbose = [flags, &["--verbose"]].concat();
            let (code, text) = check(&home, &project, &verbose);
            assert_eq!(code, Some(if settles { 0 } else { 2 }), "{label}: {text}");
            assert!(
                text.contains(&format!("bad object {HASH}")),
                "{label}: {text}"
            );
        }

        let (_, json) = check(&home, &project, &["--json"]);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        let line = &parsed["sections"][0]["lines"][0];
        assert_eq!(
            line["class"],
            if settles { "settling" } else { "unknown" },
            "{json}"
        );
        assert!(line["detail"].as_str().unwrap().contains(HASH), "{json}");
        assert_eq!(
            technical(line["text"].as_str().unwrap()),
            Vec::<&str>::new()
        );
    }
}
