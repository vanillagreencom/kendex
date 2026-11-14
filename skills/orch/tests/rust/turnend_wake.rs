//! The bound controller's watch facts at its turn end: the wake that lets
//! its fleet's watch reach it, and the overseer mailbox it reads while no
//! watch holds its fleet.

use super::*;

/// A process the row holds running `sh <script> <args>`, `script` a loop
/// that only sleeps, so its command line stays as the row spelled it.
fn running_script(script: &Path, args: &[&str]) -> Owned {
    fs::create_dir_all(script.parent().unwrap()).unwrap();
    fs::write(script, "while :; do sleep 1; done\n").unwrap();
    let child = std::process::Command::new("sh")
        .arg(script)
        .args(args)
        .spawn()
        .expect("sh");
    Owned(child)
}

/// The waiter `follow.sh` in `dir`, following `dir/watch.log`.
fn waiter(dir: &Path) -> Owned {
    let log = dir.join("watch.log").display().to_string();
    running_script(&dir.join("follow.sh"), &[&log, "0"])
}

/// The directory a live claim names as its watch's working directory.
fn watch_cwd(world: &TurnWorld) -> PathBuf {
    let cwd = world.root.join("watch-cwd");
    fs::create_dir_all(&cwd).unwrap();
    cwd
}

/// A turn end of the session `SESSION` under `harness` from the fleet's
/// checkout, a continued one where `continued`.
fn turn_end(
    world: &TurnWorld,
    harness: &str,
    env: &[(String, String)],
    continued: bool,
) -> TurnOut {
    let payload = json!({ "session_id": SESSION, "stop_hook_active": continued });
    world.turn(&world.checkout, harness, &[], &payload.to_string(), env)
}

/// The home's own wake setting: Jarvis's watch loop for the world's
/// checkout and the command that starts it.
fn wake_setting(world: &TurnWorld) -> Vec<(String, String)> {
    let home = regex::escape(&world.checkout.display().to_string());
    vec![
        (
            "ORCH_WAKE_PROCESS".to_owned(),
            format!("watch-loop --home {home}([[:space:]]|$)"),
        ),
        (
            "ORCH_WAKE_START".to_owned(),
            "jarvis-session watch --home HOME".to_owned(),
        ),
    ]
}

