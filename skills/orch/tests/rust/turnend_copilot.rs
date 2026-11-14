//! Process tests of a Copilot session's compaction and context reading
//! handed to the turn end. Every row runs the real `orch-runtime turn-end`
//! in a [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

const ITEM: &str = "ken-1";

const EXTENSION: &str = "80% of tokenLimit, Copilot's backgroundCompactionThreshold default";

/// The longest path the kernel takes, its closing NUL counted.
const PATH_MAX: usize = if cfg!(target_os = "macos") {
    1024
} else {
    4096
};

/// A launched Copilot lane: the checkout `root`, its launch marker under the
/// common git directory `common`, its mailbox, and the lead record of `s1`
/// under the world's home.
struct Lane {
    root: PathBuf,
    common: PathBuf,
}

impl Lane {
    fn launched(world: &TurnWorld, root: &Path, common: &Path) -> Lane {
        let lane = Lane {
            root: root.to_path_buf(),
            common: common.to_path_buf(),
        };
        fs::create_dir_all(lane.mailbox()).unwrap();
        fs::create_dir_all(lane.common.join("lane-mail")).unwrap();
        fs::write(lane.marker(), format!("{}\n", root.display())).unwrap();
        let leads = world.home.join(".cache/lane-mail/copilot-leads");
        fs::create_dir_all(&leads).unwrap();
        fs::write(leads.join("s1"), "").unwrap();
        lane
    }

    fn marker(&self) -> PathBuf {
        self.common.join("lane-mail").join(ITEM)
    }

    fn mailbox(&self) -> PathBuf {
        self.root.join("tmp/lane-mail").join(ITEM)
    }

    fn record_path(&self) -> PathBuf {
        self.mailbox().join("context.json")
    }

    /// The context record in the mailbox, `None` where none stands.
    fn record(&self) -> Option<Value> {
        let text = fs::read_to_string(self.record_path()).ok()?;
        Some(serde_json::from_str(&text).unwrap())
    }

    /// A reading of `session` below any mark, as the extension's reading
    /// before this one left it.
    fn plant_reading(&self) {
        let record = json!({"harness": "copilot", "model": null, "tokens": 1_000,
            "window": 217_600, "capacity_source": EXTENSION, "session_id": "s1",
            "pane_key": null, "gap": null, "at": "2026-11-11T00:00:00Z"});
        fs::write(self.record_path(), record.to_string()).unwrap();
    }

    /// The usage arm run from the world's root under `harness`'s install,
    /// handed a reading of `session` naming this lane's checkout.
    fn usage(
        &self,
        world: &TurnWorld,
        harness: &str,
        session: &str,
        tokens: Value,
        limit: Value,
    ) -> TurnOut {
        let payload = json!({"session_id": session, "cwd": self.root,
            "current_tokens": tokens, "token_limit": limit})
        .to_string();
        world.turn(&world.root, harness, &["usage"], &payload, &self.env(world))
    }

    /// A compaction of `s1` begun on `trigger`, through the Copilot install,
    /// run in the lane's checkout.
    fn compact(&self, world: &TurnWorld, trigger: &str) -> TurnOut {
        let payload = json!({"sessionId": "s1", "timestamp": 1, "trigger": trigger}).to_string();
        world.turn(
            &self.root,
            "copilot",
            &["compact"],
            &payload,
            &self.env(world),
        )
    }

    /// The turn end of `s1`, through the Copilot install.
    fn stop(&self, world: &TurnWorld) -> TurnOut {
        let payload = r#"{"sessionId":"s1","timestamp":1}"#;
        world.turn(&self.root, "copilot", &[], payload, &self.env(world))
    }

    /// The lane's item, and an account directory under the world's root.
    fn env(&self, world: &TurnWorld) -> Vec<(String, String)> {
        let account = world.root.join("copilot-account").display().to_string();
        vec![
            ("LANE_MAIL_ITEM".to_owned(), ITEM.to_owned()),
            ("COPILOT_HOME".to_owned(), account),
        ]
    }
}

/// The world's own checkout as a launched lane.
fn checkout_lane(world: &TurnWorld) -> Lane {
    Lane::launched(world, &world.checkout, &world.checkout.join(".git"))
}

