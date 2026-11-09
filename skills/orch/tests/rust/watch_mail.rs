//! The mail duty: the real mailbox program on a temporary checkout, read
//! through the duty on the runner and its fake clock, and a stand-in that
//! dies between its append and its receipt. Each row's name carries the
//! defect it catches.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant mailboxes and records, run the real mailbox program and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use agent_runtime::process::Identity;
use orch_runtime::effects;
use orch_runtime::mailbox::{Drain, Mailbox, Refusal, Sent};
use orch_runtime::ops::Env;
use orch_runtime::schedule::{Duty, SystemClock};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::{FLEET_FILE_NAME, Locking};
use orch_runtime::watch::mail::{self, Config, MailDuty};
use orch_runtime::watch::owner_alert;
use orch_runtime::watch::wake::{OVERSEER_TARGET, UNREAD_KIND};
use orch_runtime::watch::{Baseline, Change, Event, Flags, Paths, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

/// The fake clock's epoch second, 2026-01-29T15:20:00Z.
const WALL: u64 = 1_769_700_000;
const ITEM: &str = "KEN-1";

/// The real mailbox program, the sibling package's.
fn real_lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap()
}

/// The stand-in that runs the real program from the lane root it names,
/// isolated from the operator's git configuration, since the rows hand it
/// to the client in-process.
fn hold() -> PathBuf {
    isolated_program(&fixtures().join("lane-mail-hold/lane-mail"))
}

/// A program a row hands the client in-process inherits this test process's
/// environment, so a `git` it runs could read the operator's own
/// configuration, or, inside a git hook, the hook's repository and its `-c`
/// values. Each route by which an inherited environment names a
/// configuration is planted alone in a stand-in for that environment: `git`
/// started plainly reads the planted key; behind [`isolated_program`],
/// which [`hold`] wraps the mailbox program with, it never does.
#[test]
fn a_program_run_in_process_reads_no_git_configuration_its_environment_names() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let (home, cwd, outer) = (root.join("home"), root.join("cwd"), root.join("outer"));
    for dir in [&home, &cwd] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let init = program("git")
        .args(["init", "-q"])
        .arg(&outer)
        .output()
        .unwrap();
    assert!(init.status.success(), "{init:?}");
    let wrapped = isolated_program(Path::new("git"));
    let named = |name: &'static str, value: &Path| vec![(name, value.as_os_str().to_owned())];
    let set = |pairs: &[(&'static str, &str)]| -> Vec<(&'static str, std::ffi::OsString)> {
        pairs
            .iter()
            .map(|(name, value)| (*name, (*value).into()))
            .collect()
    };
    for (route, vars, file) in [
        ("home", Vec::new(), Some(home.join(".gitconfig"))),
        (
            "xdg",
            named("XDG_CONFIG_HOME", &root.join("xdg")),
            Some(root.join("xdg/git/config")),
        ),
        (
            "global",
            named("GIT_CONFIG_GLOBAL", &root.join("global")),
            Some(root.join("global")),
        ),
        (
            "system",
            named("GIT_CONFIG_SYSTEM", &root.join("system")),
            Some(root.join("system")),
        ),
        (
            "git-dir",
            named("GIT_DIR", &outer.join(".git")),
            Some(outer.join(".git/config")),
        ),
        (
            "parameters",
            set(&[("GIT_CONFIG_PARAMETERS", "'probe.operator=planted'")]),
            None,
        ),
        (
            "count",
            set(&[
                ("GIT_CONFIG_COUNT", "1"),
                ("GIT_CONFIG_KEY_0", "probe.operator"),
                ("GIT_CONFIG_VALUE_0", "planted"),
            ]),
            None,
        ),
    ] {
        if let Some(file) = &file {
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, "[probe]\n\toperator = planted\n").unwrap();
        }
        let read = |program: &Path| {
            Command::new(program)
                .env_clear()
                .env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .env("HOME", &home)
                .env("GIT_CEILING_DIRECTORIES", &root)
                .envs(vars.iter().map(|(name, value)| (name, value)))
                .current_dir(&cwd)
                .args(["config", "--get", "probe.operator"])
                .output()
                .unwrap()
        };
        let plain = read(Path::new("git"));
        assert_eq!(plain.stdout, b"planted\n", "{route}: {plain:?}");
        let isolated = read(&wrapped);
        assert_eq!(isolated.status.code(), Some(1), "{route}: {isolated:?}");
        assert!(isolated.stdout.is_empty(), "{route}: {isolated:?}");
        if let Some(file) = &file {
            std::fs::remove_file(file).unwrap();
        }
    }
}

/// One checkout holding the fleet state, its running lanes rooted at the
/// checkout itself and the overseer's box, with the mailbox program `cli`
/// and the mail interval `interval` in its settings.
struct World {
    _dir: tempfile::TempDir,
    root: PathBuf,
    settings: Settings,
    paths: Paths,
}

/// The world with the one lane `ITEM`.
fn world(cli: &Path, interval: u64) -> World {
    world_of(cli, interval, &[ITEM])
}

fn world_of(cli: &Path, interval: u64, items: &[&str]) -> World {
    world_with(cli, interval, items, &[])
}

