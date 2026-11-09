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
use std::time::{Duration, Instant, SystemTime};

mod support;

use orch_runtime::ops::Env;
use orch_runtime::ops::queue_watch::{Programs, QueueWatch, Reply, run};
use orch_runtime::schedule::Clock;
use orch_runtime::state::Locking;
use serde_json::{Map, Value, json};
use support::{FakeClock, fixtures, tool_path, write_executable};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const ITEM_ID: &str = "KEN-4687";
const REPO: &str = "owner/repo";
const PR: u64 = 7;
/// The recorded witnesses' head, which the probe rows hand `verify-pr`.
const HEAD: &str = "737bce791577e140436490e0fed5751bb5144a61";
const NODE_ID: &str = "PR_node123";
const LOCK: Locking = Locking::FLOCK;
/// The merge-group head a queued entry exposes, whose check runs the
/// progress read counts.
const QUEUE_HEAD: &str = "aaa111";
const MERGED_AT: &str = "2026-07-24T10:00:00Z";
/// How many deadlines a wait the row no longer drives is run out by: 60
/// seconds of real time at one advance per 20 ms.
const RUN_OUT_ADVANCES: u32 = 3000;

/// The wait's clock over the row's, freed once the run-out's advances are
/// spent: a sleep after that panics in the wait's own thread, so a wait no
/// deadline ends fails its row at the join instead of holding it.
struct Freeable<'a> {
    clock: &'a dyn Clock,
    free: std::sync::atomic::AtomicBool,
}

impl Freeable<'_> {
    fn freed(&self) -> bool {
        self.free.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl Clock for Freeable<'_> {
    fn now(&self) -> Instant {
        self.clock.now()
    }

    fn wall(&self) -> SystemTime {
        self.clock.wall()
    }

    fn sleep(&self, d: Duration) {
        assert!(!self.freed(), "the wait slept again after its run-out");
        self.clock.sleep(d);
    }
}

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

/// The replies of a recorded verify witness (`fixtures/gh/witnesses/`).
fn witness_map(name: &str) -> Map<String, Value> {
    let text = fs::read_to_string(fixtures().join(format!("gh/witnesses/{name}.json"))).unwrap();
    serde_json::from_str(&text).unwrap()
}

/// The queue read's pull request: in the queue (with or without a
/// merge-group head), armed only, out, or held behind a live group.
fn queue_body(pull: Value) -> Value {
    json!({"body": {"data": {"repository": {"pullRequest": pull}}}})
}

fn in_queue(head: Option<&str>) -> Value {
    queue_body(json!({
        "id": NODE_ID,
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
        "mergeQueueEntry": null,
        "autoMergeRequest": {"enabledAt": "2026-07-24T10:00:00Z"}
    }))
}

