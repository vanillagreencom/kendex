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
use std::process::{Command, Output};
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
        // The project the binary runs in installs the github package, whose
        // resolver names a checkout's repository.
        let skills = fleet.state_dir().join(".agents/skills");
        std::fs::create_dir_all(&skills).unwrap();
        std::os::unix::fs::symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../github"),
            skills.join("github"),
        )
        .unwrap();
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
            .env("AGENT_RUNTIME_TMUX_SESSION", "fleet")
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
            .env("LANE_MAIL_CLI", lane_mail())
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

    /// An item state for `item` naming `branch`, the branch a holder's own
    /// pull request is named by.
    fn init_item(&self, item: &str, branch: &str) {
        let out = self.run(&["state", "init", "--item", item, "--branch", branch]);
        assert!(out.status.success(), "init {item}: {}", stderr(&out));
    }

    /// An open `review` stage in the current session of `item`, whose item
    /// state stands in the fleet's state directory: a holder in its review.
    fn review(&self, item: &str) {
        stage(&self.state_dir(), item, "review");
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
        self.write_lanes_and_intents(lanes, Vec::new());
    }

    fn write_lanes_and_intents(&self, lanes: Vec<Value>, intents: Vec<Value>) {
        let mut fleet = self.fleet();
        fleet["lanes"] = Value::Array(lanes);
        fleet["intents"] = Value::Array(intents);
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
/// set, `None` for a record the admission reads from its item. The default
/// harness is unconfined so the other admission gates can be tested alone.
fn holder(item: &str, status: &str, process: Option<&Owned>, touched: Option<&[&str]>) -> Value {
    let launch = match process {
        Some(p) => json!({"pane": "%7", "server": 41020, "pid": p.pid(), "start": p.start()}),
        None => Value::Null,
    };
    let mut record = json!({
        "item": item,
        "tracker": "linear",
        "harness": "copilot",
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

/// The epoch second of a [`holder`]'s `session_since`, plus one minute: a
/// stage that opened in the holder's current session.
const IN_SESSION: u64 = 1_769_698_860;

/// An open stage of `kind` in the current session of `item`, written into
/// its item state under `dir`, over a state that stands there or a new one.
fn stage(dir: &Path, item: &str, kind: &str) {
    stages(
        dir,
        item,
        json!([{"kind": kind, "round_id": "r1", "start": IN_SESSION}]),
    );
}

/// The stages `list` as the item state of `item` under `dir` records them,
/// over a state that stands there or a new one.
fn stages(dir: &Path, item: &str, list: Value) {
    let path = support::item_record(dir, item);
    let mut doc: Value = std::fs::read_to_string(&path)
        .map(|text| serde_json::from_str(&text).unwrap())
        .unwrap_or_else(|_| json!({}));
    doc["stages"] = list;
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
}

/// The directives `item`'s lane inbox under the checkout `root` holds, one
/// envelope each.
fn inbox(root: &Path, item: &str) -> Vec<Value> {
    std::fs::read_to_string(root.join(format!("tmp/lane-mail/{item}/to-lane.jsonl")))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// The report of a launch reply: a join's, which runs no effect, or a
/// persisted launch's.
fn joined_or_launched(answer: &Value) -> &Value {
    match &answer["result"]["persisted"] {
        Value::Null => &answer["result"]["report"],
        persisted => &persisted["report"],
    }
}

fn launch(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "tracker": "linear",
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
        "model": "claude-fable-5-1",
        "class": CLASS,
        "class_reason": CLASS_REASON,
    })
}

#[test]
fn launch_readiness_probes_only_the_requests_local_confined_harness() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let bin = fleet.dir.path().join("refusing");
    std::fs::create_dir_all(&bin).unwrap();
    write_executable(
        &bin.join("bwrap"),
        "#!/bin/sh\necho 'uid map refused' >&2\nexit 1\n",
    );
    let path = tool_path(&[&bin]);
    let before = std::fs::read(fleet.fleet_path()).unwrap();
    for (harness, host, permission, expected) in [
        ("claude", None, "--dangerously-skip-permissions", "unready"),
        ("copilot", None, "--allow-all", "launch-class-missing"),
        (
            "claude",
            Some("/fixture/provider"),
            "--dangerously-skip-permissions",
            "launch-class-missing",
        ),
        (
            "claude",
            Some("claude-cloud"),
            "--dangerously-skip-permissions",
            "launch-class-missing",
        ),
    ] {
        let mut request = launch("KEN-N", &fleet.state_dir());
        request["harness"] = json!(harness);
        request["permission"] = json!(permission);
        request["host"] = json!(host);
        request.as_object_mut().unwrap().remove("class");
        request.as_object_mut().unwrap().remove("class_reason");
        let (key, fields) = refusal(&fleet.op_with(&request, &[("PATH", &path)]));
        assert_eq!(key, expected, "harness={harness} host={host:?}: {fields:?}");
        if expected == "unready" {
            assert!(
                fields.contains(&("cause".to_owned(), "userns-off".to_owned())),
                "{fields:?}"
            );
        }
        assert_eq!(std::fs::read(fleet.fleet_path()).unwrap(), before);
    }
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
    /// The body the object reports; `None` plants GitHub's null.
    body: Option<&'static str>,
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
        body: None,
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
                "body": p.body,
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

/// At the holder: a holder in its review whose recorded harness is a live
/// process blocks the launch with its id and nothing is written; the same
/// holder ended, its record still reading `running`, yields: the launch is
/// admitted, its record carries the touched set and no order, and the
/// holder's record keeps every field.
#[test]
fn a_live_holder_in_review_blocks_the_launch_and_a_gone_one_yields() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-H", "ken-h");
    fleet.review("KEN-H");
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

    // Under direct delivery the publication takes the order: the holder in
    // its review lets a first launch on its path pass, no order and no join
    // written; a delivery word outside the two refuses the launch.
    fleet.item("KEN-D", "`src/a.sh`", 0, &[]);
    let direct = |word: &str| {
        fleet.op_with(
            &launch("KEN-D", fleet.state_dir().as_path()),
            &[("ORCH_DELIVERY", word)],
        )
    };
    let (key, fields) = refusal(&direct("push_base"));
    assert_eq!(key, "setting-invalid");
    assert_eq!(
        fields,
        pairs(&[("key", "ORCH_DELIVERY"), ("value", "push_base")])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    let out = direct("push-base");
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-D");
    assert_eq!(lane["touched"], json!(["src/a.sh"]));
    assert_eq!(lane.get("rebase"), None, "no order is recorded");
    assert_eq!(
        fleet.lane("KEN-H"),
        before["lanes"][0],
        "the holder in its review is not joined"
    );

    end(&mut harness);
    let out = fleet.op(&launch("KEN-L", fleet.state_dir().as_path()));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-L");
    assert_eq!(lane["touched"], json!(["docs/x.md", "src/a.sh"]));
    assert_eq!(lane["in_scope"], json!([]));
    assert_eq!(lane.get("rebase"), None, "no order is recorded");
    assert_eq!(
        answer["result"]["persisted"]["report"]["lane"]["touched"], lane["touched"],
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
/// sets; a live holder in its review of a path the item now names refuses
/// `launch-overlap`, and with the holder gone, an open pull request on the
/// path beside it, the launch is admitted, its touched set the item's.
#[test]
fn a_launch_over_a_done_record_is_judged_as_a_first_launch() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.init_item("KEN-H", "ken-h");
    fleet.review("KEN-H");
    fleet.item("KEN-L", "`src/a.sh`, `docs/x.md`", 0, &[]);
    let mut harness = Owned::sleep();
    let mut live = holder("KEN-H", "running", Some(&harness), Some(&["src/a.sh"]));
    live["repo"] = json!("o/r");
    let mut done = holder("KEN-L", "done", None, Some(&["old/path.rs"]));
    done["repo"] = json!("o/r");
    fleet.write_lanes(vec![live, done]);
    fleet.gh_api(&gh_map(&[fake_pull(7, "ken-h", &["src/a.sh"])]));
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
    assert_eq!(fleet.lane_count(), 2, "the record's slot is taken");
    assert_eq!(fleet.lane("KEN-H"), before["lanes"][0]);
}

/// A stopped record holds nothing, so a running lane is admitted a path it
/// recorded; the stopped lane's relaunch then meets that holder, as a
/// running lane's added path does, with its record's set, or its item's
/// Location paths where the record holds none, and its record's scope, in
/// the repository the request names, else its record's. It is refused
/// `launch-overlap`, never joined, nothing written: under
/// `ORCH_DELIVERY=push-base` before the holder's review, and under `pr`
/// with the holder in its review. Under `push-base` with the holder in its
/// review it is relaunched, the publication taking the order, over its kept
/// sets. Only the Location row plants an item, so the others read none.
#[test]
fn a_relaunch_meets_a_live_holder_of_its_recorded_path_and_is_never_joined() {
    let set: &[&str] = &["docs/x.md", "src/a.sh"];
    // The row, the record's repository, the one the relaunch names, and
    // the record's set.
    type Row<'a> = (&'a str, &'a str, Option<&'a str>, Option<&'a [&'a str]>);
    let rows: [Row; 3] = [
        ("its recorded set", "o/r", None, Some(set)),
        ("its item's Location paths", "o/r", None, None),
        (
            "a record of another repository relaunched into the holder's",
            "o/a",
            Some("o/r"),
            Some(set),
        ),
    ];
    for (row, record_repo, repo, touched) in rows {
        let fleet = Fleet::new();
        fleet.init_fleet();
        fleet.init_item("KEN-H", "ken-h");
        if touched.is_none() {
            fleet.item("KEN-R", "`docs/x.md`, `src/a.sh`", 0, &[]);
        }
        let harness = Owned::sleep();
        let mut stopped = holder("KEN-R", "stopped", None, touched);
        stopped["in_scope"] = json!(["docs/"]);
        stopped["repo"] = json!(record_repo);
        let mut holding = holder("KEN-H", "running", Some(&harness), Some(&["docs/x.md"]));
        holding["repo"] = json!("o/r");
        fleet.write_lanes(vec![stopped, holding]);
        let out = fleet.admit(&json!({"item": "KEN-H", "paths": ["src/a.sh"]}));
        assert_eq!(
            reply(&out)["ok"],
            true,
            "{row}: a stopped record yields: {}",
            stderr(&out)
        );
        let before = fleet.fleet();
        let mut request = launch("KEN-R", fleet.state_dir().as_path());
        if let Some(repo) = repo {
            request["repo"] = json!(repo);
        }
        let relaunch = |delivery: &str| fleet.op_with(&request, &[("ORCH_DELIVERY", delivery)]);

        let refused = |delivery: &str, stage: &str| {
            let out = relaunch(delivery);
            let (key, fields) = refusal(&out);
            assert_eq!(key, "launch-overlap", "{row}, {stage}: {}", stderr(&out));
            assert_eq!(
                fields,
                pairs(&[("item", "KEN-R"), ("file", "src/a.sh"), ("holder", "KEN-H")]),
                "{row}, {stage}: the record's scope leaves docs/x.md out"
            );
            assert_eq!(
                fleet.fleet(),
                before,
                "{row}, {stage}: nothing written, no join"
            );
        };
        refused("push-base", "push-base before the holder's review");
        fleet.review("KEN-H");
        refused("pr", "pr with the holder in its review");
        assert!(
            live(harness.pid()),
            "{row}: a refused relaunch signals nothing"
        );

        let out = relaunch("push-base");
        assert_eq!(reply(&out)["ok"], true, "{row}: {}", stderr(&out));
        let lane = fleet.lane("KEN-R");
        assert_eq!(
            lane["touched"],
            touched.map_or(Value::Null, |paths| json!(paths)),
            "{row}: the relaunch records no set"
        );
        assert_eq!(lane["in_scope"], json!(["docs/"]));
        // No fleet server exists here, so the relaunch fails before any window.
        assert_eq!(lane["status"], "stopped");
        assert_eq!(
            fleet.lane("KEN-H"),
            before["lanes"][1],
            "{row}: the holder is not joined"
        );
    }
}

/// A stopped record no judgement wrote, whose item names no Location path,
/// holds no set its relaunch could meet a holder with: the relaunch is
/// refused `touched-unreadable read=location` beside a live holder, nothing
/// written.
#[test]
fn a_relaunch_over_no_recorded_set_and_no_location_is_refused() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.plant("KEN-R", json!({}));
    let harness = Owned::sleep();
    fleet.write_lanes(vec![
        holder("KEN-R", "stopped", None, None),
        holder("KEN-H", "running", Some(&harness), Some(&["src/a.sh"])),
    ]);
    let before = fleet.fleet();

    let out = fleet.op(&launch("KEN-R", fleet.state_dir().as_path()));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "touched-unreadable", "{}", stderr(&out));
    assert_eq!(fields, pairs(&[("item", "KEN-R"), ("read", "location")]));
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
}