/// A world with `extra` settings beside the mail interval and the client.
fn world_with(cli: &Path, interval: u64, items: &[&str], extra: &[(&str, &str)]) -> World {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    for args in [
        vec!["init", "-q"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(&root)
            .args(&args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    }
    let mut fleet: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-oversee.json")).unwrap();
    fleet["lanes"] = items
        .iter()
        .map(|item| {
            json!({
                "item": item,
                "harness": "claude",
                "kind": "local",
                "host": null,
                "mail_root": root.display().to_string(),
                "status": "running",
                "session_since": "2026-01-29T15:00:00Z",
                "launched_at": "2026-01-29T15:00:00Z",
                "running_at": "2026-01-29T15:00:10Z",
            })
        })
        .collect();
    fleet["intents"] = json!([]);
    let state = root.join(FLEET_FILE_NAME);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let roots = Roots {
        project: root.clone(),
        common: root.clone(),
    };
    let mut env: Vec<(std::ffi::OsString, std::ffi::OsString)> = vec![
        (
            "ORCH_WATCH_MAIL_INTERVAL".into(),
            interval.to_string().into(),
        ),
        ("LANE_MAIL_CLI".into(), cli.display().to_string().into()),
    ];
    env.extend(extra.iter().map(|(k, v)| ((*k).into(), (*v).into())));
    let settings = settings::load(
        &roots,
        &env,
        &SettingsFlags {
            state_dir: Some(root.clone()),
            private_env: false,
        },
    )
    .unwrap();
    let paths = Paths::of(&state).unwrap();
    World {
        _dir: dir,
        root,
        settings,
        paths,
    }
}

impl World {
    fn duty(&self) -> MailDuty {
        MailDuty::new(
            Mailbox::new(self.settings.lane_mail_cli.clone()),
            Config::of(&self.settings, &self.paths),
        )
    }

    fn runner<'a>(&self, clock: &'a FakeClock) -> Runner<'a> {
        let mut runner = Runner::new(
            self.paths.clone(),
            clock,
            &self.settings,
            Flags {
                interval: secs(240),
                max_loops: 25,
                since: None,
                replace: None,
            },
            me(),
            Recorded {
                pane: "none".into(),
                script: "/w/orch-runtime".into(),
                cwd: "/w".into(),
            },
        );
        mail::register_duty(&mut runner, self.duty());
        runner
    }

    /// The mailbox file `file` of `item` under the checkout, its directory
    /// made.
    fn box_file(&self, item: &str, file: &str) -> PathBuf {
        let dir = self.root.join("tmp").join("lane-mail").join(item);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(file)
    }

    /// Append `line` to the mailbox file `file` of `item` under the checkout.
    fn plant(&self, item: &str, file: &str, line: &Value) {
        let path = self.box_file(item, file);
        let mut text = std::fs::read_to_string(&path).unwrap_or_default();
        text.push_str(&line.to_string());
        text.push('\n');
        std::fs::write(path, text).unwrap();
    }

    fn cursor(&self, item: &str) -> Option<String> {
        std::fs::read_to_string(self.box_file(item, "to-lane.cursor")).ok()
    }

    /// The handler's own read of `item`'s box, which moves its cursor.
    fn inbox(&self, item: &str) {
        self.lane_mail(&[
            "inbox",
            "--item",
            item,
            "--root",
            self.root.to_str().unwrap(),
        ]);
    }

    /// The real program run from the checkout, as a handler runs it.
    fn lane_mail(&self, args: &[&str]) -> Output {
        let out = program(real_lane_mail())
            .args(args)
            .current_dir(&self.root)
            .output()
            .unwrap();
        assert!(out.status.success(), "lane-mail {args:?}: {}", stderr(&out));
        out
    }

    fn log(&self) -> Vec<String> {
        std::fs::read_to_string(&self.paths.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn baseline(&self) -> Baseline {
        Baseline::load(&self.paths.baseline).unwrap()
    }

    /// A program written under the checkout.
    fn script(&self, name: &str, text: &str) -> PathBuf {
        let path = self.root.join(name);
        write_executable(&path, text);
        path
    }
}

fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

fn note(id: &str, text: &str) -> Value {
    json!({"id": id, "kind": "directive", "at": "2026-01-29T15:20:00Z", "from": "owner", "text": text})
}

fn directive(id: &str, at: &str, text: &str) -> Value {
    json!({"id": id, "kind": "directive", "at": at, "from": "overseer:kendex", "text": text})
}

fn notice(id: &str, item: &str, text: &str) -> Value {
    json!({"id": id, "kind": "notice", "at": "2026-01-29T15:20:00Z", "from": item, "text": text})
}

/// Announcing acknowledges nothing: the handler's own read does. A log the
/// handoff left at line 3; a note in the overseer's box and a directive 400
/// s old in the lane's. The first turn appends the directive's
/// `directive-unread` and the note with its text past line 3 and moves no
/// cursor of either box; a poll with nothing landed appends nothing; the
/// handler's own `inbox` acknowledges the note and the lane's reads its
/// directive, and only the next full turn reports `directive-read`.
#[test]
fn a_note_is_announced_past_the_handoff_line_and_stays_unread_until_the_handler_acks() {
    let w = world(&hold(), 20);
    std::fs::write(
        &w.paths.log,
        "EVENT handoff KEN-9\nEVENT lane-closed KEN-9\nEVENT heartbeat loops=25 interval=240s since=none\n",
    )
    .unwrap();
    w.plant(
        "overseer",
        "to-lane.jsonl",
        &note("n-1", "Hold KEN-7 for the owner."),
    );
    w.plant(
        ITEM,
        "to-lane.jsonl",
        &directive("d-1", "2026-01-29T15:13:20Z", "Rebase onto main."),
    );
    let clock = FakeClock::new();
    let identity = me();
    let runner = w.runner(&clock);
    let ended = run_driven(runner, &clock, &w.paths, &identity, || {
        clock.await_sleepers(2);
        assert_eq!(
            w.log()[3..],
            [
                "EVENT directive-unread KEN-1 d-1 age=400",
                "EVENT owner-note n-1",
                "  Hold KEN-7 for the owner.",
            ],
            "announced past line 3"
        );
        assert_eq!(
            w.cursor("overseer"),
            None,
            "the box's cursor is the handler's"
        );
        assert_eq!(w.cursor(ITEM), None, "the lane's cursor is the lane's");
        clock.pass(secs(1));
        assert_eq!(w.log().len(), 6, "a poll with nothing landed");
        // The handler acknowledges the note; the lane reads its directive.
        w.inbox("overseer");
        w.inbox(ITEM);
        assert_eq!(w.cursor("overseer").as_deref(), Some("1\n"));
        assert_eq!(w.cursor(ITEM).as_deref(), Some("1\n"));
        clock.pass(secs(1));
        assert_eq!(w.log().len(), 6, "a poll after the handler's read");
        clock.pass(secs(19));
        assert_eq!(
            w.log()[6..],
            ["EVENT directive-read KEN-1 d-1"],
            "the lane's own read reports the directive read"
        );
        clock.pass(secs(20));
        assert_eq!(w.log().len(), 7, "nothing new on the next full turn");
    });
    assert!(ended.is_ok(), "{ended:?}");
    let baseline = w.baseline();
    assert_eq!(baseline.get("lane-mail", "overseer"), Some("1 n-1"));
    assert_eq!(baseline.get("directive", ITEM), Some("1 1:0 d-1"));
    assert_eq!(
        w.cursor("overseer").as_deref(),
        Some("1\n"),
        "never moved by the duty"
    );
}

/// The announcement's row moves only once its line is on disk. The
/// baseline's temporary path is blocked, so the first run's write of its
/// row fails after the log's append: the note and its text are on disk, no
/// row stands, the run ends `watch-record`; the next run prints them again
/// and moves the row; a third prints nothing.
#[test]
fn a_crash_between_the_announcement_and_its_row_reprints_the_note_once() {
    let w = world(&hold(), 20);
    w.plant(
        "overseer",
        "to-lane.jsonl",
        &note("n-1", "Hold KEN-7 for the owner."),
    );
    let lines = ["EVENT owner-note n-1", "  Hold KEN-7 for the owner."];
    let blocked = w.paths.baseline.with_extension("json.tmp");
    std::fs::create_dir(&blocked).unwrap();
    let clock = FakeClock::new();
    let identity = me();
    // The mail thread appends, then fails its store and ends the run; the
    // drive waits for the lines before the stop that wakes the other thread.
    let crashed = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
        let deadline = Instant::now() + secs(20);
        while w.log().len() < 2 {
            assert!(Instant::now() < deadline, "the note was never announced");
            std::thread::sleep(Duration::from_millis(20));
        }
    });
    assert!(
        matches!(&crashed, Err(e) if e.key() == "watch-record"),
        "{crashed:?}"
    );
    assert_eq!(w.log(), lines, "the lines are on disk");
    assert!(
        std::fs::metadata(&w.paths.baseline).is_err(),
        "the row never moved: no baseline was written"
    );
    assert_eq!(w.cursor("overseer"), None);
    std::fs::remove_dir(&blocked).unwrap();
    for round in [2, 3] {
        let identity = me();
        let ended = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
            clock.await_sleepers(2);
        });
        assert!(ended.is_ok(), "round {round}: {ended:?}");
        assert_eq!(
            w.log(),
            [lines, lines].concat(),
            "round {round}: printed once more, then nothing"
        );
        assert_eq!(w.baseline().get("lane-mail", "overseer"), Some("1 n-1"));
    }
}

