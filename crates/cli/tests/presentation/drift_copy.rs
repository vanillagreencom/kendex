//! The session report a person reads: what they must act on or know, with
//! the git command, the hash and what git printed behind `--verbose` and
//! `--json`. The fixture is the 2026-09-29 one: a comparison that failed
//! on a cached copy missing a commit, which a source refresh repairs.

use super::*;
use kendex_core::drift::snapshot::{SNAPSHOT_SCHEMA, ScopeSnapshot, UnreadableSnapshot};
use kendex_core::drift::stamps;
use kendex_core::model::{ItemKind, Scope};

const HASH: &str = "f7db7e89c3a1d04b5e6f7a8b9c0d1e2f3a4b5c6d";

/// A project whose last comparison could not read one package's history,
/// with the source's fetch last done `fetched_ago` seconds back.
#[allow(clippy::unwrap_used)]
fn failed_comparison(home: &Path, fetched_ago: u64, superseded: bool) -> PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.cat]\nrepo = \"owner/repo\"\n",
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
            taken_at: now - 7 * 3600,
            scope: scope.label(),
            packages: vec![],
            unreadable: vec![UnreadableSnapshot {
                kind: ItemKind::Skill,
                name: "gh".into(),
                message: "kendex could not find the installed version in its source".into(),
                unfetched: true,
                detail: Some(format!(
                    "git log --first-parent --format=%H {HASH} -- :(literal)skills/gh failed: fatal: bad object {HASH}"
                )),
                repo: "owner/repo".into(),
                refs_state: Some(if superseded { "old-refs" } else { "refs" }.into()),
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

/// A due fetch cannot excuse current unreadability. Superseded refs remain
/// visible and non-clean even with background refresh disabled by this fixture.
#[test]
#[allow(clippy::unwrap_used)]
fn a_failed_comparison_says_only_what_the_person_needs() {
    for (fetched_ago, superseded) in [(2 * stamps::TTL.as_secs(), false), (0, false), (0, true)] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = failed_comparison(&home, fetched_ago, superseded);
        let expected_code = if superseded { 1 } else { 2 };
        for quiet in [true, false] {
            let flags: &[&str] = if quiet { &["--quiet"] } else { &[] };
            let (code, text) = check(&home, &project, flags);
            assert_eq!(code, Some(expected_code));
            assert_eq!(technical(&text), Vec::<&str>::new());
            assert!(!text.is_empty());
            // A clone that must not commit is told the step that writes
            // nothing in it; a superseded comparison names its own.
            assert_eq!(
                text.contains("fix: kendex source refresh"),
                !superseded,
                "{text}"
            );
            let verbose = [flags, &["--verbose"]].concat();
            let (code, text) = check(&home, &project, &verbose);
            assert_eq!(code, Some(expected_code));
            assert!(text.contains(&format!("bad object {HASH}")));
        }
        let (code, json) = check(&home, &project, &["--json"]);
        assert_eq!(code, Some(expected_code));
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        let line = &parsed["sections"][0]["lines"][0];
        assert_eq!(
            line["class"],
            if superseded { "settling" } else { "unknown" }
        );
        assert_eq!(
            parsed["status"],
            if superseded { "drift" } else { "unknown" }
        );
        assert!(line["detail"].as_str().unwrap().contains(HASH));
        match superseded {
            true => assert!(line["remedy"].is_null(), "{line}"),
            false => assert_eq!(line["remedy"]["verb"], "source-refresh", "{line}"),
        }
        assert_eq!(
            technical(line["text"].as_str().unwrap()),
            Vec::<&str>::new()
        );
        if superseded {
            assert!(parsed["snapshotAgeSecs"].as_u64().unwrap() >= 7 * 3600);
            // The session consumer relays these observation fields as text.
            assert!(
                line["text"]
                    .as_str()
                    .unwrap()
                    .contains("background refresh disabled")
            );
        }
    }
}

/// A project checkout on `main` with no install record and one package,
/// `gh`, that reads behind its source, and origin's `main` placed `origin`
/// relative to it: `behind` is one commit the checkout lacks, `diverged`
/// adds one of its own, `even` is the checkout's own commit, and `None` is
/// a clone that never fetched. The commit the checkout lacks commits an
/// install record of the package `records` names, or changes no record.
#[allow(clippy::unwrap_used)]
fn behind_checkout(home: &Path, origin: Option<&str>, records: Option<&str>) -> PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.cat]\nrepo = \"owner/repo\"\n",
    )
    .unwrap();
    test_util::git(&project, &["init", "--quiet", "-b", "main"]);
    test_util::git(&project, &["add", "-A"]);
    test_util::git(&project, &["commit", "--quiet", "-m", "one"]);
    let one = test_util::git(&project, &["rev-parse", "HEAD"]);
    if let Some(name) = records {
        commit_record(&project, name);
    }
    test_util::git(
        &project,
        &["commit", "--quiet", "--allow-empty", "-m", "two"],
    );
    let two = test_util::git(&project, &["rev-parse", "HEAD"]);
    test_util::git(&project, &["reset", "--quiet", "--hard", one.trim()]);
    let upstream = match origin {
        Some("behind") => Some(two),
        Some("diverged") => {
            test_util::git(
                &project,
                &["commit", "--quiet", "--allow-empty", "-m", "own"],
            );
            Some(two)
        }
        Some("even") => Some(one),
        Some(other) => panic!("no such origin {other}"),
        None => None,
    };
    if let Some(upstream) = upstream {
        test_util::git(
            &project,
            &["update-ref", "refs/remotes/origin/main", upstream.trim()],
        );
        test_util::git(
            &project,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
    }
    let env = Env::host_rooted(home);
    let scope = Scope::Project {
        root: kendex_core::paths::canonical(&project).unwrap(),
    };
    let now = kendex_core::clock::unix_now();
    let key = kendex_core::remote::cache_key(&env, "owner/repo");
    stamps::record_success(&env, &key, Some("refs".into()), now).unwrap();
    kendex_core::drift::snapshot::store(
        &env,
        &scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at: now,
            scope: scope.label(),
            packages: vec![kendex_core::drift::snapshot::PackageSnapshot {
                kind: ItemKind::Skill,
                name: "gh".into(),
                source: "cat".into(),
                repo: "owner/repo".into(),
                refs_state: Some("refs".into()),
                update_available: true,
                removed_upstream: false,
                held: false,
                ignored: false,
                edited: false,
                mixed: false,
                forked: false,
                recorded: Vec::new(),
            }],
            unreadable: vec![],
        },
    )
    .unwrap();
    project
}