/// A holder that yields holds nothing, so its set is never read: a stopped
/// record no judgement wrote, whose item cannot be read, refuses neither a
/// relaunch nor a first launch of a path its item might name.
#[test]
fn a_yielding_holder_whose_set_cannot_be_read_blocks_no_launch() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-F", "`src/a.sh`", 0, &[]);
    // KEN-S's item is planted nowhere, so its read fails.
    fleet.write_lanes(vec![
        holder("KEN-S", "stopped", None, None),
        holder("KEN-R", "stopped", None, Some(&["src/a.sh"])),
    ]);
    for item in ["KEN-R", "KEN-F"] {
        let out = fleet.op(&launch(item, fleet.state_dir().as_path()));
        assert_eq!(reply(&out)["ok"], true, "{item}: {}", stderr(&out));
        // No fleet server exists here, so the launch fails before any window.
        assert_eq!(fleet.lane(item)["status"], "stopped", "{item}");
    }
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
    let read = |item: &str| format!("issues get {item} --format=safe");
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
        "a recorded lane's relaunch keeps the item judgement of its admission"
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
    fleet.init_item("KEN-H", "ken-h");
    fleet.review("KEN-H");
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
}

/// An item naming its `skills/` files "with their `.agents/skills`
/// renders" records each file and that file's render, never the bare render
/// directory. Beside the first as a live holder in its review, a second on
/// disjoint files is admitted, and a third on the first's render meets it.
#[test]
fn items_naming_their_renders_hold_each_files_render_and_disjoint_ones_both_launch() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item(
        "KEN-A",
        "`skills/a/SKILL.md` (Tests) and its `.agents/skills` render.",
        0,
        &[],
    );
    fleet.item(
        "KEN-B",
        "`skills/b/SKILL.md`, `skills/b/x.md`, with their `.agents/skills` renders.",
        0,
        &[],
    );
    fleet.item("KEN-C", "`.agents/skills/a/SKILL.md`", 0, &[]);

    let out = fleet.op(&launch("KEN-A", fleet.state_dir().as_path()));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let held = [".agents/skills/a/SKILL.md", "skills/a/SKILL.md"];
    assert_eq!(fleet.lane("KEN-A")["touched"], json!(held));

    fleet.init_item("KEN-A", "ken-a");
    fleet.review("KEN-A");
    let mut harness = Owned::sleep();
    fleet.write_lanes(vec![holder(
        "KEN-A",
        "running",
        Some(&harness),
        Some(&held),
    )]);
    let out = fleet.op(&launch("KEN-B", fleet.state_dir().as_path()));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(
        fleet.lane("KEN-B")["touched"],
        json!([
            ".agents/skills/b/SKILL.md",
            ".agents/skills/b/x.md",
            "skills/b/SKILL.md",
            "skills/b/x.md"
        ])
    );

    let (key, fields) = refusal(&fleet.op(&launch("KEN-C", fleet.state_dir().as_path())));
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-C"),
            ("file", ".agents/skills/a/SKILL.md"),
            ("holder", "KEN-A")
        ])
    );
    end(&mut harness);
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
                "model": "claude-fable-5-1",
                "class": CLASS,
                "class_reason": CLASS_REASON,
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
/// `admit` and widens its record's touched set past a stopped holder, which
/// yields, the standing scope kept; a live holder refuses it with its id
/// and the record stays as it was; a done lane refuses.
#[test]
fn a_running_lanes_added_path_widens_its_record_or_is_refused_by_a_live_holder() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let live_holder = Owned::sleep();
    let mut ended = Owned::sleep();
    end(&mut ended);
    fleet.write_lanes(vec![
        json!({
            "item": "KEN-L", "tracker": "linear", "harness": "claude", "status": "running",
            "mail_root": "/w/l", "touched": ["src/a.sh"], "in_scope": ["docs/"],
            "launch": {"pane": "%1", "server": 41020, "pid": 1, "start": "ticks:1"},
        }),
        json!({
            "item": "KEN-D", "tracker": "linear", "harness": "claude", "status": "done",
            "mail_root": "/w/d", "touched": [],
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
    assert_eq!(answer["result"]["in_scope"], json!(["docs/"]));
    let lane = fleet.lane("KEN-L");
    assert_eq!(
        lane["touched"],
        json!(["src/a.sh", "src/b.sh", "src/new.sh"])
    );
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
    assert_eq!(fleet.fleet(), before);

    let out = fleet.admit(&json!({"item": "KEN-D", "paths": ["src/z.sh"]}));
    assert_eq!(refusal(&out).0, "lane-done");
    assert_eq!(fleet.fleet(), before);
}

/// A folder entry without its `/`, read in the checkout on this machine
/// that holds the lane's files, a hosted lane's recorded `checkout`: a
/// launch's Location path and a running lane's added path that name a
/// folder there record it with the `/`, so another lane's admit of a file
/// under it meets the live lane and is refused `launch-overlap`; a path
/// naming nothing there, or a symlink to a folder, is recorded as written.
/// A record already holding the folder without its `/`, or holding no set
/// while its item's Location names the folder, holds the files under it as
/// that folder, and a stopped one's relaunch meets a live holder of a file
/// under it. An in-scope folder without its `/` covers the files under it.
/// The tier classifies the spelling the holders meet: a micro brief over a
/// Location naming the workflows folder is refused `tier-narrower`.
#[test]
fn an_admitted_folder_entry_without_its_slash_holds_the_files_under_it() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    // Outside the binary's working directory, so only a read in the lane's
    // own checkout finds the folder.
    let root = fleet.checkout("repo", None);
    std::fs::create_dir_all(root.join("src/sub")).unwrap();
    std::fs::create_dir_all(root.join(".github/workflows")).unwrap();
    std::fs::write(root.join("src/sub/a.rs"), "\n").unwrap();
    std::os::unix::fs::symlink("sub", root.join("src/link")).unwrap();
    let harness = Owned::sleep();
    let checkout = root.display().to_string();
    let other = json!({
        "item": "KEN-O", "tracker": "linear", "harness": "claude", "status": "running",
        "mail_root": checkout, "touched": ["docs/o.md"],
        "launch": {"pane": "%2", "server": 41020, "pid": 1, "start": "ticks:1"},
    });
    // The holder `lane` live under this test's harness, beside KEN-O.
    let live_beside_other = |mut lane: Value| {
        lane["status"] = json!("running");
        lane["launch"] =
            json!({"pane": "%7", "server": 41020, "pid": harness.pid(), "start": harness.start()});
        fleet.write_lanes(vec![lane, other.clone()]);
    };
    // A lane on a provider: its root is the host's path, and the checkout
    // here is the one its launch ran from.
    let hosted = |mut lane: Value| {
        lane["host"] = json!("/w/provider");
        lane["kind"] = json!("ssh");
        lane["mail_root"] = json!("/w/on-host");
        lane["checkout"] = json!(checkout);
        lane
    };
    let refused_under = |holder: &str| {
        let before = fleet.fleet();
        let out = fleet.admit(&json!({"item": "KEN-O", "paths": ["src/sub/a.rs"]}));
        let (key, fields) = refusal(&out);
        assert_eq!(key, "launch-overlap", "{holder}: {}", stderr(&out));
        assert_eq!(
            fields,
            pairs(&[
                ("item", "KEN-O"),
                ("file", "src/sub/a.rs"),
                ("holder", holder)
            ])
        );
        assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    };

    fleet.item("KEN-W", "`.github/workflows`", 0, &[]);
    let brief = fleet.dir.path().join("brief.md");
    std::fs::write(
        &brief,
        "tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=- paths=1\nAnswer on the item.\n",
    )
    .unwrap();
    let mut request = launch("KEN-W", &root);
    request["brief_file"] = json!(brief.display().to_string());
    let before = fleet.fleet();
    let (key, fields) = refusal(&fleet.op(&request));
    assert_eq!(key, "tier-narrower", "{fields:?}");
    assert!(
        fields.contains(&("judged".to_owned(), "standard".to_owned())),
        "{fields:?}"
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");

    fleet.item("KEN-F", "`src/sub`, `src/none`, `src/link`", 0, &[]);
    let out = fleet.op(&launch("KEN-F", &root));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-F");
    assert_eq!(lane["touched"], json!(["src/link", "src/none", "src/sub/"]));
    live_beside_other(lane);
    refused_under("KEN-F");

    for (item, on_host) in [("KEN-A", false), ("KEN-HA", true)] {
        let mut lane = holder(item, "running", None, Some(&["docs/x.md"]));
        lane["mail_root"] = json!(checkout);
        if on_host {
            lane = hosted(lane);
        }
        live_beside_other(lane);
        let out = fleet.admit(&json!({"item": item, "paths": ["src/sub", "src/gone"]}));
        assert_eq!(reply(&out)["ok"], true, "{item}: {}", stderr(&out));
        assert_eq!(
            fleet.lane(item)["touched"],
            json!(["docs/x.md", "src/gone", "src/sub/"]),
            "{item}"
        );
        refused_under(item);
    }

    let mut lane = holder("KEN-R", "running", None, Some(&["src/sub"]));
    lane["mail_root"] = json!(checkout);
    live_beside_other(lane);
    refused_under("KEN-R");
    live_beside_other(hosted(holder(
        "KEN-HR",
        "running",
        None,
        Some(&["src/sub"]),
    )));
    refused_under("KEN-HR");

    fleet.item("KEN-S", "`src/sub`", 0, &[]);
    let mut lane = holder("KEN-S", "running", None, None);
    lane["mail_root"] = json!(checkout);
    live_beside_other(lane);
    refused_under("KEN-S");

    let mut lane = holder("KEN-H", "running", None, Some(&["src/sub/"]));
    lane["mail_root"] = json!(checkout);
    live_beside_other(lane);
    let out = fleet.admit(&json!({
        "item": "KEN-O", "paths": ["src/sub/a.rs"], "in_scope": ["src/sub"],
    }));
    assert_eq!(reply(&out)["ok"], true, "in scope: {}", stderr(&out));

    let mut stopped = holder("KEN-RS", "stopped", None, Some(&["src/sub"]));
    stopped["mail_root"] = json!(checkout);
    let mut live = holder("KEN-H", "running", Some(&harness), Some(&["src/sub/a.rs"]));
    live["mail_root"] = json!(checkout);
    fleet.write_lanes(vec![stopped, live]);
    let before = fleet.fleet();
    let out = fleet.op_with(&launch("KEN-RS", &root), &[("ORCH_DELIVERY", "pr")]);
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap", "relaunch: {}", stderr(&out));
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-RS"),
            ("file", "src/sub/a.rs"),
            ("holder", "KEN-H")
        ])
    );
    assert_eq!(fleet.fleet(), before, "a refused relaunch writes nothing");
}

