//! The merge-queue wait: `queue_watch::run` in-process on the fake clock,
//! the fixture `gh` and `github.sh` answering from reply maps a row rewrites
//! between polls, the failed-check probe reaching `verify-pr`'s own reads of
//! a recorded witness through the same `gh`, and the built binary where a
//! row proves the command's own refusal.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows run the library on the fake clock, read the record they wrote and run the built binary"
)]

use std::fs;
use std::path::PathBuf;
use std::process::Output;
use std::time::Duration;

mod support;

use orch_runtime::ops::Env;
use orch_runtime::ops::queue_watch::{Programs, QueueWatch, Reply, run};
use orch_runtime::state::Locking;
use serde_json::{Map, Value, json};
use support::{FakeClock, fixtures, tool_path};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const ITEM_ID: &str = "KEN-4687";
const REPO: &str = "owner/repo";
const PR: u64 = 7;
/// The recorded witnesses' head, which the probe rows hand `verify-pr`.
const HEAD: &str = "737bce791577e140436490e0fed5751bb5144a61";
const NODE_ID: &str = "PR_node123";
const LOCK: Locking = Locking::FLOCK;

fn env() -> Env {
    Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_123_456_789,
        nonce: 4242,
        owner: None,
    }
}

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

/// One row's world: the item record, the two fakes symlinked beside their
/// reply maps, and the maps a row edits between polls.
struct World {
    dir: tempfile::TempDir,
    item: PathBuf,
    replies: Map<String, Value>,
    threads: Map<String, Value>,
}

/// The queue read's pull request: in the queue (with or without a
/// merge-group head), armed only, out, or held behind a live group.
fn queue_body(pull: Value) -> Value {
    json!({"body": {"data": {"repository": {"pullRequest": pull}}}})
}

fn in_queue(head: Option<&str>) -> Value {
    queue_body(json!({
        "id": NODE_ID,
        "isInMergeQueue": true,
        "mergeQueueEntry": {
            "state": "QUEUED",
            "position": 1,
            "headCommit": head.map(|h| json!({"oid": h})),
            "mergeQueue": {"entries": {"nodes": []}}
        },
        "autoMergeRequest": {"enabledAt": "2026-07-24T10:00:00Z"}
    }))
}

fn armed_only() -> Value {
    queue_body(json!({
        "id": NODE_ID,
        "isInMergeQueue": false,
        "mergeQueueEntry": null,
        "autoMergeRequest": {"enabledAt": "2026-07-24T10:00:00Z"}
    }))
}

fn out() -> Value {
    queue_body(json!({
        "id": NODE_ID,
        "isInMergeQueue": false,
        "mergeQueueEntry": null,
        "autoMergeRequest": null
    }))
}

/// `in_queue`'s entry under another arm: `enabled_at` a timestamp, or
/// `None` for an entry enqueued directly, with no auto-merge request.
fn in_queue_armed(enabled_at: Option<&str>) -> Value {
    let mut body = in_queue(None);
    body["body"]["data"]["repository"]["pullRequest"]["autoMergeRequest"] =
        enabled_at.map_or(Value::Null, |at| json!({"enabledAt": at}));
    body
}