fn out() -> Value {
    queue_body(json!({
        "id": NODE_ID,
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

    /// The `pr view` answer for a merged pull request, `mergeable` as GitHub
    /// last left it.
    fn merged(&mut self, mergeable: &str) -> &mut Self {
        self.replies.insert(
            format!("pr view {PR}"),
            json!({"body": {
                "state": "MERGED", "mergedAt": MERGED_AT, "mergeable": mergeable,
                "headRefOid": HEAD, "baseRefName": "main"
            }}),
        );
        self
    }

    /// A read gh could not make: nothing printed, `stderr` as gh writes it,
    /// exit 1.
    fn failed(&mut self, key: &str, stderr: &str) -> &mut Self {
        self.replies.insert(
            key.to_owned(),
            json!({"text": "", "stderr": stderr, "exit": 1}),
        );
        self
    }

    /// The check runs on the merge-group head, as the progress read lists
    /// them: `completed` done and `running` still in progress; `None` is a
    /// read that fails.
    fn check_runs(&mut self, counts: Option<(usize, u64)>) -> &mut Self {
        let key = format!("repos/{REPO}/commits/{QUEUE_HEAD}/check-runs?per_page=100&page=1");
        match counts {
            Some((completed, running)) => {
                let runs: Vec<Value> = (0..completed)
                    .map(|_| ("completed", json!("success")))
                    .chain((0..running).map(|_| ("in_progress", Value::Null)))
                    .enumerate()
                    .map(|(i, (status, conclusion))| {
                        json!({"id": i + 1, "node_id": format!("CR_{}", i + 1), "name": format!("check-{}", i + 1),
                            "status": status, "conclusion": conclusion, "check_suite": {"id": 1},
                            "started_at": null, "completed_at": null, "html_url": null, "details_url": null})
                    })
                    .collect();
                self.replies.insert(
                    key,
                    json!({"body": {"total_count": runs.len(), "check_runs": runs}}),
                );
            }
            None => {
                self.replies.remove(&key);
            }
        }
        self
    }

    fn threads(&mut self, unresolved: u64) -> &mut Self {
        self.threads.insert(
            format!("pr-threads {PR}"),
            json!({"body": {"count": unresolved, "unresolved_count": unresolved, "threads": []}}),
        );
        self
    }

    /// A thread read that answers no count: `text` printed as is, or with
    /// `None` no answer at all (the command refuses).
    fn threads_unreadable(&mut self, text: Option<&str>) -> &mut Self {
        let key = format!("pr-threads {PR}");
        match text {
            Some(text) => {
                self.threads.insert(key, json!({"text": text}));
            }
            None => {
                self.threads.remove(&key);
            }
        }
        self
    }

    /// The thread reads the fake `github.sh` answered.
    fn thread_reads(&self) -> usize {
        fs::read_to_string(self.root().join("github.log"))
            .unwrap_or_default()
            .lines()
            .filter(|l| l.contains("pr-threads"))
            .count()
    }

    /// A guard mutation's answer: its payload type's fields on success
    /// (`DequeuePullRequestPayload` the dequeued entry,
    /// `DisablePullRequestAutoMergePayload` the pull request), a GraphQL
    /// `errors` body with gh's nonzero exit otherwise.
    fn mutation(&mut self, name: &str, ok: bool) -> &mut Self {
        let reply = if !ok {
            json!({"body": {"data": {name: null}, "errors": [{"message": format!("{name} refused")}]},
                   "exit": 1, "stderr": format!("gh: {name} refused")})
        } else if name == "dequeuePullRequest" {
            json!({"body": {"data": {name: {"clientMutationId": null, "mergeQueueEntry": {"id": "MQE_1"}}}}})
        } else {
            json!({"body": {"data": {name: {"clientMutationId": null, "pullRequest": {"id": NODE_ID}}}}})
        };
        self.replies.insert(format!("mutation {name}"), reply);
        self
    }

    /// A recorded verify witness as the base of the replies, for a probe
    /// row.
    fn witness(&mut self, name: &str) -> &mut Self {
        for (key, value) in witness_map(name) {
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
            reach_cmd: None,
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
    /// at a time, and only while it sleeps with its wake ahead, so a poll's
    /// reads, however slow the host, spend none of its budget. Past a
    /// real-time bound the row fails with the memory the wait wrote so far
    /// and the reply it gives once let run out, never a reply read as the
    /// row's answer.
    fn wait(&mut self, request: &QueueWatch, drive: impl FnOnce(&mut World, &FakeClock)) -> Reply {
        let clock = FakeClock::new();
        self.wait_on(&clock, &clock, request, drive)
    }

    /// [`World::wait`] with the wait reading `wait_clock`, a clock over
    /// `clock` that the row shapes; the drive and the release act on
    /// `clock`.
    fn wait_on(
        &mut self,
        wait_clock: &dyn Clock,
        clock: &FakeClock,
        request: &QueueWatch,
        drive: impl FnOnce(&mut World, &FakeClock),
    ) -> Reply {
        self.write();
        let (item, programs, root) = (self.item.clone(), self.programs(), self.root());
        let freeable = Freeable {
            clock: wait_clock,
            free: std::sync::atomic::AtomicBool::new(false),
        };
        std::thread::scope(|s| {
            let handle = s.spawn(|| run(&item, request, &programs, &root, &freeable, &env(), LOCK));
            // The wait sleeps on a clock only this thread releases: run it
            // out by a bounded count of deadlines, as long in real time as
            // the slowest fixture read's own bound. A wait no advance ended
            // is woken with its clock freed, so its next sleep panics and
            // the scope's join ends, never spun on or waited on.
            let run_out = |handle: &std::thread::ScopedJoinHandle<'_, _>| {
                for _ in 0..RUN_OUT_ADVANCES {
                    if handle.is_finished() {
                        return;
                    }
                    clock.release(request.max_wait);
                    std::thread::sleep(Duration::from_millis(20));
                }
                freeable
                    .free
                    .store(true, std::sync::atomic::Ordering::SeqCst);
                clock.release(secs(365 * 86_400));
            };
            let driven =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drive(self, clock)));
            if let Err(failure) = driven {
                // Run out, so the row fails with the drive's panic instead of
                // hanging the scope that joins it.
                run_out(&handle);
                std::panic::resume_unwind(failure);
            }
            let bound = std::time::Instant::now() + secs(60);
            while !handle.is_finished() {
                if std::time::Instant::now() >= bound {
                    let memory = self.memory();
                    run_out(&handle);
                    let reply = handle.join().map_err(|_| "its thread panicked");
                    panic!(
                        "the wait still polled after 60 s of real time; its memory then: {memory}; let run out it answered {reply:?}"
                    );
                }
                if clock.asleep() {
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
    fn binary(&self, repo: &str, args: &[&str]) -> Output {
        self.write();
        let root = self.root();
        support::isolated()
            .args(["--state-dir", &root.display().to_string()])
            .arg("queue-watch")
            .args(["--item", ITEM_ID, "--repo", repo, "--pr", &PR.to_string()])
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
        "body": {"data": null, "errors": [{"message": "Field 'mergeQueueEntry' doesn't exist"}]},
        "exit": 1,
        "stderr": "gh: Field 'mergeQueueEntry' doesn't exist"
    }));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!((reply.status, reply.verdict), ("error", "unknown"));
    let error = reply.error.unwrap_or_default();
    assert!(
        error.starts_with("queue-rejected") && error.contains("mergeQueueEntry"),
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
    let request = probe_request(&world, 5);
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
    let request = probe_request(&world, 5);
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
    let out = world.binary(REPO, &["--poll", "60", "--max-wait", "30"]);
    assert!(!out.status.success());
    assert!(
        support::stderr(&out).contains("queue-watch-invalid"),
        "{}",
        support::stderr(&out)
    );
    assert!(world.gh_log().is_empty(), "no read before the refusal");
}

/// The repository is the request's own `owner/name`: one outside that form
/// is refused before any read, never resolved from a checkout or handed to
/// gh.
#[test]
fn a_repository_outside_its_form_is_refused_before_any_read() {
    let world = World::new();
    let out = world.binary("elsewhere", &[]);
    assert!(!out.status.success());
    assert!(
        support::stderr(&out).contains("verify-request-invalid"),
        "{}",
        support::stderr(&out)
    );
    assert!(world.gh_log().is_empty(), "no read before the refusal");
}

/// A merged pull request ends the wait on the poll that reads it, whatever
/// `mergeable` still says of the merged head, with `merged_at` and no
/// cause, and the memory the earlier polls wrote stands on the reply, so
/// the workflow reads that the merge went through the queue it armed.
#[test]
fn a_merged_pull_request_is_merged_whatever_mergeable_says_and_keeps_its_queue_memory() {
    let mut world = World::new();
    world.queue(in_queue(None));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.merged("CONFLICTING").write();
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "merged", None, 2),
        "{reply:?}"
    );
    assert_eq!(reply.merged_at, MERGED_AT);
    assert!(reply.was_queued && reply.was_in_merge_queue, "{reply:?}");

    // Merged before the first poll: one read, no queue read after the state.
    let mut world = World::new();
    world.merged("MERGEABLE").queue(in_queue(None));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.polls, reply.was_queued),
        ("complete", "merged", 1, false),
        "{reply:?}"
    );
    assert!(
        !world.gh_log().iter().any(|l| l.contains("mergeQueueEntry")),
        "{:?}",
        world.gh_log()
    );
}

/// A closed, unmerged pull request is `closed` with `closed_without_merge`
/// on the poll that reads it, before any queue read: the workflow hands
/// back rather than waiting on a queue the pull request has left.
#[test]
fn a_closed_pull_request_is_closed_without_merge_before_any_queue_read() {
    let mut world = World::new();
    world.pull("CLOSED", "MERGEABLE").queue(in_queue(None));
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "closed", Some("closed_without_merge"), 1),
        "{reply:?}"
    );
    assert!(
        !world.gh_log().iter().any(|l| l.contains("mergeQueueEntry")),
        "{:?}",
        world.gh_log()
    );
}