/// A running lane's added path is judged in its own lane's repository, so
/// the documented request, item and paths alone, meets a live holder of
/// the same named repository and is refused with its id; a request naming
/// another repository than the lane's is refused by name; one naming the
/// lane's own, case apart, widens the record.
#[test]
fn a_running_lanes_added_path_is_judged_in_its_lanes_repository() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let (a_harness, b_harness) = (Owned::sleep(), Owned::sleep());
    let named = |item: &str, harness: &Owned, path: &str| {
        let mut lane = holder(item, "running", Some(harness), Some(&[path]));
        lane["repo"] = json!("o/r");
        lane
    };
    fleet.write_lanes(vec![
        named("KEN-A", &a_harness, "src/a.sh"),
        named("KEN-B", &b_harness, "src/b.sh"),
    ]);
    let before = fleet.fleet();

    let out = fleet.admit(&json!({"item": "KEN-B", "paths": ["src/a.sh"]}));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap", "{}", stderr(&out));
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-B"), ("file", "src/a.sh"), ("holder", "KEN-A")])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");

    let out = fleet.admit(&json!({"item": "KEN-B", "repo": "o/other", "paths": ["src/n.sh"]}));
    let (key, fields) = refusal(&out);
    assert_eq!(key, "lane-repo-conflict", "{}", stderr(&out));
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-B"), ("repo", "o/other"), ("lane_repo", "o/r")])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");

    let out = fleet.admit(&json!({"item": "KEN-B", "repo": "O/R", "paths": ["src/n.sh"]}));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(
        fleet.lane("KEN-B")["touched"],
        json!(["src/b.sh", "src/n.sh"])
    );
}

/// A live holder before its review stage that owns an open pull request,
/// one on its head branch (its item key), is in its review: the candidate
/// sharing its path is refused `launch-overlap` with nothing written and
/// the holder told nothing; an unrelated path, a fork's pull request or
/// a closed one leaves the candidate free to join the holder.
#[test]
fn a_holder_owning_an_open_pull_request_is_in_its_review_and_never_joined() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-N", "`docs/x.md`", 0, &[]);
    let root = fleet.checkout("t", None);
    let harness = Owned::sleep();
    let mut t = holder("KEN-T", "running", Some(&harness), Some(&["docs/x.md"]));
    t["repo"] = json!("o/r");
    t["mail_root"] = json!(root.display().to_string());
    fleet.write_lanes(vec![t]);
    let mut request = launch("KEN-N", &fleet.checkout("n", None));
    request["repo"] = json!("o/r");
    fleet.gh_api(&gh_map(&[fake_pull(8, "KEN-T", &["docs/x.md"])]));
    let before = fleet.fleet();

    let (key, fields) = refusal(&fleet.op(&request));
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-N"),
            ("file", "docs/x.md"),
            ("holder", "KEN-T")
        ])
    );
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    assert!(inbox(&root, "KEN-T").is_empty());
    let (key, _) = refusal(&fleet.op_with(&request, &[("ORCH_DELIVERY", "push-base")]));
    assert_eq!(key, "launch-overlap", "its pull request keeps the order");
    assert_eq!(fleet.fleet(), before);

    let mut fork = fake_pull(9, "KEN-T", &["docs/x.md"]);
    fork.head_repo = Some("fork/r");
    let mut merged = fake_pull(10, "KEN-T", &["docs/x.md"]);
    merged.state = "closed";
    fleet.gh_api(&gh_map(&[
        fake_pull(8, "other-work", &["docs/y.md"]),
        fork,
        merged,
    ]));
    let out = fleet.op(&request);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(joined_or_launched(&answer)["holder"], "KEN-T");
    assert_eq!(inbox(&root, "KEN-T").len(), 1);
}

#[test]
fn an_unowned_open_pull_request_holds_paths_against_a_first_launch() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-N", "`docs/x.md`", 0, &[]);
    fleet.gh_api(&gh_map(&[fake_pull(8, "other-work", &["docs/x.md"])]));
    let mut request = launch("KEN-N", &fleet.checkout("n", None));
    request["repo"] = json!("o/r");
    let before = std::fs::read(fleet.fleet_path()).unwrap();

    let out = fleet.op(&request);
    let (key, fields) = refusal(&out);
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-N"), ("file", "docs/x.md"), ("holder", "#8")])
    );
    assert_eq!(std::fs::read(fleet.fleet_path()).unwrap(), before);

    // A body line `Closes KEN-N` names the candidate's own pull request on a
    // branch past its key; a mention or a `Closes` of a longer key does not.
    // The admitted row comes last, since its launch records a lane.
    let rows: [(&str, bool); 3] = [
        ("Follows KEN-N.\n", false),
        ("Closes KEN-NX\n", false),
        ("Context.\n- Closes KEN-N\n", true),
    ];
    for (body, own) in rows {
        let mut pull = fake_pull(8, "ken-n-suffix", &["docs/x.md"]);
        pull.body = Some(body);
        fleet.gh_api(&gh_map(&[pull]));
        let out = fleet.op(&request);
        if own {
            assert_eq!(reply(&out)["ok"], true, "{body:?}: {}", stderr(&out));
        } else {
            assert_eq!(refusal(&out).0, "launch-overlap", "{body:?}");
        }
    }
}