fn held_behind(ahead: u64) -> Value {
    queue_body(json!({
        "id": NODE_ID,
        "isInMergeQueue": true,
        "mergeQueueEntry": {
            "state": "QUEUED",
            "position": 2,
            "headCommit": null,
            "mergeQueue": {"entries": {"nodes": [
                {"position": 1, "headCommit": {"oid": "aaaa"}, "pullRequest": {"number": ahead}},
                {"position": 2, "headCommit": null, "pullRequest": {"number": PR}}
            ]}}
        },
        "autoMergeRequest": {"enabledAt": "2026-07-24T10:00:00Z"}
    }))
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let item = root.join(format!("workflow-state-{ITEM_ID}.json"));
        fs::write(&item, ITEM).unwrap();
        let fakes = fixtures().join("queue-watch");
        for name in ["gh", "github.sh"] {
            std::os::unix::fs::symlink(fakes.join(name), root.join(name)).unwrap();
        }
        let mut world = World {
            dir,
            item,
            replies: Map::new(),
            threads: Map::new(),
        };
        world.pull("OPEN", "MERGEABLE").threads(0);
        world
    }

    fn root(&self) -> PathBuf {
        self.dir.path().canonicalize().unwrap()
    }

    /// The `pr view` answer: the fields the wait and `verify-pr` each ask
    /// for, in one export.
    fn pull(&mut self, state: &str, mergeable: &str) -> &mut Self {
        self.replies.insert(
            format!("pr view {PR}"),
            json!({"body": {
                "state": state, "mergedAt": null, "mergeable": mergeable,
                "headRefOid": HEAD, "baseRefName": "main"
            }}),
        );
        self
    }

    fn queue(&mut self, reply: Value) -> &mut Self {
        self.replies.insert("queue".to_owned(), reply);
        self
    }

    fn threads(&mut self, unresolved: u64) -> &mut Self {
        self.threads.insert(
            format!("pr-threads {PR}"),
            json!({"body": {"count": unresolved, "unresolved_count": unresolved, "threads": []}}),
        );
        self
    }

    /// A guard mutation's answer: the payload on success, a GraphQL
    /// `errors` body with gh's nonzero exit otherwise.
    fn mutation(&mut self, name: &str, ok: bool) -> &mut Self {
        let reply = if ok {
            json!({"body": {"data": {name: {"clientMutationId": null, "mergeQueueEntry": {"id": "MQE_1"}}}}})
        } else {
            json!({"body": {"data": {name: null}, "errors": [{"message": format!("{name} refused")}]},
                   "exit": 1, "stderr": format!("gh: {name} refused")})
        };
        self.replies.insert(format!("mutation {name}"), reply);
        self
    }

    /// A recorded verify witness as the base of the replies, for a probe
    /// row.
    fn witness(&mut self, name: &str) -> &mut Self {
        let text =
            fs::read_to_string(fixtures().join(format!("gh/witnesses/{name}.json"))).unwrap();
        let map: Map<String, Value> = serde_json::from_str(&text).unwrap();
        for (key, value) in map {
            self.replies.entry(key).or_insert(value);
        }
        self
    }

    /// Publish the maps the fakes read.
    fn write(&self) -> &Self {
        let root = self.root();
        fs::write(
            root.join("gh.json"),
            Value::Object(self.replies.clone()).to_string(),
        )
        .unwrap();
        fs::write(
            root.join("github.json"),
            Value::Object(self.threads.clone()).to_string(),
        )
        .unwrap();
        self
    }

    fn programs(&self) -> Programs {
        let root = self.root();
        Programs {
            gh: root.join("gh"),
            github: root.join("github.sh"),
        }
    }

    fn request(&self, poll: u64, max_wait: u64) -> QueueWatch {
        QueueWatch {
            repo: REPO.to_owned(),
            pr: PR,
            poll: secs(poll),
            max_wait: secs(max_wait),
            arm_grace: secs(120),
            confirm_polls: 2,
            probe_interval: secs(120),
            check_probe: false,
            guard: true,
        }
    }

    fn gh_log(&self) -> Vec<String> {
        fs::read_to_string(self.root().join("gh.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The memory the wait wrote on the item.
    fn memory(&self) -> Value {
        let doc: Value = serde_json::from_str(&fs::read_to_string(&self.item).unwrap()).unwrap();
        doc.get("queue_watch").cloned().unwrap_or(Value::Null)
    }

    /// The guard mutations the fake `gh` was asked to send.
    fn mutations(&self) -> Vec<String> {
        self.gh_log()
            .into_iter()
            .filter(|l| l.contains("query=mutation"))
            .collect()
    }

    /// Run the wait on the fake clock while `drive` rewrites the maps and
    /// passes time between polls; the wait's own thread answers. A wait
    /// still polling after the drive is released to its deadline one poll
    /// at a time, and only while it sleeps, so a poll's reads, however slow
    /// the host, spend none of its budget; past a real-time bound it is
    /// released regardless, so a wrong route answers a wrong reply rather
    /// than hanging the row.
    fn wait(&mut self, request: &QueueWatch, drive: impl FnOnce(&mut World, &FakeClock)) -> Reply {
        self.write();
        let clock = FakeClock::new();
        let (item, programs, root) = (self.item.clone(), self.programs(), self.root());
        std::thread::scope(|s| {
            let handle = s.spawn(|| run(&item, request, &programs, &root, &clock, &env(), LOCK));
            drive(self, &clock);
            let bound = std::time::Instant::now() + secs(60);
            while !handle.is_finished() {
                if clock.sleepers() > 0 || std::time::Instant::now() >= bound {
                    clock.release(request.poll);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            handle
                .join()
                .expect("the wait's thread")
                .expect("the wait's reply")
        })
    }

    /// One call of the binary, the fakes ahead of the inherited PATH.
    fn binary(&self, args: &[&str]) -> Output {
        self.write();
        let root = self.root();
        support::isolated()
            .args(["--state-dir", &root.display().to_string()])
            .arg("queue-watch")
            .args(["--item", ITEM_ID, "--repo", REPO, "--pr", &PR.to_string()])
            .args(args)
            .env(
                "PATH",
                tool_path(&[fixtures().join("queue-watch").as_path()]),
            )
            .env("GH_FAKE_REPLIES", root.join("gh.json"))
            .env("GH_FAKE_LOG", root.join("gh.log"))
            .current_dir(&root)
            .output()
            .unwrap()
    }
}

/// A later run reads the membership an earlier run recorded on the item,
/// so a pull request that is out of the queue when the later run starts is
/// `ejected` after its confirmation polls, never `not_queued`: the
/// transition the first run's deadline cut off is re-observed by the
/// record, not by nobody.
#[test]
fn a_second_run_reads_the_membership_the_first_recorded_so_leaving_the_queue_is_ejected() {
    let mut world = World::new();
    world.queue(in_queue(None));
    let first = world.request(10, 10);
    let reply = world.wait(&first, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!((reply.verdict, reply.was_in_merge_queue), ("queued", true));
    let memory = world.memory();
    assert_eq!(
        (
            memory["pr"].as_u64(),
            memory["was_in_queue"].as_bool(),
            memory["head"].as_str()
        ),
        (Some(PR), Some(true), Some(HEAD))
    );
    world.queue(out());
    let second = world.request(10, 30);
    let reply = world.wait(&second, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "ejected", Some("merge_group_failed"), 2)
    );
}

/// An unresolved review thread read while the pull request is queued pulls
/// the arm: the disarm first, then the dequeue by the pull request's node
/// id, each recorded on the item and settled, and the verdict `dequeued`.
#[test]
fn late_finding_while_queued_disarms_then_dequeues() {
    let mut world = World::new();
    world
        .queue(in_queue(None))
        .threads(1)
        .mutation("disablePullRequestAutoMerge", true)
        .mutation("dequeuePullRequest", true);
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.cause,
            reply.unresolved_count
        ),
        ("complete", "dequeued", Some("late_findings"), Some(1))
    );
    let log = world.gh_log();
    let disarm = log
        .iter()
        .position(|l| l.contains("disablePullRequestAutoMerge") && l.contains(NODE_ID));
    let dequeue = log
        .iter()
        .position(|l| l.contains("dequeuePullRequest") && l.contains(NODE_ID));
    assert!(
        disarm.zip(dequeue).is_some_and(|(d, q)| d < q),
        "the disarm precedes the dequeue: {log:?}"
    );
    let guard = &world.memory()["guard"];
    assert_eq!(
        (
            guard["threads"].as_u64(),
            guard["disarm"]["state"].as_str(),
            guard["dequeue"]["state"].as_str()
        ),
        (Some(1), Some("done"), Some("done"))
    );
}

#[test]
fn a_late_arm_is_bound_to_the_memory_so_a_re_arm_is_a_new_guard() {
    let mut world = World::new();
    world.queue(out());
    let request = world.request(10, 30);
    let first = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world
            .queue(in_queue(None))
            .threads(1)
            .mutation("disablePullRequestAutoMerge", true)
            .mutation("dequeuePullRequest", true)
            .write();
        clock.release(secs(10));
    });
    assert_eq!(first.verdict, "dequeued");
    assert_eq!(
        world.memory()["enabled_at"],
        "2026-07-24T10:00:00Z",
        "the first arm a poll read is bound"
    );
    world.queue(in_queue_armed(Some("2026-07-24T11:00:00Z")));
    let second = world.wait(&request, |_, _| {});
    assert_eq!(second.verdict, "dequeued");
    assert_eq!(world.mutations().len(), 4, "{:?}", world.gh_log());
}