/// A bound controller nothing can wake is held at its turn end with the
/// command that starts its wake, and on a continued turn told it and
/// passed: a live watch is followed by a waiter on the watch's log (only
/// through its own log where a succession restarted the watch), a home
/// with no live watch by the process its setting names, Jarvis's watch
/// loop; a Jarvis session the record binds as its home's overseer is
/// checked as the binding's controller. A session no claim or setting
/// covers is woken by a single pass's exit and passes.
#[test]
fn an_overseer_with_no_live_wake_is_held_and_told_on_a_continued_turn() {
    type Plant = fn(&TurnWorld, &Owned) -> (Vec<Owned>, Vec<(String, String)>);
    struct Case {
        name: &'static str,
        plant: Plant,
        jarvis: bool,
        continued: bool,
        held: Option<&'static str>,
        told: bool,
    }
    const FOLLOW: &str = "sh \"[RUN_DIR]/follow.sh\" \"[RUN_DIR]/watch.log\" [NEXT_LINE]";
    let cases = [
        Case {
            name: "a live watch with no waiter",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&watch.start()),
                    &cwd,
                    "hand",
                );
                (Vec::new(), Vec::new())
            },
            jarvis: false,
            continued: false,
            held: Some(FOLLOW),
            told: false,
        },
        Case {
            name: "a live watch with its waiter",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&watch.start()),
                    &cwd,
                    "hand",
                );
                (vec![waiter(&cwd.join("tmp/waiter.a1"))], Vec::new())
            },
            jarvis: false,
            continued: false,
            held: None,
            told: false,
        },
        Case {
            name: "a live watch with no waiter, on a continued turn",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&watch.start()),
                    &cwd,
                    "hand",
                );
                (Vec::new(), Vec::new())
            },
            jarvis: false,
            continued: true,
            held: None,
            told: true,
        },
        Case {
            name: "a watch a succession restarted, its waiter on the watch's log",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&watch.start()),
                    &cwd,
                    "succession",
                );
                let log = world.fleet_path().with_file_name("oversee-watch.log");
                fs::write(&log, "").unwrap();
                let dir = cwd.join("tmp/waiter.b2");
                fs::create_dir_all(&dir).unwrap();
                std::os::unix::fs::symlink(&log, dir.join("watch.log")).unwrap();
                (vec![waiter(&dir)], Vec::new())
            },
            jarvis: false,
            continued: false,
            held: None,
            told: false,
        },
        Case {
            name: "a watch a succession restarted, its waiter on another log",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&watch.start()),
                    &cwd,
                    "succession",
                );
                let log = world.fleet_path().with_file_name("oversee-watch.log");
                fs::write(&log, "").unwrap();
                let dir = cwd.join("tmp/waiter.c3");
                fs::create_dir_all(&dir).unwrap();
                fs::write(dir.join("watch.log"), "").unwrap();
                (vec![waiter(&dir)], Vec::new())
            },
            jarvis: false,
            continued: false,
            held: Some("Link [RUN_DIR]/watch.log to "),
            told: false,
        },
        Case {
            name: "the home's watch loop absent",
            plant: |world, _| (Vec::new(), wake_setting(world)),
            jarvis: false,
            continued: false,
            held: Some("jarvis-session watch --home HOME"),
            told: false,
        },
        Case {
            name: "the home's watch loop running",
            plant: |world, _| {
                let home = world.checkout.display().to_string();
                let script = world.root.join("jarvis/watch-loop");
                let held = running_script(&script, &["--home", &home]);
                (vec![held], wake_setting(world))
            },
            jarvis: false,
            continued: false,
            held: None,
            told: false,
        },
        Case {
            name: "no live watch and no setting",
            plant: |_, _| (Vec::new(), Vec::new()),
            jarvis: false,
            continued: false,
            held: None,
            told: false,
        },
        Case {
            name: "a Jarvis session bound as its home's overseer, its watch loop absent",
            plant: |world, _| (Vec::new(), wake_setting(world)),
            jarvis: true,
            continued: false,
            held: Some("jarvis-session watch --home HOME"),
            told: false,
        },
    ];
    for case in cases {
        let world = TurnWorld::new();
        let mut env = if case.jarvis {
            jarvis_on(&world, true).0
        } else {
            let (env, account) = claude_on(&world, PANE);
            world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
            env
        };
        let watch = Owned::sleep();
        let (held_processes, setting) = (case.plant)(&world, &watch);
        env.extend(setting);
        let out = turn_end(&world, "claude", &env, case.continued);
        let name = case.name;
        let keyed = out.keyed();
        if let Some(start) = case.held {
            assert_eq!(out.code, 2, "{name}: {}", out.stderr);
            assert_eq!(keyed, ["wake=unarmed"], "{name}: {}", out.stderr);
            assert!(out.stderr.contains(start), "{name}: {}", out.stderr);
        } else {
            assert_eq!(out.code, 0, "{name}: {}", out.stderr);
            let wake: Vec<_> = keyed
                .iter()
                .filter(|line| line.starts_with("wake"))
                .collect();
            if case.told {
                assert_eq!(wake, [&"wake=unarmed"], "{name}: {}", out.stderr);
                assert!(out.stderr.contains(FOLLOW), "{name}: {}", out.stderr);
            } else {
                assert!(wake.is_empty(), "{name}: {}", out.stderr);
            }
        }
        drop(held_processes);
        drop(watch);
    }
}