/// The fleet's own repository, which a request names by its checkout alone
/// (`repo_dir`; its lane records name none): the pull requests a join reads
/// are that repository's, what `gh repo view` answers in the checkout, else
/// what its `origin` remote names on github.com; a checkout naming no GitHub
/// repository refuses `holders-unreadable read=repo` with nothing written,
/// never joined past unread pull requests.
#[test]
fn the_fleets_own_repository_is_read_from_its_checkout_by_gh_then_by_its_origin() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-M", "`src/m.sh`", 0, &[]);
    let root = fleet.checkout("h", None);
    let harness = Owned::sleep();
    let mut held = holder(
        "KEN-H",
        "running",
        Some(&harness),
        Some(&["src/a.sh", "src/m.sh"]),
    );
    held["mail_root"] = json!(root.display().to_string());
    fleet.write_lanes(vec![held]);
    let repo = fleet.dir.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main", "."]);
    let mut map = gh_map(&[fake_pull(7, "feat-a", &["src/z.sh"])]);
    fleet.gh_api(&map);
    let mut launch_l = launch("KEN-L", &fleet.checkout("l", None));
    launch_l["repo_dir"] = json!(repo.display().to_string());
    let mut launch_m = launch("KEN-M", &fleet.checkout("m", None));
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
    // The origin names github.com, gh still naming none: `o/r`'s pull
    // requests are read and none is the holder's. A repository the
    // environment names for other commands is not the checkout's.
    git(
        &repo,
        &["remote", "add", "origin", "git@github.com:O/r.git"],
    );
    let out = fleet.op_with(
        &launch_l,
        &[("GH_REPO", "o/other"), ("GITHUB_REPOSITORY", "o/other")],
    );
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(joined_or_launched(&answer)["op"], "joined");
    // gh answers, ahead of an origin naming no GitHub host.
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
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(joined_or_launched(&answer)["op"], "joined");
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

/// At the pull requests a join reads: a failed list, a member the
/// documented shape does not decode, a pull request answering nothing and a
/// state outside the documented pair each refuse `holders-unreadable`
/// naming the read, with nothing written and the holder told nothing,
/// although a live holder before its review stood ready to be joined.
#[test]
fn a_gh_failure_or_a_malformed_member_refuses_a_join_holders_unreadable_with_nothing_written() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    let root = fleet.checkout("s", None);
    let mut harness = Owned::sleep();
    let mut joinable = holder("KEN-S", "running", Some(&harness), Some(&["src/a.sh"]));
    joinable["repo"] = json!("o/r");
    joinable["mail_root"] = json!(root.display().to_string());
    fleet.write_lanes(vec![joinable]);
    let before = fleet.fleet();
    let mut weird = fake_pull(7, "feat", &["src/a.sh"]);
    weird.state = "weird";
    let mut unanswered = gh_map(&[fake_pull(7, "feat", &["src/a.sh"])]);
    unanswered
        .as_object_mut()
        .unwrap()
        .remove("repos/o/r/pulls/7");
    let rows: [(&str, Value, &str); 4] = [
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
    ];
    let mut request = launch("KEN-L", &fleet.checkout("l", None));
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
        assert!(inbox(&root, "KEN-S").is_empty(), "{defect}");
    }
    // Unread pull requests still hold admission when the live lane yields.
    end(&mut harness);
    let out = fleet.op(&request);
    assert_eq!(refusal(&out).0, "holders-unreadable");
    assert_eq!(fleet.fleet(), before);
}

/// A first launch sharing a path with a running lane on this disk whose
/// current session holds no review stage joins that lane: the reply is
/// `joined` naming the holder, the holder's record carries the item with
/// its touched set widened, no record, intent or slot is the candidate's
/// (the cap of one the holder fills admits it), and the holder's own inbox
/// holds the item's brief after the widened set as its `Admitted paths:`
/// line, which a repeated launch delivers once. The
/// holder's recorded `micro` tier is judged over the widened set: a
/// candidate whose brief names a workflow file needs `standard` and is
/// refused `join-tier-narrower`. Once the holder's session holds a review
/// stage, ended with a fix round open after it, the next candidate is
/// refused `launch-overlap`.
#[test]
fn a_launch_beside_a_running_lane_before_its_review_joins_it_and_its_lane_is_told() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let root = fleet.checkout("h", None);
    let harness = Owned::sleep();
    let mut held = holder("KEN-H", "running", Some(&harness), Some(&["src/a.sh"]));
    held["mail_root"] = json!(root.display().to_string());
    held["tier"] = json!("micro");
    fleet.write_lanes(vec![held]);
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    let brief = fleet.dir.path().join("brief.md");
    std::fs::write(&brief, "Change `src/a.sh` and `src/b.sh` for KEN-L.\n").unwrap();
    let mut request = launch("KEN-L", &fleet.checkout("l", None));
    request["brief_file"] = json!(brief.display().to_string());
    let cap = [("ORCH_OVERSEER_LANES", "1")];

    let out = fleet.op_with(&request, &cap);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let report = joined_or_launched(&answer);
    assert_eq!(
        (&report["op"], &report["item"], &report["holder"]),
        (&json!("joined"), &json!("KEN-L"), &json!("KEN-H")),
        "{report}"
    );
    assert_eq!(fleet.lane_count(), 1, "no record is the candidate's");
    assert_eq!(fleet.fleet()["intents"], json!([]), "no intent");
    let lane = fleet.lane("KEN-H");
    assert_eq!(lane["carried"].as_array().unwrap().len(), 1, "{lane}");
    assert_eq!(
        (&lane["carried"][0]["item"], &lane["carried"][0]["tracker"]),
        (&json!("KEN-L"), &json!("linear"))
    );
    assert_eq!(lane["touched"], json!(["src/a.sh", "src/b.sh"]));
    let told = inbox(&root, "KEN-H");
    assert_eq!(told.len(), 1, "{told:?}");
    let text = told[0]["text"].as_str().unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(
        lines[..2],
        [
            "joined item=KEN-L holder=KEN-H",
            r#"Admitted paths: ["src/a.sh","src/b.sh"]"#,
        ],
        "{text}"
    );
    assert!(text.contains("for KEN-L."), "{text}");

    let out = fleet.op_with(&request, &cap);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(fleet.lane("KEN-H")["carried"], lane["carried"]);
    assert_eq!(inbox(&root, "KEN-H").len(), 1, "a repeated join lands once");

    fleet.item("KEN-T", "`src/a.sh`", 0, &[]);
    std::fs::write(
        &brief,
        "Change `src/a.sh` and `.github/workflows/ci.yml`.\n",
    )
    .unwrap();
    let mut wider = launch("KEN-T", &fleet.checkout("t", None));
    wider["brief_file"] = json!(brief.display().to_string());
    let before = fleet.fleet();
    let (key, fields) = refusal(&fleet.op_with(&wider, &cap));
    assert_eq!(key, "join-tier-narrower");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-T"),
            ("holder", "KEN-H"),
            ("tier", "micro"),
            ("needs", "standard")
        ])
    );
    assert_eq!(fleet.fleet(), before, "a refused join writes nothing");

    // Its review ended and a fix round opened after it: the review ran in
    // this session, so the lane is in review.
    stages(
        &root.join("tmp"),
        "KEN-H",
        json!([
            {"kind": "review", "round_id": "r1", "start": IN_SESSION, "end": IN_SESSION + 60},
            {"kind": "fix", "round_id": "r1", "start": IN_SESSION + 60},
        ]),
    );
    fleet.item("KEN-M", "`src/a.sh`", 0, &[]);
    let (key, fields) = refusal(&fleet.op(&launch("KEN-M", &fleet.checkout("m", None))));
    assert_eq!(key, "launch-overlap");
    assert_eq!(
        fields,
        pairs(&[("item", "KEN-M"), ("file", "src/a.sh"), ("holder", "KEN-H")])
    );
    assert_eq!(inbox(&root, "KEN-H").len(), 1);
}

/// A holder the join cannot judge or reach keeps the candidate out by
/// name, nothing written: a local holder whose item state is no object
/// refuses `holder-unreadable read=stage`; a hosted holder in flight whose
/// host answers no read of its branch refuses `join-unreachable
/// route=hosted`, naming the held file and the cause; one carrying the
/// candidate's launch blocker refuses naming that blocker.
#[test]
fn a_holder_whose_stage_cannot_be_read_or_whose_mailbox_is_on_its_host_is_not_joined() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let root = fleet.checkout("h", None);
    let harness = Owned::sleep();
    let mut held = holder("KEN-H", "running", Some(&harness), Some(&["src/a.sh"]));
    held["mail_root"] = json!(root.display().to_string());
    let mut hosted = holder("KEN-R", "running", None, Some(&["src/r.sh"]));
    hosted["host"] = json!("/w/provider");
    hosted["kind"] = json!("ssh");
    fleet.write_lanes(vec![held, hosted]);
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    std::fs::write(support::item_record(&root.join("tmp"), "KEN-H"), "[]").unwrap();
    fleet.item("KEN-L", "`src/a.sh`", 0, &[]);
    fleet.item("KEN-S", "`src/r.sh`", 0, &[]);
    let before = fleet.fleet();

    let (key, fields) = refusal(&fleet.op(&launch("KEN-L", &fleet.checkout("l", None))));
    assert_eq!(key, "holder-unreadable");
    assert_eq!(
        fields[..3],
        pairs(&[("item", "KEN-L"), ("holder", "KEN-H"), ("read", "stage")])[..]
    );
    let (key, fields) = refusal(&fleet.op(&launch("KEN-S", &fleet.checkout("s", None))));
    assert_eq!(key, "join-unreachable");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-S"),
            ("file", "src/r.sh"),
            ("holder", "KEN-R"),
            ("route", "hosted"),
            ("branch", "unknown"),
            ("cause", "head-unread"),
        ])
    );
    fleet.item_under("KEN-B", "", &["KEN-R"]);
    let (key, fields) = refusal(&fleet.op(&launch("KEN-B", &fleet.checkout("b", None))));
    assert_eq!(key, "join-unreachable");
    assert_eq!(
        fields,
        pairs(&[
            ("item", "KEN-B"),
            ("blockers", "KEN-R"),
            ("holder", "KEN-R"),
            ("route", "hosted"),
        ])
    );
    assert_eq!(fleet.fleet(), before, "nothing written");
    assert!(inbox(&root, "KEN-H").is_empty());
}