#[test]
fn a_dequeue_an_earlier_run_landed_is_sent_again_for_a_direct_re_enqueue() {
    let mut world = World::new();
    world
        .queue(in_queue(None))
        .threads(1)
        .mutation("disablePullRequestAutoMerge", true)
        .mutation("dequeuePullRequest", true);
    let request = world.request(10, 30);
    assert_eq!(world.wait(&request, |_, _| {}).verdict, "dequeued");
    world.queue(in_queue_armed(None));
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict),
        ("complete", "dequeued"),
        "{reply:?}"
    );
    let sent = world.mutations();
    assert_eq!(sent.len(), 3, "{sent:?}");
    assert!(sent[2].contains("dequeuePullRequest"), "{sent:?}");
}

#[test]
fn an_owed_guard_whose_threads_were_resolved_since_sends_nothing() {
    let mut world = World::new();
    world.queue(in_queue(None)).threads(0);
    let mut doc: Value = serde_json::from_str(&fs::read_to_string(&world.item).unwrap()).unwrap();
    doc["queue_watch"] = json!({
        "pr": PR, "head": HEAD, "enabled_at": "2026-07-24T10:00:00Z",
        "was_queued": true, "was_in_queue": true,
        "guard": {"threads": 1, "disarm": {"state": "owed"}, "dequeue": {"state": "owed"}}
    });
    fs::write(&world.item, serde_json::to_vec_pretty(&doc).unwrap()).unwrap();
    let request = world.request(10, 10);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(reply.verdict, "queued", "{reply:?}");
    assert!(world.mutations().is_empty(), "{:?}", world.gh_log());
    let guard = &world.memory()["guard"];
    assert_eq!(
        (
            guard["disarm"]["state"].as_str(),
            guard["dequeue"]["state"].as_str()
        ),
        (Some("unneeded"), Some("unneeded"))
    );
}

