//! Process tests of the lane admission through the `orch-runtime`
//! executable: the holders' identities are processes this test holds, so
//! the kernel table answers for them as it would for a harness, the item
//! bodies come from a fake tracker keyed by item, and the range's paths
//! from the change-scope package's own path reader over a repository this
//! test makes. The launches run with no tmux server at all: an admitted
//! launch fails before any window, the admission being the transition under
//! test and the committed record what the next admission reads.
//!
//! The suite reads the kernel's `/proc` table for the identities it holds,
//! so it runs on Linux alone.
#![cfg(target_os = "linux")]
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;
use tempfile::TempDir;

/// The kernel's state letter for a pid, `None` once its entry is gone.
fn state_of(pid: u32) -> Option<char> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(')')
        .and_then(|(_, rest)| rest.split_whitespace().next())
        .and_then(|f| f.chars().next())
}

/// End a held child and wait until the kernel holds it as a zombie: exited,
/// unreaped, its pid reused by nothing this test can see, so it reads gone.
fn end(owned: &mut Owned) {
    owned.0.kill().unwrap();
    for _ in 0..500 {
        if state_of(owned.pid()) == Some('Z') {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("the ended child never became a zombie");
}

/// The linear package's formatter library in this checkout, which the
/// tracker stand-in runs over the planted answers.
fn linear_formatters() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../linear/scripts/lib/formatters.sh")
}

/// The change-scope package's path reader in this checkout.
fn harness_only() -> PathBuf {
    fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("change-scope/scripts/harness-only")
}

/// The binary against a fleet state in its own directory, with no tmux
/// server to reach, a cap of four, the tracker stand-in running the linear
/// package's real bundle formatter over the GraphQL answers this test
/// writes, the real path reader, and one fake `gh` on `PATH`: `gh-issue`
/// for the item read, or `gh` answering `gh api` and `gh repo view` from
/// the map a row plants ([`Fleet::gh_api`]). Every child runs with
/// `--no-private-env` and `GIT_CEILING_DIRECTORIES` at the temp root, so no
/// checkout above the test directory is its project.
struct Fleet {
    dir: TempDir,
    gh_fixture: &'static str,
}

impl Fleet {
    fn new() -> Fleet {
        let fleet = Fleet {
            dir: tempfile::tempdir().unwrap(),
            gh_fixture: "gh-issue",
        };
        std::fs::create_dir_all(fleet.items_dir()).unwrap();
        std::fs::create_dir_all(fleet.state_dir().join("state")).unwrap();
        fleet
    }

    fn state_dir(&self) -> PathBuf {
        self.dir.path().join("state")
    }

    fn items_dir(&self) -> PathBuf {
        self.dir.path().join("items")
    }

    fn fleet_path(&self) -> PathBuf {
        self.state_dir().join("workflow-state-oversee.json")
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = isolated();
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(args)
            .env(
                "TMUX",
                format!("{},0,0", self.dir.path().join("no-such.sock").display()),
            )
            .env("ORCH_TMUX_SESSION", "fleet")
            .env("ORCH_OVERSEER_LANES", "4")
            .env(
                "OVERSEE_WATCH_TRACKER",
                fixtures().join("linear-items/linear.sh"),
            )
            .env("LINEAR_ITEMS_DIR", self.items_dir())
            .env("LINEAR_FORMATTERS", linear_formatters())
            .env("LINEAR_FAKE_LOG", self.dir.path().join("linear.log"))
            .env("CHANGE_SCOPE_PATHS_CLI", harness_only())
            .env("GH_ISSUES_DIR", self.items_dir())
            .env("GH_FAKE_LOG", self.dir.path().join("gh.log"))
            .env("GH_FAKE_REPLIES", self.dir.path().join("gh.json"))
            .env(
                "PATH",
                support::tool_path(&[fixtures().join(self.gh_fixture).as_path()]),
            )
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "DEV_VALIDATE_CLI",
                fixtures().join("dev-validate-quiet/dev-validate-run"),
            )
            // No project settings or private env reach the test's own tree.
            .current_dir(self.state_dir());
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().expect("orch-runtime")
    }

    /// A repository at `name` under the test directory, whose `origin`
    /// is `origin` where one is named.
    fn checkout(&self, name: &str, origin: Option<&str>) -> PathBuf {
        let repo = self.dir.path().join(name);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main", "."]);
        if let Some(url) = origin {
            git(&repo, &["remote", "add", "origin", url]);
        }
        repo
    }

    /// The launch `request` applied under the settings `env` names.
    fn op_with(&self, request: &Value, env: &[(&str, &str)]) -> Output {
        let path = self.request_file("request", request);
        let mut command =
            self.command(&["op", "--fleet", "--request", &path.display().to_string()]);
        for (name, value) in env {
            command.env(name, value);
        }
        command.output().expect("orch-runtime")
    }

    fn request_file(&self, name: &str, request: &Value) -> PathBuf {
        let path = self.dir.path().join(format!("{name}.json"));
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        path
    }

    fn op(&self, request: &Value) -> Output {
        let path = self.request_file("request", request);
        self.run(&["op", "--fleet", "--request", &path.display().to_string()])
    }

    fn admit(&self, request: &Value) -> Output {
        let path = self.request_file("admit", request);
        self.run(&["admit", "--fleet", "--request", &path.display().to_string()])
    }

    fn init_fleet(&self) {
        let out = self.run(&["state", "init", "--fleet"]);
        assert!(out.status.success(), "init: {}", stderr(&out));
    }

    /// An item state for `item` naming `branch`: what a holder's rebase
    /// obligation reads its branch from.
    fn init_item(&self, item: &str, branch: &str) {
        let out = self.run(&["state", "init", "--item", item, "--branch", branch]);
        assert!(out.status.success(), "init {item}: {}", stderr(&out));
    }

    /// The tracker's GraphQL answer for `item` as `issues get` receives it
    /// and the bundle formatter reads it: `fields` over an unstarted
    /// issue with no parent, children, labels or relations.
    fn plant(&self, item: &str, fields: Value) {
        let mut node = json!({
            "id": format!("uuid-{item}"),
            "identifier": item,
            "title": item,
            "description": "Some text.\n",
            "state": {"name": "Todo", "type": "unstarted"},
            "parent": Value::Null,
            "labels": {"nodes": []},
            "children": {"nodes": []},
            "relations": {"nodes": []},
            "inverseRelations": {"nodes": []},
        });
        for (key, value) in fields.as_object().unwrap() {
            node[key] = value.clone();
        }
        std::fs::write(
            self.items_dir().join(format!("{item}.json")),
            serde_json::to_vec(&json!({"issue": node})).unwrap(),
        )
        .unwrap();
    }

    /// The tracker's answer for `item`: a body with one Location line,
    /// `children` child issues and the labels.
    fn item(&self, item: &str, location: &str, children: usize, labels: &[&str]) {
        let children: Vec<Value> = (0..children)
            .map(|n| {
                json!({"id": format!("uuid-{item}-c{n}"), "identifier": format!("{item}-c{n}"),
                            "state": {"name": "Todo", "type": "unstarted"}})
            })
            .collect();
        self.plant(
            item,
            json!({
                "description": format!("Some text.\n**Location**: {location}\n"),
                "labels": {"nodes": labels.iter().map(|l| json!({"name": l})).collect::<Vec<_>>()},
                "children": {"nodes": children},
            }),
        );
    }

    /// The tracker's answer for `item` under the container `parent` (none
    /// for an empty word), blocked by the started issues `blockers`.
    fn item_under(&self, item: &str, parent: &str, blockers: &[&str]) {
        let relations: Vec<Value> = blockers
            .iter()
            .map(|b| {
                json!({"id": format!("rel-{b}"), "type": "blocks",
                       "issue": {"id": format!("uuid-{b}"), "identifier": b, "title": b,
                                 "state": {"name": "In Progress", "type": "started"}}})
            })
            .collect();
        self.plant(
            item,
            json!({
                "parent": if parent.is_empty() { Value::Null } else { json!({"identifier": parent}) },
                "inverseRelations": {"nodes": relations},
            }),
        );
    }

    /// Every tracker read made so far, one argument line each.
    fn linear_log(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("linear.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Plant the `gh api` fixture's map and put that fake `gh` on `PATH`.
    fn gh_api(&mut self, map: &Value) {
        std::fs::write(
            self.dir.path().join("gh.json"),
            serde_json::to_vec(map).unwrap(),
        )
        .unwrap();
        self.gh_fixture = "gh";
    }

    /// Every `gh` call made so far, one argument line each.
    fn gh_log(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("gh.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_path()).unwrap()).unwrap()
    }

    fn write_lanes(&self, lanes: Vec<Value>) {
        let mut fleet = self.fleet();
        fleet["lanes"] = Value::Array(lanes);
        fleet["intents"] = json!([]);
        std::fs::write(
            self.fleet_path(),
            serde_json::to_string_pretty(&fleet).unwrap(),
        )
        .unwrap();
    }

    fn lane(&self, item: &str) -> Value {
        self.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .cloned()
            .unwrap_or(Value::Null)
    }

    fn lane_count(&self) -> usize {
        self.fleet()["lanes"].as_array().unwrap().len()
    }
}

/// A holder's lane record: `process` its harness, `touched` its recorded
/// set, `None` for a record the admission reads from its item.
fn holder(item: &str, status: &str, process: Option<&Owned>, touched: Option<&[&str]>) -> Value {
    let launch = match process {
        Some(p) => json!({"pane": "%7", "server": 41020, "pid": p.pid(), "start": p.start()}),
        None => Value::Null,
    };
    let mut record = json!({
        "item": item,
        "tracker": "linear",
        "harness": "claude",
        "window": format!("fleet:{item}"),
        "mail_root": "/w/holder",
        "session_since": "2026-01-29T15:00:00Z",
        "launched_at": "2026-01-29T15:00:00Z",
        "status": status,
        "launch": launch,
    });
    if let Some(paths) = touched {
        record["touched"] = json!(paths);
    }
    record
}

fn launch(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "tracker": "linear",
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
    })
}

/// Run git in `repo` as a test child: the fixed identity and no operator
/// configuration are the constructor's.
fn git(repo: &Path, args: &[&str]) {
    let out = program("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
}

/// A pull request of repository `o/r` as the gh fixture answers it: the
/// open list names it, its object is read by number, and an open
/// same-repository one's files page is read.
struct FakePull {
    number: u64,
    state: &'static str,
    /// Its head branch, `head.ref`.
    branch: &'static str,
    /// The head repository's `full_name`; `None` plants a deleted fork.
    head_repo: Option<&'static str>,
    /// The files page's members, "Diff Entry" objects.
    files: Vec<Value>,
    /// The `changed_files` the object reports, where a row plants one that
    /// disagrees with the files page.
    changed: Option<u64>,
}

/// An open pull request of `o/r` (its head repository spelled `O/r`, as
/// GitHub names are case-insensitive) changing `files`.
fn fake_pull(number: u64, branch: &'static str, files: &[&str]) -> FakePull {
    FakePull {
        number,
        state: "open",
        branch,
        head_repo: Some("O/r"),
        files: files.iter().map(|f| json!({"filename": f})).collect(),
        changed: None,
    }
}

/// A head commit no row reads.
const ZERO_SHA: &str = "0000000000000000000000000000000000000000";

/// The open-list path the admission reads for `o/r`.
const PULLS_LIST: &str = "repos/o/r/pulls?state=open&per_page=100&page=1";

/// The gh fixture's map, `{path: {body}}` per read, for these pull
/// requests: the open list naming every one, each object, each files page.
fn gh_map(pulls: &[FakePull]) -> Value {
    let mut map = serde_json::Map::new();
    let listed: Vec<Value> = pulls
        .iter()
        .map(|p| json!({"number": p.number, "state": "open", "title": "a holder", "body": null, "merged_at": null, "merge_commit_sha": null, "author_association": "NONE", "head": {"sha": ZERO_SHA, "ref": p.branch, "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null}))
        .collect();
    map.insert(PULLS_LIST.to_owned(), json!({"body": listed}));
    for p in pulls {
        let merged_at = if p.state == "closed" {
            json!("2026-01-29T15:00:00Z")
        } else {
            Value::Null
        };
        map.insert(
            format!("repos/o/r/pulls/{}", p.number),
            json!({"body": {
                "number": p.number,
                "state": p.state,
                "title": "a holder",
                "body": null,
                "merged_at": merged_at,
                "merge_commit_sha": null,
                "changed_files": p.changed.unwrap_or(p.files.len() as u64),
                "author_association": "NONE",
                "head": {
                    "sha": ZERO_SHA,
                    "ref": p.branch,
                    "repo": p.head_repo.map(|name| json!({"full_name": name, "owner": {"login": "o", "type": "Organization"}})),
                },
                "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"},
                "user": null,
            }}),
        );
        map.insert(
            format!("repos/o/r/pulls/{}/files?per_page=100&page=1", p.number),
            json!({"body": p.files}),
        );
    }
    Value::Object(map)
}

fn refusal(out: &Output) -> (String, Vec<(String, String)>) {
    assert!(!out.status.success(), "admitted: {}", stderr(out));
    let answer = reply(out);
    assert_eq!(answer["ok"], false);
    let fields = answer["refusal"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pair| {
            (
                pair[0].as_str().unwrap().to_owned(),
                pair[1].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    (
        answer["refusal"]["key"].as_str().unwrap().to_owned(),
        fields,
    )
}

fn pairs(rows: &[(&str, &str)]) -> Vec<(String, String)> {
    rows.iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

/// At the holder: a holder whose recorded harness is a live process blocks
/// the launch with its id and nothing is written; the same holder ended,
/// its record still reading `running`, yields: the launch is admitted, its
/// record carries the touched set and a rebase obligation naming the holder
/// and the branch its item state records, and the holder's record keeps
/// every field.
#[test]
fn a_live_holder_blocks_the_launch_and_a_gone_one_yields_with_a_rebase_obligation() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-H", "ken-h");
    fleet.item("KEN-L", "`src/a.sh`, `docs/x.md`", 0, &[]);
    let mut harness = Owned::sleep();
    fleet.write_lanes(vec![holder(
        "KEN-H",
        "running",
        Some(&harness),
        Some(&["src/a.sh"]),
    )]);
    let before = fleet.fleet();

    let out = fleet.op(&launch("KEN-L", fleet.state_dir().as_path()));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-L"), ("file", "src/a.sh"), ("holder", "KEN-H")])
    );
    assert!(
        stderr(&out)
            .starts_with("orch-runtime: launch-overlap item=KEN-L file=src/a.sh holder=KEN-H"),
        "{}",
        stderr(&out)
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    assert!(live(harness.pid()), "a refused launch signals nothing");

    end(&mut harness);
    let out = fleet.op(&launch("KEN-L", fleet.state_dir().as_path()));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-L");
    assert_eq!(lane["touched"], json!(["docs/x.md", "src/a.sh"]));
    assert_eq!(lane["in_scope"], json!([]));
    let rebase = lane["rebase"].as_array().unwrap();
    assert_eq!(rebase.len(), 1);
    assert_eq!(rebase[0]["holder"], "KEN-H");
    assert_eq!(rebase[0]["branch"], "ken-h");
    assert_eq!(rebase[0]["paths"], json!(["src/a.sh"]));
    assert!(rebase[0]["at"].as_str().unwrap().ends_with('Z'));
    assert_eq!(
        answer["result"]["persisted"]["report"]["lane"]["rebase"][0]["holder"], "KEN-H",
        "the reply carries the judgement"
    );
    assert_eq!(
        fleet.lane("KEN-H"),
        before["lanes"][0],
        "the holder's record keeps every field"
    );
    // No fleet server exists here, so the admitted launch fails before any
    // window; the record it leaves is `stopped`, its judgement kept.
    assert_eq!(lane["status"], "stopped");
}

/// A record reading `done`: the item's next phase is
/// judged as a first launch, on its item, its brief and the range it
/// names, over the record's slot. KEN-L's done record keeps its earlier
/// sets; a live holder of a path the item now names refuses
/// `launch-overlap`, and with the holder gone and an open pull request on
/// the path the launch is admitted with both obligations on the record,
/// its touched set the item's.
#[test]
fn a_launch_over_a_done_record_is_judged_as_a_first_launch() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-H", "ken-h");
    fleet.item("KEN-L", "`src/a.sh`, `docs/x.md`", 0, &[]);
    let mut harness = Owned::sleep();
    let mut live = holder("KEN-H", "running", Some(&harness), Some(&["src/a.sh"]));
    live["repo"] = json!("o/r");
    let mut done = holder("KEN-L", "done", None, Some(&["old/path.rs"]));
    done["repo"] = json!("o/r");
    fleet.write_lanes(vec![live, done]);
    fleet.gh_api(&gh_map(&[fake_pull(7, "feature/x", &["src/a.sh"])]));
    let before = fleet.fleet();
    let mut request = launch("KEN-L", fleet.state_dir().as_path());
    request["repo"] = json!("o/r");

    let out = fleet.op(&request);
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap", "{}", stderr(&out));
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-L"), ("file", "src/a.sh"), ("holder", "KEN-H")])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");

    end(&mut harness);
    let out = fleet.op(&request);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-L");
    // No fleet server exists here, so the admitted launch fails before any
    // window; the record it leaves is `stopped`, its judgement kept.
    assert_eq!(lane["status"], "stopped");
    assert_eq!(
        lane["touched"],
        json!(["docs/x.md", "src/a.sh"]),
        "the item's set, never the done record's"
    );
    let holders: Vec<&str> = lane["rebase"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["holder"].as_str().unwrap())
        .collect();
    assert_eq!(holders, ["KEN-H", "#7"], "{lane}");
    assert_eq!(fleet.lane_count(), 2, "the record's slot is taken");
    assert_eq!(fleet.lane("KEN-H"), before["lanes"][0]);
}

/// The bundle reply a linear package whose formatter names no launch
/// blockers prints over a node blocked by the started issue CC-9: that
/// formatter's own output, planted as it stands for the row below, since
/// such a package may be installed beside this runtime.
const RELEASED_BUNDLE_REPLY: &str = r#"{"id":"CC-8","identifier":"CC-8","uuid":"uuid-CC-8","title":"CC-8","description":"Some text.\n","in_pr_bundle":false,"state":"Todo","state_type":"unstarted","agent":"","platform":"","labels":[],"priority":0,"estimate":0,"sort_order":0,"project":"","project_id":"","assignee":"","parent_id":"","milestone":"","cycle":"","created_at":"","updated_at":"","blocks":[],"blocked_by":["CC-9"],"blocked_by_open":["CC-9"],"related":[],"url":"","children":[],"pending_count":0}"#;

/// The tracker's bundle read names a launch blocker on the container
/// ancestor that holds it, so the launch reads each ancestor's. Through the
/// real `launch-lane` and the linear package's real bundle formatter over
/// planted GraphQL answers: an item whose grandparent holds a blocker is
/// refused `launch-blocked` naming it after reading the three, nothing
/// written; the item's own blocker refuses after one read; an ancestor the
/// tracker cannot answer for refuses `launch-blocked-unread` naming it; a
/// reply with no launch-blocker field refuses `launch-blocked-unread`
/// naming its node, for the item itself and for an ancestor; a chain with
/// no blocker admits; and a relaunch over a recorded lane reads no item at
/// all.
#[test]
fn a_launch_under_a_container_ancestor_holding_a_blocker_is_refused_before_any_record() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let reads_since = |after: usize| fleet.linear_log()[after..].to_vec();
    let read = |item: &str| format!("issues get {item} --with-bundle --format=safe");
    fleet.item_under("CC-1", "CC-2", &[]);
    fleet.item_under("CC-2", "CC-3", &["CC-9"]);
    fleet.item_under("CC-3", "", &[]);
    let before = fleet.fleet();
    let (key, fields) = refusal(&fleet.op(&launch("CC-1", fleet.state_dir().as_path())));
    assert_eq!(key, "launch-blocked");
    assert_eq!(fields, pairs(&[("item", "CC-1"), ("blockers", "CC-9")]));
    assert_eq!(fleet.fleet(), before, "nothing written, no intent");
    assert_eq!(
        reads_since(0),
        vec![read("CC-1"), read("CC-2"), read("CC-3")],
        "the item and its two ancestors, once each"
    );
    fleet.item_under("CC-4", "", &["CC-9", "CC-8"]);
    let (key, fields) = refusal(&fleet.op(&launch("CC-4", fleet.state_dir().as_path())));
    assert_eq!(key, "launch-blocked");
    assert_eq!(
        fields,
        pairs(&[("item", "CC-4"), ("blockers", "CC-8,CC-9")])
    );
    assert_eq!(reads_since(3), vec![read("CC-4")]);
    fleet.item_under("CC-5", "CC-6", &[]);
    let (key, fields) = refusal(&fleet.op(&launch("CC-5", fleet.state_dir().as_path())));
    assert_eq!(key, "launch-blocked-unread");
    assert_eq!(fields, pairs(&[("item", "CC-5"), ("read", "CC-6")]));
    assert_eq!(fleet.fleet(), before, "an unread chain writes nothing");
    std::fs::write(
        fleet.items_dir().join("CC-8.released.json"),
        RELEASED_BUNDLE_REPLY,
    )
    .unwrap();
    let (key, fields) = refusal(&fleet.op(&launch("CC-8", fleet.state_dir().as_path())));
    assert_eq!(
        key, "launch-blocked-unread",
        "a reply with no launch-blocker field is no judgement"
    );
    assert_eq!(fields, pairs(&[("item", "CC-8"), ("read", "CC-8")]));
    fleet.item_under("CC-10", "CC-8", &[]);
    let (key, fields) = refusal(&fleet.op(&launch("CC-10", fleet.state_dir().as_path())));
    assert_eq!(key, "launch-blocked-unread");
    assert_eq!(fields, pairs(&[("item", "CC-10"), ("read", "CC-8")]));
    assert_eq!(fleet.fleet(), before, "an unjudged chain writes nothing");
    fleet.item_under("CC-7", "CC-3", &[]);
    let admitted = reply(&fleet.op(&launch("CC-7", fleet.state_dir().as_path())));
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(reads_since(9), vec![read("CC-7"), read("CC-3")]);
    assert_eq!(
        fleet.lane("CC-7")["status"],
        "stopped",
        "admitted, no server"
    );
    fleet.item_under("CC-7", "CC-2", &[]);
    let mut relaunch = launch("CC-7", fleet.state_dir().as_path());
    relaunch["tracker"] = json!("linear");
    let admitted = reply(&fleet.op(&relaunch));
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(
        reads_since(11),
        Vec::<String>::new(),
        "a recorded lane's relaunch was judged when it was admitted"
    );
}

/// At the holder: a holder whose touched set cannot be read, its record
/// carrying none and its item unreadable, blocks as unknown; nothing is
/// written.
#[test]
fn an_unreadable_holder_blocks_the_launch_and_never_admits() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    fleet.write_lanes(vec![holder("KEN-H", "running", None, None)]);
    let before = fleet.fleet();
    let out = fleet.op(&launch("KEN-L", fleet.state_dir().as_path()));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "holder-unreadable");
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-L"), ("holder", "KEN-H"), ("read", "touched")])
    );
    assert_eq!(fleet.fleet(), before);
}

/// The touched set is the union of the Location paths, the brief's paths
/// and the change-scope paths over the named range. Each source alone names
/// a path the live holder holds, and each alone blocks with that file.
#[test]
fn a_path_only_one_source_names_overlaps_the_holder() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    let mut harness = Owned::sleep();
    fleet.write_lanes(vec![holder(
        "KEN-H",
        "running",
        Some(&harness),
        Some(&["src/a.sh", "src/b.sh", "src/c.sh"]),
    )]);
    // A repository whose range changes src/c.sh alone, on github.com with
    // no open pull request.
    let repo = fleet.dir.path().join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main", "."]);
    git(
        &repo,
        &["remote", "add", "origin", "https://github.com/o/r.git"],
    );
    std::fs::write(repo.join("src/z.sh"), "echo\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "base"]);
    std::fs::write(repo.join("src/c.sh"), "echo\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "head"]);
    let brief = fleet.dir.path().join("brief.md");
    std::fs::write(&brief, "Edit `src/b.sh` and run `cargo test`.\n").unwrap();

    fleet.item("KEN-1", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-2", "`docs/only.md`", 0, &[]);
    fleet.item("KEN-3", "`docs/only.md`", 0, &[]);
    let rows = [
        ("KEN-1", json!({}), "src/a.sh"),
        (
            "KEN-2",
            json!({"brief_file": brief.display().to_string()}),
            "src/b.sh",
        ),
        (
            "KEN-3",
            json!({
                "repo_dir": repo.display().to_string(),
                "scope_range": {"base": "HEAD~1", "head": "HEAD"},
            }),
            "src/c.sh",
        ),
    ];
    for (item, extra, file) in rows {
        let mut request = launch(item, fleet.state_dir().as_path());
        for (key, value) in extra.as_object().unwrap() {
            request[key] = value.clone();
        }
        let out = fleet.op(&request);
        let (key, fields) = refusal(&out);
        assert_eq!(key, "launch-overlap", "{item}: {}", stderr(&out));
        assert_eq!(
            fields,
            pairs(&[("item", item), ("file", file), ("holder", "KEN-H")]),
            "{item}"
        );
    }
    assert_eq!(fleet.lane_count(), 1, "nothing was launched");
    // The same brief and range with no live holder: the record carries the
    // whole union, sorted, the brief's non-path tokens left out.
    fleet.gh_api(&gh_map(&[]));
    end(&mut harness);
    let mut request = launch("KEN-3", fleet.state_dir().as_path());
    request["brief_file"] = json!(brief.display().to_string());
    request["repo_dir"] = json!(repo.display().to_string());
    request["scope_range"] = json!({"base": "HEAD~1", "head": "HEAD"});
    request["in_scope"] = json!(["src/b.sh"]);
    let out = fleet.op(&request);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-3");
    assert_eq!(
        lane["touched"],
        json!(["docs/only.md", "src/b.sh", "src/c.sh"])
    );
    assert_eq!(lane["in_scope"], json!(["src/b.sh"]));
    assert_eq!(
        lane["rebase"][0]["paths"],
        json!(["src/c.sh"]),
        "the in-scope path is left out of the obligation"
    );
}

/// A container, by children or by the `agent:multi` label, is refused from
/// its body before any record or intent; a GitHub item is read through gh,
/// launched from a checkout of its repository.
#[test]
fn an_ineligible_item_is_refused_from_its_body_before_any_record() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let checkout = fleet.checkout("repo", Some("https://github.com/o/r.git"));
    fleet.item("KEN-P", "`src/a.sh`", 2, &[]);
    fleet.item("KEN-M", "`src/a.sh`", 0, &["agent:multi"]);
    std::fs::write(
        fleet.items_dir().join("7.json"),
        br#"{"body": "**Location**: `src/a.sh`", "labels": [{"name": "agent:multi"}, {"name": "bug"}]}"#,
    )
    .unwrap();
    let before = fleet.fleet();
    let rows = [
        (
            launch("KEN-P", fleet.state_dir().as_path()),
            "KEN-P",
            "parent-with-children",
        ),
        (
            launch("KEN-M", fleet.state_dir().as_path()),
            "KEN-M",
            "agent-multi",
        ),
        (
            json!({
                "op": "launch-lane",
                "item": "issue-7",
                "tracker": "github",
                "repo": "o/r",
                "harness": "claude",
                "mail_root": checkout.display().to_string(),
            }),
            "issue-7",
            "agent-multi",
        ),
    ];
    for (request, item, cause) in rows {
        let out = fleet.op(&request);
        let (key, fields) = refusal(&out);
        assert_eq!(key, "item-ineligible", "{item}");
        assert_eq!(fields, pairs(&[("item", item), ("cause", cause)]), "{item}");
    }
    assert_eq!(fleet.fleet(), before, "nothing written, no intent");
    let reads: Vec<String> = fleet
        .gh_log()
        .into_iter()
        .filter(|line| line.starts_with("issue "))
        .collect();
    assert_eq!(
        reads,
        ["issue view 7 --repo o/r --json body,labels"],
        "the GitHub item was read through gh, once"
    );
}

/// A running lane's added path is judged against the holders through
/// `admit` and widens its record with the touched set and the obligation a
/// stopped holder yields; a live holder refuses it with its id and the
/// record stays as it was.
#[test]
fn a_running_lanes_added_path_widens_its_record_or_is_refused_by_a_live_holder() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-S", "ken-s");
    let live_holder = Owned::sleep();
    let mut ended = Owned::sleep();
    end(&mut ended);
    fleet.write_lanes(vec![
        json!({
            "item": "KEN-L", "tracker": "linear", "harness": "claude", "status": "running",
            "mail_root": "/w/l", "touched": ["src/a.sh"], "in_scope": [],
            "launch": {"pane": "%1", "server": 41020, "pid": 1, "start": "ticks:1"},
        }),
        holder(
            "KEN-S",
            "running",
            Some(&ended),
            Some(&["src/b.sh", "src/s.sh"]),
        ),
        holder("KEN-H", "running", Some(&live_holder), Some(&["src/c.sh"])),
    ]);
    let out = fleet.admit(&json!({"item": "KEN-L", "paths": ["src/b.sh", "src/new.sh"]}));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(answer["result"]["recorded"], true);
    assert_eq!(
        answer["result"]["touched"],
        json!(["src/a.sh", "src/b.sh", "src/new.sh"])
    );
    assert_eq!(answer["result"]["rebase"][0]["holder"], "KEN-S");
    assert_eq!(answer["result"]["rebase"][0]["branch"], "ken-s");
    let lane = fleet.lane("KEN-L");
    assert_eq!(
        lane["touched"],
        json!(["src/a.sh", "src/b.sh", "src/new.sh"])
    );
    assert_eq!(lane["rebase"][0]["paths"], json!(["src/b.sh"]));
    assert_eq!(
        lane["status"], "running",
        "the record moves in nothing else"
    );

    let before = fleet.fleet();
    let out = fleet.admit(&json!({"item": "KEN-L", "paths": ["src/c.sh"]}));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-L"), ("file", "src/c.sh"), ("holder", "KEN-H")])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");

    // A launcher's judgement before its record stands: answered, nothing
    // written.
    fleet.item("KEN-N", "`src/s.sh`", 0, &[]);
    let out = fleet.admit(&json!({"item": "KEN-N", "tracker": "linear"}));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(answer["result"]["recorded"], false);
    assert_eq!(answer["result"]["touched"], json!(["src/s.sh"]));
    assert_eq!(
        answer["result"]["rebase"],
        json!([{
            "holder": "KEN-S", "branch": "ken-s", "paths": ["src/s.sh"],
            "at": answer["result"]["rebase"][0]["at"],
        }])
    );
    assert_eq!(fleet.fleet(), before);
}

/// An open same-repository pull request touching a candidate path is a
/// holder with no lane: the launch yields, its record carrying a rebase
/// obligation naming `#N` and the head branch, a rename's old path among
/// the shared paths; one touching no candidate path, a fork's and a merged
/// one (listed open, read closed by number) hold nothing. The open list is
/// read once, each pull request by number, and the files of the open
/// same-repository ones alone.
#[test]
fn an_open_pull_request_on_a_candidate_path_yields_with_a_rebase_obligation_naming_its_branch_and_number()
 {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`, `docs/x.md`", 0, &[]);
    let mut renamed = fake_pull(7, "feature/x", &["src/a.sh"]);
    renamed
        .files
        .push(json!({"filename": "src/moved.sh", "previous_filename": "docs/x.md"}));
    let mut fork = fake_pull(9, "fork-work", &["src/a.sh"]);
    fork.head_repo = Some("fork/r");
    let mut merged = fake_pull(10, "merged-work", &["docs/x.md"]);
    merged.state = "closed";
    fleet.gh_api(&gh_map(&[
        renamed,
        fake_pull(8, "docs-only", &["README.md"]),
        fork,
        merged,
    ]));
    let mut request = launch("KEN-L", fleet.state_dir().as_path());
    request["repo"] = json!("o/r");
    let out = fleet.op(&request);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-L");
    assert_eq!(lane["touched"], json!(["docs/x.md", "src/a.sh"]));
    let rebase = lane["rebase"].as_array().unwrap();
    assert_eq!(
        rebase.len(),
        1,
        "one holder, the open same-repository pull request on a candidate path: {rebase:?}"
    );
    assert_eq!(rebase[0]["holder"], "#7");
    assert_eq!(rebase[0]["branch"], "feature/x");
    assert_eq!(rebase[0]["paths"], json!(["docs/x.md", "src/a.sh"]));
    assert!(rebase[0]["at"].as_str().unwrap().ends_with('Z'));
    assert_eq!(
        fleet.gh_log(),
        [
            format!("api {PULLS_LIST}"),
            "api repos/o/r/pulls/7".to_owned(),
            "api repos/o/r/pulls/7/files?per_page=100&page=1".to_owned(),
            "api repos/o/r/pulls/8".to_owned(),
            "api repos/o/r/pulls/8/files?per_page=100&page=1".to_owned(),
            "api repos/o/r/pulls/9".to_owned(),
            "api repos/o/r/pulls/10".to_owned(),
        ],
        "the list once, each pull request by number, the files of the open same-repository ones alone"
    );
}

/// With the lanes of this fleet, a pull request a lane record names, by its
/// `pending_pr` number or by its head branch (the lane's item key), is
/// judged as that lane, once; a `done` record names none, so the open pull
/// request it left is a holder as a pull request; and the item's own pull
/// request, on its branch, is no holder against a path the running lane
/// adds.
#[test]
fn a_pull_request_a_lane_record_of_this_fleet_names_is_judged_once_as_that_lane() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-S", "ken-s");
    fleet.item("KEN-N", "`src/a.sh`, `docs/x.md`", 0, &[]);
    let mut ended_s = Owned::sleep();
    end(&mut ended_s);
    let mut ended_t = Owned::sleep();
    end(&mut ended_t);
    let mut s = holder("KEN-S", "running", Some(&ended_s), Some(&["src/a.sh"]));
    s["repo"] = json!("o/r");
    s["pending_pr"] = json!({"repo": "o/r", "pr": 7});
    let mut t = holder("KEN-T", "running", Some(&ended_t), Some(&["docs/x.md"]));
    t["repo"] = json!("o/r");
    let mut d = holder("KEN-D", "done", None, Some(&["src/a.sh"]));
    d["repo"] = json!("o/r");
    d["pending_pr"] = json!({"repo": "o/r", "pr": 11});
    let l = json!({
        "item": "KEN-L", "tracker": "linear", "repo": "o/r", "harness": "claude",
        "status": "running", "mail_root": "/w/l", "touched": ["src/l.sh"], "in_scope": [],
        "launch": {"pane": "%1", "server": 41020, "pid": 1, "start": "ticks:1"},
    });
    fleet.write_lanes(vec![s, t, d, l]);
    fleet.gh_api(&gh_map(&[
        fake_pull(7, "ken-s-work", &["src/a.sh"]),
        fake_pull(8, "KEN-T", &["docs/x.md"]),
        fake_pull(11, "ken-d-work", &["src/a.sh"]),
        fake_pull(12, "ken-l", &["src/new.sh"]),
    ]));
    let out = fleet.admit(&json!({"item": "KEN-N", "tracker": "linear", "repo": "o/r"}));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let rebase = answer["result"]["rebase"].as_array().unwrap();
    let holders: Vec<&str> = rebase
        .iter()
        .map(|o| o["holder"].as_str().unwrap())
        .collect();
    assert_eq!(
        holders,
        ["KEN-S", "KEN-T", "#11"],
        "each lane holder once, as its lane; the done record's pull request as a pull request: {rebase:?}"
    );
    assert_eq!(rebase[0]["branch"], "ken-s", "the lane's recorded branch");
    assert_eq!(rebase[0]["paths"], json!(["src/a.sh"]));
    assert!(
        rebase[1]["branch"].is_null(),
        "no item state names a branch"
    );
    assert_eq!(rebase[1]["paths"], json!(["docs/x.md"]));
    assert_eq!(rebase[2]["branch"], "ken-d-work", "the pull request's head");
    assert_eq!(rebase[2]["paths"], json!(["src/a.sh"]));

    let out = fleet.admit(&json!({"item": "KEN-L", "repo": "o/r", "paths": ["src/new.sh"]}));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(answer["result"]["recorded"], true);
    assert_eq!(
        answer["result"]["rebase"],
        json!([]),
        "the lane's own pull request holds nothing against it"
    );
    assert_eq!(
        fleet.lane("KEN-L")["touched"],
        json!(["src/l.sh", "src/new.sh"])
    );
}

/// The fleet's own repository, which a request names by its checkout alone
/// (`repo_dir`; its lane records name none): the repository is what `gh
/// repo view` answers in the checkout, else what its `origin` remote names
/// on github.com, and that repository's open pull requests hold their
/// files; a checkout naming no GitHub repository refuses
/// `holders-unreadable read=repo` with nothing written, never admitted past
/// unread holders.
#[test]
fn the_fleets_own_repository_is_read_from_its_checkout_by_gh_then_by_its_origin() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-M", "`src/m.sh`", 0, &[]);
    let repo = fleet.dir.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main", "."]);
    let mut map = gh_map(&[
        fake_pull(7, "feat-a", &["src/a.sh"]),
        fake_pull(8, "feat-m", &["src/m.sh"]),
    ]);
    fleet.gh_api(&map);
    let mut launch_l = launch("KEN-L", fleet.state_dir().as_path());
    launch_l["repo_dir"] = json!(repo.display().to_string());
    let mut launch_m = launch("KEN-M", fleet.state_dir().as_path());
    launch_m["repo_dir"] = json!(repo.display().to_string());
    let before = fleet.fleet();
    // No origin, and gh naming none: the repository cannot be named.
    let out = fleet.op(&launch_l);
    let (key, fields) = refusal(&out);
    assert_eq!(key, "holders-unreadable", "{}", stderr(&out));
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-L"),
            ("repo", &repo.display().to_string()),
            ("read", "repo"),
        ])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    // The origin names github.com, gh still naming none: #7 holds src/a.sh.
    git(
        &repo,
        &["remote", "add", "origin", "git@github.com:O/r.git"],
    );
    let out = fleet.op(&launch_l);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let rebase = fleet.lane("KEN-L")["rebase"].clone();
    assert_eq!(rebase.as_array().map(Vec::len), Some(1), "{rebase:?}");
    assert_eq!(rebase[0]["holder"], "#7");
    assert_eq!(rebase[0]["branch"], "feat-a");
    // gh answers, ahead of an origin naming no GitHub host: #8 holds
    // src/m.sh.
    map["repo view"] = json!({"text": "O/r\n"});
    fleet.gh_api(&map);
    git(
        &repo,
        &[
            "remote",
            "set-url",
            "origin",
            "https://gitlab.example/g/github.com/o/r",
        ],
    );
    let out = fleet.op(&launch_m);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let rebase = fleet.lane("KEN-M")["rebase"].clone();
    assert_eq!(rebase.as_array().map(Vec::len), Some(1), "{rebase:?}");
    assert_eq!(rebase[0]["holder"], "#8");
    assert_eq!(rebase[0]["branch"], "feat-m");
    let log = fleet.gh_log();
    let view = "repo view --json nameWithOwner -q .nameWithOwner";
    assert_eq!(
        log.iter().filter(|line| *line == view).count(),
        3,
        "gh is asked for the repository once per admission: {log:?}"
    );
    assert_eq!(
        log.iter()
            .filter(|line| **line == format!("api {PULLS_LIST}"))
            .count(),
        2,
        "the open list is read once per admission that named a repository: {log:?}"
    );
}