fn git(dir: &Path, args: &[&str]) {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
}

/// A launched lane whose context record's path is two bytes inside the
/// longest path the kernel takes, its git directory kept apart and short:
/// the record stands and can be removed, while the temporary file its writer
/// replaces it through, nine bytes or more longer, cannot be made.
fn lane_at_the_path_limit(world: &TurnWorld) -> Lane {
    let record_tail = format!("/tmp/lane-mail/{ITEM}/context.json").len();
    let len = PATH_MAX - 1 - 2 - record_tail;
    let mut root = world.root.join("deep");
    while root.as_os_str().len() < len {
        let left = len - root.as_os_str().len() - 1;
        root.push("d".repeat(if left > 250 { 200 } else { left }));
    }
    fs::create_dir_all(&root).unwrap();
    let common = world.root.join("deep-git");
    git(
        &root,
        &["init", "-q", "--separate-git-dir", common.to_str().unwrap()],
    );
    for args in [
        &["config", "gc.auto", "0"][..],
        &["config", "maintenance.auto", "false"],
        &["checkout", "-q", "-b", "main"],
        &["commit", "-q", "--allow-empty", "-m", "base"],
    ] {
        git(&root, args);
    }
    let lane = Lane::launched(world, &root, &common);
    assert_eq!(lane.record_path().as_os_str().len(), PATH_MAX - 3);
    lane
}

/// A Copilot lead's context reading, handed over by its context extension,
/// is recorded silently in its launched lane's mailbox, the lane its
/// payload names whatever directory the hook runs in, with the capacity
/// Copilot compacts at, 80 percent of the token limit, so its turn end
/// judges the mark before that compaction. A reading of a session no lead
/// record names, one naming no token limit and one through another
/// harness's install are refused at exit 2 for the session timeline and
/// recorded nowhere; a session no launch made a lane passes silently.
#[test]
fn a_copilot_usage_reading_is_recorded_at_eighty_percent_of_its_limit_in_its_roles_box() {
    let world = TurnWorld::new();
    let lane = checkout_lane(&world);
    let out = lane.usage(&world, "copilot", "s1", json!(150_000), json!(272_000));
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let record = lane.record().expect("the reading is recorded");
    assert_eq!(
        [
            &record["harness"],
            &record["tokens"],
            &record["window"],
            &record["used_pct"],
            &record["capacity_source"],
            &record["session_id"],
            &record["model"],
            &record["pane_key"],
            &record["gap"],
        ],
        [
            &json!("copilot"),
            &json!(150_000),
            &json!(217_600),
            &json!(68),
            &json!(EXTENSION),
            &json!("s1"),
            &Value::Null,
            &Value::Null,
            &Value::Null,
        ]
    );
    let refused: [(&str, &str, Value, String); 3] = [
        (
            "copilot",
            "s5",
            json!(272_000),
            "session-unrecorded=s5".to_owned(),
        ),
        ("copilot", "s1", json!(0), "payload=invalid-json".to_owned()),
        (
            "claude",
            "s1",
            json!(272_000),
            format!("harness-unlisted={}", world.hooks("claude").display()),
        ),
    ];
    fs::remove_file(lane.record_path()).unwrap();
    for (harness, session, limit, keyed) in refused {
        let out = lane.usage(&world, harness, session, json!(150_000), limit);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.keyed()),
            (2, "", vec![keyed.as_str()]),
            "{}",
            out.stderr
        );
        assert_eq!(lane.record(), None, "{keyed}");
    }
    fs::remove_file(lane.marker()).unwrap();
    let out = lane.usage(&world, "copilot", "s1", json!(150_000), json!(272_000));
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    assert_eq!(lane.record(), None, "a session no launch made a lane");
}

