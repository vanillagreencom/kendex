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

const NONE: &[Recorded] = &[];
const GH_A: &[Recorded] = &[Recorded {
    name: "gh",
    commit: A,
}];
const GH_B: &[Recorded] = &[Recorded {
    name: "gh",
    commit: B,
}];
const OTHER_B: &[Recorded] = &[Recorded {
    name: "other",
    commit: B,
}];
const GH_A_OTHER_A: &[Recorded] = &[
    Recorded {
        name: "gh",
        commit: A,
    },
    Recorded {
        name: "other",
        commit: A,
    },
];
const GH_B_OTHER_A: &[Recorded] = &[
    Recorded {
        name: "gh",
        commit: B,
    },
    Recorded {
        name: "other",
        commit: A,
    },
];

/// A project checkout where `gh`, and every other package the checkout
/// records, reads behind its source. `head` is what the checkout's commit
/// records, no lock where it is empty; origin's commit records
/// `upstream`, or leaves the lock as `head` has it where that is `None`;
/// and `local` is what is done to the checkout after. The project sits at
/// the repository's root, or in a folder below it where `below`. The
/// snapshot's verdicts are about the record the checkout holds at the
/// end, so the check reads them as they stand.
#[allow(clippy::unwrap_used)]
fn following_copy(
    home: &Path,
    head: &'static [Recorded],
    origin: Origin,
    upstream: Option<&'static [Recorded]>,
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
    if !head.is_empty() {
        write_record(&project, head);
    }
    test_util::git(&repository, &["add", "-A"]);
    test_util::git(&repository, &["commit", "--quiet", "-m", "one"]);
    let one = test_util::git(&repository, &["rev-parse", "HEAD"]);
    if let Some(records) = upstream {
        write_record(&project, records);
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
    let mut holds = head.to_vec();
    match local {
        Local::Clean => {}
        Local::Untracked(commit) | Local::Rewritten(commit) => {
            holds = vec![Recorded { name: "gh", commit }];
            write_record(&project, &holds);
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
    let mut names: Vec<&str> = holds.iter().map(|record| record.name).collect();
    if !names.contains(&"gh") {
        names.push("gh");
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
            packages: names
                .into_iter()
                .map(|name| kendex_core::drift::snapshot::PackageSnapshot {
                    kind: ItemKind::Skill,
                    name: name.into(),
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
                        .iter()
                        .filter(|record| record.name == name)
                        .map(|record| record.commit.to_owned())
                        .collect(),
                })
                .collect(),
            unreadable: vec![],
        },
    )
    .unwrap();
    project
}

/// Writes the project's install record as skills at source commits.
#[allow(clippy::unwrap_used)]
fn write_record(project: &Path, records: &[Recorded]) {
    let harness = kendex_core::model::HarnessId::Claude;
    let entry = |record: &Recorded| kendex_core::lock::LockEntry {
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
        entries: records
            .iter()
            .map(|record| {
                (
                    kendex_core::lock::entry_key(ItemKind::Skill, record.name, harness),
                    entry(record),
                )
            })
            .collect(),
        ..Default::default()
    };
    let path = Env::project_lock_file(project);
    fs::write(
        &path,
        kendex_core::lock::committed_text(&path, &lock).unwrap(),
    )
    .unwrap();
}

/// A copy that follows `main` and has not pulled is told to pull for a
/// package the pull brings another record, which the next check reads
/// again: a refresh there would write a record the copy must not commit.
/// The report's next step is then that pull, never a project refresh,
/// which would rewrite the lock and make git refuse the pull. Every copy
/// the pull would leave at the same record, or that the pull would
/// refuse or not move, keeps the refresh. A checkout git cannot answer
/// for is offered neither, and the default text says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_behind_its_default_branch_is_told_to_pull_where_the_pull_moves_the_record() {
    type Row = (
        &'static str,
        &'static [Recorded],
        Origin,
        Option<&'static [Recorded]>,
        Local,
        bool,
        Option<&'static str>,
    );
    let rows: [Row; 14] = [
        (
            "origin records gh where the checkout records nothing",
            NONE,
            Origin::Behind,
            Some(GH_B),
            Local::Clean,
            false,
            Some("pull"),
        ),
        (
            "origin records gh at another commit",
            GH_A,
            Origin::Behind,
            Some(GH_B),
            Local::Clean,
            false,
            Some("pull"),
        ),
        (
            "origin records gh at another commit and other as the checkout does",
            GH_A_OTHER_A,
            Origin::Behind,
            Some(GH_B_OTHER_A),
            Local::Clean,
            false,
            Some("pull"),
        ),
        (
            "origin records gh where a project below the root records nothing",
            NONE,
            Origin::Behind,
            Some(GH_B),
            Local::Clean,
            true,
            Some("pull"),
        ),
        (
            "origin's commits leave the lock unchanged",
            GH_A,
            Origin::Behind,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "origin records only another package",
            NONE,
            Origin::Behind,
            Some(OTHER_B),
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "an untracked local lock",
            NONE,
            Origin::Behind,
            Some(GH_B),
            Local::Untracked(A),
            false,
            Some("refresh"),
        ),
        (
            "a tracked lock with an uncommitted rewrite of gh",
            GH_A,
            Origin::Behind,
            Some(GH_B),
            Local::Rewritten(C),
            false,
            Some("refresh"),
        ),
        (
            "a checkout with a commit of its own",
            GH_A,
            Origin::Diverged,
            Some(GH_B),
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a checkout at origin's commit",
            GH_A,
            Origin::Even,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a clone that never fetched",
            GH_A,
            Origin::Unfetched,
            None,
            Local::Clean,
            false,
            Some("refresh"),
        ),
        (
            "a checkout off the default branch",
            GH_A,
            Origin::Behind,
            Some(GH_B),
            Local::Branch,
            false,
            Some("refresh"),
        ),
        (
            "a detached HEAD",
            GH_A,
            Origin::Behind,
            Some(GH_B),
            Local::Detached,
            false,
            Some("refresh"),
        ),
        (
            "a remote HEAD naming no branch of origin",
            GH_A,
            Origin::Behind,
            Some(GH_B),
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
        // The pasteable commands the session hook hands an agent: the
        // line's fix and the report's next step.
        let (_, text) = check(&home, &project, &[]);
        let line = text
            .lines()
            .find(|line| line.contains("'gh'") && line.contains("newer version"))
            .unwrap_or_else(|| panic!("{case}: no stale gh line in {text}"));
        let next = text.lines().find(|line| line.starts_with("Next: "));
        match verb {
            Some("pull") => {
                assert!(line.contains("fix: git pull --ff-only"), "{case}: {text}");
                assert!(
                    next.is_some_and(|next| next.starts_with("Next: git pull --ff-only")),
                    "{case}: {text}"
                );
                assert!(
                    !text.contains("kendex refresh --scope project"),
                    "{case}: {text}"
                );
            }
            Some("refresh") => {
                assert!(line.contains("fix: kendex refresh"), "{case}: {text}");
                assert!(
                    next.is_some_and(|next| next.starts_with("Next: kendex refresh")),
                    "{case}: {text}"
                );
            }
            _ => {
                // The default text drops the detail, so the line says it
                // could not name the fix.
                assert!(!line.contains("fix:"), "{case}: {text}");
                assert!(line.contains("could not tell"), "{case}: {text}");
            }
        }
    }
}