/// A guard half GitHub refused is loud: the reply names the failed
/// mutation and the pull request still queued, and the record keeps the
/// refusal beside the half that landed.
#[test]
fn late_finding_with_a_failed_dequeue_half_is_loud() {
    let mut world = World::new();
    world
        .queue(in_queue(None))
        .threads(2)
        .mutation("disablePullRequestAutoMerge", true)
        .mutation("dequeuePullRequest", false);
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("error", "dequeued", Some("late_findings_dequeue_failed"))
    );
    let error = reply.error.unwrap_or_default();
    assert!(
        error.contains("operation=dequeuePullRequest") && error.contains("threads=2"),
        "{error}"
    );
    let guard = &world.memory()["guard"];
    assert_eq!(
        (
            guard["disarm"]["state"].as_str(),
            guard["dequeue"]["state"].as_str()
        ),
        (Some("done"), Some("failed"))
    );
}

/// A conflicting head is read from `mergeable` ahead of the membership
/// transitions and confirmed like them: one reading ends nothing, and a
/// pull request that also left the queue routes to the restack, never to
/// a CI cycle for a failure CI never had.
#[test]
fn conflicting_outranks_ejected_and_is_confirmed() {
    let mut world = World::new();
    world.pull("OPEN", "CONFLICTING").queue(in_queue(None));
    let request = world.request(10, 60);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.queue(out()).write();
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "conflicting", Some("base_conflict"), 2)
    );
    assert!(reply.was_in_merge_queue);
}

/// An entry that exposes no merge-group head has nothing to read progress
/// from: the deadline says `progress_unobservable`, never `stalled`, and no
/// check-run read is made.
#[test]
fn no_head_commit_on_the_entry_is_progress_unobservable() {
    let mut world = World::new();
    world.queue(in_queue(None));
    let request = world.request(10, 10);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.progressing),
        ("timeout", "queued", Some("progress_unobservable"), None)
    );
    assert_eq!(
        (reply.progress_head_polls, reply.progress_check_reads),
        (0, 0)
    );
    assert!(
        !world.gh_log().iter().any(|l| l.contains("check-runs")),
        "no check-run read without a head"
    );
}

/// A headless `QUEUED` entry behind a live group names that group's pull
/// request, so the workflow waits for it instead of spending a recovery
/// cycle on an idle-looking queue.
#[test]
fn held_behind_a_live_group_names_the_entry_ahead() {
    let mut world = World::new();
    world.queue(held_behind(9));
    let request = world.request(10, 10);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.verdict, reply.cause, reply.queue_ahead_pr),
        ("queued", Some("blocked_by_entry_ahead"), Some(9))
    );
}