/// An arm GitHub cleared from a pull request a poll saw armed and never
/// enqueued is `disarmed` with `auto_merge_cleared` once the confirmation
/// count agrees, `mergeable` clean routing nothing else; `mergeable`
/// `UNKNOWN` is GitHub recomputing and routes nothing, so an armed pull
/// request whose rollup no probe read awaits its checks unread.
#[test]
fn an_arm_cleared_after_being_armed_is_disarmed_once_confirmed() {
    let mut world = World::new();
    world.queue(armed_only());
    let request = world.request(10, 60);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.queue(out()).write();
        clock.pass(secs(10));
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "disarmed", Some("auto_merge_cleared"), 3),
        "{reply:?}"
    );
    assert!(reply.was_queued && !reply.was_in_merge_queue, "{reply:?}");

    let mut world = World::new();
    world.pull("OPEN", "UNKNOWN").queue(armed_only());
    let request = world.request(10, 10);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.cause,
            reply.unconfirmed_verdict
        ),
        (
            "timeout",
            "armed_awaiting_checks",
            Some("checks_unread"),
            None
        ),
        "{reply:?}"
    );
}

/// A transient failure of a read (a 5xx, a rate limit, a timeout) is
/// absorbed under the backoff and counted on the reply, and the next poll
/// that reads goes on from it; one that never clears ends the wait only
/// once the budget is spent, as the read's failure, never as a pull request
/// that was never armed.
#[test]
fn a_transient_read_failure_is_absorbed_and_counted_and_ends_the_wait_only_at_the_budget() {
    let mut world = World::new();
    world.failed("queue", "HTTP 502: Bad Gateway");
    let request = world.request(10, 60);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.merged("MERGEABLE").write();
        clock.release(secs(10));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.transient_api_errors,
            reply.polls
        ),
        ("complete", "merged", Some(1), 2),
        "{reply:?}"
    );

    let mut world = World::new();
    world.failed(
        &format!("pr view {PR}"),
        "API rate limit already exceeded for installation ID 161253865",
    );
    let request = world.request(1, 3);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.pass(secs(1));
        clock.release(secs(2));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.transient_api_errors,
            reply.polls
        ),
        ("error", "unknown", Some(2), 2),
        "{reply:?}"
    );
    let error = reply.error.unwrap_or_default();
    assert!(
        error.starts_with("pr-view-failed pr=7 repo=owner/repo"),
        "{error}"
    );
}

/// A queue answer that is no pull request (an empty object, an empty body)
/// is absorbed up to the bound and then ends the wait `queue-unreadable`
/// with the polls it spent, never `not_queued`.
#[test]
fn an_unreadable_queue_answer_ends_the_wait_after_the_bound_never_not_queued() {
    for (name, answer) in [
        ("an empty object", json!({"body": {}})),
        ("an empty body", json!({"text": ""})),
    ] {
        let mut world = World::new();
        world.queue(answer);
        let request = world.request(1, 30);
        let reply = world.wait(&request, |_, clock| {
            clock.await_sleepers(1);
            clock.pass(secs(1));
            clock.release(secs(1));
        });
        assert_eq!(
            (reply.status, reply.verdict, reply.polls),
            ("error", "unknown", 3),
            "{name}: {reply:?}"
        );
        assert_eq!(
            reply.error.as_deref(),
            Some("queue-unreadable pr=7 repo=owner/repo polls=3"),
            "{name}"
        );
    }
}

/// The deadline is a timeout on the budget, never a silent success or a
/// poll past it: the last sleep is clamped to the remaining budget, and a
/// pull request still queued at the deadline is `queued` with its entry
/// read on the reply.
#[test]
fn the_deadline_is_a_timeout_on_the_budget_with_the_entry_still_read() {
    let mut world = World::new();
    world.queue(in_queue(None));
    let request = world.request(3, 4);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.pass(secs(3));
        clock.release(secs(1));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.elapsed_seconds,
            reply.polls
        ),
        ("timeout", "queued", 4, 2),
        "{reply:?}"
    );
    assert!(
        reply.in_merge_queue && reply.merge_queue_state == "QUEUED",
        "{reply:?}"
    );
}

/// Progress on a queued entry with a merge-group head is read from that
/// head's check runs: a completed count that moved within the window, or a
/// run still running, is `still_progressing`; a count that has not moved
/// with nothing running is `stalled`; a read that failed is no count, never
/// zero, so every read failing is `progress_unobservable` and one failing
/// between two reads erases no movement.
#[test]
fn progress_is_read_from_the_heads_check_runs_and_a_failed_read_is_never_zero() {
    struct Row {
        name: &'static str,
        reads: &'static [Option<(usize, u64)>],
        cause: &'static str,
        progressing: Option<bool>,
        check_reads: u64,
        last_running: Option<u64>,
    }
    let rows = [
        Row {
            name: "a completed count advancing every poll",
            reads: &[Some((1, 0)), Some((2, 0)), Some((3, 0))],
            cause: "still_progressing",
            progressing: Some(true),
            check_reads: 3,
            last_running: Some(0),
        },
        Row {
            name: "one change older than the window, then flat",
            reads: &[
                Some((1, 0)),
                Some((2, 0)),
                Some((2, 0)),
                Some((2, 0)),
                Some((2, 0)),
                Some((2, 0)),
            ],
            cause: "stalled",
            progressing: Some(false),
            check_reads: 6,
            last_running: Some(0),
        },
        Row {
            name: "a flat count with a run still running",
            reads: &[Some((1, 1)), Some((1, 1)), Some((1, 1))],
            cause: "still_progressing",
            progressing: Some(true),
            check_reads: 3,
            last_running: Some(1),
        },
        Row {
            name: "every read failing",
            reads: &[None, None, None],
            cause: "progress_unobservable",
            progressing: None,
            check_reads: 0,
            last_running: None,
        },
        Row {
            name: "a failed read between two reads",
            reads: &[Some((1, 0)), None, Some((2, 0))],
            cause: "still_progressing",
            progressing: Some(true),
            check_reads: 2,
            last_running: Some(0),
        },
    ];
    for row in rows {
        let mut world = World::new();
        world
            .queue(in_queue(Some(QUEUE_HEAD)))
            .check_runs(row.reads[0]);
        let request = world.request(1, row.reads.len() as u64);
        let reply = world.wait(&request, |world, clock| {
            clock.await_sleepers(1);
            for read in &row.reads[1..] {
                world.check_runs(*read).write();
                clock.pass(secs(1));
            }
            clock.release(secs(1));
        });
        assert_eq!(
            (reply.status, reply.verdict, reply.cause, reply.progressing),
            ("timeout", "queued", Some(row.cause), row.progressing),
            "{}: {reply:?}",
            row.name
        );
        assert_eq!(
            (
                reply.progress_head_polls,
                reply.progress_check_reads,
                reply.last_running_count
            ),
            (row.reads.len() as u64, row.check_reads, row.last_running),
            "{}: {reply:?}",
            row.name
        );
    }
}

