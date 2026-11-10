#![allow(
    clippy::disallowed_methods,
    reason = "the rows own their scratch files and run the executable with the common process isolation"
)]

mod support;

use orch_runtime::settings::{self, Flags, Roots};
use orch_runtime::watch::tracker::reconcile_items as reconcile;
use serde_json::{Value, json};
use std::fs;

const NOW: u64 = 1_791_072_000;

struct World {
    dir: tempfile::TempDir,
}

impl World {
    fn new(items: Vec<Value>) -> Self {
        let dir = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(
            support::fixtures().join("linear-reconcile/linear"),
            dir.path().join("linear"),
        )
        .unwrap();
        let out = support::program("git")
            .args(["init", "-q"])
            .arg(dir.path())
            .output()
            .unwrap();
        assert!(out.status.success());
        for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
            assert!(
                support::program("git")
                    .arg("-C")
                    .arg(dir.path())
                    .args(["config", key, value])
                    .status()
                    .unwrap()
                    .success()
            );
        }
        std::os::unix::fs::symlink(
            support::fixtures().join("linear-reconcile/curl"),
            dir.path().join("curl"),
        )
        .unwrap();
        fs::write(
            dir.path().join("issues.json"),
            json!({"issues":{"nodes":items}}).to_string(),
        )
        .unwrap();
        Self { dir }
    }

    fn settings(&self, extra: &[(&str, &str)]) -> settings::Settings {
        let root = self.dir.path();
        let mut env = vec![(
            "OVERSEE_WATCH_TRACKER".into(),
            support::isolated_program(&root.join("linear")).into(),
        )];
        env.extend(extra.iter().map(|(k, v)| ((*k).into(), (*v).into())));
        settings::load(
            &Roots {
                project: root.into(),
                common: root.into(),
            },
            &env,
            &Flags {
                state_dir: Some(root.join("state")),
                private_env: true,
            },
        )
        .unwrap()
    }

    fn run(&self) -> reconcile::Report {
        reconcile::run(
            &self.settings(&[]),
            None,
            &[],
            Some(&self.dir.path().join("gh-missing")),
            NOW,
        )
        .unwrap()
    }

    fn cli(&self, args: &[&str]) -> std::process::Output {
        support::isolated()
            .current_dir(self.dir.path())
            .env("OVERSEE_WATCH_TRACKER", self.dir.path().join("linear"))
            .args(args)
            .output()
            .unwrap()
    }
}

fn issue(id: &str, state: &str, kind: &str, desc: &str, parent: Option<&str>) -> Value {
    json!({"id":format!("uuid-{id}"), "identifier":id, "title":id,
        "state":{"name":state,"type":kind}, "description":desc,
        "parent":parent.map(|id| json!({"identifier":id})),
        "updatedAt":"2026-10-01T00:00:00Z", "createdAt":"2026-09-01T00:00:00Z",
        "labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}, "assignee":{"name":"Maya Owner"},
        "team":{"id":"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47","key":"T","name":"Test"},
        "children":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
        "inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}, "relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}})
}

fn kinds(report: &reconcile::Report) -> Vec<(&str, &str)> {
    report
        .findings
        .iter()
        .map(|f| (f.kind, f.issue.as_str()))
        .collect()
}