/// Stages an install record of the skill `name` at a source commit, for
/// the next commit to carry.
#[allow(clippy::unwrap_used)]
fn commit_record(project: &Path, name: &str) {
    let harness = kendex_core::model::HarnessId::Claude;
    let entry = kendex_core::lock::LockEntry {
        requirer_provenance: None,
        name: name.to_owned(),
        kind: ItemKind::Skill,
        harness,
        source: "cat".to_owned(),
        source_repo: "owner/repo".to_owned(),
        source_hash: "0".repeat(64),
        source_commit: Some(HASH.to_owned()),
        selector: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        output_style: None,
        reasons: std::collections::BTreeSet::new(),
        machine: None,
    };
    let lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        entries: std::collections::BTreeMap::from([(
            kendex_core::lock::entry_key(ItemKind::Skill, name, harness),
            entry,
        )]),
        ..Default::default()
    };
    let path = Env::project_lock_file(project);
    fs::write(
        &path,
        kendex_core::lock::committed_text(&path, &lock).unwrap(),
    )
    .unwrap();
    test_util::git(project, &["add", kendex_core::lock::LOCK_FILE]);
}

/// A copy that follows `main` and has not pulled is told to pull where
/// `main` records the package at another commit: the pull brings that
/// record, and a refresh would write files the copy must not commit. A
/// pull that leaves the package's record as it is would leave the newer
/// version where it is, so that copy, and any copy the pull does not
/// apply to, keeps the refresh.
#[test]
#[allow(clippy::unwrap_used)]
fn a_checkout_behind_its_default_branch_is_told_to_pull() {
    for (origin, records, verb, command) in [
        (Some("behind"), Some("gh"), "pull", "git pull --ff-only"),
        (Some("behind"), None, "refresh", "kendex refresh"),
        (Some("behind"), Some("other"), "refresh", "kendex refresh"),
        (Some("diverged"), Some("gh"), "refresh", "kendex refresh"),
        (Some("even"), None, "refresh", "kendex refresh"),
        (None, None, "refresh", "kendex refresh"),
    ] {
        let case = format!("{origin:?} recording {records:?}");
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = behind_checkout(&home, origin, records);
        let (code, json) = check(&home, &project, &["--json"]);
        assert_eq!(code, Some(1), "{case}: {json}");
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        let line = parsed["sections"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|section| section["lines"].as_array().unwrap())
            .find(|line| line["text"].as_str().unwrap().contains("'gh'"))
            .unwrap_or_else(|| panic!("{case}: no gh line in {json}"));
        assert_eq!(line["remedy"]["verb"], verb, "{case}: {line}");
        let (_, text) = check(&home, &project, &[]);
        let fix = text
            .lines()
            .find(|line| line.contains("'gh'"))
            .unwrap_or_else(|| panic!("{case}: no gh line in {text}"));
        assert!(fix.contains(&format!("fix: {command}")), "{case}: {fix}");
    }
}