/// A hold is named only by a live group ahead of a headless `QUEUED` or
/// `UNMERGEABLE` entry: a group behind this entry, an entry ahead without a
/// head, or another entry state proves no hold, and an entry with its own
/// group keeps its progress reading.
#[test]
fn a_hold_is_named_only_by_a_live_group_ahead_of_a_headless_entry() {
    let entry = |edit: fn(&mut Value)| -> Value {
        let mut body = held_behind(9);
        edit(&mut body["body"]["data"]["repository"]["pullRequest"]["mergeQueueEntry"]);
        body
    };
    let cases: [(&str, Value, &str, Option<u64>); 5] = [
        (
            "an UNMERGEABLE entry behind a live group",
            entry(|e| e["state"] = json!("UNMERGEABLE")),
            "blocked_by_entry_ahead",
            Some(9),
        ),
        (
            "a live group behind this entry",
            entry(|e| e["mergeQueue"]["entries"]["nodes"][0]["position"] = json!(3)),
            "progress_unobservable",
            None,
        ),
        (
            "an entry ahead without a group",
            entry(|e| e["mergeQueue"]["entries"]["nodes"][0]["headCommit"] = Value::Null),
            "progress_unobservable",
            None,
        ),
        (
            "an entry with its own group",
            entry(|e| e["headCommit"] = json!({"oid": QUEUE_HEAD})),
            "still_progressing",
            None,
        ),
        (
            "another entry state",
            entry(|e| e["state"] = json!("AWAITING_CHECKS")),
            "progress_unobservable",
            None,
        ),
    ];
    for (name, queue, cause, ahead) in cases {
        let mut world = World::new();
        world.queue(queue).check_runs(Some((1, 1)));
        let request = world.request(10, 10);
        let reply = world.wait(&request, |_, clock| {
            clock.await_sleepers(1);
            clock.release(secs(10));
        });
        assert_eq!(
            (reply.verdict, reply.cause, reply.queue_ahead_pr),
            ("queued", Some(cause), ahead),
            "{name}: {reply:?}"
        );
    }
}

/// The confirmation count is the whole rule: a candidate the budget cannot
/// confirm, however the gaps shrink, is reported beside `queued` as
/// `unconfirmed_verdict`, never under a confirmed verdict's name; a pull
/// request read out of the queue is `exit_unconfirmed`, never a progress
/// reading the workflow would route to a recovery cycle.
#[test]
fn a_candidate_the_budget_cannot_confirm_is_reported_beside_queued_never_as_its_verdict() {
    let cases: [(&str, &str, Option<Value>, &str, &str); 2] = [
        (
            "an ejection",
            "MERGEABLE",
            Some(out()),
            "exit_unconfirmed",
            "ejected",
        ),
        (
            "a conflict",
            "CONFLICTING",
            None,
            "progress_unobservable",
            "conflicting",
        ),
    ];
    for (name, mergeable, later, cause, unconfirmed) in cases {
        let mut world = World::new();
        world.pull("OPEN", mergeable).queue(in_queue(None));
        let request = QueueWatch {
            confirm_polls: 100,
            ..world.request(1, 2)
        };
        let reply = world.wait(&request, |world, clock| {
            clock.await_sleepers(1);
            if let Some(queue) = later.clone() {
                world.queue(queue).write();
            }
            clock.pass(secs(1));
            clock.release(secs(1));
        });
        assert_eq!(
            (
                reply.status,
                reply.verdict,
                reply.cause,
                reply.unconfirmed_verdict,
                reply.polls
            ),
            ("timeout", "queued", Some(cause), Some(unconfirmed), 2),
            "{name}: {reply:?}"
        );
        assert!(
            reply.elapsed_seconds <= 2 && reply.last_poll_age_seconds.is_some(),
            "{name}: {reply:?}"
        );
    }
}

/// How a drive moves the fake clock after it rewrote the maps: `pass`
/// waits for the wait's thread to sleep again, `release` wakes it for a
/// poll that may end the wait.
enum Advance {
    Pass(Duration),
    Release(Duration),
}

/// One poll's world as the drive rewrites it before moving the clock.
struct Step {
    mergeable: Option<&'static str>,
    queue: Option<Value>,
    then: Advance,
}

/// An ejection or a disarm is a transition, observed once, so one the
/// deadline cuts off mid-confirmation is re-observed by nobody and the
/// workflow re-arms a pull request the queue threw out: the confirmation
/// polls a transition still owes near the deadline are moved inside the
/// budget, which stays the upper bound; the move is owed per candidate, so
/// a transition after a candidate that spent its move is still confirmed;
/// and polls owed exactly the remaining budget are moved too, since a gap
/// landing on the deadline is a poll never made.
#[test]
fn a_transition_first_seen_near_the_deadline_is_confirmed_inside_the_budget() {
    struct Row {
        name: &'static str,
        first: Value,
        poll: u64,
        max_wait: u64,
        confirm_polls: u32,
        steps: Vec<Step>,
        verdict: &'static str,
        cause: &'static str,
        polls: u64,
    }
    let step = |mergeable: Option<&'static str>, queue: Option<Value>, then: Advance| Step {
        mergeable,
        queue,
        then,
    };
    let rows = vec![
        Row {
            name: "an ejection at the deadline",
            first: in_queue(None),
            poll: 2,
            max_wait: 3,
            confirm_polls: 2,
            steps: vec![
                step(None, Some(out()), Advance::Pass(secs(2))),
                step(None, None, Advance::Release(Duration::from_millis(500))),
            ],
            verdict: "ejected",
            cause: "merge_group_failed",
            polls: 3,
        },
        Row {
            name: "a disarm at the deadline",
            first: armed_only(),
            poll: 2,
            max_wait: 3,
            confirm_polls: 2,
            steps: vec![
                step(None, Some(out()), Advance::Pass(secs(2))),
                step(None, None, Advance::Release(Duration::from_millis(500))),
            ],
            verdict: "disarmed",
            cause: "auto_merge_cleared",
            polls: 3,
        },
        Row {
            name: "a transition after a candidate that spent its move",
            first: in_queue(None),
            poll: 3,
            max_wait: 5,
            confirm_polls: 2,
            steps: vec![
                step(Some("CONFLICTING"), None, Advance::Pass(secs(3))),
                step(Some("MERGEABLE"), Some(out()), Advance::Pass(secs(1))),
                step(None, None, Advance::Release(Duration::from_millis(500))),
            ],
            verdict: "ejected",
            cause: "merge_group_failed",
            polls: 4,
        },
        Row {
            name: "owed polls that fit the budget exactly",
            first: in_queue(None),
            poll: 1,
            max_wait: 3,
            confirm_polls: 3,
            steps: vec![
                step(None, Some(out()), Advance::Pass(secs(1))),
                step(None, None, Advance::Pass(Duration::from_millis(667))),
                step(None, None, Advance::Release(secs(1))),
            ],
            verdict: "ejected",
            cause: "merge_group_failed",
            polls: 4,
        },
    ];
    for row in rows {
        let Row {
            name,
            first,
            poll,
            max_wait,
            confirm_polls,
            steps,
            verdict,
            cause,
            polls,
        } = row;
        let mut world = World::new();
        world.queue(first);
        let request = QueueWatch {
            confirm_polls,
            ..world.request(poll, max_wait)
        };
        let reply = world.wait(&request, |world, clock| {
            clock.await_sleepers(1);
            for step in steps {
                if let Some(mergeable) = step.mergeable {
                    world.pull("OPEN", mergeable);
                }
                if let Some(queue) = step.queue {
                    world.queue(queue);
                }
                world.write();
                match step.then {
                    Advance::Pass(d) => clock.pass(d),
                    Advance::Release(d) => clock.release(d),
                }
            }
        });
        assert_eq!(
            (reply.status, reply.verdict, reply.cause, reply.polls),
            ("complete", verdict, Some(cause), polls),
            "{name}: {reply:?}"
        );
        assert!(reply.elapsed_seconds <= max_wait, "{name}: {reply:?}");
    }
}