#[test]
fn lifecycle_findings_distinguish_parked_containers_from_live_items() {
    let world = World::new(vec![
        issue(
            "T-1",
            "Todo",
            "unstarted",
            "## Done when\n- [ ] Every child Done or cancelled",
            None,
        ),
        issue("T-2", "Done", "completed", "", Some("T-1")),
        issue("T-3", "Canceled", "canceled", "", Some("T-1")),
        issue("T-4", "Done", "completed", "- [ ] missing proof", None),
        issue(
            "T-5",
            "Done",
            "completed",
            "- [x] proved\n  Evidence: reading",
            None,
        ),
        issue("T-6", "Todo", "unstarted", "", None),
        issue("T-7", "In Progress", "started", "", Some("T-6")),
        issue(
            "T-8",
            "In Review",
            "started",
            "**In-PR bundle**: yes\n\n## Done when\n- [ ] branch",
            None,
        ),
        issue("T-9", "Canceled", "canceled", "", Some("T-8")),
        // A pending child beside a Done one holds its parent open.
        issue("T-10", "Done", "completed", "", Some("T-6")),
        // A closed parent is no container to close.
        issue("T-11", "Done", "completed", "", None),
        issue("T-12", "Done", "completed", "", Some("T-11")),
        // A trashed issue is archived: the list never asks for it.
        {
            let mut trashed = issue("T-15", "Done", "completed", "- [ ] two", None);
            trashed["trashed"] = json!(true);
            trashed["archivedAt"] = json!("2026-10-01T00:00:00Z");
            trashed
        },
    ]);
    let report = world.run();
    let found = kinds(&report);
    assert!(found.contains(&("container-parked", "T-1")));
    assert!(found.contains(&("verifying-empty", "T-1")));
    assert!(found.contains(&("done-unchecked", "T-4")));
    for id in ["T-5", "T-6", "T-8", "T-11"] {
        assert!(!found.contains(&("container-parked", id)));
        assert!(!found.contains(&("done-unchecked", id)));
    }
    assert!(!found.iter().any(|(_, id)| *id == "T-15"), "{found:?}");
    let out = world.cli(&["reconcile-items", "--stale-hours", "999999"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["counts"]["items"], 1);
    assert!(
        reply["result"]["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["kind"] == "done-unchecked")
    );
    assert!(!world.dir.path().join("state").exists());
}

#[test]
fn an_unread_or_invalid_inventory_never_becomes_clean() {
    let world = World::new(vec![]);
    let refusal = |out: &std::process::Output| {
        assert_eq!(
            out.status.code(),
            Some(1),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["refusal"]["key"].clone()
    };
    // Outside any checkout nothing is read.
    let out = support::isolated()
        .env("OVERSEE_WATCH_TRACKER", world.dir.path().join("linear"))
        .arg("reconcile-items")
        .output()
        .unwrap();
    assert_eq!(refusal(&out), "not-repository");
    assert!(!world.dir.path().join("linear.log").exists());
    // No tracker CLI to run.
    let out = support::isolated()
        .current_dir(world.dir.path())
        .env(
            "OVERSEE_WATCH_TRACKER",
            world.dir.path().join("linear-missing"),
        )
        .arg("reconcile-items")
        .output()
        .unwrap();
    assert_eq!(refusal(&out), "tracker-list-failed");
    assert!(world.run().findings.is_empty());
    fs::write(world.dir.path().join("read.fail"), "").unwrap();
    let out = world.cli(&["reconcile-items"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["refusal"]["key"],
        "tracker-list-failed"
    );
    fs::remove_file(world.dir.path().join("read.fail")).unwrap();
    for bad in [json!({}), issue("T-1", "In Progress", "started", "", None)] {
        let mut row = bad;
        row["updatedAt"] = json!("");
        fs::write(
            world.dir.path().join("issues.json"),
            json!({"issues":{"nodes":[row]}}).to_string(),
        )
        .unwrap();
        let out = world.cli(&["reconcile-items"]);
        assert_eq!(
            out.status.code(),
            Some(1),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}

#[test]
fn verification_uses_the_real_parser_for_empty_invalid_and_overdue_boxes() {
    let world = World::new(vec![
        issue(
            "T-1",
            "Verifying",
            "started",
            "## Done when\n- [x] proof\n  Evidence: tests",
            None,
        ),
        issue(
            "T-2",
            "Verifying",
            "started",
            "## Done when\n- [ ] branch\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: 2026-10-02T00:00:00Z",
            None,
        ),
        issue(
            "T-3",
            "Verifying",
            "started",
            "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: 2026-10-02T00:00:00Z",
            None,
        ),
        issue(
            "T-4",
            "Verifying",
            "started",
            "## Done when\n- [ ] Post-merge: health",
            None,
        ),
    ]);
    let report = world.run();
    let found = kinds(&report);
    assert!(found.contains(&("verifying-empty", "T-1")));
    assert!(found.contains(&("verifying-invalid", "T-2")));
    assert!(found.contains(&("verifying-overdue", "T-3")));
    assert!(found.contains(&("verifying-invalid", "T-4")));
    // An invalid finding carries the parser's own reply: its open branch
    // box, its refused box.
    let parser = |id: &str| {
        report
            .findings
            .iter()
            .find(|f| f.kind == "verifying-invalid" && f.issue == id)
            .map(|f| f.detail["parser"].as_str().unwrap_or_default().to_owned())
            .unwrap_or_default()
    };
    assert!(
        parser("T-2").contains("\"unmet_branch_boxes\":[1]"),
        "{}",
        parser("T-2")
    );
    assert!(parser("T-4").contains("\"box\":1"), "{}", parser("T-4"));
    assert_eq!(report.counts.overdue, 1);
    assert_eq!(report.counts.items, 4);
    assert_eq!(report.lines.len(), 2);
    assert!(!found.iter().any(|(kind, _)| *kind == "started-stale"));
}

#[test]
fn settings_and_private_file_thresholds_scope_the_same_live_read() {
    let mut fresh = issue("T-2", "In Progress", "started", "", None);
    fresh["updatedAt"] = json!(agent_runtime::clock::iso_utc(NOW - 2 * 3600));
    let world = World::new(vec![
        issue("T-1", "In Progress", "started", "", None),
        fresh,
    ]);
    // With no setting the threshold is 24 hours: 72 hours is stale, 2 is not.
    let report = world.run();
    let found = kinds(&report);
    assert!(found.contains(&("started-stale", "T-1")), "{found:?}");
    assert!(!found.iter().any(|(_, id)| *id == "T-2"), "{found:?}");
    for (file, text) in [
        (
            "kendex.settings.toml",
            "[env]\nRECONCILE_STALE_HOURS = \"999999\"\nLINEAR_TEAM = \"T\"\n",
        ),
        (
            ".env.local",
            "RECONCILE_STALE_HOURS=999999\nLINEAR_TEAM=T\n",
        ),
    ] {
        fs::write(world.dir.path().join(file), text).unwrap();
        let report = world.run();
        assert!(report.findings.is_empty(), "{report:?}");
        assert!(
            fs::read_to_string(world.dir.path().join("linear.log"))
                .unwrap()
                .contains("issues list --max --team T --format=safe")
        );
        fs::remove_file(world.dir.path().join(file)).unwrap();
    }
    for value in ["bad", "01", "-1"] {
        let settings = world.settings(&[("RECONCILE_STALE_HOURS", value)]);
        assert_eq!(
            reconcile::run(&settings, None, &[], None, NOW)
                .unwrap_err()
                .key(),
            "reconcile-threshold-invalid"
        );
        assert!(
            reconcile::run(&settings, Some(999999), &[], None, NOW)
                .unwrap()
                .findings
                .is_empty()
        );
    }
}

#[test]
fn merged_review_is_reported_before_age_and_a_failed_probe_keeps_its_finding() {
    let world = World::new(vec![
        issue("T-1", "In Review", "started", "", None),
        issue("T-2", "In Progress", "started", "", None),
    ]);
    let gh = world.dir.path().join("gh");
    support::write_executable(
        &gh,
        "#!/bin/sh\n[ -z \"$GH_REPO\" ] && [ -z \"$GITHUB_REPOSITORY\" ] || exit 1\n[ ! -f \"${0%/*}/gh.fail\" ] || { echo 'gh-stub: pr-list-unavailable' >&2; exit 1; }\ncat \"${0%/*}/pulls.json\"\n",
    );
    let detail = |report: &reconcile::Report, kind: &str, id: &str| {
        report
            .findings
            .iter()
            .find(|f| f.kind == kind && f.issue == id)
            .map(|f| f.detail.clone())
            .unwrap_or_default()
    };
    for (rows, expected) in [
        (json!([]), false),
        (
            json!([{"state":"MERGED","mergedAt":"2026-10-01T00:00:00.123Z","isCrossRepository":false}]),
            true,
        ),
        (
            json!([{"state":"MERGED","mergedAt":"2026-10-01T00:00:00Z","isCrossRepository":true}]),
            false,
        ),
        (json!([{"state":"OPEN","isCrossRepository":false}]), false),
        (
            json!([{"state":"MERGED","mergedAt":"2026-10-01T00:00:00Z","isCrossRepository":false}, {"state":"OPEN","isCrossRepository":false}]),
            false,
        ),
        (
            json!([{"state":"MERGED","mergedAt":"2026-10-01T00:00:00Z","isCrossRepository":false}, {"state":"CLOSED","isCrossRepository":false}]),
            false,
        ),
    ] {
        fs::write(world.dir.path().join("pulls.json"), rows.to_string()).unwrap();
        let report =
            reconcile::run(&world.settings(&[]), Some(999999), &[], Some(&gh), NOW).unwrap();
        assert_eq!(
            kinds(&report).contains(&("merged-in-review", "T-1")),
            expected
        );
    }
    // Both items are 72 hours old at the 24-hour default.
    let pulls =
        |rows: Value| fs::write(world.dir.path().join("pulls.json"), rows.to_string()).unwrap();
    let stale = || reconcile::run(&world.settings(&[]), None, &[], Some(&gh), NOW).unwrap();
    // A merged pull request: the In Review item is merged-in-review, the In
    // Progress one is stale with its pull request merged, never in review.
    pulls(json!([{"state":"MERGED","mergedAt":"2026-10-01T00:00:00Z","isCrossRepository":false}]));
    let report = stale();
    assert_eq!(
        kinds(&report),
        [("merged-in-review", "T-1"), ("started-stale", "T-2")],
        "{report:?}"
    );
    assert_eq!(detail(&report, "started-stale", "T-2")["pr"], "merged");
    // An open pull request is live work, whatever the clock says.
    pulls(json!([{"state":"OPEN","isCrossRepository":false}]));
    assert!(stale().findings.is_empty());
    // A probe gh refuses: each item names it with gh's words and stays
    // stale, its pull request unverified.
    fs::write(world.dir.path().join("gh.fail"), "").unwrap();
    let report = stale();
    for id in ["T-1", "T-2"] {
        let cause = detail(&report, "pr-probe-failed", id)["cause"].clone();
        assert!(
            cause
                .as_str()
                .unwrap_or_default()
                .contains("gh-stub: pr-list-unavailable"),
            "{report:?}"
        );
        assert_eq!(
            detail(&report, "started-stale", id)["pr"],
            "unverified",
            "{report:?}"
        );
    }
    fs::remove_file(world.dir.path().join("gh.fail")).unwrap();
    // A reply that is no JSON fails the probe; a fresh item stays fresh.
    fs::write(world.dir.path().join("pulls.json"), "not-json\n").unwrap();
    let report = reconcile::run(&world.settings(&[]), Some(999999), &[], Some(&gh), NOW).unwrap();
    assert_eq!(kinds(&report), [("pr-probe-failed", "T-1")], "{report:?}");
    // No gh at all.
    let report = world.run();
    assert!(kinds(&report).contains(&("pr-probe-failed", "T-1")));
    assert!(
        !detail(&report, "pr-probe-failed", "T-1")["cause"]
            .as_str()
            .unwrap_or_default()
            .is_empty()
    );
    assert!(kinds(&report).contains(&("started-stale", "T-1")));
}

fn release_item(id: &str) -> Value {
    issue(
        id,
        "Verifying",
        "started",
        "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: release; Trigger: release owner/repo v*; Deadline: +72h",
        None,
    )
}

/// A `gh pr list --json state,mergedAt,isCrossRepository,url` row.
fn merged_pull(number: u64, at: &str) -> Value {
    json!({"state":"MERGED", "mergedAt":at, "isCrossRepository":false,
        "url":format!("https://github.com/owner/repo/pull/{number}")})
}

/// GitHub's `GET /repos/owner/repo/pulls/N` reply, the fields of it the judge reads.
fn rest_pull(number: u64, at: &str, oid: &str) -> Value {
    json!({"number":number, "state":"closed", "title":"merged work", "body":null, "merged":true, "merged_at":at, "merge_commit_sha":oid,
        "author_association":"NONE", "head":{"sha":"0000000000000000000000000000000000000000", "ref":"merged-work", "repo":null}, "base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"}, "user":null})
}

fn release(tag: &str, at: &str) -> Value {
    json!({"tag_name":tag, "published_at":at, "draft":false})
}

const OID: &str = "1111111111111111111111111111111111111111";

/// One release world: its items, the files its `gh` answers from
/// (`pulls.json`, or `pulls-<branch>.json` for one branch; `pull-<number>.json`;
/// `releases-<page>.json`; `compare-<tag>.json`; a missing file is a failed
/// call), the verb's answer
/// and the `gh` calls it made.
fn release_world(
    items: Vec<Value>,
    files: &[(&str, Value)],
) -> (orch_runtime::Result<reconcile::Report>, Vec<String>) {
    release_world_named(items, files, &[])
}

/// [`release_world`] with the merged pull requests a reader names.
fn release_world_named(
    items: Vec<Value>,
    files: &[(&str, Value)],
    merged: &[&str],
) -> (orch_runtime::Result<reconcile::Report>, Vec<String>) {
    let world = World::new(items);
    let dir = world.dir.path();
    let gh = dir.join("gh");
    support::write_executable(
        &gh,
        "#!/bin/sh\nd=\"${0%/*}\"\nprintf '%s\\n' \"$*\" >>\"$d/gh.log\"\ncase \"$1 $2\" in\n'pr list') f=\"$d/pulls-$6.json\"; [ -f \"$f\" ] || f=\"$d/pulls.json\" ;;\n'api repos/owner/repo/pulls/'*) f=\"$d/pull-${2##*/}.json\" ;;\n'api repos/owner/repo/releases?'*) f=\"$d/releases-${2##*page=}.json\" ;;\n'api repos/owner/repo/compare/'*) f=\"$d/compare-${2##*...}.json\" ;;\n*) exit 1 ;;\nesac\n[ -f \"$f\" ] || { echo 'gh-stub: HTTP 502' >&2; exit 1; }\ncat \"$f\"\n",
    );
    for (name, value) in files {
        fs::write(dir.join(name), value.to_string()).unwrap();
    }
    let merged: Vec<String> = merged.iter().map(|m| (*m).to_owned()).collect();
    let report = reconcile::run(&world.settings(&[]), None, &merged, Some(&gh), NOW);
    let calls = fs::read_to_string(dir.join("gh.log"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    (report, calls)
}

/// The released release reads, each through the real probe and the shared
/// judge: the publication that fires the box, the unfired box, a blocker,
/// every page of the list, a draft, a publication before the merge, a tag
/// behind the merge commit, one release history shared by every item, and
/// each read that cannot answer.
#[test]
fn release_merge_evidence_from_the_real_probe_reaches_the_shared_judge() {
    let pulls = json!([merged_pull(1, "2026-10-01T00:00:00.123Z")]);
    let rest = rest_pull(1, "2026-10-01T00:00:00Z", OID);
    let ahead = json!({"status":"ahead"});
    let line = |report: &reconcile::Report, id: &str| {
        report
            .lines
            .iter()
            .find(|l| l.starts_with(&format!("verifying {id} ")))
            .cloned()
            .unwrap_or_default()
    };
    // A publication after the merge fires the box: its deadline counts from it.
    let (report, _) = release_world(
        vec![release_item("T-1")],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            (
                "releases-1.json",
                json!([release("v1", "2026-10-02T00:00:00Z")]),
            ),
            ("compare-v1.json", ahead.clone()),
        ],
    );
    let report = report.unwrap();
    assert_eq!(
        (report.counts.items, report.counts.due),
        (1, 1),
        "{report:?}"
    );
    assert!(line(&report, "T-1").contains(
        "status=due deadline=2026-10-05T00:00:00Z merged=2026-10-01T00:00:00Z blocked_by=-"
    ));
    assert!(report.findings.is_empty(), "{report:?}");
    // No release yet: waiting with no deadline, never overdue, the merge kept.
    let (report, _) = release_world(
        vec![release_item("T-1")],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            ("releases-1.json", json!([])),
        ],
    );
    let report = report.unwrap();
    assert_eq!(report.counts.waiting, 1, "{report:?}");
    assert!(line(&report, "T-1").contains("status=waiting deadline=- merged=2026-10-01T00:00:00Z"));
    assert!(report.findings.is_empty(), "{report:?}");
    // A fired box with an open blocker is blocked.
    let mut blocked = release_item("T-1");
    blocked["inverseRelations"]["nodes"] = json!([{"id":"r-1", "type":"blocks",
        "issue":{"id":"uuid-KEN-99", "identifier":"KEN-99", "title":"KEN-99",
            "state":{"name":"In Progress", "type":"started"}}}]);
    let (report, _) = release_world(
        vec![blocked],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            (
                "releases-1.json",
                json!([release("v1", "2026-10-02T00:00:00Z")]),
            ),
            ("compare-v1.json", ahead.clone()),
        ],
    );
    let report = report.unwrap();
    assert_eq!(report.counts.blocked, 1, "{report:?}");
    assert!(line(&report, "T-1").contains(
        "status=blocked deadline=2026-10-05T00:00:00Z merged=2026-10-01T00:00:00Z blocked_by=KEN-99"
    ));
    // Every page is read; a match on the second page fires.
    let full: Vec<Value> = (0..100)
        .map(|n| release(&format!("build-{n}"), "2026-10-02T00:00:00Z"))
        .collect();
    let (report, calls) = release_world(
        vec![release_item("T-1")],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            ("releases-1.json", json!(full)),
            (
                "releases-2.json",
                json!([release("v1", "2026-10-02T12:00:00Z")]),
            ),
            ("compare-v1.json", ahead.clone()),
        ],
    );
    assert!(line(&report.unwrap(), "T-1").contains("status=due deadline=2026-10-05T12:00:00Z"));
    assert_eq!(
        calls.iter().filter(|c| c.contains("/releases?")).count(),
        2,
        "{calls:?}"
    );
    // A draft never fires; a publication before the merge never fires; the
    // earliest publication after it does.
    let (report, _) = release_world(
        vec![release_item("T-1")],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            (
                "releases-1.json",
                json!([
                    {"tag_name":"v9", "published_at":null, "draft":true},
                    release("v0", "2026-09-30T00:00:00Z"),
                    release("v3", "2026-10-03T00:00:00Z"),
                    release("v2", "2026-10-02T06:00:00Z"),
                ]),
            ),
            ("compare-v0.json", ahead.clone()),
            ("compare-v2.json", ahead.clone()),
            ("compare-v3.json", ahead.clone()),
            ("compare-v9.json", ahead.clone()),
        ],
    );
    assert!(line(&report.unwrap(), "T-1").contains("deadline=2026-10-05T06:00:00Z"));
    // A tag behind the merge commit is passed over.
    let (report, _) = release_world(
        vec![release_item("T-1")],
        &[
            ("pulls.json", pulls.clone()),
            ("pull-1.json", rest.clone()),
            (
                "releases-1.json",
                json!([
                    release("v1", "2026-10-02T00:00:00Z"),
                    release("v2", "2026-10-02T12:00:00Z")
                ]),
            ),
            ("compare-v1.json", json!({"status":"behind"})),
            ("compare-v2.json", ahead.clone()),
        ],
    );
    assert!(line(&report.unwrap(), "T-1").contains("deadline=2026-10-05T12:00:00Z"));
    // Two items share one release history, each judged from its own merge.
    let (report, calls) = release_world(
        vec![release_item("T-1"), release_item("T-2")],
        &[
            (
                "pulls-t-1.json",
                json!([merged_pull(1, "2026-10-02T00:00:00Z")]),
            ),
            ("pull-1.json", rest_pull(1, "2026-10-02T00:00:00Z", OID)),
            (
                "pulls-t-2.json",
                json!([merged_pull(2, "2026-10-01T00:00:00Z")]),
            ),
            ("pull-2.json", rest_pull(2, "2026-10-01T00:00:00Z", OID)),
            (
                "releases-1.json",
                json!([
                    release("v2", "2026-10-02T12:00:00Z"),
                    release("v1", "2026-10-01T12:00:00Z")
                ]),
            ),
            ("compare-v1.json", ahead.clone()),
            ("compare-v2.json", ahead.clone()),
        ],
    );
    let report = report.unwrap();
    assert!(
        line(&report, "T-1").contains("deadline=2026-10-05T12:00:00Z"),
        "{report:?}"
    );
    assert!(
        line(&report, "T-2").contains("deadline=2026-10-04T12:00:00Z"),
        "{report:?}"
    );
    assert_eq!(
        calls.iter().filter(|c| c.contains("/releases?")).count(),
        1,
        "{calls:?}"
    );
    // Each read that cannot answer refuses the verb, its item named.
    for (case, key, files) in [
        (
            "merged pull",
            "verifying-merge-unread",
            vec![("pulls.json", pulls.clone())],
        ),
        (
            "merge commit",
            "verifying-release-unread",
            vec![
                (
                    "pulls.json",
                    json!([merged_pull(1, "2026-10-01T00:00:00Z")]),
                ),
                ("pull-1.json", rest_pull(1, "2026-10-01T00:00:00Z", "abc")),
                (
                    "releases-1.json",
                    json!([release("v1", "2026-10-02T00:00:00Z")]),
                ),
                ("compare-v1.json", ahead.clone()),
            ],
        ),
        (
            "release page",
            "verifying-release-unread",
            vec![("pulls.json", pulls.clone()), ("pull-1.json", rest.clone())],
        ),
        (
            "release fields",
            "verifying-release-unread",
            vec![
                ("pulls.json", pulls.clone()),
                ("pull-1.json", rest.clone()),
                (
                    "releases-1.json",
                    json!([{"tag_name":"v1", "published_at":"2026-10-02T00:00:00Z"}]),
                ),
            ],
        ),
        (
            "comparison",
            "verifying-release-unread",
            vec![
                ("pulls.json", pulls.clone()),
                ("pull-1.json", rest.clone()),
                (
                    "releases-1.json",
                    json!([release("v1", "2026-10-02T00:00:00Z")]),
                ),
            ],
        ),
        (
            "comparison status",
            "verifying-release-unread",
            vec![
                ("pulls.json", pulls.clone()),
                ("pull-1.json", rest.clone()),
                (
                    "releases-1.json",
                    json!([release("v1", "2026-10-02T00:00:00Z")]),
                ),
                ("compare-v1.json", json!({"status":"unknown"})),
            ],
        ),
    ] {
        let (report, _) = release_world(vec![release_item("T-1")], &files);
        let err = report.expect_err(case);
        assert_eq!(err.key(), key, "{case}");
        assert!(
            err.fields().iter().any(|(k, v)| k == "issue" && v == "T-1"),
            "{case}"
        );
    }
    // A merge on another branch, which the branch probe cannot find, named
    // by the reader: the boxes count from the latest named merge, read from
    // GitHub, and the probe is not asked.
    let releases = (
        "releases-1.json",
        json!([release("v1", "2026-10-02T00:00:00Z")]),
    );
    let (report, calls) = release_world_named(
        vec![release_item("T-1")],
        &[
            ("pulls.json", json!([])),
            ("pull-7.json", rest_pull(7, "2026-09-30T00:00:00Z", OID)),
            ("pull-8.json", rest_pull(8, "2026-10-01T00:00:00Z", OID)),
            releases.clone(),
            ("compare-v1.json", ahead.clone()),
        ],
        &["T-1=owner/repo#7", "T-1=owner/repo#8"],
    );
    let report = report.unwrap();
    assert!(
        line(&report, "T-1").contains(
            "status=due deadline=2026-10-05T00:00:00Z merged=2026-10-01T00:00:00Z blocked_by=-"
        ),
        "{report:?}"
    );
    assert!(report.findings.is_empty(), "{report:?}");
    assert!(!calls.iter().any(|c| c.starts_with("pr list")), "{calls:?}");
    // A named pull request whose read fails refuses, its item named.
    let (report, _) = release_world_named(
        vec![release_item("T-1")],
        &[("pulls.json", pulls.clone())],
        &["T-1=owner/repo#9"],
    );
    let err = report.unwrap_err();
    assert_eq!(err.key(), "verifying-merge-unread");
    assert!(err.fields().iter().any(|(k, v)| k == "issue" && v == "T-1"));
    // A value that names no item and pull request, and an item the
    // inventory judges no box of, refuse before any GitHub read.
    let mut started = release_item("T-2");
    started["state"] = json!({"name":"In Progress","type":"started"});
    for (merged, key, field) in [
        ("T-1=owner/repo", "merged-invalid", "T-1=owner/repo"),
        ("T-1=owner#7", "merged-invalid", "T-1=owner#7"),
        ("=owner/repo#7", "merged-invalid", "=owner/repo#7"),
        ("T-1=owner/repo#0", "merged-invalid", "T-1=owner/repo#0"),
        ("T-9=owner/repo#7", "merged-unjudged", "T-9"),
        ("T-2=owner/repo#7", "merged-unjudged", "T-2"),
    ] {
        let (report, calls) = release_world_named(
            vec![release_item("T-1"), started.clone()],
            &[("pulls.json", pulls.clone())],
            &[merged],
        );
        let err = report.expect_err(merged);
        assert_eq!(err.key(), key, "{merged}");
        assert_eq!(err.fields()[0].1, field, "{merged}");
        assert!(calls.is_empty(), "{merged}: {calls:?}");
    }
    // The verb's flag reaches the judge.
    let world = World::new(vec![release_item("T-1")]);
    let out = world.cli(&["reconcile-items", "--merged", "T-1=owner/repo#0"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["refusal"]["key"],
        "merged-invalid"
    );
}

fn repair_passes(mode: &str) {
    use orch_runtime::schedule::{Clock, Duty, SystemClock};
    use orch_runtime::state::Locking;
    use orch_runtime::watch::{Baseline, Tick, tracker};
    // A rate-limited update ends the owner read: no read-back, no comment
    // read, no answer delivered on that pass.
    let quota = mode == "write.quota";
    let landed = mode != "write.drop" && !quota;
    let world = World::new(vec![issue(
        "T-7",
        "In Progress",
        "started",
        "Engineering body.\n",
        None,
    )]);
    if !mode.is_empty() {
        fs::write(world.dir.path().join(mode), "").unwrap();
    }
    let comment = |id: &str, email: &str, at: &str, body: &str| {
        json!({"id":id, "body":body, "createdAt":at, "updatedAt":at,
            "user":{"name":"Maya Owner", "email":email}})
    };
    fs::write(
        world.dir.path().join("comments-T-7.json"),
        json!({"issue":{"comments":{"nodes":[
            comment("question-1", "overseer@example.test", "2026-10-01T00:00:02Z", "Read the log?"),
            comment("answer-1", "Owner@Example.test", "2026-10-01T00:05:00Z", "yes"),
        ]}}})
        .to_string(),
    )
    .unwrap();
    let mail = world.dir.path().join("tmp/lane-mail/overseer");
    fs::create_dir_all(&mail).unwrap();
    let ask = json!({"id":"1780000000-12-34","kind":"ask","at":"2026-10-01T00:00:00Z",
        "from":"overseer:test","to":"owner","issue":"T-7","do":"Read the deployment log.",
        "text":"Read the log?","options":["yes","hold"],"reserved":true,
        "wait":120,"deadline":"2099-01-01T00:00:00Z","tracker_pending":true});
    let posted = json!({"id":"1780000000-12-35","kind":"tracker-posted","at":"2026-10-01T00:00:01Z",
        "from":"overseer:test","re":"1780000000-12-34","issue":"T-7","tracker_label":"owner-gated",
        "tracker_comment":"question-1","text":""});
    fs::write(mail.join("to-overseer.jsonl"), format!("{ask}\n{posted}\n")).unwrap();
    let real_mail =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../mailbox/scripts/lane-mail");
    let cli = support::isolated_program(&real_mail.canonicalize().unwrap());
    let cli = cli.display().to_string();
    // The watch runs in the project checkout, the repository the mailbox
    // takes an answer's send to belong to; this process runs this row alone.
    std::env::set_current_dir(world.dir.path()).unwrap();
    let settings = world.settings(&[
        ("LANE_MAIL_CLI", &cli),
        ("LINEAR_TEAM", "T"),
        ("ORCH_OWNER_EMAIL", "owner@example.test"),
        ("ORCH_OWNER_ASK_LABEL", "owner-gated"),
    ]);
    // The checkout's fleet record, where the mailbox finds the overseer an
    // owner answer goes to; one with no server, so no tmux server is read.
    let mut record: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-oversee.json")).unwrap();
    record["overseer"] = json!({"runtime": "tmux", "harness": "claude"});
    record["lanes"] = json!([]);
    let fleet = world.dir.path().join("tmp/workflow-state-oversee.json");
    fs::write(&fleet, record.to_string()).unwrap();
    let mut duty = tracker::body(tracker::Context {
        fleet,
        settings,
        since: None,
        gh: world.dir.path().join("gh-missing"),
        repos: Vec::new(),
        locking: Locking::FLOCK,
        nonce: 1,
        owner: None,
        shared: tracker::Shared::default(),
    });
    let delivered = || {
        fs::read_dir(&mail)
            .unwrap()
            .map(|entry| fs::read_to_string(entry.unwrap().path()).unwrap_or_default())
            .map(|text| text.matches("\"delivery_id\":\"linear:answer-1\"").count())
            .sum::<usize>()
    };
    let baseline = Baseline::default();
    let clock = SystemClock;
    for pass in [1, 2] {
        fs::write(world.dir.path().join("linear.log"), "").unwrap();
        duty(&Tick {
            duty: Duty::Tracker,
            now: clock.now(),
            wall: NOW,
            baseline: &baseline,
            clock: &clock,
        })
        .unwrap();
        let calls = fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
        assert_eq!(
            calls.contains("issues update T-7 --description"),
            pass == 1 || !landed,
            "{mode} pass {pass}: {calls}"
        );
        assert_eq!(
            calls.contains("issues get T-7 --format=safe"),
            !quota && (pass == 1 || !landed),
            "{mode} pass {pass}: {calls}"
        );
        assert_eq!(
            calls.contains("comments bulk-list T-7 --format=safe"),
            !quota,
            "{mode} pass {pass}: {calls}"
        );
        assert_eq!(delivered(), usize::from(!quota), "{mode} pass {pass}");
    }
}

#[test]
fn an_owner_answer_is_delivered_once_whatever_its_description_repair_did() {
    const ROW: &str = "an_owner_answer_is_delivered_once_whatever_its_description_repair_did";
    if let Some(mode) = std::env::var_os("REPAIR_CHILD") {
        repair_passes(&mode.to_string_lossy());
        return;
    }
    // The duty says an unconfirmed repair on this process's stderr: the
    // passes run in a child whose stderr the row reads.
    for (mode, said) in [
        ("write.drop", 2),
        ("", 0),
        ("write.lost", 0),
        ("write.quota", 0),
    ] {
        let out = support::program(std::env::current_exe().unwrap())
            .args(["--exact", ROW, "--nocapture"])
            .env("REPAIR_CHILD", mode)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && stdout.contains("1 passed"),
            "{mode}: {stdout}{stderr}"
        );
        assert_eq!(
            stderr
                .matches("lane-mail: tracker-unwritten issue=T-7 cause=description\n")
                .count(),
            said,
            "{mode}: {stderr}"
        );
    }
}

#[test]
fn completed_checklists_from_the_real_completion_owner_leave_no_findings() {
    let world = World::new(vec![
        issue(
            "T-1",
            "In Review",
            "started",
            "## Done when\n- [ ] branch proof\n- [ ] second proof",
            None,
        ),
        issue(
            "T-2",
            "In Review",
            "started",
            "## Done when\n- [x] branch proof\n  Evidence: branch tests\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: 2026-10-02T00:00:00Z",
            None,
        ),
    ]);
    let proof = world.dir.path().join("proof.txt");
    fs::write(&proof, "1: branch tests passed\n2: deployment log read\n").unwrap();
    for (id, extra) in [
        ("T-1", vec![]),
        ("T-2", vec!["--post-merge-at", "2026-10-01T00:00:00Z"]),
    ] {
        let out = support::program(world.dir.path().join("linear"))
            .current_dir(world.dir.path())
            .args([
                "issues",
                "complete",
                id,
                "--done-when-met",
                "all",
                "--evidence-file",
            ])
            .arg(&proof)
            .args(extra)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{id}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let report = world.run();
    assert!(report.findings.is_empty(), "{report:?}");
    assert!(report.lines.is_empty());
    let stored: Value =
        serde_json::from_str(&fs::read_to_string(world.dir.path().join("issues.json")).unwrap())
            .unwrap();
    for row in stored["issues"]["nodes"].as_array().unwrap() {
        assert_eq!(row["state"]["type"], "completed");
        assert!(!row["description"].as_str().unwrap().contains("- [ ]"));
    }
}

#[test]
fn a_missing_merge_stays_a_finding_but_a_failed_verification_read_refuses() {
    let world = World::new(vec![issue(
        "T-1",
        "Verifying",
        "started",
        "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: +24h",
        None,
    )]);
    let gh = world.dir.path().join("gh");
    support::write_executable(&gh, "#!/bin/sh\nprintf '[]\\n'\n");
    let report = reconcile::run(&world.settings(&[]), None, &[], Some(&gh), NOW).unwrap();
    assert!(kinds(&report).contains(&("verifying-merge-unread", "T-1")));
    assert!(report.lines.is_empty());
    let err = reconcile::run(
        &world.settings(&[]),
        None,
        &[],
        Some(&world.dir.path().join("missing-gh")),
        NOW,
    )
    .unwrap_err();
    assert_eq!(err.key(), "verifying-merge-unread");
    assert!(
        err.fields().iter().any(|(k, v)| k == "issue" && v == "T-1"),
        "{:?}",
        err.fields()
    );
}

#[test]
fn future_tracker_updates_never_become_stale_at_a_zero_hour_threshold() {
    let mut future = issue("T-FUTURE", "In Progress", "started", "", None);
    future["updatedAt"] = json!(agent_runtime::clock::iso_utc(NOW + 1800));
    let world = World::new(vec![future]);
    let report = reconcile::run(
        &world.settings(&[]),
        Some(0),
        &[],
        Some(&world.dir.path().join("missing-gh")),
        NOW,
    )
    .unwrap();
    assert!(report.findings.is_empty(), "{report:?}");
}

#[test]
fn a_stale_started_container_keeps_its_started_findings_beside_container_parked() {
    let world = World::new(vec![
        issue("T-1", "In Progress", "started", "", None),
        issue("T-2", "Done", "completed", "", Some("T-1")),
    ]);
    let gh = world.dir.path().join("gh");
    support::write_executable(&gh, "#!/bin/sh\nprintf '[]\\n'\n");
    let report = reconcile::run(&world.settings(&[]), None, &[], Some(&gh), NOW).unwrap();
    assert_eq!(
        kinds(&report),
        [
            ("container-parked", "T-1"),
            ("started-stale", "T-1"),
            ("verifying-empty", "T-1")
        ],
        "{report:?}"
    );
    let stale = &report.findings[1].detail;
    assert_eq!(stale["age_hours"], 72);
    assert_eq!(stale["pr"], "absent");
}

#[test]
fn a_checklist_the_parser_could_not_read_refuses_the_verb() {
    let world = World::new(vec![issue(
        "T-1",
        "Verifying",
        "started",
        "## Done when\n- [x] proof\n  Evidence: tests",
        None,
    )]);
    let out = world.cli(&["reconcile-items"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // The real parser over a failing dependency: no checklist was read.
    let failing = world.dir.path().join("parser-path");
    fs::create_dir(&failing).unwrap();
    support::write_executable(&failing.join("jq"), "#!/bin/sh\nexit 127\n");
    let out = world.cli(&["reconcile-items"]);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["refusal"]["key"], "verifying-checklist-unread");
}

const WATCH_INVALID: &str = "The Verifying item has invalid post-merge metadata or an open branch-provable box. Correct its checklist before verification.";

fn verification_passes() {
    use orch_runtime::schedule::{Clock, Duty, SystemClock};
    use orch_runtime::watch::tracker::{Latest, TrackerInventory, VerifyingItem};
    use orch_runtime::watch::{Baseline, Change, Event, Tick, verifying};
    let world = World::new(vec![]);
    let item = |id: &str, description: &str| VerifyingItem {
        id: id.to_owned(),
        created_at: "2026-09-01T00:00:00Z".to_owned(),
        description: description.to_owned(),
        priority: "-".to_owned(),
        container: false,
        blocked_by_open: Vec::new(),
    };
    let shared = std::sync::Arc::new(std::sync::Mutex::new(Latest {
        tracker: Some(TrackerInventory {
            verifying: vec![item("T-1", "## Done when\n- [x] proof\n  Evidence: tests")],
            ..TrackerInventory::default()
        }),
        ..Latest::default()
    }));
    let context = |settings| verifying::Context {
        settings,
        gh: world.dir.path().join("gh-missing"),
        shared: shared.clone(),
        lines: verifying::Lines::default(),
    };
    let mut duty = verifying::body(context(world.settings(&[])));
    let row = |identity: &str, value: &str| Change::Set {
        kind: verifying::DEADLINE_ROW.to_owned(),
        identity: identity.to_owned(),
        value: value.to_owned(),
    };
    let mut baseline = Baseline::default();
    baseline.apply(row("T-1", "boxes=0"));
    let clock = SystemClock;
    let pass = |duty: &mut orch_runtime::watch::Body<'_>, baseline: &Baseline| {
        duty(&Tick {
            duty: Duty::Verification,
            now: clock.now(),
            wall: NOW,
            baseline,
            clock: &clock,
        })
    };
    // Read whole, the item's row stands as it is.
    let first = pass(&mut duty, &baseline).unwrap();
    assert!(first.changes.is_empty(), "{:?}", first.changes);
    let failing = world.dir.path().join("parser-path");
    fs::create_dir(&failing).unwrap();
    support::write_executable(&failing.join("jq"), "#!/bin/sh\nexit 127\n");
    assert_eq!(
        pass(&mut duty, &baseline).unwrap().changes,
        [Change::Clear {
            kind: verifying::DEADLINE_ROW.to_owned(),
            identity: "T-1".to_owned(),
        }]
    );
    fs::remove_dir_all(&failing).unwrap();
    // An invalid item, then a due one, then one whose merge is unread with
    // a row from an earlier pass: the due item is judged and its row
    // written, the unread one keeps its row.
    shared.lock().unwrap().tracker.as_mut().unwrap().verifying = vec![
        item("T-0", "## Done when\n- [ ] Post-merge: malformed"),
        item(
            "T-1",
            "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: 2026-10-02T00:00:00Z",
        ),
        item(
            "T-2",
            "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: +24h",
        ),
    ];
    baseline.apply(row(
        "T-2",
        "box=1 trigger=\"merge\" status=due deadline=2026-10-03T00:00:00Z",
    ));
    let produced = pass(&mut duty, &baseline).unwrap();
    assert!(
        produced
            .events
            .iter()
            .any(|e| matches!(e, Event::VerifyingDeadline { id, .. } if id == "T-1")),
        "{:?}",
        produced.events
    );
    let touched: Vec<&Change> = produced
        .changes
        .iter()
        .filter(|c| match c {
            Change::Set { identity, .. } | Change::Clear { identity, .. } => identity != "T-1",
            _ => true,
        })
        .collect();
    assert!(touched.is_empty(), "{touched:?}");
    assert!(
        produced
            .changes
            .iter()
            .any(|c| matches!(c, Change::Set { identity, .. } if identity == "T-1")),
        "{:?}",
        produced.changes
    );
    // No parser to run.
    let mut missing = verifying::body(context(
        world.settings(&[("OVERSEE_WATCH_TRACKER", "/nonexistent/linear")]),
    ));
    let err = pass(&mut missing, &baseline).unwrap_err();
    assert_eq!(err.key(), "missing-linear", "{err:?}");
}

#[test]
fn the_watch_reads_a_checklist_the_parser_could_not_read_as_invalid_and_keeps_no_deadline() {
    const ROW: &str =
        "the_watch_reads_a_checklist_the_parser_could_not_read_as_invalid_and_keeps_no_deadline";
    if std::env::var_os("VERIFICATION_CHILD").is_some() {
        verification_passes();
        return;
    }
    // The duty says the invalid item on this process's stderr: the passes
    // run in a child whose stderr the row reads.
    let out = support::program(std::env::current_exe().unwrap())
        .args(["--exact", ROW, "--nocapture"])
        .env("VERIFICATION_CHILD", "1")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success() && stdout.contains("1 passed"),
        "{stdout}{stderr}"
    );
    let said = |words: &str| format!("verifying-invalid issue={words}");
    // A reader of the watch's stderr file keys on each line's first word.
    assert!(
        stderr
            .lines()
            .filter(|l| l.contains("verifying-invalid issue="))
            .all(|l| l.starts_with("verifying-invalid issue=")),
        "{stderr}"
    );
    assert_eq!(
        stderr
            .matches(&said(&format!(
                "T-1\n{WATCH_INVALID}\ndone-when parse exit="
            )))
            .count(),
        1,
        "{stderr}"
    );
    assert!(
        stderr.contains(&said(&format!(
            "T-0\n{WATCH_INVALID}\nverifying-invalid issue=T-0\n{{"
        ))),
        "{stderr}"
    );
    assert!(stderr.contains("\"box\":1"), "{stderr}");
    assert!(
        stderr.contains(&said(&format!(
            "T-2\n{WATCH_INVALID}\nverifying-merge-unread issue=T-2\n"
        ))),
        "{stderr}"
    );
}