/// What the wake check cannot judge is said under its own key and the turn
/// end goes on to its other checks; the notice travels into a later
/// refusal's text where the harness reads that text from stdout.
#[test]
fn each_wake_gap_is_reported_under_its_key() {
    type Plant = fn(&TurnWorld, &Owned) -> Vec<(String, String)>;
    struct Case {
        name: &'static str,
        plant: Plant,
        key: fn(&TurnWorld) -> String,
        cause: &'static str,
    }
    let cases = [
        Case {
            name: "a claim that is no readable file",
            plant: |world, _| {
                fs::create_dir_all(claim_path(world)).unwrap();
                Vec::new()
            },
            key: |world| format!("wake-record={}", claim_path(world).display()),
            cause: "",
        },
        Case {
            name: "a live claim naming no working directory",
            plant: |world, watch| {
                let start = watch.start();
                plant_claim(
                    world,
                    u64::from(watch.pid()),
                    Some(&start),
                    Path::new(""),
                    "hand",
                );
                Vec::new()
            },
            key: |world| format!("wake-record={}", claim_path(world).display()),
            cause: "the live watch claim names no cwd",
        },
        Case {
            name: "a running claim with no start to judge it by",
            plant: |world, watch| {
                let cwd = watch_cwd(world);
                plant_claim(world, u64::from(watch.pid()), None, &cwd, "hand");
                Vec::new()
            },
            key: |world| format!("wake-record={}", claim_path(world).display()),
            cause: "start-missing",
        },
        Case {
            name: "a wake pattern with no start command",
            plant: |_, _| vec![("ORCH_WAKE_PROCESS".to_owned(), "watch-loop".to_owned())],
            key: |_| "wake-setting=ORCH_WAKE_START".to_owned(),
            cause: "ORCH_WAKE_PROCESS is set but no start command is set",
        },
        Case {
            name: "a wake pattern that does not parse",
            plant: |_, _| {
                vec![
                    ("ORCH_WAKE_PROCESS".to_owned(), "watch-loop (".to_owned()),
                    ("ORCH_WAKE_START".to_owned(), "start it".to_owned()),
                ]
            },
            key: |_| "wake-process=watch-loop (".to_owned(),
            cause: "unclosed group",
        },
    ];
    for case in cases {
        let world = TurnWorld::new();
        let (mut env, account) = claude_on(&world, PANE);
        world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
        let watch = Owned::sleep();
        env.extend((case.plant)(&world, &watch));
        let out = turn_end(&world, "claude", &env, false);
        let name = case.name;
        let key = (case.key)(&world);
        assert_eq!(out.code, 0, "{name}: {}", out.stderr);
        assert_eq!(out.keyed(), [key.as_str()], "{name}: {}", out.stderr);
        assert!(out.stderr.contains(case.cause), "{name}: {}", out.stderr);
        // The turn end went on: the overseer's gap record was written.
        assert!(box_record(&world).is_some(), "{name}: no context record");
        drop(watch);
    }

    // A gap under a later refusal: a Copilot overseer whose compaction its
    // box flags is held, and the reason it reads names the wake's gap too.
    let world = TurnWorld::new();
    let (env, account) = copilot_on(&world, PANE);
    world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
    fs::create_dir_all(claim_path(&world)).unwrap();
    fs::create_dir_all(overseer_box(&world)).unwrap();
    fs::write(
        overseer_box(&world).join("compaction.json"),
        json!({ "session_id": SESSION }).to_string(),
    )
    .unwrap();
    let out = turn_end(&world, "copilot", &env, false);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let answer: Value = serde_json::from_str(&out.stdout).unwrap();
    let reason = answer["reason"].as_str().unwrap();
    let key = format!(
        "\nlane-mail-check: wake-record={}\n",
        claim_path(&world).display()
    );
    assert!(
        reason.starts_with("lane-mail-check: compacted=auto\n") && reason.contains(&key),
        "{reason}"
    );
}

/// The mailbox package's own reader, which the mail rows run.
fn lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../mailbox/scripts/lane-mail")
}

/// A note in the checkout's overseer mailbox, as `lane-mail peer send
/// --repo` lands one there.
fn note_overseer(world: &TurnWorld, id: &str) {
    let mailbox = overseer_box(world);
    fs::create_dir_all(&mailbox).unwrap();
    let line = json!({"id": id, "kind": "directive", "at": "2026-11-12T00:00:00Z", "from": "owner", "text": "review the peer's pull request"});
    fs::write(mailbox.join("to-lane.jsonl"), format!("{line}\n")).unwrap();
}