/// The guard's thread read is three-valued: a read that failed, or an
/// answer that is no count, is no evidence (nothing pulled, no count on
/// the reply, the wait goes on), never no threads; and with the guard off
/// no thread is read at all.
#[test]
fn a_thread_read_that_failed_or_answered_no_count_is_no_evidence() {
    for (name, text) in [
        ("a refused read", None),
        ("an answer that is no count", Some("not json")),
    ] {
        let mut world = World::new();
        world.queue(in_queue(None)).threads_unreadable(text);
        let request = world.request(10, 10);
        let reply = world.wait(&request, |_, clock| {
            clock.await_sleepers(1);
            clock.release(secs(10));
        });
        assert_eq!(
            (
                reply.status,
                reply.verdict,
                reply.unresolved_count,
                world.thread_reads()
            ),
            ("timeout", "queued", None, 2),
            "{name}: {reply:?}"
        );
        assert!(world.mutations().is_empty(), "{name}: {:?}", world.gh_log());
    }

    let mut world = World::new();
    world.queue(in_queue(None)).threads(1);
    let request = QueueWatch {
        guard: false,
        ..world.request(10, 10)
    };
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(10));
    });
    assert_eq!(
        (reply.verdict, reply.unresolved_count, world.thread_reads()),
        ("queued", None, 0),
        "{reply:?}"
    );
    assert!(world.mutations().is_empty(), "{:?}", world.gh_log());
}

/// The guard pulls the halves the shape calls for: an armed, unenqueued
/// pull request takes the disarm alone; a disarm GitHub refused does not
/// skip the dequeue, and the reply names the refused half; and the deadline
/// runs one last probe, so a thread landing before it is still pulled.
#[test]
fn the_guard_pulls_the_halves_the_shape_calls_for_and_probes_once_more_at_the_deadline() {
    let mut world = World::new();
    world
        .queue(armed_only())
        .threads(1)
        .mutation("disablePullRequestAutoMerge", true);
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("complete", "dequeued", Some("late_findings")),
        "{reply:?}"
    );
    let sent = world.mutations();
    assert!(
        sent.len() == 1 && sent[0].contains("disablePullRequestAutoMerge"),
        "{sent:?}"
    );
    let guard = &world.memory()["guard"];
    assert_eq!(
        (
            guard["disarm"]["state"].as_str(),
            guard["dequeue"]["state"].as_str()
        ),
        (Some("done"), Some("unneeded"))
    );

    let mut world = World::new();
    world
        .queue(in_queue(None))
        .threads(1)
        .mutation("disablePullRequestAutoMerge", false)
        .mutation("dequeuePullRequest", true);
    let request = world.request(10, 30);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("error", "dequeued", Some("late_findings_dequeue_failed")),
        "{reply:?}"
    );
    let error = reply.error.unwrap_or_default();
    assert!(
        error.contains("operation=disablePullRequestAutoMerge pr=7"),
        "{error}"
    );
    let guard = &world.memory()["guard"];
    assert_eq!(
        (
            guard["disarm"]["state"].as_str(),
            guard["dequeue"]["state"].as_str()
        ),
        (Some("failed"), Some("done"))
    );
    assert_eq!(world.mutations().len(), 2, "{:?}", world.gh_log());

    let mut world = World::new();
    world
        .queue(in_queue(None))
        .threads(0)
        .mutation("disablePullRequestAutoMerge", true)
        .mutation("dequeuePullRequest", true);
    let request = world.request(1, 1);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.threads(1).write();
        clock.release(secs(1));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "dequeued", Some("late_findings"), 1),
        "{reply:?}"
    );
}

/// The failed-check probe's settled answers: every required check passed
/// with still no entry is `armed_blocked` with `not_mergeable` at the
/// deadline, and a probe that could not read keeps the reading before it,
/// never replacing it with none.
#[test]
fn a_settled_probe_is_armed_blocked_at_the_deadline_and_an_unreadable_probe_keeps_the_reading() {
    let mut world = World::new();
    world
        .witness("required-build-optional-docs-active")
        .queue(armed_only());
    let request = QueueWatch {
        probe_interval: secs(0),
        ..probe_request(&world, 3)
    };
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.replies.remove(&format!(
            "repos/{REPO}/commits/{HEAD}/check-runs?filter=all&per_page=100&page=1"
        ));
        world.write();
        clock.release(secs(1));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("timeout", "armed_blocked", Some("not_mergeable"), 3),
        "{reply:?}"
    );
    assert!(reply.pending_checks.is_none(), "{reply:?}");

    // A standing conflict is never overtaken by the probe's one reading of
    // a failed check: the probe runs only past a candidate's confirmation,
    // so the verdict keeps the conflict's cause, not `check_failed`.
    let mut world = World::new();
    world
        .pull("OPEN", "CONFLICTING")
        .witness("bound-run-failed-own-check")
        .queue(armed_only());
    let request = probe_request(&world, 10);
    let reply = world.wait(&request, |_, clock| {
        clock.await_sleepers(1);
        clock.release(secs(1));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("complete", "conflicting", Some("base_conflict"), 2),
        "{reply:?}"
    );
    assert!(
        !world.gh_log().iter().any(|l| l.contains("check-runs")),
        "no probe past a standing candidate: {:?}",
        world.gh_log()
    );
}