/// A reading the record cannot take is refused at exit 2, and the earlier
/// reading, which can lie below the mark this one crossed, is removed, so
/// the next turn end reports the context unmeasured rather than judging the
/// older figure as room; where the directory takes no removal either, the
/// refusal says that the older figure still stands.
#[test]
fn a_usage_reading_the_record_cannot_take_removes_the_stale_record_and_is_refused() {
    let world = TurnWorld::new();
    let lane = lane_at_the_path_limit(&world);
    lane.plant_reading();
    let out = lane.usage(&world, "copilot", "s1", json!(199_000), json!(272_000));
    let keyed = format!("context-unrecorded={}", lane.record_path().display());
    assert_eq!(
        (out.code, out.stdout.as_str(), out.keyed()),
        (2, "", vec![keyed.as_str()]),
        "{}",
        out.stderr
    );
    assert!(
        out.stderr.contains("no earlier reading stands there now"),
        "{}",
        out.stderr
    );
    assert!(
        fs::symlink_metadata(lane.record_path()).is_err(),
        "the earlier reading is removed"
    );
    // A directory that takes neither the record nor the removal, where the
    // permission bits hold (they do not for root).
    let lane = checkout_lane(&world);
    lane.plant_reading();
    fs::set_permissions(lane.mailbox(), fs::Permissions::from_mode(0o555)).unwrap();
    let probe = lane.mailbox().join("probe");
    if fs::write(&probe, "").is_ok() {
        fs::remove_file(&probe).unwrap();
        fs::set_permissions(lane.mailbox(), fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }
    let out = lane.usage(&world, "copilot", "s1", json!(199_000), json!(272_000));
    fs::set_permissions(lane.mailbox(), fs::Permissions::from_mode(0o755)).unwrap();
    let keyed = format!("context-unrecorded={}", lane.record_path().display());
    assert_eq!(
        (out.code, out.stdout.as_str(), out.keyed()),
        (2, "", vec![keyed.as_str()]),
        "{}",
        out.stderr
    );
    assert!(
        out.stderr.contains("could not be removed either"),
        "{}",
        out.stderr
    );
    assert_eq!(lane.record().unwrap()["tokens"], json!(1_000));
}

/// A Copilot lead's automatic compaction is flagged silently in its launched
/// lane's mailbox, and its next turn end is held on that flag; a manual
/// compaction is the operator's own and flags nothing. A flag that cannot be
/// written is refused at exit 2, which Copilot shows the operator while the
/// compaction goes on.
#[test]
fn an_automatic_compaction_flags_its_box_and_a_manual_one_nothing() {
    let world = TurnWorld::new();
    let lane = checkout_lane(&world);
    let flag = lane.mailbox().join("compaction.json");
    let out = lane.compact(&world, "manual");
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    assert!(
        fs::symlink_metadata(&flag).is_err(),
        "a manual compaction flags nothing"
    );
    let out = lane.compact(&world, "auto");
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let flagged: Value = serde_json::from_str(&fs::read_to_string(&flag).unwrap()).unwrap();
    assert_eq!(
        [
            &flagged["harness"],
            &flagged["trigger"],
            &flagged["session_id"],
            &flagged["pane_key"]
        ],
        [
            &json!("copilot"),
            &json!("auto"),
            &json!("s1"),
            &Value::Null
        ]
    );
    let out = lane.stop(&world);
    assert_eq!(
        (out.code, out.keyed().first().copied()),
        (0, Some("compacted=auto")),
        "{}",
        out.stderr
    );
    // A mailbox that is no directory takes no flag.
    fs::remove_dir_all(lane.mailbox()).unwrap();
    fs::write(lane.mailbox(), "not a directory\n").unwrap();
    let out = lane.compact(&world, "auto");
    let keyed = format!("compaction-unrecorded={}", flag.display());
    assert_eq!(
        (out.code, out.stdout.as_str(), out.keyed()),
        (2, "", vec![keyed.as_str()]),
        "{}",
        out.stderr
    );
}

const PANE: &str = "%3";
const SESSION: &str = "native-1";

/// The account directory a session with no lane item runs on, and its
/// lead record of `SESSION`, empty as its session start leaves it.
fn copilot_lead(world: &TurnWorld) -> (PathBuf, PathBuf) {
    let account = world.root.join("accounts/copilot-1");
    fs::create_dir_all(&account).unwrap();
    let leads = world.home.join(".cache/lane-mail/copilot-leads");
    fs::create_dir_all(&leads).unwrap();
    fs::write(leads.join(SESSION), "").unwrap();
    (account, leads.join(SESSION))
}

/// The environment of a Copilot session on `pane` of the stand-in's
/// server, or outside tmux, on `account`.
fn copilot_env(world: &TurnWorld, pane: Option<&str>, account: &Path) -> Vec<(String, String)> {
    let mut env = pane.map(|pane| world.on_pane(pane)).unwrap_or_default();
    env.push(("COPILOT_HOME".to_owned(), account.display().to_string()));
    env
}

/// The usage arm handed a reading of `SESSION` at `tokens` of a 272000
/// limit, run in the world's checkout.
fn session_usage(world: &TurnWorld, env: &[(String, String)], tokens: u64) -> TurnOut {
    let payload = json!({"session_id": SESSION, "cwd": world.checkout,
        "current_tokens": tokens, "token_limit": 272_000})
    .to_string();
    world.turn(&world.checkout, "copilot", &["usage"], &payload, env)
}

/// An automatic compaction of `SESSION`, run in the world's checkout.
fn session_compaction(world: &TurnWorld, env: &[(String, String)]) -> TurnOut {
    let payload = json!({"sessionId": SESSION, "timestamp": 1, "trigger": "auto"}).to_string();
    world.turn(&world.checkout, "copilot", &["compact"], &payload, env)
}

/// The turn end of `SESSION`, run in the world's checkout.
fn session_stop(world: &TurnWorld, env: &[(String, String)]) -> TurnOut {
    let payload = json!({"sessionId": SESSION, "timestamp": 1}).to_string();
    world.turn(&world.checkout, "copilot", &[], &payload, env)
}

/// The block reason a Copilot turn end handed its session, `None` where it
/// passed with nothing on stdout.
fn blocked(out: &TurnOut) -> Option<String> {
    if out.stdout.is_empty() {
        return None;
    }
    let answer: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(answer["decision"], "block", "{}", out.stdout);
    Some(answer["reason"].as_str().unwrap().to_owned())
}

/// The overseer mailbox of the world's checkout.
fn overseer_box(world: &TurnWorld) -> PathBuf {
    world.checkout.join("tmp/lane-mail/overseer")
}

/// The JSON file `name` in the overseer mailbox, `None` where none stands.
fn box_file(world: &TurnWorld, name: &str) -> Option<Value> {
    let text = fs::read_to_string(overseer_box(world).join(name)).ok()?;
    Some(serde_json::from_str(&text).unwrap())
}

/// The key every controller record carries for the world's pane `pane`.
fn caller_key(world: &TurnWorld, pane: &str) -> String {
    format!("{} {pane}", world.server_pid())
}

const ROUTE: &str = " op --fleet --effect-exit --request [REQUEST FILE]\n";

/// The bound Copilot overseer's reading is recorded in the overseer mailbox
/// under its pane key, and its turn end judges that reading and names the
/// runtime succession; a session on a pane the fleet record does not name,
/// and one outside tmux, record nothing. Lost by the fleet record, its turn
/// end writes the gap over that reading, which, named again, it reports as
/// no reading.
#[test]
fn an_overseers_copilot_reading_is_recorded_in_the_overseer_box_under_its_pane_key() {
    let world = TurnWorld::new();
    let (account, _) = copilot_lead(&world);
    world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
    let mut env = copilot_env(&world, Some(PANE), &account);
    env.push(("ORCH_HANDOFF_CONTEXT_PCT".to_owned(), "90".to_owned()));
    let out = session_usage(&world, &env, 199_000);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let record = box_file(&world, "context.json").expect("the reading is recorded");
    assert_eq!(
        [
            &record["tokens"],
            &record["window"],
            &record["session_id"],
            &record["model"],
            &record["pane_key"],
        ],
        [
            &json!(199_000),
            &json!(217_600),
            &json!(SESSION),
            &Value::Null,
            &json!(caller_key(&world, PANE)),
        ]
    );
    let out = session_stop(&world, &env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let reason = blocked(&out).unwrap_or_else(|| panic!("passed: {}", out.stderr));
    assert!(
        reason.starts_with("lane-mail-check: context=199000\n"),
        "{reason}"
    );
    assert!(reason.contains(ROUTE), "{reason}");
    fs::remove_file(overseer_box(&world).join("context.json")).unwrap();
    for (name, pane) in [("another pane", Some("%5")), ("outside tmux", None)] {
        let out = session_usage(&world, &copilot_env(&world, pane, &account), 199_000);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.stderr.as_str()),
            (0, "", ""),
            "{name}"
        );
        assert_eq!(box_file(&world, "context.json"), None, "{name}");
    }
    let out = session_usage(&world, &env, 199_000);
    assert_eq!(out.code, 0, "{}", out.stderr);
    world.plant_fleet(world.controller("%9", "copilot", &account, SESSION));
    let out = session_stop(&world, &env);
    let lost = format!("pane-unrecorded={}", caller_key(&world, PANE));
    assert_eq!(
        (out.code, out.keyed().first().copied()),
        (0, Some(lost.as_str())),
        "{}",
        out.stderr
    );
    let record = box_file(&world, "context.json").unwrap();
    assert_eq!(
        [&record["tokens"], &record["gap"]],
        [&Value::Null, &json!("pane-unrecorded")]
    );
    world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
    let out = session_stop(&world, &env);
    let unrecorded = format!(
        "reading-unrecorded={}",
        overseer_box(&world).join("context.json").display()
    );
    assert_eq!(
        (out.code, out.keyed().first().copied(), blocked(&out)),
        (0, Some(unrecorded.as_str()), None),
        "{}",
        out.stderr
    );
}

