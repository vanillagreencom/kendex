//! The session report a person reads: what they must act on or know, with
//! the git command, the hash and what git printed behind `--verbose` and
//! `--json`, and the fix it names. One fixture is the 2026-09-29 one: a
//! comparison that failed on a cached copy missing a commit, which a
//! source refresh repairs. The other is a copy that follows its default
//! branch, behind origin's, with a package that reads behind.

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

/// Where origin's `main` stands against the checkout's own commit.
#[derive(Debug, Clone, Copy)]
enum Origin {
    /// One commit ahead, which the checkout lacks.
    Behind,
    /// That commit, and the checkout has one of its own.
    Diverged,
    /// At the checkout's own commit.
    Even,
    /// A clone that never fetched.
    Unfetched,
}

/// What the checkout holds besides its commit on `main`.
#[derive(Debug, Clone, Copy)]
enum Local {
    Clean,
    /// A lock recording `gh` at this commit, which git does not track.
    Untracked(&'static str),
    /// The tracked lock rewritten to record `gh` at this commit.
    Rewritten(&'static str),
    /// Another branch at the same commit.
    Branch,
    Detached,
    /// A remote HEAD set to point at no branch of origin, which no git
    /// answer can name the default branch from.
    StrayRemoteHead,
}

/// One package's record of a skill at a source commit, as committed.
#[derive(Debug, Clone, Copy)]
struct Recorded {
    name: &'static str,
    commit: &'static str,
}

const A: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const B: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const C: &str = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3";

const fn gh(commit: &'static str) -> Option<Recorded> {
    Some(Recorded { name: "gh", commit })
}

/// A project checkout whose one package, `gh`, reads behind its source.
/// `head` is what the checkout's commit records, origin's commit records
/// `upstream`, or leaves the lock as `head` has it where that is `None`,
/// and `local` is what is done to the checkout after. The project sits at
/// the repository's root, or in a folder below it where `below`. The
/// snapshot's verdict is about the record the checkout holds at the end,
/// so the check reads it as it stands.
#[allow(clippy::unwrap_used)]
fn following_copy(
    home: &Path,
    head: Option<Recorded>,
    origin: Origin,
    upstream: Option<Recorded>,
    local: Local,
    below: bool,
) -> PathBuf {
    let repository = home.join("dev/app");
    let project = match below {
        true => repository.join("tools/kit"),
        false => repository.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.cat]\nrepo = \"owner/repo\"\n",
    )
    .unwrap();
    test_util::git(&repository, &["init", "--quiet", "-b", "main"]);
    if let Some(record) = head {
        write_record(&project, record);
    }
    test_util::git(&repository, &["add", "-A"]);
    test_util::git(&repository, &["commit", "--quiet", "-m", "one"]);
    let one = test_util::git(&repository, &["rev-parse", "HEAD"]);
    if let Some(record) = upstream {
        write_record(&project, record);
        test_util::git(&repository, &["add", "-A"]);
    }
    test_util::git(
        &repository,
        &["commit", "--quiet", "--allow-empty", "-m", "two"],
    );
    let two = test_util::git(&repository, &["rev-parse", "HEAD"]);
    test_util::git(&repository, &["reset", "--quiet", "--hard", one.trim()]);
    let at = match origin {
        Origin::Behind => Some(two),
        Origin::Diverged => {
            test_util::git(
                &repository,
                &["commit", "--quiet", "--allow-empty", "-m", "own"],
            );
            Some(two)
        }
        Origin::Even => Some(one),
        Origin::Unfetched => None,
    };
    if let Some(at) = at {
        test_util::git(
            &repository,
            &["update-ref", "refs/remotes/origin/main", at.trim()],
        );
        test_util::git(
            &repository,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
    }
    let mut holds = head;
    match local {
        Local::Clean => {}
        Local::Untracked(commit) | Local::Rewritten(commit) => {
            holds = gh(commit);
            write_record(&project, holds.unwrap());
        }
        Local::Branch => {
            test_util::git(&repository, &["switch", "--quiet", "-c", "lane"]);
        }
        Local::Detached => {
            test_util::git(&repository, &["switch", "--quiet", "--detach"]);
        }
        Local::StrayRemoteHead => {
            test_util::git(
                &repository,
                &[
                    "symbolic-ref",
                    "refs/remotes/origin/HEAD",
                    "refs/heads/main",
                ],
            );
        }
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
                recorded: holds
                    .filter(|record| record.name == "gh")
                    .map(|record| record.commit.to_owned())
                    .into_iter()
                    .collect(),
            }],
            unreadable: vec![],
        },
    )
    .unwrap();
    project
}