/// A hold that cleared names no entry ahead: the reply names a group ahead
/// only while the last poll read one, so the workflow routes on the queue
/// as it stands, never on a hold that lifted.
#[test]
fn a_hold_that_cleared_names_no_entry_ahead() {
    let mut world = World::new();
    world.queue(held_behind(9)).check_runs(Some((1, 1)));
    let request = world.request(1, 3);
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        world.queue(in_queue(Some(QUEUE_HEAD))).write();
        clock.pass(secs(1));
        clock.release(secs(2));
    });
    assert_eq!(
        (
            reply.status,
            reply.verdict,
            reply.cause,
            reply.queue_ahead_pr
        ),
        ("timeout", "queued", Some("still_progressing"), None),
        "{reply:?}"
    );
}

/// An enqueued entry keeps its progress reading: the probe reads the pull
/// request's own checks, which say nothing of the merge group's, so a
/// queued entry whose own check failed is still `queued`, never
/// `armed_blocked` while the queue holds it.
#[test]
fn an_enqueued_entry_is_not_probed_for_a_failed_check() {
    let mut world = World::new();
    world
        .witness("bound-run-failed-own-check")
        .queue(in_queue(Some(QUEUE_HEAD)))
        .check_runs(Some((1, 1)));
    let request = probe_request(&world, 3);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("timeout", "queued", Some("still_progressing")),
        "{reply:?}"
    );
    assert!(
        !world
            .gh_log()
            .iter()
            .any(|l| l.contains(HEAD) && l.contains("check-runs")),
        "no probe of the pull request's own head: {:?}",
        world.gh_log()
    );
}