/// The count the overseer mailbox's cursor stands at, none before a read.
fn overseer_cursor(world: &TurnWorld) -> String {
    fs::read_to_string(overseer_box(world).join("to-lane.cursor"))
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// The watch's claim beside the fleet record, naming `pid` under `start`
/// (none where `None`), as the watch writes it.
fn plant_claim(world: &TurnWorld, pid: u64, start: Option<&str>, cwd: &Path, origin: &str) {
    let fleet = world.fleet_path();
    let mut text = format!("pid={pid}\n");
    if let Some(start) = start {
        text.push_str(&format!("start={start}\n"));
    }
    text.push_str(&format!(
        "state={}\npane={PANE}\norigin={origin}\nscript=orch-runtime\ncwd={}\n",
        fleet.display(),
        cwd.display()
    ));
    fs::write(claim_path(world), text).unwrap();
}

fn claim_path(world: &TurnWorld) -> PathBuf {
    world.fleet_path().with_file_name("oversee-watch.pid")
}

/// The checkout's overseer mailbox is read at a turn end by the session
/// the fleet record binds and by no other, and only while no live watch
/// holds the fleet: the watch reads that box itself. A claim whose process
/// cannot be judged refuses rather than reading or passing the box.
#[test]
fn the_overseer_mailbox_is_handed_to_its_bound_reader_only_while_no_watch_holds_the_fleet() {
    struct Case {
        name: &'static str,
        bound: bool,
        claim: Option<(bool, bool)>,
        handed: bool,
        fleet_state: bool,
    }
    let cases = [
        Case {
            name: "no watch",
            bound: true,
            claim: None,
            handed: true,
            fleet_state: false,
        },
        Case {
            name: "a live watch holds the fleet",
            bound: true,
            claim: Some((true, true)),
            handed: false,
            fleet_state: false,
        },
        Case {
            name: "a watch that has ended",
            bound: true,
            claim: Some((false, true)),
            handed: true,
            fleet_state: false,
        },
        Case {
            name: "a running claim with no start to judge it by",
            bound: true,
            claim: Some((true, false)),
            handed: false,
            fleet_state: true,
        },
        Case {
            name: "a session the fleet record does not bind",
            bound: false,
            claim: None,
            handed: false,
            fleet_state: false,
        },
    ];
    for case in cases {
        let world = TurnWorld::new();
        let (mut env, account) = claude_on(&world, PANE);
        env.push((
            "LANE_MAIL_CLI".to_owned(),
            lane_mail().display().to_string(),
        ));
        let pane = if case.bound { PANE } else { "%9" };
        let session = if case.bound { SESSION } else { "native-other" };
        world.plant_fleet(world.controller(pane, "claude", &account, session));
        note_overseer(&world, "n1");
        let watch = Owned::sleep();
        // A live watch's controller follows it, so its wake holds nothing.
        let mut followed = None;
        if let Some((live, started)) = case.claim {
            let pid = if live {
                u64::from(watch.pid())
            } else {
                GONE_PID
            };
            let start = started.then(|| watch.start());
            plant_claim(&world, pid, start.as_deref(), &world.checkout, "hand");
            followed = Some(waiter(&world.checkout.join("tmp/waiter.m1")));
        }
        let out = stop(&world, &env, None);
        drop(followed);
        let keyed = out.keyed();
        if case.handed {
            assert_eq!(out.code, 2, "{}: {}", case.name, out.stderr);
            assert_eq!(
                keyed.first(),
                Some(&"unread=1"),
                "{}: {}",
                case.name,
                out.stderr
            );
            assert!(
                out.stderr
                    .contains("a peer repository or the owner sent these messages there")
                    && out.stderr.contains("review the peer's pull request"),
                "{}: {}",
                case.name,
                out.stderr
            );
            assert_eq!(overseer_cursor(&world), "1", "{}", case.name);
        } else if case.fleet_state {
            assert_eq!(out.code, 2, "{}: {}", case.name, out.stderr);
            let want = format!("fleet-state={}", claim_path(&world).display());
            assert_eq!(keyed, vec![want.as_str()], "{}: {}", case.name, out.stderr);
            assert!(
                out.stderr.contains("start-missing"),
                "{}: {}",
                case.name,
                out.stderr
            );
            assert_eq!(overseer_cursor(&world), "", "{}", case.name);
        } else {
            assert_eq!(out.code, 0, "{}: {}", case.name, out.stderr);
            assert!(
                !keyed.iter().any(|line| line.starts_with("unread=")),
                "{}: {}",
                case.name,
                out.stderr
            );
            assert_eq!(overseer_cursor(&world), "", "{}", case.name);
        }
        assert!(
            world
                .tmux_calls()
                .iter()
                .all(|call| call.starts_with("display-message -p")),
            "{}: {:?}",
            case.name,
            world.tmux_calls()
        );
        drop(watch);
    }
}

/// The overseer's finished tool call that hands its mailbox over carries
/// the call's own notice ahead of the mail, once: the gap is recorded told,
/// so the next call hands the mail alone.
#[test]
fn an_overseer_tool_call_handing_its_mail_over_carries_its_notice_once() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push((
        "LANE_MAIL_CLI".to_owned(),
        lane_mail().display().to_string(),
    ));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    note_overseer(&world, "n1");
    let elsewhere = world
        .root
        .join(format!("accounts/other/projects/p/{SESSION}.jsonl"));
    let elsewhere = transcript(&elsewhere, &[claude_usage(50_000)]);
    let gap = format!("transcript-unowned={}", elsewhere.display());
    let payload =
        json!({ "session_id": SESSION, "transcript_path": elsewhere.display().to_string() });
    let call = || {
        world.turn(
            &world.checkout,
            "claude",
            &["deliver"],
            &payload.to_string(),
            &env,
        )
    };
    let out = call();
    assert_eq!(out.code, 0, "{}", out.stderr);
    let lines = handed(&out);
    assert_eq!(lines.first(), Some(&gap), "{}", out.stdout);
    assert_eq!(
        lines.iter().filter(|line| **line == gap).count(),
        1,
        "{}",
        out.stdout
    );
    assert!(lines.contains(&"unread=1".to_owned()), "{}", out.stdout);
    assert_eq!(out.keyed(), [gap.as_str()], "{}", out.stderr);
    let told = fs::read_to_string(overseer_box(&world).join("context-told")).ok();
    let want = format!("{SESSION}\tlane-mail-check: {gap}\n");
    assert_eq!(told.as_deref(), Some(want.as_str()));
    assert_eq!(overseer_cursor(&world), "1");
    // A second note: the next call hands it without the gap told above.
    let line = json!({"id": "n2", "kind": "directive", "at": "2026-11-12T00:00:01Z", "from": "owner", "text": "merge the peer's fix"});
    let inbox = overseer_box(&world).join("to-lane.jsonl");
    let mut text = fs::read_to_string(&inbox).unwrap();
    text.push_str(&format!("{line}\n"));
    fs::write(&inbox, text).unwrap();
    let out = call();
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(handed(&out).first().map(String::as_str), Some("unread=1"));
    assert!(!handed(&out).contains(&gap), "{}", out.stdout);
    assert!(
        out.stdout.contains("merge the peer's fix"),
        "{}",
        out.stdout
    );
    assert_eq!(overseer_cursor(&world), "2");
}

/// The bound overseer's pre-tool call never reads its mailbox: a halt a
/// peer or the owner left there halts no one, by the reader's own
/// contract, so the call passes and the box stays unread.
#[test]
fn an_overseer_pre_tool_call_never_reads_a_halt_from_its_mailbox() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push((
        "LANE_MAIL_CLI".to_owned(),
        lane_mail().display().to_string(),
    ));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    let mailbox = overseer_box(&world);
    fs::create_dir_all(&mailbox).unwrap();
    let line = json!({"id": "h1", "kind": "directive", "at": "2026-11-12T00:00:00Z",
        "from": "owner", "text": "stop all work", "halt": true});
    fs::write(mailbox.join("to-lane.jsonl"), format!("{line}\n")).unwrap();
    let payload = json!({ "session_id": SESSION, "tool_name": "Bash",
        "tool_input": { "command": "git status" } });
    let out = world.turn(
        &world.checkout,
        "claude",
        &["halt"],
        &payload.to_string(),
        &env,
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(out.keyed().is_empty(), "{}", out.stderr);
    assert_eq!(out.stdout, "", "{}", out.stderr);
    assert_eq!(overseer_cursor(&world), "");
}
