//! The mail duty (step5-map § A7, § A8, § B rows 1, 2 and 4; decisions 31,
//! 121 Q1, Q2, 141 (4), 142 (1)): the real mailbox program on a temporary
//! checkout, read through the duty on the runner and its fake clock, and a
//! stand-in that dies between its append and its receipt. Each row names
//! the defect it catches at its doc comment.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant mailboxes and records, run the real mailbox program and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use agent_runtime::process::Identity;
use orch_runtime::mailbox::{Drain, Mailbox, Refusal, Sent};
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::FLEET_FILE_NAME;
use orch_runtime::watch::mail::{self, Config, MailDuty};
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
        std::fs::write(&path, text).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// § B rows 1 and 2. Defect: the scheduler acknowledging the overseer's box
/// on announcing (the legacy `inbox --ack`), so a note announced to a
/// controller that never handled it is read; or a directive reported read
/// on the overseer's send rather than the lane's own read. A log the
/// handoff left at line 3; a note in the overseer's box and a directive
/// 400 s old in the lane's. The first turn appends the directive's
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

/// § B row 1's crash variant. Defect: the announcement's row moving before
/// the line is on disk, so a crash between the two loses the note for the
/// successor. The baseline's temporary path is blocked, so the first run's
/// write of its row fails after the log's append: the note and its text
/// are on disk, no row stands, the run ends `watch-record`; the next run
/// prints them again and moves the row; a third prints nothing.
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

/// § B row 4. Defect: a send that appended and died before its receipt
/// repeated as a second envelope. The stand-in runs the real `send` to its
/// end, then blocks on a FIFO before relaying the receipt and is killed
/// there: the client reads a refused call, one envelope stands with the
/// operation's delivery id, and the same send again answers `Repeated`
/// naming that envelope, the mailbox still holding one.
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

/// Decision 142 (1). Defect: a refused read taken as a lane with nothing
/// new, or as an empty box. A program that exits nonzero, one whose header
/// is not one, one that stops short of its receipts, one naming another
/// lane, one that never answers and one that never starts each refuse the
/// batched read by its typed cause with no lane drained, the last two
/// apart; one that prints the first lane whole
/// and exits on the second answers for the first alone. Through the duty
/// on the runner the nonzero exit is `watch-step-failed step=mail` once,
/// the next refused turn under the runner's repeat rule (decision 156 (1),
/// `watch_core`'s row), with no row written.
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

/// Decision 141 (4). Defect: a box with nothing new emitting a line or
/// moving a row each turn, waking the session for nothing. A lane's notice
/// is one line with its text and the two rows on the first turn; the next
/// full turn with the same box is no line and no change; a second notice
/// is one more line and the row moved to it.
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
/// Defect: the duty closing a reserved ask, or announcing a close it made
/// before the mailbox holds it.
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

/// Decision 159, the wake's slot. Defect: the `unread` row set from the
/// box's count alone, so it stands after the target's own read, and the
/// wake nudges a lead or lane that has read its mail; or the lead's row
/// waiting the mail interval instead of the box poll. The real program on
/// the fixture: a directive in the lane's box and a note in the lead's set
/// one row each with the newest id on the first turn; a poll and a full
/// turn with no news change nothing; a note landing between full turns
/// moves the lead's row on the poll, a second directive the lane's on the
/// next full turn; the handler's and the lane's own `inbox` move the
/// cursors, which the next full turn reads and clears both rows; the box
/// itself is never written by the duty.
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

/// Decision 133. Defect: one unreadable mailbox holding every lane's mail,
/// or the refused lane's row moved so its mail is skipped once it reads
/// again. Three lanes with a notice each, the second's cursor file holding
/// no count: the turn names the second alone with the program's own key,
/// delivers the first and third with their rows and no row of the second;
/// on the runner the two lanes' lines precede `watch-step-failed step=mail
/// count=1`; with the cursor file gone the next full turn delivers the
/// second lane's notice with no failure line.
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

/// R-RECON F4, decision 156 (1). Defect: the one-second poll between full
/// turns, which reads the overseer box alone, ending the failure count, so
/// a lane whose read stands refused is said as a first failure on every
/// full turn (every 20 s) instead of on the first and every Nth. Three
/// lanes, the second's cursor holding no count, 60 one-second slices under
/// `ORCH_OVERSEER_MARK_REPEAT=3`: the full turns at 0, 20, 40 and 60 s are
/// failures 1 to 4, said at the first and the third; the polls between them
/// judge no lane and move the count neither way.
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