/// A running hosted holder of a shared path refuses `join-unreachable`
/// whatever its branch shows, since edits it has not committed are on its
/// host alone; the refusal names the held file and says whether its head
/// commit, as GitHub compares it with the default branch, changes a shared
/// path. A shared change, a
/// rename's old path among them, refuses as an unjudged holder did. A head
/// that changes none refuses `worktree-unproved` naming the head. A failed
/// comparison, a head GitHub does not hold and a comparison at GitHub's
/// file cap each refuse naming the branch and the cause. Each refusal writes
/// nothing.
#[test]
fn a_hosted_holder_refuses_a_shared_path_naming_its_head_verdict() {
    let mut fleet = Fleet::new();
    fleet.init_fleet();
    let world = fleet.dir.path().join("host");
    let provider = world.join("provider");
    std::fs::create_dir_all(&world).unwrap();
    write_executable(
        &provider,
        format!(
            "#!/bin/sh\nLANE_HOST_WORLD='{}' exec '{}' \"$@\"\n",
            world.display(),
            fixtures().join("lane-host/provider").display(),
        ),
    );
    let disk = |path: &str, text: &str| {
        let at = world.join("disk").join(path.trim_start_matches('/'));
        std::fs::create_dir_all(at.parent().unwrap()).unwrap();
        std::fs::write(at, text).unwrap();
    };
    disk("/w/ken-r/.git", "gitdir: /w/main/.git/worktrees/ken-r\n");
    disk(
        "/w/main/.git/worktrees/ken-r/HEAD",
        "ref: refs/heads/ken-r\n",
    );
    disk("/w/main/.git/refs/heads/ken-r", "h1\n");
    let mut hosted = holder("KEN-R", "running", None, Some(&["src/r.sh"]));
    hosted["host"] = json!(provider.display().to_string());
    hosted["kind"] = json!("ssh");
    hosted["repo"] = json!("o/r");
    hosted["mail_root"] = json!("/w/ken-r");
    fleet.write_lanes(vec![hosted]);
    fleet.item("KEN-S", "`src/r.sh`", 0, &[]);
    let mut request = launch("KEN-S", &fleet.checkout("s", None));
    request["repo"] = json!("o/r");
    const COMPARE: &str = "repos/o/r/compare/main...h1";
    let compared = |files: Value| {
        let mut map = gh_map(&[]);
        map["repos/o/r"] = json!({"body": {"default_branch": "main"}});
        map[COMPARE] = files;
        map
    };
    let changing = |files: &[&str]| {
        compared(json!({"body": {
            "files": files.iter().map(|f| json!({"filename": f})).collect::<Vec<_>>(),
        }}))
    };
    let before = fleet.fleet();
    let refused = |fleet: &Fleet| {
        let (key, fields) = refusal(&fleet.op(&request));
        assert_eq!(key, "join-unreachable", "{fields:?}");
        assert_eq!(fleet.fleet(), before, "nothing written");
        fields
    };
    let unread = |fleet: &Fleet, cause: &str| {
        let fields = refused(fleet);
        assert_eq!(
            fields[..5],
            pairs(&[
                ("item", "KEN-S"),
                ("file", "src/r.sh"),
                ("holder", "KEN-R"),
                ("route", "hosted"),
                ("branch", "ken-r"),
            ])[..]
        );
        assert_eq!(fields[5].0, "cause");
        assert!(fields[5].1.starts_with(cause), "{fields:?}");
    };
    let held = pairs(&[
        ("item", "KEN-S"),
        ("file", "src/r.sh"),
        ("holder", "KEN-R"),
        ("route", "hosted"),
    ]);

    fleet.gh_api(&changing(&["src/r.sh"]));
    assert_eq!(refused(&fleet), held);
    fleet.gh_api(&compared(json!({"body": {"files": [
        {"filename": "src/s.sh", "previous_filename": "src/r.sh"},
    ]}})));
    assert_eq!(refused(&fleet), held, "a rename away holds the old path");

    fleet.gh_api(&changing(&["docs/other.md"]));
    unread(&fleet, "worktree-unproved head=h1");
    fleet.gh_api(&compared(
        json!({"exit": 1, "stderr": "gh: HTTP 500: boom"}),
    ));
    unread(&fleet, "compare-unread ");
    let mut map = changing(&[]);
    map.as_object_mut().unwrap().remove(COMPARE);
    fleet.gh_api(&map);
    unread(&fleet, "head-unpushed head=h1");
    // GitHub lists at most 300 changed files for a comparison, so a list
    // that long may leave the shared path out.
    let many: Vec<String> = (0..300).map(|n| format!("docs/{n}.md")).collect();
    fleet.gh_api(&changing(
        &many.iter().map(String::as_str).collect::<Vec<_>>(),
    ));
    unread(&fleet, "files-capped files=300");
}

/// A lane whose confinement binds its checkout read-only touches no path.
/// Beside a running hosted holder of its item's Location path, the lane
/// that writes is refused `join-unreachable`; the read-only one meets no
/// holder and is recorded `read_only` with an empty touched set, which its
/// relaunch keeps, while a launch over its `done` record naming none
/// records a writing lane. The tier still classifies the Location paths: a
/// read-only brief requesting `micro` over a workflow file is refused
/// `tier-narrower`. A read-only lane nothing holds to changing no file, on
/// a Copilot harness here or in a cloud session, is refused
/// `read-only-unconfined`. Each refusal writes nothing.
#[test]
fn a_read_only_lane_meets_no_holder_and_one_this_machine_cannot_confine_is_refused() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let mut hosted = holder("KEN-R", "running", None, Some(&["src/r.sh"]));
    hosted["host"] = json!("/w/provider");
    hosted["kind"] = json!("ssh");
    fleet.write_lanes(vec![hosted]);
    fleet.item("KEN-P", "`src/r.sh`, `.github/workflows/ci.yml`", 0, &[]);
    let checkout = fleet.checkout("p", None);
    let before = fleet.fleet();
    let read_only = |fields: Value| {
        let mut request = launch("KEN-P", &checkout);
        request["read_only"] = json!(true);
        for (key, value) in fields.as_object().unwrap() {
            request[key] = value.clone();
        }
        request
    };

    let (key, fields) = refusal(&fleet.op(&launch("KEN-P", &checkout)));
    assert_eq!(key, "join-unreachable", "{fields:?}");
    assert_eq!(fleet.fleet(), before, "nothing written");

    for (fields, harness, cause) in [
        (
            json!({"harness": "copilot", "permission": "--allow-all"}),
            "copilot",
            "token-on-session-bus",
        ),
        (json!({"host": "claude-cloud"}), "claude", "cloud"),
    ] {
        let (key, refused) = refusal(&fleet.op(&read_only(fields)));
        assert_eq!(key, "read-only-unconfined", "{harness}: {refused:?}");
        assert_eq!(
            refused,
            pairs(&[("item", "KEN-P"), ("harness", harness), ("cause", cause)])
        );
        assert_eq!(fleet.fleet(), before, "{harness}: nothing written");
    }

    let brief = fleet.dir.path().join("brief.md");
    std::fs::write(
        &brief,
        "tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=- paths=1\nAnswer on the item.\n",
    )
    .unwrap();
    let (key, fields) = refusal(&fleet.op(&read_only(
        json!({"brief_file": brief.display().to_string()}),
    )));
    assert_eq!(key, "tier-narrower", "{fields:?}");
    assert!(
        fields.contains(&("judged".to_owned(), "standard".to_owned())),
        "{fields:?}"
    );
    assert_eq!(fleet.fleet(), before, "nothing written");

    let out = fleet.op(&read_only(json!({})));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-P");
    assert_eq!(
        (&lane["read_only"], &lane["touched"]),
        (&json!(true), &json!([])),
        "{lane}"
    );
    assert_eq!(fleet.lane("KEN-R"), before["lanes"][0]);
    // No fleet server exists here, so the admitted launch fails before any
    // window and leaves its record `stopped`, whose relaunch keeps it.
    assert_eq!(lane["status"], "stopped");
    let out = fleet.op(&launch("KEN-P", &checkout));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(fleet.lane("KEN-P")["read_only"], true);

    // Over its `done` record, the hosted holder stopped, a launch naming no
    // `read_only` is the item's next phase: a writing lane holding the
    // Location paths.
    let mut lanes = fleet.fleet()["lanes"].as_array().unwrap().clone();
    for lane in &mut lanes {
        lane["status"] = json!(if lane["item"] == "KEN-P" {
            "done"
        } else {
            "stopped"
        });
    }
    fleet.write_lanes(lanes);
    let out = fleet.op(&launch("KEN-P", &checkout));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("KEN-P");
    assert_eq!(
        (&lane["read_only"], &lane["touched"]),
        (
            &Value::Null,
            &json!([".github/workflows/ci.yml", "src/r.sh"])
        ),
        "{lane}"
    );
}