/// The bound Copilot overseer's automatic compaction is flagged in the
/// overseer mailbox under its pane key, and its turn end is held on it,
/// succession on or off, naming the runtime succession; a session on a pane
/// the fleet record does not name, and one outside tmux, flag nothing; the
/// overseer's own handoff record standing, its turn end passes.
#[test]
fn an_overseers_automatic_compaction_is_flagged_in_the_overseer_box_under_its_pane_key() {
    let world = TurnWorld::new();
    let (account, _) = copilot_lead(&world);
    world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
    let env = copilot_env(&world, Some(PANE), &account);
    let out = session_compaction(&world, &env);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let flag = box_file(&world, "compaction.json").expect("the compaction is flagged");
    assert_eq!(
        [
            &flag["harness"],
            &flag["trigger"],
            &flag["session_id"],
            &flag["pane_key"]
        ],
        [
            &json!("copilot"),
            &json!("auto"),
            &json!(SESSION),
            &json!(caller_key(&world, PANE))
        ]
    );
    for off in [false, true] {
        let mut env = env.clone();
        if off {
            let setting = "AGENT_RUNTIME_CONTROLLER_SUCCESSION";
            env.push((setting.to_owned(), "off".to_owned()));
        }
        let out = session_stop(&world, &env);
        assert_eq!(out.code, 0, "off {off}: {}", out.stderr);
        let reason = blocked(&out).unwrap_or_else(|| panic!("off {off}: {}", out.stderr));
        assert!(
            reason.starts_with("lane-mail-check: compacted=auto\n"),
            "off {off}: {reason}"
        );
        assert!(reason.contains(ROUTE), "off {off}: {reason}");
    }
    fs::remove_file(overseer_box(&world).join("compaction.json")).unwrap();
    for (name, pane) in [("another pane", Some("%5")), ("outside tmux", None)] {
        let out = session_compaction(&world, &copilot_env(&world, pane, &account));
        assert_eq!(
            (out.code, out.stdout.as_str(), out.stderr.as_str()),
            (0, "", ""),
            "{name}"
        );
        assert_eq!(box_file(&world, "compaction.json"), None, "{name}");
    }
    let out = session_compaction(&world, &env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let mut fleet = world.fleet();
    fleet["handoff"] = json!({ "session_id": SESSION, "pane_key": caller_key(&world, PANE) });
    fs::write(world.fleet_path(), fleet.to_string()).unwrap();
    let out = session_stop(&world, &env);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
}
