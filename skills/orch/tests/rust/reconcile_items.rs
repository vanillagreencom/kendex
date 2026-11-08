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
    ]);
    let report = world.run();
    let found = kinds(&report);
    assert!(found.contains(&("container-parked", "T-1")));
    assert!(found.contains(&("verifying-empty", "T-1")));
    assert!(found.contains(&("done-unchecked", "T-4")));
    for id in ["T-5", "T-6", "T-8"] {
        assert!(!found.contains(&("container-parked", id)));
        assert!(!found.contains(&("done-unchecked", id)));
    }
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
    assert_eq!(report.counts.overdue, 1);
    assert_eq!(report.counts.items, 4);
    assert_eq!(report.lines.len(), 2);
    assert!(!found.iter().any(|(kind, _)| *kind == "started-stale"));
}

#[test]
fn settings_and_private_file_thresholds_scope_the_same_live_read() {
    let world = World::new(vec![issue("T-1", "In Progress", "started", "", None)]);
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
            reconcile::run(&settings, None, None, NOW)
                .unwrap_err()
                .key(),
            "reconcile-threshold-invalid"
        );
        assert!(
            reconcile::run(&settings, Some(999999), None, NOW)
                .unwrap()
                .findings
                .is_empty()
        );
    }
}

#[test]
fn merged_review_is_reported_before_age_and_a_failed_probe_keeps_its_finding() {
    let world = World::new(vec![issue("T-1", "In Review", "started", "", None)]);
    let gh = world.dir.path().join("gh");
    support::write_executable(
        &gh,
        "#!/bin/sh\n[ -z \"$GH_REPO\" ] && [ -z \"$GITHUB_REPOSITORY\" ] || exit 1\ncat \"${0%/*}/pulls.json\"\n",
    );
    for (rows, expected) in [
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
        let report = reconcile::run(&world.settings(&[]), Some(999999), Some(&gh), NOW).unwrap();
        assert_eq!(
            kinds(&report).contains(&("merged-in-review", "T-1")),
            expected
        );
    }
    let report = world.run();
    assert!(kinds(&report).contains(&("pr-probe-failed", "T-1")));
    assert!(kinds(&report).contains(&("started-stale", "T-1")));
}

#[test]
fn release_merge_evidence_from_the_real_probe_reaches_the_shared_judge() {
    let world = World::new(vec![issue(
        "T-1",
        "Verifying",
        "started",
        "## Done when\n- [ ] Post-merge: health; Where: logs; Why after merge: release; Trigger: release owner/repo v*; Deadline: +72h",
        None,
    )]);
    let gh = world.dir.path().join("gh");
    support::write_executable(
        &gh,
        "#!/bin/sh\ncase \"$1 $2\" in\n'pr list') echo '[{\"state\":\"MERGED\",\"mergedAt\":\"2026-10-01T00:00:00.123Z\",\"isCrossRepository\":false,\"url\":\"https://github.com/owner/repo/pull/1\",\"mergeCommit\":{\"oid\":\"1111111111111111111111111111111111111111\"}}]' ;;\n'api repos/owner/repo/releases?'*) echo '[{\"tag_name\":\"v1\",\"published_at\":\"2026-10-02T00:00:00Z\",\"draft\":false}]' ;;\n'api repos/owner/repo/compare/'*) echo '{\"status\":\"ahead\"}' ;;\n*) exit 1 ;;\nesac\n",
    );
    let report = reconcile::run(&world.settings(&[]), None, Some(&gh), NOW).unwrap();
    assert_eq!(report.counts.items, 1);
    assert_eq!(report.lines.len(), 1);
    assert!(report.lines[0].contains("merged=2026-10-01T00:00:00Z"));
    assert!(report.lines[0].contains("deadline=2026-10-05T00:00:00Z"));
    assert!(
        !kinds(&report)
            .iter()
            .any(|(kind, _)| *kind == "verifying-merge-unread")
    );
}