/// At the pull requests: a failed list, a member the documented shape does
/// not decode, a pull request answering nothing, a state outside the
/// documented pair, a files list short of the pull request's count and a
/// file with no name each refuse `holders-unreadable` naming the read, with
/// nothing written, although a lane holder stood ready to yield; an item
/// touching nothing reads no pull request.
#[test]
fn a_gh_failure_a_short_files_list_and_a_malformed_member_each_refuse_holders_unreadable_with_nothing_written()
 {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    let mut ended = Owned::sleep();
    end(&mut ended);
    let mut yielding = holder("KEN-S", "running", Some(&ended), Some(&["src/a.sh"]));
    yielding["repo"] = json!("o/r");
    fleet.write_lanes(vec![yielding]);
    let before = fleet.fleet();
    let mut short = fake_pull(7, "feat", &["src/a.sh", "src/b.sh"]);
    short.changed = Some(3);
    let mut weird = fake_pull(7, "feat", &["src/a.sh"]);
    weird.state = "weird";
    let mut nameless = fake_pull(7, "feat", &[]);
    nameless.files = vec![json!({"status": "modified"})];
    let mut unanswered = gh_map(&[fake_pull(7, "feat", &["src/a.sh"])]);
    unanswered
        .as_object_mut()
        .unwrap()
        .remove("repos/o/r/pulls/7");
    let rows: [(&str, Value, &str); 6] = [
        (
            "a failed list",
            json!({PULLS_LIST: {"exit": 1, "stderr": "gh: HTTP 500: boom"}}),
            "pulls",
        ),
        (
            "a number that is no number",
            json!({PULLS_LIST: {"body": [{"number": "7", "state": "open", "title": "a holder", "body": null, "merged_at": null, "merge_commit_sha": null, "author_association": "NONE", "head": {"sha": ZERO_SHA, "ref": "feat", "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null}]}}),
            "pulls",
        ),
        ("a pull request answering nothing", unanswered, "pull"),
        (
            "a state outside the documented pair",
            gh_map(&[weird]),
            "pull",
        ),
        ("a files list short of its count", gh_map(&[short]), "files"),
        ("a file with no name", gh_map(&[nameless]), "files"),
    ];
    let mut request = launch("KEN-L", fleet.state_dir().as_path());
    request["repo"] = json!("o/r");
    for (defect, map, read) in rows {
        fleet.gh_api(&map);
        let out = fleet.op(&request);
        let (key, fields) = refusal(&out);
        assert_eq!(key, "holders-unreadable", "{defect}: {}", stderr(&out));
        assert_eq!(
            fields,
            pairs(&[("item", "KEN-L"), ("repo", "o/r"), ("read", read)]),
            "{defect}"
        );
        assert!(
            stderr(&out).starts_with(&format!(
                "orch-runtime: holders-unreadable item=KEN-L repo=o/r read={read}"
            )),
            "{defect}: {}",
            stderr(&out)
        );
        assert_eq!(fleet.fleet(), before, "{defect}: a refusal writes nothing");
    }
    // An item whose body names no path has nothing to hold: no pull request
    // is read, and the failing map above is never reached.
    let reads = fleet.gh_log().len();
    fleet.plant("KEN-E", json!({"description": "Touches nothing."}));
    let mut request = launch("KEN-E", fleet.state_dir().as_path());
    request["repo"] = json!("o/r");
    let out = fleet.op(&request);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(
        fleet.gh_log().len(),
        reads,
        "an empty candidate set reads no pull request"
    );
}

/// The judgement runs inside the fleet launch lock, so two contenders on
/// one path are judged one after the other: the second reads the first's
/// committed record, as a live holder (its preparing row under its open
/// launch intent) or, once the first's launch ended, as a yielding one;
/// never does each admit the other's path unseen.
#[test]
fn two_contenders_on_one_path_are_judged_one_after_the_other() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-X", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-Y", "`src/a.sh`", 0, &[]);
    let x = fleet.request_file("x", &launch("KEN-X", fleet.state_dir().as_path()));
    let y = fleet.request_file("y", &launch("KEN-Y", fleet.state_dir().as_path()));
    let spawn = |request: &Path| {
        fleet
            .command(&["op", "--fleet", "--request", &request.display().to_string()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };
    let mut children = vec![spawn(&x), spawn(&y)];
    let outputs: Vec<Output> = children
        .drain(..)
        .map(|c| c.wait_with_output().unwrap())
        .collect();
    let replies: Vec<Value> = outputs.iter().map(reply).collect();
    let unseen = replies
        .iter()
        .filter(|r| {
            r["ok"] == true
                && r["result"]["persisted"]["report"]["lane"]["rebase"]
                    .as_array()
                    .is_none_or(Vec::is_empty)
        })
        .count();
    assert_eq!(
        unseen, 1,
        "exactly one contender saw no holder: {replies:#?}"
    );
    let first = replies
        .iter()
        .find(|r| {
            r["ok"] == true
                && r["result"]["persisted"]["report"]["lane"]["rebase"]
                    .as_array()
                    .is_none_or(Vec::is_empty)
        })
        .map(|r| r["result"]["persisted"]["report"]["lane"]["item"].clone())
        .unwrap();
    let other = replies
        .iter()
        .find(|r| r["result"]["persisted"]["report"]["lane"]["item"] != first)
        .unwrap();
    if other["ok"] == true {
        assert_eq!(
            other["result"]["persisted"]["report"]["lane"]["rebase"][0]["holder"], first,
            "the second read the first's ended record and owes it a rebase"
        );
    } else {
        assert_eq!(other["refusal"]["key"], "launch-overlap");
        let holder = other["refusal"]["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p[0] == "holder")
            .map(|p| p[1].clone())
            .unwrap();
        assert_eq!(holder, first, "the second read the first's preparing row");
    }
}

/// With the fleet's state in its own repository (`o/fleet`): a checkout
/// sharing its git directory, and a second clone whose origin names the
/// same repository in another case, are its own and admitted; a checkout of
/// `o/other` is refused `overseer-foreign` naming both before anything is
/// read or written, and admitted once `ORCH_CONNECTED_REPOS` lists it; a
/// directory in no checkout, and a checkout with no origin while the fleet
/// connects repositories, are refused `overseer-unjudged` with the cause. A
/// fleet in no checkout binds a launch under a translated git; a relaunch
/// over a stopped record is bound on its request's checkout.
#[test]
fn a_launch_from_a_checkout_the_fleet_neither_owns_nor_connects_is_refused() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    // A fleet in no checkout binds every launch as its own, under a
    // translated git too: `LANGUAGE` takes effect under any installed
    // locale but C, and `en_US.UTF-8` is the one a host most often has.
    let mut unbound = launch("KEN-0", &fleet.state_dir());
    unbound.as_object_mut().unwrap().remove("tracker");
    let out = fleet.op_with(&unbound, &[("LANGUAGE", "de"), ("LANG", "en_US.UTF-8")]);
    assert_eq!(
        reply(&out)["ok"],
        true,
        "a translated git: {}",
        stderr(&out)
    );
    git(&fleet.state_dir(), &["init", "-q", "-b", "main", "."]);
    git(
        &fleet.state_dir(),
        &["remote", "add", "origin", "git@github.com:o/fleet.git"],
    );
    let launch_from = |item: &str, root: &Path| {
        let mut request = launch(item, root);
        request.as_object_mut().unwrap().remove("tracker");
        request
    };
    let inside = fleet.state_dir().join("work");
    std::fs::create_dir_all(&inside).unwrap();
    let clone = fleet.checkout("clone", Some("https://github.com/O/Fleet"));
    for (item, root) in [("KEN-1", &inside), ("KEN-2", &clone)] {
        let out = fleet.op(&launch_from(item, root));
        assert_eq!(reply(&out)["ok"], true, "{item}: {}", stderr(&out));
    }
    let other = fleet.checkout("other", Some("git@github.com:o/other.git"));
    let before = fleet.fleet();
    let (key, fields) = refusal(&fleet.op(&launch_from("KEN-3", &other)));
    assert_eq!(key, "overseer-foreign");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-3"),
            ("repo", "o/other"),
            ("overseer", "o/fleet"),
            ("route", "connected-repos,peer-mail"),
        ])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    let bare = fleet.dir.path().join("bare");
    std::fs::create_dir_all(&bare).unwrap();
    let (key, fields) = refusal(&fleet.op(&launch_from("KEN-4", &bare)));
    assert_eq!(key, "overseer-unjudged");
    assert_eq!(
        fields,
        pairs(&[
            ("cause", "checkout-root"),
            ("path", bare.display().to_string().as_str())
        ])
    );
    let connected = [("ORCH_CONNECTED_REPOS", "O/Other")];
    let unnamed = fleet.checkout("unnamed", None);
    let (key, fields) = refusal(&fleet.op_with(&launch_from("KEN-5", &unnamed), &connected));
    assert_eq!(key, "overseer-unjudged");
    assert_eq!(
        fields,
        pairs(&[
            ("cause", "origin"),
            ("path", unnamed.display().to_string().as_str())
        ])
    );
    assert_eq!(fleet.fleet(), before, "an unjudged binding writes nothing");
    let out = fleet.op_with(&launch_from("KEN-3", &other), &connected);
    assert_eq!(reply(&out)["ok"], true, "connected: {}", stderr(&out));
    assert_eq!(
        fleet.lane("KEN-3")["mail_root"],
        other.display().to_string()
    );
    // KEN-1's launch failed (no server) and left its record stopped: a
    // relaunch is bound on its own checkout, as a first launch is.
    assert_eq!(fleet.lane("KEN-1")["status"], "stopped");
    let before = fleet.fleet();
    let (key, _) = refusal(&fleet.op(&launch_from("KEN-1", &other)));
    assert_eq!(
        key, "overseer-foreign",
        "a relaunch into another repository"
    );
    assert_eq!(fleet.fleet(), before, "a refused relaunch writes nothing");
    let out = fleet.op(&launch_from("KEN-1", &inside));
    assert_eq!(
        reply(&out)["ok"],
        true,
        "its own checkout: {}",
        stderr(&out)
    );
}

/// A `github` item whose repository is not the one its checkout's origin
/// names, and a `linear` item of another team than the fleet's
/// `LINEAR_TEAM` (read through the linear package's real team formatter
/// over a planted answer), are refused `item-foreign` before the item is
/// read; a team the tracker cannot answer for is refused
/// `item-repo-unresolved`; the item of the fleet's own team is read and
/// admitted; a relaunch over a stopped GitHub record naming another
/// repository refuses `item-foreign`, nothing written; a connected
/// checkout's item of another team than the fleet's is admitted.
#[test]
fn an_item_of_another_repository_or_team_than_its_checkouts_is_refused() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let checkout = fleet.checkout("repo", Some("https://github.com/o/r.git"));
    let github = json!({
        "op": "launch-lane",
        "item": "issue-7",
        "tracker": "github",
        "repo": "o/x",
        "harness": "claude",
        "mail_root": checkout.display().to_string(),
    });
    let before = fleet.fleet();
    let (key, fields) = refusal(&fleet.op(&github));
    assert_eq!(key, "item-foreign");
    assert_eq!(fields, pairs(&[("repo", "o/x"), ("route", "peer-mail")]));
    assert!(
        !fleet.gh_log().iter().any(|line| line.starts_with("issue ")),
        "a foreign item is not read: {:?}",
        fleet.gh_log()
    );
    let team = [("LINEAR_TEAM", "Kendex")];
    fleet.item("CC-1", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-1", "`src/a.sh`", 0, &[]);
    let (key, fields) = refusal(&fleet.op_with(&launch("KEN-1", &checkout), &team));
    assert_eq!(key, "item-repo-unresolved");
    assert_eq!(fields, pairs(&[("tracker", "linear"), ("team", "Kendex")]));
    std::fs::write(
        fleet.items_dir().join("team-Kendex.json"),
        serde_json::to_vec(&json!({"team": {"id": "uuid-team", "name": "Kendex", "key": "KEN"}}))
            .unwrap(),
    )
    .unwrap();
    let (key, fields) = refusal(&fleet.op_with(&launch("CC-1", &checkout), &team));
    assert_eq!(key, "item-foreign");
    assert_eq!(fields, pairs(&[("repo", "CC"), ("route", "peer-mail")]));
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    let reads = fleet.linear_log();
    assert!(
        !reads.iter().any(|line| line.starts_with("issues get CC-1")),
        "a foreign item is not read: {reads:?}"
    );
    let out = fleet.op_with(&launch("KEN-1", &checkout), &team);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert!(
        fleet
            .linear_log()
            .iter()
            .any(|line| line == "issues get KEN-1 --with-bundle --format=safe"),
        "the fleet's own team's item is read"
    );
    // A relaunch over the stopped record of a GitHub item admitted from its
    // checkout, naming another repository, is the foreign item it names.
    std::fs::write(
        fleet.items_dir().join("12.json"),
        br#"{"body": "Some text.\n", "labels": []}"#,
    )
    .unwrap();
    let mut github = github.clone();
    github["item"] = json!("issue-12");
    github["repo"] = json!("o/r");
    assert_eq!(reply(&fleet.op(&github))["ok"], true);
    assert_eq!(fleet.lane("issue-12")["status"], "stopped");
    let before = fleet.fleet();
    github["repo"] = json!("o/foreign");
    let (key, fields) = refusal(&fleet.op(&github));
    assert_eq!(key, "item-foreign", "a relaunch naming another repository");
    assert_eq!(
        fields,
        pairs(&[("repo", "o/foreign"), ("route", "peer-mail")])
    );
    assert_eq!(fleet.fleet(), before, "a refused relaunch writes nothing");
    // A connected checkout's item is judged on no team of the fleet's: its
    // team is that checkout's setting.
    git(&fleet.state_dir(), &["init", "-q", "-b", "main", "."]);
    git(
        &fleet.state_dir(),
        &["remote", "add", "origin", "https://github.com/o/fleet.git"],
    );
    let connected = fleet.checkout("other", Some("https://github.com/o/other.git"));
    fleet.item("CC-3", "`src/c.sh`", 0, &[]);
    let out = fleet.op_with(
        &launch("CC-3", &connected),
        &[
            ("LINEAR_TEAM", "Kendex"),
            ("ORCH_CONNECTED_REPOS", "o/other"),
        ],
    );
    assert_eq!(
        reply(&out)["ok"],
        true,
        "the connected checkout's item: {}",
        stderr(&out)
    );
}

/// A review lane keyed on a pull request's number, the item `issue-N` of a
/// `github` tracker: `gh issue view N` resolves the number through GitHub's
/// `issueOrPullRequest` lookup (gh 2.103.3's own query; the client refuses a
/// pull request only for `issue delete`, `transfer` and artifacts), so it
/// answers the pull request's body and labels, the shape an issue's answer
/// has. Through the real `launch-lane` over that answer: the lane is
/// admitted after one `gh issue view` read, its touched set the body's
/// Location; the pull request numbered as the item is the lane's own, never
/// its holder, and another open pull request on the path is.
#[test]
fn a_review_lane_keyed_on_a_pull_request_number_is_admitted_on_its_body() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    let checkout = fleet.checkout("repo", Some("https://github.com/o/r.git"));
    std::fs::write(
        fleet.items_dir().join("12.json"),
        br#"{"body": "Review the change.\n**Location**: `src/a.rs`\n", "labels": [{"name": "review"}]}"#,
    )
    .unwrap();
    fleet.gh_api(&gh_map(&[
        fake_pull(12, "feature/work", &["src/a.rs"]),
        fake_pull(13, "feature/other", &["src/a.rs"]),
    ]));
    // One `gh` for both reads: the item through the issue fixture, the pull
    // requests through the API fixture.
    let bin = fleet.dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let dispatch = bin.join("gh");
    write_executable(
        &dispatch,
        format!(
            "#!/bin/bash\nif [ \"${{1:-}}\" = issue ]; then exec {} \"$@\"; fi\nexec {} \"$@\"\n",
            fixtures().join("gh-issue/gh").display(),
            fixtures().join("gh/gh").display()
        ),
    );
    let path = support::tool_path(&[bin.as_path()]);
    let out = fleet.op_with(
        &json!({
            "op": "launch-lane",
            "item": "issue-12",
            "tracker": "github",
            "repo": "o/r",
            "harness": "claude",
            "mail_root": checkout.display().to_string(),
        }),
        &[("PATH", path.as_str())],
    );
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("issue-12");
    assert_eq!(lane["touched"], json!(["src/a.rs"]));
    let holders: Vec<&str> = lane["rebase"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|row| row["holder"].as_str())
        .collect();
    assert_eq!(holders, ["#13"], "{lane}");
    let reads: Vec<String> = fleet
        .gh_log()
        .into_iter()
        .filter(|line| line.starts_with("issue "))
        .collect();
    assert_eq!(reads, ["issue view 12 --repo o/r --json body,labels"]);
}