/// The probe reserves the poll after it: none runs at the last poll before
/// the deadline, where its reads would run past the budget, so a check
/// that failed after the earlier probe is read by the next call, and the
/// deadline reports the reading the earlier probe left.
#[test]
fn the_last_poll_before_the_deadline_runs_no_probe() {
    let mut world = World::new();
    world.witness("required-build-missing").queue(armed_only());
    let request = QueueWatch {
        probe_interval: secs(0),
        ..probe_request(&world, 2)
    };
    let reply = world.wait(&request, |world, clock| {
        clock.await_sleepers(1);
        for (key, value) in witness_map("bound-run-failed-own-check") {
            world.replies.insert(key, value);
        }
        world.write();
        clock.release(secs(1));
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        (
            "timeout",
            "armed_awaiting_checks",
            Some("checks_pending"),
            2
        ),
        "{reply:?}"
    );
    assert_eq!(reply.pending_checks, Some(vec!["build".to_owned()]));
    assert_eq!(
        world
            .gh_log()
            .iter()
            .filter(|l| l.contains(HEAD) && l.contains("check-runs"))
            .count(),
        1,
        "one probe, at the first poll: {:?}",
        world.gh_log()
    );
}

/// The probe's reads spend the budget the wait has left past the poll after
/// it: a check-run read that answers past the deadline is no reading, so
/// the deadline reports the reading before it, never a verdict read after
/// the wait was due to end.
#[test]
fn a_probe_answered_past_the_deadline_is_no_reading() {
    let mut world = World::new();
    world
        .witness("bound-run-failed-own-check")
        .queue(armed_only());
    let root = world.root();
    // The fake `gh` behind a wrapper that holds the pull request's check-run
    // read until the row releases it.
    fs::rename(root.join("gh"), root.join("gh-answers")).unwrap();
    let wrapper = format!(
        "#!/bin/bash\nhere=\"$(dirname \"$0\")\"\ncase \"$*\" in\n  *\"commits/{HEAD}/check-runs?filter=all\"*)\n    : > \"$here/probe-entered\"\n    while [ ! -f \"$here/probe-released\" ]; do sleep 0.01; done ;;\nesac\nexec \"$here/gh-answers\" \"$@\"\n"
    );
    write_executable(&root.join("gh"), wrapper);
    let request = probe_request(&world, 3);
    let reply = world.wait(&request, |world, clock| {
        let entered = world.root().join("probe-entered");
        let bound = std::time::Instant::now() + secs(10);
        while !entered.exists() {
            assert!(
                std::time::Instant::now() < bound,
                "the probe did not reach its check-run read: {:?}",
                world.gh_log()
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        clock.release(secs(4));
        fs::write(world.root().join("probe-released"), "").unwrap();
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause, reply.polls),
        ("timeout", "armed_awaiting_checks", Some("checks_unread"), 1),
        "{reply:?}"
    );
}

/// A clock each read of which takes `tick`, as a real clock's reads do: no
/// two reads see the same moment.
struct Ticking<'a> {
    clock: &'a FakeClock,
    tick: Duration,
}

impl Clock for Ticking<'_> {
    fn now(&self) -> Instant {
        let at = self.clock.now();
        self.clock.release(self.tick);
        at
    }

    fn wall(&self) -> SystemTime {
        self.clock.wall()
    }

    fn sleep(&self, d: Duration) {
        self.clock.sleep(d);
    }
}

/// The probe's cutoff is the wait's own deadline less the poll after it,
/// however far apart the clock reads that set it fall: on a clock whose
/// reads each take a tick, the probe's last read answering half a tick past
/// that cutoff is no reading, never the failed check it carries.
#[test]
fn time_between_the_probes_clock_reads_never_moves_its_cutoff() {
    const TICK: Duration = Duration::from_millis(1);
    let mut world = World::new();
    world
        .witness("bound-run-failed-own-check")
        .queue(armed_only());
    let root = world.root();
    // The fake `gh` behind a wrapper that holds the probe's last read, the
    // check suite's runs, until the row releases it.
    fs::rename(root.join("gh"), root.join("gh-answers")).unwrap();
    let wrapper = "#!/bin/bash\nhere=\"$(dirname \"$0\")\"\ncase \"$*\" in\n  *\"check-suites/5000300/check-runs\"*)\n    : > \"$here/probe-entered\"\n    while [ ! -f \"$here/probe-released\" ]; do sleep 0.01; done ;;\nesac\nexec \"$here/gh-answers\" \"$@\"\n";
    write_executable(&root.join("gh"), wrapper);
    let request = probe_request(&world, 10);
    let clock = FakeClock::new();
    let ticking = Ticking {
        clock: &clock,
        tick: TICK,
    };
    let reply = world.wait_on(&ticking, &clock, &request, |world, clock| {
        let entered = world.root().join("probe-entered");
        let bound = std::time::Instant::now() + secs(10);
        while !entered.exists() {
            assert!(
                std::time::Instant::now() < bound,
                "the probe did not reach its last read: {:?}",
                world.gh_log()
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        // `run` reads the clock first for the wait's start, so its deadline
        // less the poll falls nine seconds after the clock's own start. A
        // read added before it moves the wait's cutoff a tick past this
        // instant, and the row fails, never passes.
        clock.release(secs(9) + TICK / 2 - clock.elapsed());
        fs::write(world.root().join("probe-released"), "").unwrap();
    });
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("timeout", "armed_awaiting_checks", Some("checks_unread")),
        "{reply:?}"
    );
}

/// A probe read that never answers is ended at what its budget has left,
/// so a hung read is no reading and the wait keeps its deadline. The fake
/// clock stands while the read hangs, so the bound is the budget's two
/// seconds of real time against a read held for eight; the fixture's other
/// reads take tens of milliseconds.
#[test]
fn a_hung_probe_read_is_ended_at_what_its_budget_has_left() {
    let mut world = World::new();
    world
        .witness("bound-run-failed-own-check")
        .queue(armed_only());
    let root = world.root();
    // The fake `gh` behind a wrapper that holds the pull request's check-run
    // read on a fifo it reads with a bound, so a killed read leaves no
    // child behind.
    fs::rename(root.join("gh"), root.join("gh-answers")).unwrap();
    let wrapper = format!(
        "#!/bin/bash\nhere=\"$(dirname \"$0\")\"\ncase \"$*\" in\n  *\"commits/{HEAD}/check-runs?filter=all\"*)\n    [ -p \"$here/hold\" ] || mkfifo \"$here/hold\"\n    exec 3<>\"$here/hold\"\n    read -t 8 -u 3 || true ;;\nesac\nexec \"$here/gh-answers\" \"$@\"\n"
    );
    write_executable(&root.join("gh"), wrapper);
    let request = probe_request(&world, 3);
    let reply = world.wait(&request, |_, _| {});
    assert_eq!(
        (reply.status, reply.verdict, reply.cause),
        ("timeout", "armed_awaiting_checks", Some("checks_unread")),
        "{reply:?}"
    );
}

// --- an ejected group's reach ---

/// The fixture item's open dev round, which a validation start names.
const ROUND: &str = "1769600000123456789-1837";

/// The orch package's directory: its siblings are the packages the real
/// validation start runs, and the checkout above them holds the reach
/// command kendex declares.
fn orch_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

/// A checkout of its own under `root` for kendex's reach command, which
/// selects from the checkout it sits in: copies of the real tools the
/// selection runs, a crates workspace holding the CLI smoke target
/// `tools/rust-reads` requires, and the change the row validates, tracked
/// in a repository of its own, so the answer never depends on the checkout
/// the tests run in or on whether it is a repository. Answers its
/// `tools/ci-reach`.
fn reach_world(root: &std::path::Path) -> PathBuf {
    let world = root.join("reach-world");
    let tools = orch_dir().join("../../tools");
    fs::create_dir_all(world.join("tools")).unwrap();
    for name in [
        "ci-reach",
        "ci-job-set",
        "macos-test-contracts",
        "macos-test-contracts.json",
        "rust-reads",
    ] {
        fs::copy(tools.join(name), world.join("tools").join(name)).unwrap();
    }
    let copied = support::program("cp")
        .arg("-R")
        .arg(tools.join("lib"))
        .arg(world.join("tools/lib"))
        .output()
        .unwrap();
    assert!(copied.status.success(), "{}", support::stderr(&copied));
    for (path, text) in [
        (
            "Cargo.toml",
            "[workspace]\nmembers = [\"crates/cli\"]\nresolver = \"2\"\n",
        ),
        (
            "crates/cli/Cargo.toml",
            "[package]\nname = \"kendex-cli\"\nversion = \"0.1.0\"\n\n[[test]]\nname = \"cli_smoke\"\npath = \"tests/cli_smoke.rs\"\n",
        ),
        ("crates/cli/src/lib.rs", ""),
        ("crates/cli/tests/cli_smoke.rs", "fn smoke() {}\n"),
        ("skills/price-handling/SKILL.md", "x\n"),
    ] {
        let path = world.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    for args in [
        &["init", "-q"][..],
        &["config", "gc.auto", "0"],
        &["config", "maintenance.auto", "false"],
        &["add", "-A"],
    ] {
        let out = support::program("git")
            .arg("-C")
            .arg(&world)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            support::stderr(&out)
        );
    }
    world.join("tools/ci-reach")
}

impl World {
    /// `path` committed in a fixture worktree under the row's root and
    /// validated there by the real `validate start`, in the foreground,
    /// over the real classifier: the stage and run directory an
    /// ejection's reach reads. Answers the validated head.
    fn validated(&mut self, path: &str) -> String {
        let root = self.root();
        let worktree = root.join("wt");
        fs::create_dir_all(worktree.join(path).parent().unwrap()).unwrap();
        let git = |args: &[&str]| {
            let out = support::program("git")
                .arg("-C")
                .arg(&worktree)
                .args(args)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {args:?}: {}",
                support::stderr(&out)
            );
            String::from_utf8_lossy(&out.stdout).trim().to_owned()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "gc.auto", "0"]);
        git(&["config", "maintenance.auto", "false"]);
        fs::write(worktree.join(".gitignore"), "tmp\n").unwrap();
        fs::write(
            worktree.join("kendex.settings.toml"),
            "[env]\nHARNESS_CI_PER_PUSH_REASON = \"fixture exercises per-push coverage\"\n",
        )
        .unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "base"]);
        git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        fs::write(worktree.join(path), "x\n").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "change"]);
        fs::write(
            &self.item,
            ITEM.replacen(
                "\"worktree\": \"/home/u/dev/.worktrees/kendex/ken-4687\"",
                &format!("\"worktree\": \"{}\"", worktree.display()),
                1,
            ),
        )
        .unwrap();
        let orch = orch_dir();
        let out = support::isolated()
            .args(["--state-dir", &root.display().to_string()])
            .args(["validate", "start", "--item", ITEM_ID, "--round", ROUND])
            .args(["--poll", "1", "--foreground"])
            .current_dir(&worktree)
            .env("DEV_VALIDATE_CLI", orch.join("scripts/dev-validate-run"))
            .env(
                "CHANGE_SCOPE_PATHS_CLI",
                orch.join("../change-scope/scripts/harness-only"),
            )
            .env("DEV_VALIDATE_CMD", "echo full")
            .env("DEV_VALIDATE_TIMEOUT_SECS", "20")
            .env("ORCH_PR_ORDER", "review-first")
            .env("ORCH_DELIVERY", "push-base")
            .env("LANE_MAIL_CLI", orch.join("../mailbox/scripts/lane-mail"))
            .env("LANE_MAIL_DIR", root.join("mail"))
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}\n{}",
            support::stderr(&out),
            String::from_utf8_lossy(&out.stdout)
        );
        git(&["rev-parse", "HEAD"])
    }

    /// The `pr view` answer for an open pull request at `head`.
    fn pull_at(&mut self, head: &str) -> &mut Self {
        self.replies.insert(
            format!("pr view {PR}"),
            json!({"body": {
                "state": "OPEN", "mergedAt": null, "mergeable": "MERGEABLE",
                "headRefOid": head, "baseRefName": "main"
            }}),
        );
        self
    }

    /// The merge-group head's check runs, each completed with its
    /// conclusion; the run with id N has the page `runs/N`.
    fn group_checks(&mut self, checks: &[(&str, &str)]) -> &mut Self {
        let key = format!("repos/{REPO}/commits/{QUEUE_HEAD}/check-runs?per_page=100&page=1");
        let runs: Vec<Value> = checks
            .iter()
            .enumerate()
            .map(|(i, (name, conclusion))| {
                json!({"id": i + 1, "node_id": format!("CR_{}", i + 1), "name": name,
                    "status": "completed", "conclusion": conclusion, "check_suite": {"id": 1},
                    "started_at": "2026-07-24T10:00:00Z", "completed_at": "2026-07-24T10:05:00Z",
                    "html_url": format!("https://github.com/{REPO}/runs/{}", i + 1),
                    "details_url": format!("https://github.com/{REPO}/actions/runs/9/job/{}", i + 1)})
            })
            .collect();
        self.replies.insert(
            key,
            json!({"body": {"total_count": runs.len(), "check_runs": runs}}),
        );
        self
    }
}