/// The stand-in runs the real `send` to its end, then blocks on a FIFO
/// before relaying the receipt and is killed there: the client reads a
/// refused call, one envelope stands with the operation's delivery id, and
/// the same send again answers `Repeated` naming that envelope, the mailbox
/// still holding one.
#[test]
fn a_send_that_dies_before_its_receipt_repeated_under_its_operation_id_lands_one_envelope() {
    let w = world(&hold(), 20);
    let fifo = w.root.join("hold.fifo");
    mkfifo(&fifo);
    let mark = w.root.join("hold.mark");
    let holding = w.script(
        "lane-mail-holding",
        &format!(
            "#!/bin/bash\nexport LANE_MAIL_HOLD_FIFO={} LANE_MAIL_HOLD_MARK={}\nexec {} \"$@\"\n",
            fifo.display(),
            mark.display(),
            hold().display()
        ),
    );
    let text = w.root.join("directive.txt");
    std::fs::write(&text, "Rebase onto main.\n").unwrap();
    let held = Mailbox::new(holding).bounded(secs(30));
    let first = std::thread::scope(|s| {
        let send =
            s.spawn(|| held.send_directive(ITEM, Some(&w.root), false, &text, Some("op-1"), None));
        let deadline = Instant::now() + secs(20);
        let pid = loop {
            if let Ok(pid) = std::fs::read_to_string(&mark)
                && !pid.trim().is_empty()
            {
                break pid.trim().to_owned();
            }
            assert!(
                Instant::now() < deadline,
                "the stand-in never reached its hold"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        let kill = Command::new("kill").args(["-9", &pid]).output().unwrap();
        assert!(kill.status.success(), "{}", stderr(&kill));
        send.join().unwrap()
    });
    assert!(
        matches!(
            &first,
            Err(Refusal::Exit {
                verb: "send",
                status: None,
                ..
            })
        ),
        "{first:?}"
    );
    let mailbox = w
        .root
        .join("tmp")
        .join("lane-mail")
        .join(ITEM)
        .join("to-lane.jsonl");
    let rows = |mailbox: &Path| -> Vec<Value> {
        std::fs::read_to_string(mailbox)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    };
    let landed = rows(&mailbox);
    assert_eq!(landed.len(), 1, "the append landed before the death");
    assert_eq!(landed[0]["delivery_id"], "op-1");
    let again =
        Mailbox::new(hold()).send_directive(ITEM, Some(&w.root), false, &text, Some("op-1"), None);
    assert_eq!(
        again,
        Ok(Sent::Repeated {
            id: landed[0]["id"].as_str().unwrap().to_owned()
        })
    );
    assert_eq!(rows(&mailbox), landed, "one envelope");
    // Another operation's send lands beside it.
    let other =
        Mailbox::new(hold()).send_directive(ITEM, Some(&w.root), false, &text, Some("op-2"), None);
    assert!(matches!(other, Ok(Sent::Mailbox { .. })), "{other:?}");
    assert_eq!(rows(&mailbox).len(), 2);
}

/// This host's clock: the mailbox stamps and judges its repeats on it.
fn wall() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// The two owner-notice senders through the real mailbox: the owner alert
/// and a closed intent's notice each land once, and the mailbox's refusal
/// of a repeat, the same envelope inside the minute or the same text inside
/// the day, reads as sent to both, so neither sends the owner the same
/// words again; a refusal by the program's own key reads as unsent.
#[test]
fn an_owner_notice_lands_once_and_both_senders_read_its_repeats_as_sent() {
    let w = world(&isolated_program(&real_lane_mail()), 20);
    let owner_box = w.root.join("tmp/lane-mail/overseer/to-overseer.jsonl");
    let notices = |text: &str| -> Vec<Value> {
        std::fs::read_to_string(&owner_box)
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .filter(|e| e["kind"] == "notice" && e["to"] == "owner" && e["text"] == text.trim_end())
            .collect()
    };
    let alert = |text: &str| owner_alert::send(&w.settings, "alerts/gap.notice", text);
    let gap = "the overseer context gap stands\n";
    assert_eq!(alert(gap), Ok(()));
    assert_eq!(notices(gap).len(), 1, "the alert landed");
    assert_eq!(alert(gap), Ok(()), "a repeat inside the minute is sent");
    assert_eq!(notices(gap).len(), 1);
    // The landed notice an hour old: the same text again is the day's repeat.
    let aged: Vec<String> = std::fs::read_to_string(&owner_box)
        .unwrap()
        .lines()
        .map(|l| {
            let mut e: Value = serde_json::from_str(l).unwrap();
            if e["text"] == gap.trim_end() {
                e["at"] = json!(agent_runtime::clock::iso_utc(wall() - 3600));
            }
            e.to_string()
        })
        .collect();
    std::fs::write(&owner_box, aged.join("\n") + "\n").unwrap();
    assert_eq!(alert(gap), Ok(()), "a repeat inside the day is sent");
    assert_eq!(notices(gap).len(), 1);

    // Two closed intents whose owners are gone owe the same words: the
    // reconcile sends the first, and the second is the minute's repeat.
    let state = w.root.join(FLEET_FILE_NAME);
    let failed = "the transfer job failed";
    let intent = |id: &str| {
        json!({
            "id": id, "op": "request-transfer", "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "completed_at": "2026-01-29T15:21:00Z",
            "outcome": "failed",
            "notice": {"key": "job-launch-failed", "text": failed, "owner": "owed"}
        })
    };
    let plant = |intents: Value| {
        let mut fleet: Value =
            serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
        fleet["lanes"] = json!([]);
        fleet["intents"] = intents;
        std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    };
    let reconcile = || {
        let now = wall();
        effects::reconcile(
            &state,
            &w.settings,
            &Env {
                now_secs: now,
                now_nanos: u128::from(now) * 1_000_000_000,
                nonce: 0,
                owner: None,
            },
            Locking::FLOCK,
            &SystemClock,
        )
        .unwrap();
        let fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
        fleet["intents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["notice"]["owner"].as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>()
    };
    plant(json!([
        intent("request-transfer:overseer:3:1-1"),
        intent("request-transfer:overseer:3:1-2")
    ]));
    assert_eq!(reconcile(), vec!["sent", "sent"]);
    assert_eq!(notices(failed).len(), 1, "one landed");

    // The overseer mailbox behind a symlink: the program refuses every
    // write by its own key, before the append.
    let mailboxes = w.root.join("tmp/lane-mail");
    std::fs::rename(mailboxes.join("overseer"), mailboxes.join("moved")).unwrap();
    std::os::unix::fs::symlink("moved", mailboxes.join("overseer")).unwrap();
    let refused = alert("a new condition\n");
    assert!(
        refused
            .as_ref()
            .is_err_and(|e| e.contains("mailbox-unsafe")),
        "{refused:?}"
    );
    plant(json!([intent("request-transfer:overseer:3:1-3")]));
    let marks = reconcile();
    assert!(marks[0].starts_with("unsent:notice: status=2"), "{marks:?}");
}

/// A program that exits nonzero, one whose header is not one, one that
/// stops short of its receipts, one naming another lane, one that never
/// answers and one that never starts each refuse the batched read by its
/// typed cause with no lane drained, the last two apart; one that prints
/// the first lane whole and exits on the second answers for the first
/// alone. Through the duty on the runner the nonzero exit is
/// `watch-step-failed step=mail` once, the next refused turn under the
/// runner's repeat rule (`watch_core`'s row), with no row written.
#[test]
fn a_refused_read_stops_the_turn_with_its_cause_and_reads_no_box_as_empty() {
    let w = world(&hold(), 20);
    let request = w.root.join("request");
    let drain = |item: &str| Drain {
        item: item.into(),
        after: 0,
        root: w.root.clone(),
    };
    let lanes = vec![drain(ITEM)];
    let exit = w.script(
        "lm-exit",
        "#!/bin/bash\necho 'lane-mail: file-unreadable=/x/to-overseer.jsonl' >&2\nexit 2\n",
    );
    let header = w.script(
        "lm-header",
        "#!/bin/bash\necho item=KEN-1\necho 'first=a count=1'\n",
    );
    let short = w.script(
        "lm-short",
        "#!/bin/bash\necho item=KEN-1\necho 'count=1 first=a'\necho '{\"id\":\"a\",\"kind\":\"notice\"}'\n",
    );
    let other = w.script(
        "lm-other",
        "#!/bin/bash\necho item=KEN-2\necho 'count=0 first='\necho 'receipts cursor=0 count=0 first='\n",
    );
    let silent = w.script("lm-silent", "#!/bin/bash\nsleep 30\n");
    type Check = Box<dyn Fn(&Refusal) -> bool>;
    let rows: Vec<(&str, PathBuf, Check)> = vec![
        (
            "exit",
            exit.clone(),
            Box::new(|r| {
                matches!(r, Refusal::Exit { verb: "drain-many", status: Some(2), keyed: Some(k), .. }
                    if k == "file-unreadable=/x/to-overseer.jsonl")
            }),
        ),
        (
            "header",
            header,
            Box::new(|r| {
                matches!(
                    r,
                    Refusal::Reply {
                        cause: "header",
                        ..
                    }
                )
            }),
        ),
        (
            "short",
            short,
            Box::new(|r| matches!(r, Refusal::Reply { cause: "short", .. })),
        ),
        (
            "other lane",
            other,
            Box::new(|r| matches!(r, Refusal::Reply { cause: "item", .. })),
        ),
        (
            "silent",
            silent,
            Box::new(|r| {
                matches!(
                    r,
                    Refusal::Unanswered {
                        verb: "drain-many",
                        ..
                    }
                )
            }),
        ),
        (
            "absent",
            w.root.join("no-such-lane-mail"),
            Box::new(|r| {
                matches!(
                    r,
                    Refusal::NotStarted {
                        verb: "drain-many",
                        ..
                    }
                )
            }),
        ),
    ];
    for (name, cli, check) in rows {
        let batch = Mailbox::new(cli)
            .bounded(secs(1))
            .drain_many(&request, &lanes);
        assert!(batch.read.is_empty(), "{name}: read as {:?}", batch.read);
        match batch.refused {
            Some(refusal) => assert!(check(&refusal), "{name}: {refusal:?}"),
            None => panic!("{name}: not refused"),
        }
    }
    // The first lane whole, the second refused: the first stands, the
    // refusal is the second's.
    let partial = w.script(
        "lm-partial",
        "#!/bin/bash\necho item=KEN-1\necho 'count=1 first=a'\necho '{\"id\":\"a\",\"kind\":\"notice\"}'\necho 'receipts cursor=0 count=0 first='\necho 'lane-mail: cursor-invalid=/x/to-lane.cursor' >&2\nexit 2\n",
    );
    let batch = Mailbox::new(partial)
        .bounded(secs(1))
        .drain_many(&request, &[drain(ITEM), drain("KEN-2")]);
    assert_eq!(batch.read.len(), 1, "{batch:?}");
    assert_eq!(batch.read[0].envelopes[0].id(), "a");
    assert!(
        matches!(&batch.refused, Some(Refusal::Exit { status: Some(2), keyed: Some(k), .. })
            if k == "cursor-invalid=/x/to-lane.cursor"),
        "{batch:?}"
    );
    // Through the duty: the turn stops, the line says so, no row moves.
    let w = world(&exit, 20);
    w.plant(ITEM, "to-overseer.jsonl", &notice("n-1", ITEM, "Rebased."));
    let clock = FakeClock::new();
    let identity = me();
    let ended = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
        clock.await_sleepers(2);
        assert_eq!(w.log(), ["EVENT watch-step-failed step=mail count=1"]);
        clock.pass(secs(20));
        assert_eq!(w.log(), ["EVENT watch-step-failed step=mail count=1"]);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(w.baseline().rows, Vec::new(), "no box read, no row moved");
}

/// A lane's notice is one line with its text and the two rows on the first
/// turn; the next full turn with the same box is no line and no change; a
/// second notice is one more line and the row moved to it.
#[test]
fn an_unchanged_box_emits_no_line_and_asks_no_change() {
    let w = world(&hold(), 20);
    w.plant(ITEM, "to-overseer.jsonl", &notice("n-1", ITEM, "Rebased."));
    let clock = FakeClock::new();
    let mut duty = w.duty();
    let mut baseline = Baseline::default();
    let start = Instant::now();
    fn tick<'a>(baseline: &'a Baseline, clock: &'a FakeClock, start: Instant, at: u64) -> Tick<'a> {
        Tick {
            duty: Duty::Mail,
            now: start + secs(at),
            wall: WALL + at,
            baseline,
            clock,
        }
    }
    let first = duty.run(&tick(&baseline, &clock, start, 0)).unwrap();
    assert_eq!(
        first.events.iter().map(Event::render).collect::<Vec<_>>(),
        ["EVENT lane-notice KEN-1 n-1", "  Rebased."]
    );
    let set = |kind: &str, identity: &str, value: &str| Change::Set {
        kind: kind.into(),
        identity: identity.into(),
        value: value.into(),
    };
    assert_eq!(
        first.changes,
        vec![
            set("lane-mail", ITEM, "1 n-1"),
            set("directive", ITEM, "0 0:0 "),
            set("lane-mail", "overseer", "0 "),
        ]
    );
    assert_eq!(first.next_due, Some(start + secs(1)), "the box poll");
    for change in first.changes {
        baseline.apply(change);
    }
    let poll = duty.run(&tick(&baseline, &clock, start, 1)).unwrap();
    assert!(
        poll.events.is_empty() && poll.changes.is_empty(),
        "{poll:?}"
    );
    let again = duty.run(&tick(&baseline, &clock, start, 20)).unwrap();
    assert!(again.events.is_empty(), "{again:?}");
    assert!(again.changes.is_empty(), "{again:?}");
    w.plant(ITEM, "to-overseer.jsonl", &notice("n-2", ITEM, "Merged."));
    let more = duty.run(&tick(&baseline, &clock, start, 40)).unwrap();
    assert_eq!(
        more.events.iter().map(Event::render).collect::<Vec<_>>(),
        ["EVENT lane-notice KEN-1 n-2", "  Merged."]
    );
    assert_eq!(more.changes, vec![set("lane-mail", ITEM, "2 n-1")]);
}

/// The owner channel on the real program: a due owner ask is closed with
/// its recommendation before the box is read, and the close is announced
/// from the box as the handler will read it; a reserved ask is left open.
#[test]
fn a_due_owner_ask_is_closed_with_its_recommendation_and_announced_from_the_box() {
    let w = world(&hold(), 20);
    // An ask whose deadline passed an hour before the fake wall, and a
    // reserved one beside it.
    w.plant(
        "overseer",
        "to-overseer.jsonl",
        &json!({"id": "a-1", "kind": "ask", "at": "2026-01-29T12:00:00Z", "from": "overseer:kendex",
            "to": "owner", "text": "Cut the scanner?", "options": ["cut", "keep"], "recommend": "cut",
            "wait": 120, "deadline": "2026-01-29T14:00:00Z"}),
    );
    w.plant(
        "overseer",
        "to-overseer.jsonl",
        &json!({"id": "a-2", "kind": "ask", "at": "2026-01-29T12:00:00Z", "from": "overseer:kendex",
            "to": "owner", "text": "Ship it?", "options": ["yes", "no"], "reserved": true,
            "wait": 120, "deadline": "2026-01-29T14:00:00Z"}),
    );
    let clock = FakeClock::new();
    let identity = me();
    let ended = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
        clock.await_sleepers(2);
    });
    assert!(ended.is_ok(), "{ended:?}");
    let log = w.log();
    let answer = log
        .iter()
        .find_map(|l| l.strip_prefix("EVENT owner-ask-resolved a-1 by=default id="))
        .unwrap_or_else(|| panic!("{log:?}"));
    assert_eq!(
        log,
        [
            format!("EVENT owner-ask-resolved a-1 by=default id={answer}"),
            "  cut".to_owned(),
            "EVENT owner-ask-closed a-1 by=default".to_owned(),
        ]
    );
    let pending = w.lane_mail(&[
        "pending",
        "--item",
        "overseer",
        "--root",
        w.root.to_str().unwrap(),
        "--to",
        "owner",
    ]);
    let open: Vec<Value> = String::from_utf8_lossy(&pending.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(
        open.iter()
            .map(|a| a["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["a-2"],
        "the reserved ask stays open"
    );
}

/// The wake's slot. The real program on the fixture: a directive in the
/// lane's box and a note in the lead's set one row each with the newest id
/// on the first turn; a poll and a full turn with no news change nothing; a
/// note landing between full turns moves the lead's row on the poll, a
/// second directive the lane's on the next full turn; the handler's and the
/// lane's own `inbox` move the cursors, which the next full turn reads and
/// clears both rows; the box itself is never written by the duty.
#[test]
fn the_unread_row_stands_with_the_newest_id_until_the_target_s_own_read_clears_it() {
    let w = world(&hold(), 20);
    w.plant(
        ITEM,
        "to-lane.jsonl",
        &directive("d-1", "2026-01-29T15:19:00Z", "Rebase onto main."),
    );
    w.plant("overseer", "to-lane.jsonl", &note("n-1", "Hold KEN-7."));
    let clock = FakeClock::new();
    let mut duty = w.duty();
    let mut baseline = Baseline::default();
    let start = Instant::now();
    fn tick<'a>(baseline: &'a Baseline, clock: &'a FakeClock, start: Instant, at: u64) -> Tick<'a> {
        Tick {
            duty: Duty::Mail,
            now: start + secs(at),
            wall: WALL + at,
            baseline,
            clock,
        }
    }
    let set = |identity: &str, value: &str| Change::Set {
        kind: UNREAD_KIND.into(),
        identity: identity.into(),
        value: value.into(),
    };
    let clear = |identity: &str| Change::Clear {
        kind: UNREAD_KIND.into(),
        identity: identity.into(),
    };
    let mut run = |baseline: &mut Baseline, at: u64| {
        let produced = duty.run(&tick(baseline, &clock, start, at)).unwrap();
        for change in produced.changes.clone() {
            baseline.apply(change);
        }
        produced
    };
    let first = run(&mut baseline, 0);
    assert!(first.changes.contains(&set(ITEM, "d-1")), "{first:?}");
    assert!(
        first.changes.contains(&set(OVERSEER_TARGET, "n-1")),
        "{first:?}"
    );
    let poll = run(&mut baseline, 1);
    assert_eq!(poll.changes, Vec::new(), "a poll with nothing landed");
    let again = run(&mut baseline, 20);
    assert_eq!(again.changes, Vec::new(), "a full turn with no news");
    // A note lands between full turns: the poll moves the lead's row.
    w.plant("overseer", "to-lane.jsonl", &note("n-2", "And KEN-8."));
    w.plant(
        ITEM,
        "to-lane.jsonl",
        &directive("d-2", "2026-01-29T15:19:30Z", "Then rebase again."),
    );
    let moved = run(&mut baseline, 21);
    assert!(
        moved.changes.contains(&set(OVERSEER_TARGET, "n-2")),
        "{moved:?}"
    );
    assert!(
        !moved.changes.iter().any(|c| matches!(c, Change::Set { identity, .. } | Change::Clear { identity, .. } if identity == ITEM)),
        "the poll reads the lead's box alone: {moved:?}"
    );
    let full = run(&mut baseline, 40);
    assert!(full.changes.contains(&set(ITEM, "d-2")), "{full:?}");
    assert_eq!(baseline.get(UNREAD_KIND, ITEM), Some("d-2"));
    assert_eq!(baseline.get(UNREAD_KIND, OVERSEER_TARGET), Some("n-2"));
    // The targets read their boxes; only their own reads move the cursors.
    assert_eq!(w.cursor(ITEM), None);
    assert_eq!(w.cursor("overseer"), None);
    w.inbox(ITEM);
    w.inbox("overseer");
    assert_eq!(w.cursor(ITEM).as_deref(), Some("2\n"));
    assert_eq!(w.cursor("overseer").as_deref(), Some("2\n"));
    let unmoved = run(&mut baseline, 41);
    assert_eq!(
        unmoved.changes,
        Vec::new(),
        "a read moves no box, so the poll reads nothing"
    );
    let read = run(&mut baseline, 60);
    assert!(
        read.changes.contains(&clear(ITEM)),
        "cleared once read: {read:?}"
    );
    assert!(
        read.changes.contains(&clear(OVERSEER_TARGET)),
        "cleared once read: {read:?}"
    );
    assert_eq!(baseline.get(UNREAD_KIND, ITEM), None);
    assert_eq!(baseline.get(UNREAD_KIND, OVERSEER_TARGET), None);
    assert_eq!(
        w.cursor(ITEM).as_deref(),
        Some("2\n"),
        "never moved by the duty"
    );
    assert_eq!(w.cursor("overseer").as_deref(), Some("2\n"));
}

/// One unreadable mailbox holds no other lane's mail, and the refused
/// lane's row stands so its mail is read once it reads again. Three lanes
/// with a notice each, the second's cursor file holding no count: the turn
/// names the second alone with the program's own key, delivers the first
/// and third with their rows and no row of the second; on the runner the
/// two lanes' lines precede `watch-step-failed step=mail count=1`; with the
/// cursor file gone the next full turn delivers the second lane's notice
/// with no failure line.
#[test]
fn one_refused_lane_among_three_delivers_the_other_two_and_is_read_again_next_turn() {
    let w = world_of(&hold(), 20, &[ITEM, "KEN-2", "KEN-3"]);
    for (item, id) in [(ITEM, "n-1"), ("KEN-2", "n-2"), ("KEN-3", "n-3")] {
        w.plant(item, "to-overseer.jsonl", &notice(id, item, "Rebased."));
    }
    let bad_cursor = w.box_file("KEN-2", "to-lane.cursor");
    std::fs::write(&bad_cursor, "x\n").unwrap();
    let clock = FakeClock::new();
    let mut duty = w.duty();
    let baseline = Baseline::default();
    let tick = Tick {
        duty: Duty::Mail,
        now: Instant::now(),
        wall: WALL,
        baseline: &baseline,
        clock: &clock,
    };
    let (produced, refused) = duty.turn(&tick).unwrap();
    assert_eq!(
        refused
            .iter()
            .map(|r| r.target.as_str())
            .collect::<Vec<_>>(),
        ["KEN-2"],
        "{refused:?}"
    );
    assert!(
        refused[0].cause.contains("cursor-invalid="),
        "the program's own key: {refused:?}"
    );
    assert_eq!(
        produced
            .events
            .iter()
            .map(Event::render)
            .collect::<Vec<_>>(),
        [
            "EVENT lane-notice KEN-1 n-1",
            "  Rebased.",
            "EVENT lane-notice KEN-3 n-3",
            "  Rebased.",
        ]
    );
    let identities = |changes: &[Change]| -> Vec<String> {
        changes
            .iter()
            .filter_map(|c| match c {
                Change::Set { kind, identity, .. } if kind == "lane-mail" => Some(identity.clone()),
                Change::Set { .. } | Change::Clear { .. } | Change::Pass { .. } => None,
            })
            .collect()
    };
    assert_eq!(
        identities(&produced.changes),
        ["KEN-1", "KEN-3", "overseer"],
        "no row of the refused lane: {:?}",
        produced.changes
    );
    // Through the runner: the lines, then the failure; the cursor file
    // gone, the next full turn reads the lane.
    let identity = me();
    let ended = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
        clock.await_sleepers(2);
        assert_eq!(
            w.log(),
            [
                "EVENT lane-notice KEN-1 n-1",
                "  Rebased.",
                "EVENT lane-notice KEN-3 n-3",
                "  Rebased.",
                "EVENT watch-step-failed step=mail count=1",
            ]
        );
        assert_eq!(w.baseline().get("lane-mail", "KEN-2"), None);
        std::fs::remove_file(&bad_cursor).unwrap();
        clock.pass(secs(20));
        assert_eq!(
            w.log()[5..],
            ["EVENT lane-notice KEN-2 n-2", "  Rebased."],
            "read again, no failure line"
        );
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(w.baseline().get("lane-mail", "KEN-2"), Some("1 n-2"));
}

/// The one-second poll between full turns reads the overseer box alone and
/// ends no lane's failure count. Three lanes, the second's cursor holding
/// no count, 60 one-second slices under `ORCH_OVERSEER_MARK_REPEAT=3`: the
/// full turns at 0, 20, 40 and 60 s are failures 1 to 4, said at the first
/// and the third; the polls between them judge no lane and move the count
/// neither way.
#[test]
fn a_standing_refused_lane_is_said_on_the_mark_repeat_rule_across_polls() {
    let w = world_with(
        &hold(),
        20,
        &[ITEM, "KEN-2", "KEN-3"],
        &[("ORCH_OVERSEER_MARK_REPEAT", "3")],
    );
    for (item, id) in [(ITEM, "n-1"), ("KEN-2", "n-2"), ("KEN-3", "n-3")] {
        w.plant(item, "to-overseer.jsonl", &notice(id, item, "Rebased."));
    }
    std::fs::write(w.box_file("KEN-2", "to-lane.cursor"), "x\n").unwrap();
    let clock = FakeClock::new();
    let identity = me();
    let ended = run_driven(w.runner(&clock), &clock, &w.paths, &identity, || {
        clock.await_sleepers(2);
        for _ in 0..60 {
            clock.pass(secs(1));
        }
    });
    assert!(ended.is_ok(), "{ended:?}");
    let failures: Vec<String> = w
        .log()
        .into_iter()
        .filter(|l| l.starts_with("EVENT watch-step-failed"))
        .collect();
    assert_eq!(
        failures,
        [
            "EVENT watch-step-failed step=mail count=1",
            "EVENT watch-step-failed step=mail count=3",
        ],
        "four refused full turns, said at the first and the third"
    );
    assert_eq!(w.baseline().get("lane-mail", "KEN-2"), None);
}

/// A lane launched on another provider than the fleet's settings name (an
/// `@host` preference entry) has its mail on that host. Two providers, the
/// fleet's (`p1`, holding nothing for the lane) as the client's default and
/// the record's (`p2`, holding the lane's mailbox): the lane's notice is
/// delivered, and every read went to `p2`.
#[test]
fn a_hosted_lanes_mail_is_drained_under_the_host_its_record_names() {
    let side = tempfile::tempdir().unwrap();
    let side = std::fs::canonicalize(side.path()).unwrap();
    let provider = |name: &str, holds: bool| -> PathBuf {
        let log = side.join(format!("{name}.log"));
        let (cat, touch) = if holds {
            ("[ -f \"$4\" ] || exit 2; exec cat -- \"$4\"", "exit 0")
        } else {
            ("exit 2", "echo \"$0: no-sandbox item=$3\" >&2; exit 1")
        };
        let text = format!(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1\" in\n  capabilities) printf 'kind=ssh\\tlaunch=ssh\\tchannel=mailbox\\tfiles=verb\\tstatus=verb\\tstop=verb\\trelaunch=resume\\tpark=none\\taccounts=none\\tpool=plan\\tland=lane\\tpane=local\\n' ;;\n  cat) {cat} ;;\n  touch) {touch} ;;\n  list) exit 0 ;;\n  *) exit 64 ;;\nesac\n",
            log.display()
        );
        let path = side.join(name);
        write_executable(&path, text);
        path
    };
    let fleet_default = provider("p1", false);
    let record_host = provider("p2", true);
    // The client as the duty starts it, the fleet's provider its default.
    let client = side.join("lane-mail");
    write_executable(
        &client,
        format!(
            "#!/bin/sh\n: \"${{ORCH_LANE_HOST:={}}}\"\nexport ORCH_LANE_HOST\nexec {} \"$@\"\n",
            fleet_default.display(),
            hold().display()
        ),
    );
    let w = world(&client, 20);
    let remote = w.root.join("remote").join(ITEM);
    let dir = remote.join("tmp").join("lane-mail").join(ITEM);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("to-overseer.jsonl"),
        format!("{}\n", notice("n-1", ITEM, "Rebased.")),
    )
    .unwrap();
    let state = w.root.join(FLEET_FILE_NAME);
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["lanes"][0]["host"] = json!(record_host.display().to_string());
    fleet["lanes"][0]["kind"] = json!("ssh");
    fleet["lanes"][0]["mail_root"] = json!(remote.display().to_string());
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let clock = FakeClock::new();
    let mut duty = w.duty();
    let baseline = Baseline::default();
    let tick = Tick {
        duty: Duty::Mail,
        now: Instant::now(),
        wall: WALL,
        baseline: &baseline,
        clock: &clock,
    };
    let (produced, refused) = duty.turn(&tick).unwrap();
    assert!(refused.is_empty(), "{refused:?}");
    assert_eq!(
        produced
            .events
            .iter()
            .map(Event::render)
            .collect::<Vec<_>>(),
        ["EVENT lane-notice KEN-1 n-1", "  Rebased."]
    );
    let log =
        |name: &str| std::fs::read_to_string(side.join(format!("{name}.log"))).unwrap_or_default();
    assert_eq!(log("p1"), "", "no read under the fleet's provider");
    assert!(log("p2").contains("to-overseer.jsonl"), "{}", log("p2"));
}