/// Writes the project's install record as one skill at a source commit.
#[allow(clippy::unwrap_used)]
fn write_record(project: &Path, record: Recorded) {
    let harness = kendex_core::model::HarnessId::Claude;
    let entry = kendex_core::lock::LockEntry {
        requirer_provenance: None,
        name: record.name.to_owned(),
        kind: ItemKind::Skill,
        harness,
        source: "cat".to_owned(),
        source_repo: "owner/repo".to_owned(),
        source_hash: "0".repeat(64),
        source_commit: Some(record.commit.to_owned()),
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
            kendex_core::lock::entry_key(ItemKind::Skill, record.name, harness),
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
}

/// A copy that follows `main` and has not pulled is told to pull only
/// where the pull brings `gh` another record, which the next check reads
/// again: a refresh there would write a record the copy must not commit.
/// Every copy the pull would leave at the same record, or that the pull
/// would refuse or not move, keeps the refresh. A checkout git cannot
/// answer for is offered neither, with git's answer as the detail.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_behind_its_default_branch_is_told_to_pull_where_the_pull_moves_the_record() {
    type Row = (
        &'static str,
        Option<Recorded>,
        Origin,
        Option<Recorded>,
        Local,
        bool,
        Option<&'static str>,
    );
    let other = Some(Recorded {
        name: "other",
        commit: B,
    });
    let rows: [Row; 13] = [
        (
            "origin records gh where the checkout records nothing",
            None,
            Origin::Behind,
            gh(B),
            Local::Clean,
            false,
            Some("pull"),
        ),
        (
            "origin records gh at another commit",
            gh(A),
            Origin::Behind,
            gh(B),
            Local::Clean,
            false,
            Some("pull"),
        ),
        (
            "origin records gh where a project below the root records nothing",
            None,
            Origin::Behind,
            gh(B),
            Local::Clean,
            true,
            Some("pull"),
        ),
        (
            "origin's commits leave the lock unchanged",
            gh(A),
            Origin::Behind,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "origin records only another package",
            None,
            Origin::Behind,
            other,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "an untracked local lock",
            None,
            Origin::Behind,
            gh(B),
            Local::Untracked(A),
            false,
            Some("refresh"),
        ),
        (
            "a tracked lock with an uncommitted rewrite of gh",
            gh(A),
            Origin::Behind,
            gh(B),
            Local::Rewritten(C),
            false,
            Some("refresh"),
        ),
        (
            "a checkout with a commit of its own",
            gh(A),
            Origin::Diverged,
            gh(B),
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a checkout at origin's commit",
            gh(A),
            Origin::Even,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a clone that never fetched",
            gh(A),
            Origin::Unfetched,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a checkout off the default branch",
            gh(A),
            Origin::Behind,
            gh(B),
            Local::Branch,
            false,
            Some("refresh"),
        ),
        (
            "a detached HEAD",
            gh(A),
            Origin::Behind,
            gh(B),
            Local::Detached,
            false,
            Some("refresh"),
        ),
        (
            "a remote HEAD naming no branch of origin",
            gh(A),
            Origin::Behind,
            gh(B),
            Local::StrayRemoteHead,
            false,
            None,
        ),
    ];
    for (case, head, origin, upstream, local, below, verb) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = following_copy(&home, head, origin, upstream, local, below);
        let (_, json) = check(&home, &project, &["--json"]);
        let parsed: serde_json::Value =
            serde_json::from_str(&json).unwrap_or_else(|error| panic!("{case}: {error}: {json}"));
        let stale = parsed["sections"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|section| section["title"] == "stale")
            .flat_map(|section| section["lines"].as_array().unwrap())
            .find(|line| line["text"].as_str().unwrap().contains("'gh'"))
            .unwrap_or_else(|| panic!("{case}: no stale gh line in {json}"));
        assert_eq!(stale["remedy"]["verb"].as_str(), verb, "{case}: {stale}");
        assert_eq!(
            stale["detail"].is_string(),
            verb.is_none(),
            "{case}: {stale}"
        );
        let command = match verb {
            Some("pull") => "fix: git pull --ff-only",
            Some("refresh") => "fix: kendex refresh",
            _ => continue,
        };
        let (_, text) = check(&home, &project, &[]);
        assert!(text.contains(command), "{case}: {text}");
    }
}