/// A lane whose brief changes no repository file starts beside its item's
/// launch blockers, its own or a container ancestor's, on this machine and
/// on an ssh host: the read-only launch is admitted and recorded
/// `read_only` with an empty touched set, while the item's writing launch
/// still refuses `launch-blocked` naming the blocker and writes nothing.
#[test]
fn a_read_only_launch_starts_beside_its_items_launch_blockers_and_a_writing_one_waits() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    fleet.item_under("CC-1", "", &["CC-9"]);
    fleet.item_under("CC-2", "CC-3", &[]);
    fleet.item_under("CC-3", "", &["CC-9"]);
    let checkout = fleet.checkout("p", None);
    for (item, host, read_only) in [
        ("CC-1", None, false),
        ("CC-1", None, true),
        ("CC-2", Some("/w/provider"), false),
        ("CC-2", Some("/w/provider"), true),
    ] {
        let row = format!("{item} host={host:?} read_only={read_only}");
        let mut request = launch(item, &checkout);
        if let Some(host) = host {
            request["host"] = json!(host);
        }
        if read_only {
            request["read_only"] = json!(true);
        }
        let before = fleet.fleet();
        let out = fleet.op(&request);
        if !read_only {
            let (key, fields) = refusal(&out);
            assert_eq!(key, "launch-blocked", "{row}: {fields:?}");
            assert_eq!(
                fields,
                pairs(&[("item", item), ("blockers", "CC-9")]),
                "{row}"
            );
            assert_eq!(fleet.fleet(), before, "{row}: nothing written");
            continue;
        }
        assert_eq!(reply(&out)["ok"], true, "{row}: {}", stderr(&out));
        let lane = fleet.lane(item);
        assert_eq!(
            (&lane["read_only"], &lane["touched"], &lane["host"]),
            (&json!(true), &json!([]), &json!(host)),
            "{row}: {lane}"
        );
    }
}

/// Two candidates of one pass sharing a path, launched one after the other:
/// the first opens its window on the fleet's server and stays `preparing`
/// (its harness never draws), and the second joins it in place of a launch
/// of its own: no record, intent or window is the second's, and the first's
/// lane, told in its own inbox, carries it.
#[test]
fn two_candidates_of_one_pass_ride_the_first_ones_lane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let root = runner.state_dir().to_path_buf();
    let candidate = |item: &str| {
        let brief = root.join(format!("{item}.md"));
        std::fs::write(&brief, format!("Change `src/a.sh` for {item}.\n")).unwrap();
        let mut request = launch_request(item, &root);
        request["brief_file"] = json!(brief.display().to_string());
        request
    };

    let first = effect_report(&runner.op_fleet(&candidate("KEN-X")));
    assert_eq!(first["intent"]["outcome"], "unconfirmed", "{first}");
    let panes = server.panes();

    let out = runner.op_fleet(&candidate("KEN-Y"));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let report = joined_or_launched(&answer);
    assert_eq!(
        (&report["op"], &report["item"], &report["holder"]),
        (&json!("joined"), &json!("KEN-Y"), &json!("KEN-X")),
        "{report}"
    );
    let fleet = runner.fleet();
    let lanes = fleet["lanes"].as_array().unwrap();
    assert_eq!(lanes.len(), 1, "no record is the second's: {fleet}");
    assert_eq!(lanes[0]["status"], "preparing");
    assert_eq!(lanes[0]["carried"][0]["item"], "KEN-Y");
    assert_eq!(fleet["intents"].as_array().unwrap().len(), 1, "{fleet}");
    assert_eq!(server.panes(), panes, "no window is the second's");
    let told = inbox(&root, "KEN-X");
    assert_eq!(told.len(), 1, "{told:?}");
    assert!(
        told[0]["text"]
            .as_str()
            .unwrap()
            .starts_with("joined item=KEN-Y holder=KEN-X")
    );
}

/// Joining two linked worktrees needs the current launch's unconfined answer.
/// A confined holder may still carry work in its own checkout. Both ties
/// are judged before the holder's record or mailbox changes.
#[test]
fn a_join_respects_the_current_holders_confinement() {
    let unconfined = json!({"state": "unconfined", "cause": "linked-seat"});
    let confined = json!({"state": "confined"});
    for (row, blocker, same_checkout, answer, refusal_cause) in [
        (
            "shared file",
            false,
            false,
            Some(&confined),
            Some("worktree-outside-holder"),
        ),
        (
            "launch blocker",
            true,
            false,
            Some(&confined),
            Some("worktree-outside-holder"),
        ),
        (
            "opening again",
            false,
            false,
            None,
            Some("confinement-unproved"),
        ),
        ("linked seat", false, false, Some(&unconfined), None),
        ("same checkout", false, true, Some(&confined), None),
    ] {
        let fleet = Fleet::new();
        fleet.init_fleet();
        let source = fleet.checkout("source", None);
        for args in [
            &["config", "gc.auto", "0"][..],
            &["config", "maintenance.auto", "false"],
            &["commit", "-q", "--allow-empty", "-m", "base"],
        ] {
            git(&source, args);
        }
        let linked = |name: &str| {
            let checkout = fleet.dir.path().join(name);
            git(
                &source,
                &[
                    "worktree",
                    "add",
                    "-q",
                    checkout.to_str().unwrap(),
                    "-b",
                    name,
                ],
            );
            checkout
        };
        let root = linked("holder");
        let checkout = if same_checkout {
            let alias = fleet.dir.path().join("holder-alias");
            std::os::unix::fs::symlink(&root, &alias).unwrap();
            alias
        } else {
            linked("candidate")
        };
        let harness = Owned::sleep();
        let status = if answer.is_some() {
            "running"
        } else {
            "preparing"
        };
        let mut held = holder(
            "KEN-H",
            status,
            answer.map(|_| &harness),
            Some(&["src/a.sh"]),
        );
        held["harness"] = json!(if answer == Some(&confined) {
            "claude"
        } else {
            "codex"
        });
        held["mail_root"] = json!(root);
        let mut current = json!({
            "id": "launch-session:KEN-H:2-1", "op": "launch-session", "target": "KEN-H",
            "created_at": held["session_since"], "lane_since": held["session_since"],
            "outcome": "not-started",
        });
        let mut intents = Vec::new();
        if let Some(answer) = answer {
            current["outcome"] = json!("confirmed");
            current["observation"] = json!({"confinement": answer});
        } else {
            // Whole-second stamps can collide on a relaunch. The prior
            // unconfined observation belongs to the earlier intent.
            let mut earlier = current.clone();
            earlier["id"] = json!("launch-session:KEN-H:1-1");
            earlier["outcome"] = json!("confirmed");
            earlier["observation"] = json!({"confinement": unconfined});
            intents.push(earlier);
        }
        intents.push(current);
        fleet.write_lanes_and_intents(vec![held], intents);
        if blocker {
            fleet.item_under("KEN-C", "", &["KEN-H"]);
        } else {
            fleet.item("KEN-C", "`src/a.sh`", 0, &[]);
        }
        let before = std::fs::read(fleet.fleet_path()).unwrap();
        let out = fleet.op(&launch("KEN-C", &checkout));
        if let Some(cause) = refusal_cause {
            assert_eq!(
                refusal(&out),
                (
                    "join-confined".to_owned(),
                    pairs(&[("item", "KEN-C"), ("holder", "KEN-H"), ("cause", cause)]),
                ),
                "{row}"
            );
            assert_eq!(std::fs::read(fleet.fleet_path()).unwrap(), before, "{row}");
            assert!(inbox(&root, "KEN-H").is_empty(), "{row}");
        } else {
            assert_eq!(joined_or_launched(&reply(&out))["holder"], "KEN-H", "{row}");
            assert_eq!(fleet.lane("KEN-H")["carried"][0]["item"], "KEN-C", "{row}");
            assert_eq!(inbox(&root, "KEN-H").len(), 1, "{row}");
        }
    }
}