/// An ejection carries the red group's reach: the failed checks on the
/// group head an earlier run recorded, judged by kendex's reach command
/// through the real `tools/ci-job-set` over the change the item's real
/// validation recorded for the pull request's head. `within` where any
/// failed check is a shard the change's paths select, `outside` where the
/// command answers every one outside them, and `unread` wherever a read
/// that claim needs fails, a lost run's cancelled checks included: never
/// `outside` on what was not read.
#[test]
fn an_ejected_groups_reach_is_its_failed_checks_judged_by_the_consumers_selector() {
    /// One case: whether the item's validation recorded the head, the
    /// group's check runs with their conclusions (`None`: their read
    /// fails), whether the reach command is declared, and the reach, its
    /// cause and each failed check's answer the reply carries.
    struct Case {
        name: &'static str,
        validated: bool,
        checks: Option<Vec<(&'static str, &'static str)>>,
        declared: bool,
        reach: &'static str,
        cause: Option<&'static str>,
        answers: Vec<(&'static str, &'static str)>,
    }
    let world = tempfile::tempdir().unwrap();
    let command = support::isolated_program(&reach_world(world.path()))
        .display()
        .to_string();
    // `rest` runs a changed skill no other shard claims; the UI lane runs
    // only for a path under `ui/`, and the bridge's shard only for the
    // bridge's package.
    let within = "Skill suites shard (rest, ubuntu-latest)";
    let outside = "UI (vitest, tsc, biome)";
    let bridge = "Skill suites shard (pi-claude-bridge, ubuntu-latest)";
    let unmapped = "Classify the diff";
    let cases = [
        Case {
            name: "outside",
            validated: true,
            checks: Some(vec![
                (within, "success"),
                (outside, "failure"),
                (bridge, "failure"),
                ("CI", "failure"),
            ]),
            declared: true,
            reach: "outside",
            cause: None,
            answers: vec![(outside, "outside"), (bridge, "outside"), ("CI", "outside")],
        },
        Case {
            name: "within",
            validated: true,
            checks: Some(vec![
                (outside, "timed_out"),
                (within, "failure"),
                ("CI", "failure"),
            ]),
            declared: true,
            reach: "within",
            cause: None,
            answers: vec![(outside, "outside"), (within, "within"), ("CI", "within")],
        },
        Case {
            name: "a check no job maps to",
            validated: true,
            checks: Some(vec![(unmapped, "failure"), ("CI", "failure")]),
            declared: true,
            reach: "unread",
            cause: Some("check-unmapped"),
            answers: vec![(unmapped, "unread"), ("CI", "unread")],
        },
        Case {
            name: "a lost run",
            validated: true,
            checks: Some(vec![(outside, "cancelled"), ("CI", "cancelled")]),
            declared: true,
            reach: "unread",
            cause: Some("no-failed-check"),
            answers: vec![],
        },
        Case {
            name: "the checks unread",
            validated: true,
            checks: None,
            declared: true,
            reach: "unread",
            cause: Some("check-runs-unread"),
            answers: vec![],
        },
        Case {
            name: "no validation of the head",
            validated: false,
            checks: Some(vec![(outside, "failure")]),
            declared: true,
            reach: "unread",
            cause: Some("change-unread"),
            answers: vec![(outside, "unread")],
        },
        Case {
            name: "no reach command",
            validated: true,
            checks: Some(vec![(outside, "failure")]),
            declared: false,
            reach: "unread",
            cause: Some("reach-unset"),
            answers: vec![(outside, "unread")],
        },
    ];
    for case in cases {
        let name = case.name;
        let mut world = World::new();
        if case.validated {
            let head = world.validated("skills/price-handling/SKILL.md");
            world.pull_at(&head);
        }
        world
            .queue(in_queue(Some(QUEUE_HEAD)))
            .check_runs(Some((0, 2)));
        let first = world.request(10, 10);
        let reply = world.wait(&first, |_, clock| {
            clock.await_sleepers(1);
            clock.release(secs(10));
        });
        assert_eq!(reply.verdict, "queued", "{name}: {reply:?}");
        assert_eq!(
            world.memory()["group_head"].as_str(),
            Some(QUEUE_HEAD),
            "{name}"
        );
        world.queue(out());
        match &case.checks {
            Some(checks) => world.group_checks(checks),
            None => world.check_runs(None),
        };
        let second = QueueWatch {
            reach_cmd: case.declared.then(|| command.clone()),
            ..world.request(10, 30)
        };
        let reply = world.wait(&second, |_, clock| {
            clock.await_sleepers(1);
            clock.release(secs(10));
        });
        assert_eq!(
            (reply.verdict, reply.cause, reply.reach, reply.reach_cause),
            (
                "ejected",
                Some("merge_group_failed"),
                Some(case.reach),
                case.cause
            ),
            "{name}: {reply:?}"
        );
        let planted = case.checks.unwrap_or_default();
        let want: Vec<(String, &str, Option<String>)> = case
            .answers
            .iter()
            .map(|(check, answer)| {
                let id = planted.iter().position(|(n, _)| n == check).unwrap() + 1;
                (
                    (*check).to_owned(),
                    *answer,
                    Some(format!("https://github.com/{REPO}/runs/{id}")),
                )
            })
            .collect();
        let got: Vec<(String, &str, Option<String>)> = reply
            .failed_checks
            .unwrap_or_default()
            .into_iter()
            .map(|c| (c.name, c.reach, c.url))
            .collect();
        assert_eq!(got, want, "{name}");
    }
}