fn repair_passes(mode: &str) {
    use orch_runtime::schedule::{Clock, Duty, SystemClock};
    use orch_runtime::state::Locking;
    use orch_runtime::watch::{Baseline, Tick, tracker};
    let landed = mode != "write.drop";
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
            pass == 1 || !landed,
            "{mode} pass {pass}: {calls}"
        );
        assert!(
            calls.contains("comments bulk-list T-7 --format=safe"),
            "{mode} pass {pass}: {calls}"
        );
        assert_eq!(delivered(), 1, "{mode} pass {pass}");
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
    for (mode, said) in [("write.drop", 2), ("", 0), ("write.lost", 0)] {
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
    let report = reconcile::run(&world.settings(&[]), None, Some(&gh), NOW).unwrap();
    assert!(kinds(&report).contains(&("verifying-merge-unread", "T-1")));
    assert!(report.lines.is_empty());
    let err = reconcile::run(
        &world.settings(&[]),
        None,
        Some(&world.dir.path().join("missing-gh")),
        NOW,
    )
    .unwrap_err();
    assert_eq!(err.key(), "verifying-merge-unread");
}

#[test]
fn future_tracker_updates_never_become_stale_at_a_zero_hour_threshold() {
    let mut future = issue("T-FUTURE", "In Progress", "started", "", None);
    future["updatedAt"] = json!(agent_runtime::clock::iso_utc(NOW + 1800));
    let world = World::new(vec![future]);
    let report = reconcile::run(
        &world.settings(&[]),
        Some(0),
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
    let report = reconcile::run(&world.settings(&[]), None, Some(&gh), NOW).unwrap();
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

fn verification_passes() {
    use orch_runtime::schedule::{Clock, Duty, SystemClock};
    use orch_runtime::watch::tracker::{Latest, TrackerInventory, VerifyingItem};
    use orch_runtime::watch::{Baseline, Change, Tick, verifying};
    let world = World::new(vec![]);
    let item = VerifyingItem {
        id: "T-1".to_owned(),
        created_at: "2026-09-01T00:00:00Z".to_owned(),
        description: "## Done when\n- [x] proof\n  Evidence: tests".to_owned(),
        priority: "-".to_owned(),
        container: false,
        blocked_by_open: Vec::new(),
    };
    let shared = std::sync::Arc::new(std::sync::Mutex::new(Latest {
        tracker: Some(TrackerInventory {
            verifying: vec![item],
            ..TrackerInventory::default()
        }),
        ..Latest::default()
    }));
    let mut duty = verifying::body(verifying::Context {
        settings: world.settings(&[]),
        gh: world.dir.path().join("gh-missing"),
        shared,
        lines: verifying::Lines::default(),
    });
    let mut baseline = Baseline::default();
    baseline.apply(Change::Set {
        kind: verifying::DEADLINE_ROW.to_owned(),
        identity: "T-1".to_owned(),
        value: "boxes=0".to_owned(),
    });
    let clock = SystemClock;
    let pass = |duty: &mut orch_runtime::watch::Body<'_>| {
        duty(&Tick {
            duty: Duty::Verification,
            now: clock.now(),
            wall: NOW,
            baseline: &baseline,
            clock: &clock,
        })
        .unwrap()
    };
    // Read whole, the item's row stands as it is.
    let first = pass(&mut duty);
    assert!(first.changes.is_empty(), "{:?}", first.changes);
    let failing = world.dir.path().join("parser-path");
    fs::create_dir(&failing).unwrap();
    support::write_executable(&failing.join("jq"), "#!/bin/sh\nexit 127\n");
    assert_eq!(
        pass(&mut duty).changes,
        [Change::Clear {
            kind: verifying::DEADLINE_ROW.to_owned(),
            identity: "T-1".to_owned(),
        }]
    );
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
    assert_eq!(
        stderr.matches("verifying-invalid issue=T-1\n").count(),
        1,
        "{stderr}"
    );
}