/// A running lane before its review takes the candidate tied to it: a
/// `linear` candidate whose one launch blocker is its item, its body naming
/// no path, joins it in place of `launch-blocked`, and so does one sharing
/// its recorded path. A `read_only` lane takes no join on either side: a
/// read-only holder, its record holding no path, leaves the blocked
/// candidate `launch-blocked`, and a read-only candidate beside a writing
/// holder opens its own lane. A holder that owns an open pull request is in
/// its review and refuses the same. A relaunch naming `read_only` over a
/// stopped writing record keeps the record writing and its path held: a
/// candidate sharing it joins. Every refusal writes nothing, and every
/// outcome but a join leaves the holder's mailbox empty.
#[test]
fn a_candidate_tied_to_a_running_lane_joins_it_unless_it_is_in_review_or_read_only() {
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum Tie {
        Blocker,
        File,
    }
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum ReadOnly {
        Neither,
        Holder,
        Candidate,
        HolderRelaunched,
    }
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum Outcome {
        Joins,
        Blocked,
        OwnLane,
    }
    for (tie, owns_pull, read_only, outcome) in [
        (Tie::Blocker, false, ReadOnly::Neither, Outcome::Joins),
        (Tie::Blocker, true, ReadOnly::Neither, Outcome::Blocked),
        (Tie::Blocker, false, ReadOnly::Holder, Outcome::Blocked),
        (Tie::Blocker, false, ReadOnly::Candidate, Outcome::OwnLane),
        (Tie::File, false, ReadOnly::HolderRelaunched, Outcome::Joins),
    ] {
        let row = format!("{tie:?} owns_pull={owns_pull} read_only={read_only:?}");
        let mut fleet = Fleet::new();
        fleet.init_fleet();
        let root = fleet.checkout("h", None);
        let harness = Owned::sleep();
        let paths: &[&str] = if read_only == ReadOnly::Holder {
            &[]
        } else {
            &["src/a.sh"]
        };
        let mut held = holder("KEN-H", "running", Some(&harness), Some(paths));
        held["mail_root"] = json!(root.display().to_string());
        held["repo"] = json!("o/r");
        match read_only {
            ReadOnly::Holder => held["read_only"] = json!(true),
            ReadOnly::HolderRelaunched => {
                let live = held.clone();
                held["status"] = json!("stopped");
                held["launch"] = Value::Null;
                fleet.write_lanes(vec![held]);
                fleet.item("KEN-H", "`src/a.sh`", 0, &[]);
                let mut relaunch = launch("KEN-H", &root);
                relaunch["read_only"] = json!(true);
                let out = fleet.op(&relaunch);
                assert_eq!(reply(&out)["ok"], true, "{row}: {}", stderr(&out));
                // No fleet server exists here, so the relaunch fails before
                // any window: its record stands `stopped`, made live again
                // as its harness would make it.
                held = fleet.lane("KEN-H");
                assert_eq!(
                    (&held["read_only"], &held["touched"]),
                    (&Value::Null, &json!(["src/a.sh"])),
                    "{row}: {held}"
                );
                held["status"] = live["status"].clone();
                held["launch"] = live["launch"].clone();
            }
            ReadOnly::Neither | ReadOnly::Candidate => {}
        }
        fleet.write_lanes(vec![held]);
        match tie {
            Tie::Blocker => fleet.item_under("CC-1", "", &["KEN-H"]),
            Tie::File => fleet.item("CC-1", "`src/a.sh`", 0, &[]),
        }
        let pulls = if owns_pull {
            vec![fake_pull(8, "KEN-H", &["src/a.sh"])]
        } else {
            vec![]
        };
        fleet.gh_api(&gh_map(&pulls));
        let mut request = launch("CC-1", &fleet.checkout("c", None));
        request["repo"] = json!("o/r");
        if read_only == ReadOnly::Candidate {
            request["read_only"] = json!(true);
        }
        let before_bytes = std::fs::read(fleet.fleet_path()).unwrap();
        let out = fleet.op(&request);
        if outcome == Outcome::OwnLane {
            assert_eq!(reply(&out)["ok"], true, "{row}: {}", stderr(&out));
            assert_eq!(fleet.lane("CC-1")["read_only"], true, "{row}");
            assert!(fleet.lane("KEN-H").get("carried").is_none(), "{row}");
            assert!(inbox(&root, "KEN-H").is_empty(), "{row}");
            continue;
        }
        if outcome == Outcome::Joins {
            let answer = reply(&out);
            assert_eq!(answer["ok"], true, "{row}: {}", stderr(&out));
            let report = joined_or_launched(&answer);
            assert_eq!(
                (&report["op"], &report["holder"]),
                (&json!("joined"), &json!("KEN-H")),
                "{row}"
            );
            assert_eq!(fleet.lane("KEN-H")["carried"][0]["item"], "CC-1");
            assert_eq!(inbox(&root, "KEN-H").len(), 1, "{row}");
            continue;
        }
        assert_eq!(reply(&out)["ok"], false, "{row}: {}", reply(&out));
        let (key, fields) = refusal(&out);
        assert_eq!(key, "launch-blocked", "{row}: {fields:?}");
        assert_eq!(
            std::fs::read(fleet.fleet_path()).unwrap(),
            before_bytes,
            "{row}: nothing written"
        );
        assert!(inbox(&root, "KEN-H").is_empty(), "{row}");
    }
}