/// Membership lost for one poll and back the next is GitHub's view catching
/// up: below the confirmation count it routes nothing, and the deadline
/// reports the entry, not an ejection.
#[test]
fn one_poll_blip_is_not_an_ejection() {
    let mut world = World::new();
    world.queue(in_queue(None));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.queue(out()).write();
        clock.pass(secs(10));
        world.queue(in_queue(None)).write();
        clock.pass(secs(10));
        clock.release(secs(10));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.unconfirmed_verdict,
            reply.polls
        ),
        ("timeout", "queued", None, 3)
    );
}

/// A pull request no poll sees queued or armed is `not_queued` once the
/// arming grace has passed, not after the whole budget.
#[test]
fn never_armed_past_the_grace_is_not_queued() {
    let mut world = World::new();
    world.queue(out());
    let request = QueueWatch {
        arm_grace: secs(20),
        ..world.request(10, 60)
    };
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.pass(secs(10));
        clock.release(secs(10));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.cause,
            reply.polls,
            reply.was_queued
        ),
        ("timeout", "not_queued", Some("never_armed"), 3, false)
    );
}

/// A GraphQL `errors` reply is an error naming GitHub's message, never a
/// pull request read as out of the queue.
#[test]
fn queue_errors_array_is_an_error_never_not_queued() {
    let mut world = World::new();
    world.queue(json!({
        "body": {"data": null, "errors": [{"message": "Field 'isInMergeQueue' doesn't exist"}]},
        "exit": 1,
        "stderr": "gh: Field 'isInMergeQueue' doesn't exist"
    }));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!((reply.status, reply.verdict), ("error", "unknown"));
    let error = reply.error.unwrap_or_default();
    assert!(
        error.starts_with("queue-rejected") && error.contains("isInMergeQueue"),
        "{error}"
    );
}

/// The probe's request: the failed-check probe on, the guard off.
fn probe_request(world: &World, max_wait: u64) -> QueueWatch {
    QueueWatch {
        check_probe: true,
        guard: false,
        ..world.request(1, max_wait)
    }
}

/// The probe rows run the wait in-process, its probe reading `verify-pr`
/// through the wait's own `gh`: a failed required check on an armed,
/// unenqueued pull request is `armed_blocked`, and a required check nothing
/// reports yet leaves it `armed_awaiting_checks` at the deadline with that
/// check named, never `progress_unobservable`.
#[test]
fn failed_required_check_on_an_armed_pr_is_armed_blocked() {
    let mut world = World::new();
    world
        .witness("bound-run-failed-own-check")
        .queue(armed_only());
    let request = probe_request(&world, 2);
    let value = serde_json::to_value(world.wait(&request, |_, _| {})).unwrap();
    assert_eq!(
        (
            value["status"].as_str(),
            value["verdict"].as_str(),
            value["cause"].as_str()
        ),
        (
            Some("complete"),
            Some("armed_blocked"),
            Some("check_failed")
        ),
        "{value}"
    );
}

#[test]
fn pending_required_checks_await_never_progress_unobservable() {
    let mut world = World::new();
    world.witness("required-build-missing").queue(armed_only());
    let request = probe_request(&world, 2);
    let value = serde_json::to_value(world.wait(&request, |_, _| {})).unwrap();
    assert_eq!(
        (
            value["status"].as_str(),
            value["verdict"].as_str(),
            value["cause"].as_str()
        ),
        (
            Some("timeout"),
            Some("armed_awaiting_checks"),
            Some("checks_pending")
        ),
        "{value}"
    );
    assert_eq!(value["pending_checks"], json!(["build"]));
    assert_eq!(value["progress_head_polls"], json!(0));
}

#[test]
fn a_poll_interval_past_the_budget_is_refused_before_any_read() {
    let world = World::new();
    let out = world.binary(&["--poll", "60", "--max-wait", "30"]);
    assert!(!out.status.success());
    assert!(
        support::stderr(&out).contains("queue-watch-invalid"),
        "{}",
        support::stderr(&out)
    );
    assert!(world.gh_log().is_empty(), "no read before the refusal");
}