/// A holder that opened with no admitted set, by an empty first-launch set
/// or a record no judgement wrote, runs unbounded, and every widening of
/// its set keeps it so: two candidates whose launch blocker it carries join
/// it in turn, its record takes both candidates' paths, and neither join's
/// directive nor the brief its relaunch through the real `launch-lane`
/// hands the harness names an `Admitted paths:` line, which would bound the
/// holder's own work by the candidates' paths alone.
#[test]
fn a_holder_that_opened_unbounded_stays_so_through_every_join_and_its_relaunch() {
    let rows: [(&str, Option<&[&str]>); 2] = [
        ("an empty first-launch set", Some(&[])),
        ("a record no judgement wrote", None),
    ];
    for (row, opened) in rows {
        let mut fleet = Fleet::new();
        fleet.init_fleet();
        let root = fleet.checkout("h", None);
        fleet.item("KEN-H", "`docs/h.md`", 0, &[]);
        let mut harness = Owned::sleep();
        let mut held = holder("KEN-H", "running", Some(&harness), opened);
        held["mail_root"] = json!(root.display().to_string());
        held["repo"] = json!("o/r");
        fleet.write_lanes(vec![held]);
        fleet.gh_api(&gh_map(&[]));
        for (item, file) in [("CC-1", "src/c.sh"), ("CC-2", "src/d.sh")] {
            fleet.item_under(item, "", &["KEN-H"]);
            let brief = fleet.dir.path().join(format!("{item}.md"));
            std::fs::write(&brief, format!("Change `{file}` for {item}.\n")).unwrap();
            let mut request = launch(item, &fleet.checkout(item, None));
            request["repo"] = json!("o/r");
            request["brief_file"] = json!(brief.display().to_string());
            let out = fleet.op(&request);
            let answer = reply(&out);
            assert_eq!(answer["ok"], true, "{row}, {item}: {}", stderr(&out));
            assert_eq!(
                joined_or_launched(&answer)["op"],
                "joined",
                "{row}, {item}: {answer}"
            );
        }
        assert_eq!(
            fleet.lane("KEN-H")["touched"],
            json!(["src/c.sh", "src/d.sh"]),
            "{row}"
        );
        let told = inbox(&root, "KEN-H");
        assert_eq!(told.len(), 2, "{row}: {told:?}");
        for (directive, item) in told.iter().zip(["CC-1", "CC-2"]) {
            let text = directive["text"].as_str().unwrap();
            assert!(
                text.starts_with(&format!("joined item={item} holder=KEN-H")),
                "{row}: {text}"
            );
            assert!(!text.contains("Admitted paths:"), "{row}, {item}: {text}");
        }

        end(&mut harness);
        let mut fleet_doc = fleet.fleet();
        fleet_doc["lanes"][0]["status"] = json!("stopped");
        fleet_doc["lanes"][0]["launch"] = Value::Null;
        std::fs::write(
            fleet.fleet_path(),
            serde_json::to_string_pretty(&fleet_doc).unwrap(),
        )
        .unwrap();
        let servers = tempfile::tempdir().unwrap();
        let server = Server::start(servers.path(), "fleet");
        let brief = fleet.dir.path().join("KEN-H.md");
        std::fs::write(&brief, "/orch start KEN-H\n").unwrap();
        let mut relaunch = launch("KEN-H", &root);
        relaunch["repo"] = json!("o/r");
        relaunch["brief_file"] = json!(brief.display().to_string());
        let stub = fixtures().join("stub-record/claude");
        let socket = format!("{},0,0", server.socket.display());
        let verify = confirm_secs(1).to_string();
        let account_state = fleet.dir.path().join("accounts");
        let out = fleet.op_with(
            &relaunch,
            &[
                ("TMUX", socket.as_str()),
                ("AGENT_RUNTIME_TMUX_SESSION", server.session.as_str()),
                (
                    "AGENT_RUNTIME_HARNESS_BINARIES",
                    &format!("claude={}", stub.display()),
                ),
                ("ORCH_AGENT_RUNTIME", &agent_runtime().display().to_string()),
                ("AGENT_RUNTIME_TMUX_VERIFY_SECS", verify.as_str()),
                (
                    "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                    &account_state.display().to_string(),
                ),
            ],
        );
        // The stub writes its command line before it draws the composer
        // marker the confirmation reads, so a confirmed relaunch has it.
        let report = effect_report(&out);
        assert_eq!(report["intent"]["outcome"], "confirmed", "{row}: {report}");
        let recorded: Value = serde_json::from_str(
            &std::fs::read_to_string(root.join("launch-record.json")).unwrap(),
        )
        .unwrap();
        let brief = recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .find(|arg| arg.starts_with("/orch start KEN-H"))
            .unwrap_or_else(|| panic!("{row}: no brief on the line: {recorded}"));
        assert!(!brief.contains("Admitted paths:"), "{row}: {brief}");
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
/// over a stopped record is bound on its request's checkout before its
/// recorded set meets a live holder.
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
    // relaunch is bound on its own checkout before anything is read, as a
    // first launch is, so a live holder of its recorded path answers only
    // once the binding stands.
    assert_eq!(fleet.lane("KEN-1")["status"], "stopped");
    let harness = Owned::sleep();
    let mut lanes = fleet.fleet()["lanes"].as_array().unwrap().clone();
    let ken_1 = lanes.iter_mut().find(|l| l["item"] == "KEN-1").unwrap();
    ken_1["touched"] = json!(["src/a.sh"]);
    lanes.push(holder(
        "KEN-H",
        "running",
        Some(&harness),
        Some(&["src/a.sh"]),
    ));
    let intents = fleet.fleet()["intents"].as_array().unwrap().clone();
    fleet.write_lanes_and_intents(lanes, intents);
    let before = fleet.fleet();
    let (key, _) = refusal(&fleet.op(&launch_from("KEN-1", &other)));
    assert_eq!(
        key, "overseer-foreign",
        "a relaunch into another repository, bound before its holders"
    );
    assert_eq!(fleet.fleet(), before, "a refused relaunch writes nothing");
    let (key, _) = refusal(&fleet.op(&launch_from("KEN-1", &inside)));
    assert_eq!(key, "launch-overlap", "its own checkout, bound");
    assert_eq!(fleet.fleet(), before);
}

/// A launch's registration records on its lane row the canonical common
/// git folder admission read from its checkout (`checkout_common`), the
/// folder the close trusts the lane's worktree to belong to: a first launch
/// from a linked worktree of a connected repository records that
/// repository's `.git`; a relaunch over the same `mail_root` after the
/// worktree's `.git` was rewritten keeps the folder first recorded, since a
/// session of the lane could have written it; a relaunch from another
/// checkout records that checkout's; a checkout whose common folder lies
/// where a lane can plant one, under its own root, under another `.git` or
/// a bare repository's `<name>.git`, in an `ORCH_LANE_WRITABLE` folder, in
/// any item's state folder or in a configured account's seat, records none.
#[test]
fn a_launch_records_its_checkouts_common_git_folder_once_and_never_one_under_its_root() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    git(&fleet.state_dir(), &["init", "-q", "-b", "main", "."]);
    git(
        &fleet.state_dir(),
        &["remote", "add", "origin", "git@github.com:o/fleet.git"],
    );
    let connected = [("ORCH_CONNECTED_REPOS", "o/other o/third")];
    let launch_from = |item: &str, root: &Path| {
        let mut request = launch(item, root);
        request.as_object_mut().unwrap().remove("tracker");
        let out = fleet.op_with(&request, &connected);
        assert_eq!(reply(&out)["ok"], true, "{item}: {}", stderr(&out));
    };
    // A repository with one commit and its linked worktree `<name>-wt`.
    let worktree_of = |name: &str| {
        let repo = fleet.checkout(name, Some(&format!("git@github.com:o/{name}.git")));
        git(
            &repo,
            &[
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "init",
            ],
        );
        let wt = fleet.dir.path().join(format!("{name}-wt"));
        git(
            &repo,
            &[
                "worktree",
                "add",
                "-q",
                &wt.display().to_string(),
                "-b",
                "lane",
            ],
        );
        (repo, wt)
    };
    // A copy of `repo`'s git folder at `at`, and `wt`'s `.git` naming the
    // copy's admin folder of `wt`: the same origin, read through a common
    // folder the lane chose.
    let redirect = |repo: &Path, wt: &Path, at: &Path| {
        std::fs::create_dir_all(at.parent().unwrap()).unwrap();
        let out = program("cp")
            .arg("-R")
            .arg(repo.join(".git"))
            .arg(at)
            .output()
            .unwrap();
        assert!(out.status.success(), "cp: {}", stderr(&out));
        let admin = at.join("worktrees").join(wt.file_name().unwrap());
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
    };
    let common = |repo: &Path| {
        json!(
            std::fs::canonicalize(repo.join(".git"))
                .unwrap()
                .display()
                .to_string()
        )
    };
    let (other, wt) = worktree_of("other");
    launch_from("KEN-1", &wt);
    assert_eq!(
        fleet.lane("KEN-1")["checkout_common"],
        common(&other),
        "a first launch"
    );
    assert_eq!(fleet.lane("KEN-1")["status"], "stopped");
    let mut done = fleet.lane("KEN-1");
    done["status"] = json!("done");
    done.as_object_mut().unwrap().remove("checkout_common");
    fleet.write_lanes(vec![done]);
    launch_from("KEN-1", &wt);
    assert_eq!(
        fleet.lane("KEN-1")["checkout_common"],
        common(&other),
        "a completed row at the same checkout records its new admission's anchor"
    );
    redirect(&other, &wt, &fleet.dir.path().join("copy/.git"));
    launch_from("KEN-1", &wt);
    assert_eq!(
        fleet.lane("KEN-1")["checkout_common"],
        common(&other),
        "a relaunch over the same mail_root"
    );
    let (third, third_wt) = worktree_of("third");
    launch_from("KEN-1", &third_wt);
    assert_eq!(
        fleet.lane("KEN-1")["checkout_common"],
        common(&third),
        "a relaunch from another checkout"
    );
    let (_, planted) = worktree_of("planted");
    let source = fleet.dir.path().join("planted");
    git(
        &source,
        &["remote", "set-url", "origin", "git@github.com:o/other.git"],
    );
    redirect(&source, &planted, &planted.join("tmp/x/.git"));
    launch_from("KEN-2", &planted);
    assert_eq!(
        fleet.lane("KEN-2")["checkout_common"],
        Value::Null,
        "a common folder under the lane's root"
    );
    let (_, nested) = worktree_of("nested");
    let source = fleet.dir.path().join("nested");
    git(
        &source,
        &["remote", "set-url", "origin", "git@github.com:o/other.git"],
    );
    redirect(&source, &nested, &other.join(".git/x/.git"));
    launch_from("KEN-3", &nested);
    assert_eq!(
        fleet.lane("KEN-3")["checkout_common"],
        Value::Null,
        "a common folder under another .git"
    );
    let (granted, granted_wt) = worktree_of("granted");
    git(
        &granted,
        &["remote", "set-url", "origin", "git@github.com:o/other.git"],
    );
    let mut request = launch("KEN-4", &granted_wt);
    request.as_object_mut().unwrap().remove("tracker");
    let writable = granted.display().to_string();
    let out = fleet.op_with(
        &request,
        &[connected[0], ("ORCH_LANE_WRITABLE", writable.as_str())],
    );
    assert_eq!(reply(&out)["ok"], true, "KEN-4: {}", stderr(&out));
    assert_eq!(
        fleet.lane("KEN-4")["checkout_common"],
        Value::Null,
        "a common folder in an ORCH_LANE_WRITABLE folder"
    );
    // A worktree of a repository of the connected slug whose `.git` leads
    // through a copy of its git folder at `at`.
    let planted_at = |name: &str, at: &Path| {
        let (source, wt) = worktree_of(name);
        git(
            &source,
            &["remote", "set-url", "origin", "git@github.com:o/other.git"],
        );
        redirect(&source, &wt, at);
        wt
    };
    let at = fleet.state_dir().join("items/KEN-1/x/.git");
    launch_from("KEN-5", &planted_at("items", &at));
    assert_eq!(
        fleet.lane("KEN-5")["checkout_common"],
        Value::Null,
        "a common folder in another item's state folder"
    );
    let at = fleet.dir.path().join("srv/repo.git/x/.git");
    launch_from("KEN-6", &planted_at("bare", &at));
    assert_eq!(
        fleet.lane("KEN-6")["checkout_common"],
        Value::Null,
        "a common folder under a bare repository's"
    );
    let seat = fleet.dir.path().join("seat");
    let wt = planted_at("seated", &seat.join("x/.git"));
    let mut request = launch("KEN-7", &wt);
    request.as_object_mut().unwrap().remove("tracker");
    let seat = seat.display().to_string();
    let out = fleet.op_with(
        &request,
        &[connected[0], ("AGENT_RUNTIME_ACCOUNT_DIRS", seat.as_str())],
    );
    assert_eq!(reply(&out)["ok"], true, "KEN-7: {}", stderr(&out));
    assert_eq!(
        fleet.lane("KEN-7")["checkout_common"],
        Value::Null,
        "a common folder in a configured account's seat"
    );
}

/// A completed phase keeps its anchor. The next phase can reuse its path
/// after Git registers the worktree in a different clone of the repository.
#[test]
fn a_new_phase_replaces_a_populated_anchor_at_the_same_worktree_path() {
    let fleet = Fleet::new();
    fleet.init_fleet();
    let repo = fleet.state_dir();
    let origin = "git@github.com:o/fleet.git";
    git(&repo, &["init", "-q", "-b", "main", "."]);
    git(&repo, &["config", "gc.auto", "0"]);
    git(&repo, &["config", "maintenance.auto", "false"]);
    git(&repo, &["remote", "add", "origin", origin]);
    git(
        &repo,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "init",
        ],
    );
    let wt = fleet.dir.path().join("worktree");
    let wt_path = wt.to_str().unwrap();
    git(&repo, &["worktree", "add", "-q", "-b", "lane", wt_path]);
    let mut request = launch("KEN-1", &wt);
    request.as_object_mut().unwrap().remove("tracker");
    let launch_here = || {
        let out = fleet.op(&request);
        assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    };
    launch_here();
    let mut done = fleet.lane("KEN-1");
    assert_eq!(
        done["checkout_common"],
        json!(repo.join(".git").canonicalize().unwrap())
    );
    done["status"] = json!("done");
    fleet.write_lanes(vec![done]);

    let next = fleet.dir.path().join("clone");
    git(
        &repo,
        &[
            "clone",
            "-q",
            "--no-hardlinks",
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            repo.to_str().unwrap(),
            next.to_str().unwrap(),
        ],
    );
    git(&next, &["remote", "set-url", "origin", origin]);
    git(&repo, &["worktree", "remove", wt_path]);
    git(&next, &["worktree", "add", "-q", "-b", "lane", wt_path]);

    launch_here();
    assert_eq!(
        fleet.lane("KEN-1")["checkout_common"],
        json!(next.join(".git").canonicalize().unwrap()),
        "the new phase at the same path replaces its prior anchor"
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
        "model": "claude-fable-5-1",
        "class": CLASS,
        "class_reason": CLASS_REASON,
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
            .any(|line| line == "issues get KEN-1 --format=safe"),
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
/// Location.
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
    fleet.gh_api(&gh_map(&[fake_pull(12, "review-me", &["src/a.rs"])]));
    // One `gh` for every read: the item through the issue fixture, the rest
    // through the API fixture.
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
            "model": "claude-fable-5-1",
            "class": CLASS,
            "class_reason": CLASS_REASON,
        }),
        &[("PATH", path.as_str())],
    );
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = fleet.lane("issue-12");
    assert_eq!(lane["touched"], json!(["src/a.rs"]));
    let reads: Vec<String> = fleet
        .gh_log()
        .into_iter()
        .filter(|line| line.starts_with("issue "))
        .collect();
    assert_eq!(reads, ["issue view 12 --repo o/r --json body,labels"]);
}
