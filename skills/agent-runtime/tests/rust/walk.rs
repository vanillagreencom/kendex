//! The preference walk through the executable: the entries classified
//! through the `kendex-launch` fixture (the one `kendex` on the rows'
//! `PATH`) and judged over accounts planted as the listing reads them
//! (`plant_listing`: local directories with their credentials and usage
//! records). No orch stands in a world, so no lane is counted and no
//! provider is read for an entry naming a host.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the listings and the record they plant and read the fixtures' logs"
)]

#[path = "account_planters.rs"]
mod account_planters;
#[path = "isolation.rs"]
mod isolation;

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use account_planters::*;
use agent_runtime::accounts::{Env, PickRequest, here};
use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::protocol::Reply;
use agent_runtime::settings::{self, AccountSettings, Judged, Keys};
use isolation::*;
use serde_json::{Value, json};
use std::ffi::OsString;

/// The controller record a world plants: its `overseer` member is a seat.
const RECORD: &str = "workflow-state-oversee.json";

/// The world's own preference, walked as `--preference` by a walk that is
/// not the controller's.
const PREFERENCE: &str = "--preference";

/// The settings a world's reading takes, owned.
struct Loaded {
    accounts: Judged<AccountSettings>,
    account_state: Judged<PathBuf>,
    home: Option<String>,
    preference: String,
}

impl Loaded {
    fn env(&self) -> Env<'_> {
        Env {
            accounts: &self.accounts,
            account_state: &self.account_state,
            home: self.home.as_deref(),
            copilot_home: None,
            controller_preference: &self.preference,
        }
    }
}

/// One world: the accounts planted under `home` as the listing reads them,
/// the usage fixture as `bin/curl` and the `kendex-launch` fixture as
/// `bin/kendex`, both first on the executable's `PATH`, a controller record
/// with no seat, and no burn (the projection is the reading).
struct World {
    dir: tempfile::TempDir,
    env: Vec<(String, String)>,
    preference: Option<String>,
}

impl World {
    fn new(extra: &[(&str, &str)]) -> World {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("bin")).unwrap();
        std::fs::create_dir_all(dir.path().join("home")).unwrap();
        for (name, fixture) in [
            ("bin/curl", "usage-curl/curl"),
            ("bin/kendex", "kendex-launch/kendex"),
        ] {
            std::os::unix::fs::symlink(account_fixtures().join(fixture), dir.path().join(name))
                .unwrap();
        }
        let base = [
            ("HOME", dir.path().join("home").display().to_string()),
            (
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                dir.path().display().to_string(),
            ),
            (
                "USAGE_FIXTURE_DIR",
                dir.path().join("fixtures").display().to_string(),
            ),
            ("AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR", "0".to_owned()),
        ];
        let mut env: Vec<(String, String)> = base
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect();
        let mut preference = None;
        for (key, value) in extra {
            if *key == PREFERENCE {
                preference = Some((*value).to_owned());
            } else {
                env.push(((*key).to_owned(), (*value).to_owned()));
            }
        }
        let world = World {
            dir,
            env,
            preference,
        };
        world.write_fleet(None);
        world
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn bin(&self) -> PathBuf {
        self.path().join("bin")
    }

    /// The directory a planted local account `alias` stands at.
    fn dir(&self, alias: &str) -> String {
        self.path()
            .join("home")
            .join(format!(".{alias}"))
            .display()
            .to_string()
    }

    /// The accounts the listing lists: the local rows as directories under
    /// the home with their records.
    fn plant_listing(&mut self, rows: &[Value]) {
        let Planted { env, .. } = plant_listing(self.path(), self.path(), rows, now());
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
    }

    /// The local rows sampled at `now`, for a judgement run in process at
    /// that second.
    fn plant_at(&mut self, now: u64, rows: &[Value]) {
        let Planted { env, .. } = plant_listing(self.path(), self.path(), rows, now);
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
    }

    /// This world's settings as the executable loads them from its
    /// environment, with no settings file and no private env file.
    fn settings(&self) -> Loaded {
        let environment: Vec<(OsString, OsString)> = self
            .env
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect();
        let keys = Keys {
            read: &[settings::ACCOUNT_KEYS, settings::ENGINE_KEYS],
            load: &[],
        };
        let values = settings::layered(self.path(), &environment, false, &keys).unwrap();
        Loaded {
            accounts: AccountSettings::read(&values),
            account_state: settings::account_state_dir(&values),
            home: values.get(settings::HOME_KEY).map(str::to_owned),
            preference: settings::ControllerSettings::read(&values).preference,
        }
    }

    fn write_fleet(&self, overseer_account: Option<&str>) {
        let mut fleet = json!({
            "issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": []
        });
        if let Some(account) = overseer_account {
            fleet["overseer"] = json!({"account": account});
        }
        std::fs::write(
            self.path().join(RECORD),
            serde_json::to_string(&fleet).unwrap(),
        )
        .unwrap();
    }

    /// Every argv the `kendex` fixture was handed.
    fn kendex_calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.bin().join("kendex.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// `accounts walk --record` with `args`, in this world: the world's
    /// preference unless the walk is the controller's.
    fn walk(&self, args: &[&str]) -> std::process::Output {
        let mut command = program(env!("CARGO_BIN_EXE_agent-runtime"));
        command
            .current_dir(self.path())
            .env("PATH", tool_path(&[&self.bin()]))
            .args(["accounts", "walk", "--record"])
            .arg(self.path().join(RECORD));
        if !args.contains(&"--controller") {
            command.args([PREFERENCE, self.preference.as_deref().unwrap_or_default()]);
        }
        command.args(args);
        for (key, value) in &self.env {
            command.env(key, value);
        }
        command.output().unwrap()
    }

    /// The reply's `result` of a walk that answered.
    fn answered(&self, args: &[&str]) -> Value {
        let out = self.walk(args);
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        reply["result"].clone()
    }

    /// The refusal of a walk that refused: its key and fields.
    fn refused(&self, args: &[&str]) -> (String, Vec<(String, String)>) {
        let out = self.walk(args);
        assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["ok"], json!(false), "{reply}");
        let refusal = &reply["refusal"];
        let fields = refusal["fields"]
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
        (refusal["key"].as_str().unwrap().to_owned(), fields)
    }
}

fn now() -> u64 {
    static NOW: OnceLock<u64> = OnceLock::new();
    *NOW.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
    })
}

fn stamp(at: u64) -> String {
    clock::iso_utc(at)
}

/// The skipped entries as `entry reason lane`.
fn skipped(result: &Value) -> Vec<String> {
    result["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            format!(
                "{} {} {}",
                s["entry"].as_str().unwrap(),
                s["reason"].as_str().unwrap(),
                s["lane"].as_str().unwrap_or("none")
            )
        })
        .collect()
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

/// One measured local Claude row at `alias`, `used` percent on its weekly
/// window (the binding, resetting 60 hours on), and the 5-hour figure the
/// endpoint still sends at `session` percent, which no judgement reads.
fn measured(alias: &str, used: u64, session: u64) -> Value {
    let weekly = stamp(now() + 60 * 3600);
    json!({
        "alias": alias,
        "harness": "claude",
        "config_dir": format!("/home/me/.{alias}"),
        "measured_through": "local",
        "status": "ok",
        "verdict": if used < 95 { "room" } else { "walled" },
        "headroom_pct": 100 - used,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": used,
        "session_5h_pct": session,
        "weekly_pct": used,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": stamp(now() + 3600), "weekly": weekly, "model": null, "monthly": null},
        "usage_rate_state": "one-sample",
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
    })
}

/// A measured Codex row at `alias`, `used` percent on its weekly window.
fn codex(alias: &str, used: u64) -> Value {
    let mut row = measured(alias, used, 5);
    row["harness"] = json!("codex");
    row
}

/// A local row nothing could read.
fn unreachable(alias: &str) -> Value {
    let mut row = measured(alias, 10, 5);
    row["status"] = json!("unreachable");
    row["headroom_pct"] = Value::Null;
    row["wall"] = Value::Null;
    row["verdict"] = json!("unmeasured");
    row
}

const BYPASS: &str = "--dangerously-skip-permissions";

#[test]
fn the_last_choice_mark_is_held_back_while_an_earlier_entry_has_room_at_the_full_bound() {
    let mut world = World::new(&[(PREFERENCE, "claude:fable:high,codex:gpt-6.1-sol:high:last")]);
    world.plant_listing(&[measured("aclaude", 96, 5), codex("codex", 20)]);
    let args = ["--source-harness", "claude", "--source-flags", BYPASS];
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("held"), "{result}");
    assert_eq!(result["last_choice"], json!("codex:gpt-6.1-sol:high"));
    assert_eq!(result["room"], json!("claude:fable:high"));
    assert_eq!(
        skipped(&result),
        [format!("claude:fable:high walled {}", world.dir("aclaude"))],
        "{result}"
    );
    assert_eq!(
        result["walk"],
        json!("claude:fable:high,codex:gpt-6.1-sol:high:last")
    );
    // No earlier entry has room at the full bound: the marked entry is
    // spent.
    world.plant_listing(&[measured("aclaude", 100, 5), codex("codex", 20)]);
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(result["chosen"]["entry"], json!("codex:gpt-6.1-sol:high"));
    assert_eq!(result["chosen"]["account"], json!(world.dir("codex")));
    assert_eq!(
        result["chosen"]["env"],
        json!(format!("CODEX_HOME={}", world.dir("codex")))
    );
    assert_eq!(result["room"], Value::Null);
    // No account of an earlier entry's harness is no room, not unread:
    // the marked entry is spent.
    world.plant_listing(&[codex("codex", 20)]);
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(skipped(&result), ["claude:fable:high no-candidate none"]);
    // An unread earlier entry (a model whose provider nothing bills) holds
    // the marked one too.
    let mut unread = World::new(&[(
        PREFERENCE,
        "pi:openai/gpt-5:high,codex:gpt-6.1-sol:high:last",
    )]);
    unread.plant_listing(&[codex("codex", 20)]);
    let result = unread.answered(&args);
    assert_eq!(result["answer"], json!("held"), "{result}");
    assert_eq!(strings(&result["unread"]), ["pi:openai/gpt-5:high"]);
    assert_eq!(result["room"], Value::Null);
    assert_eq!(result["last_choice"], json!("codex:gpt-6.1-sol:high"));
    // An unmarked walk asks no full-bound question and picks each entry
    // once.
    let mut unmarked = World::new(&[(PREFERENCE, "claude:fable:high,codex:gpt-6.1-sol:high")]);
    unmarked.plant_listing(&[measured("aclaude", 96, 5), codex("codex", 20)]);
    let result = unmarked.answered(&args);
    assert_eq!(result["chosen"]["entry"], json!("codex:gpt-6.1-sol:high"));
    assert_eq!(result["room"], Value::Null);
    // The mark off the final entry, and in an overseer walk, is a setting
    // to fix.
    let mut marked = World::new(&[
        (PREFERENCE, "claude:fable:high:last,codex:gpt-6.1-sol:high"),
        (
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
            "claude:standard:high,codex:standard:high:last",
        ),
    ]);
    marked.plant_listing(&[measured("aclaude", 20, 5)]);
    let (key, fields) = marked.refused(&args);
    assert_eq!(key, "preference-invalid");
    assert_eq!(
        fields,
        [("entry".to_owned(), "claude:fable:high:last".to_owned())]
    );
    let (key, fields) = marked.refused(&["--controller"]);
    assert_eq!(key, "preference-invalid");
    assert_eq!(
        fields,
        [("entry".to_owned(), "codex:standard:high:last".to_owned())]
    );
}

#[test]
fn an_explicit_model_is_taken_as_named_and_a_class_resolves_through_kendex() {
    for (preference, harness, model, class, warning, deprecated, call) in [
        (
            "claude:claude-opus-5-5:high",
            "claude",
            "claude-opus-5-5",
            Value::Null,
            Value::Null,
            json!([{"entry": "claude:claude-opus-5-5:high", "form": "model-class"}]),
            "tier-model claude --model claude-opus-5-5 --json",
        ),
        (
            "codex:gpt-6.1-sol:high",
            "codex",
            "gpt-6.1-sol",
            Value::Null,
            Value::Null,
            json!([]),
            "tier-model codex --model gpt-6.1-sol --json --runtime-context-json",
        ),
        (
            "claude:standard:high",
            "claude",
            "opus",
            json!("standard"),
            json!("model-resolution: requested=standard selected=opus causes=render-only source="),
            json!([]),
            "tier-model claude --model standard --json",
        ),
    ] {
        let mut world = World::new(&[(PREFERENCE, preference)]);
        world.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
        let result = world.answered(&["--source-harness", harness]);
        assert_eq!(result["answer"], json!("lane"), "{preference}: {result}");
        let chosen = &result["chosen"];
        assert_eq!(chosen["entry"], json!(preference));
        assert_eq!(chosen["model"], json!(model), "{preference}");
        assert_eq!(chosen["class"], class, "{preference}");
        assert_eq!(chosen["warning"], warning, "{preference}");
        assert_eq!(chosen["effort"], json!("high"));
        assert_eq!(result["deprecated"], deprecated, "{preference}");
        let calls = world.kendex_calls();
        assert_eq!(calls.len(), 1, "{preference}: {calls:?}");
        assert!(calls[0].starts_with(call), "{preference}: {}", calls[0]);
        if call.ends_with("--runtime-context-json") {
            assert!(
                calls[0].contains(r#""models":{"tag":"unsupported","source":"orch-launch"}"#),
                "{}",
                calls[0]
            );
        }
    }
    // A model kendex cannot classify refuses the walk with kendex's words
    // and asks the judge nothing.
    let mut broken = World::new(&[(PREFERENCE, "claude:standard:high")]);
    std::fs::remove_file(broken.bin().join("kendex")).unwrap();
    write_executable(
        &broken.bin().join("kendex"),
        "#!/bin/sh\necho 'Error: invalid manifest' >&2\nexit 1\n",
    );
    broken.plant_listing(&[measured("aclaude", 20, 5)]);
    let (key, fields) = broken.refused(&["--source-harness", "claude"]);
    assert_eq!(key, "preference-class-unread");
    assert_eq!(
        fields,
        [
            ("entry".to_owned(), "claude:standard:high".to_owned()),
            ("cause".to_owned(), "Error: invalid manifest".to_owned())
        ]
    );
}

#[test]
fn a_deprecated_numeric_entry_runs_the_callers_model_and_names_its_conversion() {
    let mut world = World::new(&[("AGENT_RUNTIME_CONTROLLER_PREFERENCE", "claude:1:high")]);
    world.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
    let result = world.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--caller-harness",
        "claude",
        "--caller-model",
        "fable",
        "--caller-pick-model",
        "fable",
    ]);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    let chosen = &result["chosen"];
    assert_eq!(chosen["entry"], json!("claude:1:high"));
    assert_eq!(chosen["model"], json!("fable"));
    assert_eq!(chosen["class"], json!("top"));
    assert_eq!(chosen["warning"], Value::Null);
    assert_eq!(chosen["account"], json!(world.dir("aclaude")));
    assert_eq!(
        result["deprecated"],
        json!([{"entry": "claude:1:high", "form": "harness:model:effort", "replacement": "claude:top:high", "model": "fable"}])
    );
    // The class alone is asked, under the runtime context even for Claude.
    let calls = world.kendex_calls();
    assert_eq!(calls.len(), 1);
    assert!(
        calls[0].starts_with("tier-model claude --model fable --json --runtime-context-json"),
        "{}",
        calls[0]
    );
    // An old exact id names no class: the conversion names no replacement.
    let mut old = World::new(&[("AGENT_RUNTIME_CONTROLLER_PREFERENCE", "claude:1:high")]);
    old.plant_listing(&[measured("aclaude", 20, 5)]);
    let result = old.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--caller-harness",
        "claude",
        "--caller-model",
        "claude-opus-5-5",
    ]);
    assert_eq!(result["chosen"]["model"], json!("claude-opus-5-5"));
    assert_eq!(result["chosen"]["class"], Value::Null);
    assert_eq!(
        result["deprecated"],
        json!([{"entry": "claude:1:high", "form": "harness:model:effort", "replacement": null, "model": "claude-opus-5-5"}])
    );
    // No caller model: the harness's default entry's class.
    let mut defaulted = World::new(&[("AGENT_RUNTIME_CONTROLLER_PREFERENCE", "claude:1:high")]);
    defaulted.plant_listing(&[measured("aclaude", 20, 5)]);
    let result = defaulted.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--caller-harness",
        "claude",
    ]);
    assert_eq!(result["chosen"]["model"], json!("opus"));
    assert_eq!(result["chosen"]["class"], json!("standard"));
    assert_eq!(
        result["deprecated"],
        json!([{"entry": "claude:1:high", "form": "harness:model:effort", "replacement": "claude:standard:high"}])
    );
    // A numeric entry of another harness than the caller's is skipped
    // before any pick, naming the caller's model; the caller's own entry
    // then sweeps its harness.
    let mut crossed = World::new(&[("AGENT_RUNTIME_CONTROLLER_PREFERENCE", "codex:2:high")]);
    crossed.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
    let result = crossed.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--source-flags",
        BYPASS,
        "--caller-harness",
        "claude",
        "--caller-model",
        "fable",
        "--caller-pick-model",
        "fable",
        "--caller-effort",
        "high",
    ]);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(
        skipped(&result),
        ["codex:2:high entry-permission-untransferable none"]
    );
    assert_eq!(result["skipped"][0]["model"], json!("fable"));
    assert_eq!(result["skipped"][0]["source"], json!("claude"));
    assert_eq!(
        result["skipped"][0]["word"],
        json!("--dangerously-bypass-approvals-and-sandbox")
    );
    let chosen = &result["chosen"];
    assert_eq!(chosen["entry"], json!("caller"));
    assert_eq!(chosen["account"], json!(crossed.dir("aclaude")));
    assert_eq!(chosen["model"], json!("fable"));
    assert_eq!(chosen["effort"], json!("high"));
    assert_eq!(chosen["kept"], json!(false));
}

#[test]
fn an_unmeasured_caller_account_is_kept_at_a_context_mark_where_the_judge_still_reads_it_unmeasured()
 {
    let mut world = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "claude:standard:high",
    )]);
    world.plant_listing(&[unreachable("aclaude")]);
    let lane = world.dir("aclaude");
    let args = [
        "--controller",
        "--source-harness",
        "claude",
        "--caller-harness",
        "claude",
        "--caller-account",
        lane.as_str(),
        "--caller-pick-model",
        "fable",
        "--keep-unmeasured",
    ];
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    let chosen = &result["chosen"];
    assert_eq!(chosen["entry"], json!("claude:standard:high"));
    assert_eq!(chosen["account"], json!(world.dir("aclaude")));
    assert_eq!(chosen["kept_unmeasured"], json!(true));
    assert_eq!(chosen["model"], json!("opus"));
    assert_eq!(chosen["record"]["verdict"], json!("unmeasured"));
    assert_eq!(result["unmeasured"], json!(1));
    // Without the mark's rule the entry is skipped and the caller's sweep
    // finds the same account unmeasured.
    let result = world.answered(&args[..args.len() - 1]);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        [
            format!("claude:standard:high unmeasured {lane}"),
            format!("caller unmeasured {lane}")
        ]
    );
    // The caller's account retired: the judge's word refuses it, and no
    // unmeasured record admits it.
    let mut retired = World::new(&[
        (
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
            "claude:standard:high",
        ),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2020-01-01"),
    ]);
    retired.plant_listing(&[unreachable("aclaude")]);
    let lane = retired.dir("aclaude");
    let mut args = args.to_vec();
    args[6] = lane.as_str();
    let result = retired.answered(&args);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        [
            format!("claude:standard:high retired {lane}"),
            format!("caller retired {lane}")
        ]
    );
}

#[test]
fn a_succession_walk_moves_past_a_no_candidate_entry_and_ends_where_every_entry_refused() {
    let mut world = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "claude:standard:high,codex:gpt-6.1-sol:high",
    )]);
    world.plant_listing(&[
        measured("aclaude", 96, 5),
        unreachable("bclaude"),
        codex("codex", 20),
        codex("1codex", 96),
    ]);
    let args = ["--controller", "--source-harness", "claude"];
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(result["chosen"]["entry"], json!("codex:gpt-6.1-sol:high"));
    assert_eq!(result["chosen"]["account"], json!(world.dir("codex")));
    assert_eq!(result["chosen"]["model"], json!("gpt-6.1-sol"));
    assert_eq!(
        skipped(&result),
        [
            format!("claude:standard:high walled {}", world.dir("aclaude")),
            format!("claude:standard:high unmeasured {}", world.dir("bclaude"))
        ]
    );
    assert_eq!(result["walled"], json!(1));
    assert_eq!(result["unmeasured"], json!(1));
    assert_eq!(result["entries"], json!(2));
    world.plant_listing(&[
        measured("aclaude", 96, 5),
        unreachable("bclaude"),
        codex("codex", 97),
        codex("1codex", 96),
    ]);
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(result["chosen"], Value::Null);
    assert_eq!(
        skipped(&result),
        [
            format!("claude:standard:high walled {}", world.dir("aclaude")),
            format!("claude:standard:high unmeasured {}", world.dir("bclaude")),
            format!("codex:gpt-6.1-sol:high walled {}", world.dir("codex")),
            format!("codex:gpt-6.1-sol:high walled {}", world.dir("1codex"))
        ]
    );
    assert_eq!(result["walled"], json!(3));
    assert_eq!(result["unmeasured"], json!(1));
}

#[test]
fn the_overseer_walk_judges_at_the_trigger_and_a_seat_as_an_ordinary_account() {
    let mut world = World::new(&[
        (
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
            "claude:standard:high,codex:gpt-6.1-sol:high",
        ),
        (PREFERENCE, "claude:fable:high,codex:gpt-6.1-sol:high"),
        ("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "50"),
    ]);
    world.plant_listing(&[measured("aclaude", 85, 5), codex("codex", 20)]);
    world.write_fleet(Some(&world.dir("aclaude")));
    // The seat at 85 is room to its own overseer at a trigger of 5 (the
    // bound 95).
    let result = world.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--min-headroom-pct",
        "5",
    ]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("claude:standard:high"),
        "{result}"
    );
    assert_eq!(result["chosen"]["account"], json!(world.dir("aclaude")));
    // At a trigger of 20 (the bound 80) it is walled and the walk moves
    // on; the trigger unnamed is the headroom setting (50 here).
    for trigger in [&["--min-headroom-pct", "20"][..], &[]] {
        let mut args = vec!["--controller", "--source-harness", "claude"];
        args.extend_from_slice(trigger);
        let result = world.answered(&args);
        assert_eq!(
            result["chosen"]["entry"],
            json!("codex:gpt-6.1-sol:high"),
            "{trigger:?}: {result}"
        );
        assert_eq!(
            skipped(&result),
            [format!(
                "claude:standard:high walled {}",
                world.dir("aclaude")
            )]
        );
    }
    // A lane's walk holds the same seat to the overseer's reserve (the
    // bound 50).
    let result = world.answered(&["--source-harness", "claude", "--source-flags", BYPASS]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex:gpt-6.1-sol:high"),
        "{result}"
    );
    assert_eq!(
        skipped(&result),
        [format!(
            "claude:fable:high seat-reserve {}",
            world.dir("aclaude")
        )]
    );
}

/// The owner's exclusion keeps an account from every walk, the controller
/// walk's included: the excluded home with the most room is no candidate,
/// so the walk moves on to the next entry.
#[test]
fn the_controller_walk_chooses_no_account_the_owner_excluded() {
    let mut world = World::new(&[
        (
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
            "claude:standard:high,codex:gpt-6.1-sol:high",
        ),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "aclaude"),
    ]);
    world.plant_listing(&[measured("aclaude", 10, 5), codex("codex", 20)]);
    let result = world.answered(&["--controller", "--source-harness", "claude"]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex:gpt-6.1-sol:high"),
        "{result}"
    );
    assert_eq!(skipped(&result), ["claude:standard:high no-candidate none"]);
}

#[test]
fn an_entry_of_another_harness_needs_the_sources_full_bypass_to_cross() {
    let mut world = World::new(&[
        (PREFERENCE, "codex:gpt-6.1-sol:high,claude:fable:high"),
        ("AGENT_RUNTIME_COPILOT_POOL", "/home/me/.pi=10/100"),
    ]);
    world.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
    for (flags, chosen) in [
        (BYPASS, "codex:gpt-6.1-sol:high"),
        (
            "--permission-mode bypassPermissions",
            "codex:gpt-6.1-sol:high",
        ),
        ("--permission-mode dontAsk", "claude:fable:high"),
        ("", "claude:fable:high"),
        (
            "--dangerously-skip-permissions --permission-mode dontAsk",
            "claude:fable:high",
        ),
    ] {
        let result = world.answered(&["--source-harness", "claude", "--source-flags", flags]);
        assert_eq!(
            result["chosen"]["entry"],
            json!(chosen),
            "{flags:?}: {result}"
        );
        if chosen != "codex:gpt-6.1-sol:high" {
            assert_eq!(
                skipped(&result),
                ["codex:gpt-6.1-sol:high entry-permission-untransferable none"],
                "{flags:?}"
            );
            assert_eq!(result["skipped"][0]["source"], json!("claude"));
            assert_eq!(
                result["skipped"][0]["word"],
                json!("--dangerously-bypass-approvals-and-sandbox")
            );
        }
    }
    // A harness with no permission word takes a transferable posture in a
    // lane's walk: a Pi entry on its stated Copilot pool.
    let mut pi = World::new(&[
        (
            PREFERENCE,
            "pi:github-copilot/gpt-6.1-sol:high,claude:fable:high",
        ),
        ("AGENT_RUNTIME_COPILOT_POOL", "/home/me/.pi=10/100"),
    ]);
    pi.plant_listing(&[measured("aclaude", 20, 5)]);
    let result = pi.answered(&["--source-harness", "claude", "--source-flags", BYPASS]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("pi:github-copilot/gpt-6.1-sol:high"),
        "{result}"
    );
    assert_eq!(result["chosen"]["account"], json!("/home/me/.pi"));
    assert_eq!(
        result["chosen"]["env"],
        json!("PI_CODING_AGENT_DIR=/home/me/.pi")
    );
    let result = pi.answered(&["--source-harness", "claude", "--source-flags", ""]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("claude:fable:high"),
        "{result}"
    );
    // A first launch writes the target's own word: a Pi entry has none.
    let mut first = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "pi:github-copilot/gpt-6.1-sol:high,claude:standard:high",
    )]);
    first.plant_listing(&[measured("aclaude", 20, 5)]);
    let result = first.answered(&["--controller"]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("claude:standard:high"),
        "{result}"
    );
    assert_eq!(
        skipped(&result),
        ["pi:github-copilot/gpt-6.1-sol:high entry-permission-unwritable none"]
    );
    // A judgement handed no words asks the source harness's row alone: a
    // Claude source writes a full bypass, a Pi source none.
    let mut rows = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "codex:gpt-6.1-sol:high",
    )]);
    rows.plant_listing(&[codex("codex", 20)]);
    let result = rows.answered(&["--controller", "--source-harness", "claude"]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex:gpt-6.1-sol:high"),
        "{result}"
    );
    let result = rows.answered(&["--controller", "--source-harness", "pi"]);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        ["codex:gpt-6.1-sol:high entry-permission-untransferable none"]
    );
}

/// An overseer's entry the judge could not judge, a provider nothing bills
/// or a pool nobody measured, is passed over with the judge's word and
/// listed unread, as a lane's is, and the walk goes on to its next entry.
#[test]
fn an_overseer_entry_the_judge_could_not_judge_is_skipped_and_the_walk_goes_on() {
    let mut pi = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "pi:openai/gpt-5:high,pi:github-copilot/gpt-6.1-sol:high,pi:pi-claude/claude-fable-5-1:high",
    )]);
    pi.plant_listing(&[measured("aclaude", 20, 5)]);
    let result = pi.answered(&["--controller", "--source-harness", "pi"]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("pi:pi-claude/claude-fable-5-1:high"),
        "{result}"
    );
    assert_eq!(result["chosen"]["account"], json!(pi.dir("aclaude")));
    assert_eq!(
        skipped(&result),
        [
            "pi:openai/gpt-5:high unmeasured none",
            "pi:github-copilot/gpt-6.1-sol:high unmeasured none"
        ]
    );
    assert_eq!(
        strings(&result["unread"]),
        ["pi:openai/gpt-5:high", "pi:github-copilot/gpt-6.1-sol:high"]
    );
}

#[test]
fn a_kept_caller_entry_is_chosen_on_its_own_lane_without_a_pick() {
    let mut world = World::new(&[]);
    world.plant_listing(&[measured("aclaude", 96, 5)]);
    let lane = world.dir("aclaude");
    let result = world.answered(&[
        "--controller",
        "--source-harness",
        "claude",
        "--caller-harness",
        "claude",
        "--caller-account",
        lane.as_str(),
        "--caller-model",
        "fable",
        "--caller-pick-model",
        "fable",
        "--caller-effort",
        "high",
        "--caller-keep",
    ]);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    let chosen = &result["chosen"];
    assert_eq!(chosen["entry"], json!("caller"));
    assert_eq!(chosen["account"], json!(world.dir("aclaude")));
    assert_eq!(chosen["kept"], json!(true));
    assert_eq!(chosen["record"], Value::Null);
    // The default preference's two entries were passed over, its Codex class
    // with no listed model; the caller was not.
    assert_eq!(
        skipped(&result),
        [
            format!("claude:standard:high walled {lane}"),
            "codex:standard:high class-unverified none".to_owned()
        ]
    );
}

#[test]
fn a_named_lane_walk_skips_the_entries_the_judge_refuses_by_word() {
    let mut world = World::new(&[
        (PREFERENCE, "claude:fable:high,codex:gpt-6.1-sol:high"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2020-01-01"),
    ]);
    world.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
    let args = [
        "--source-harness",
        "claude",
        "--source-flags",
        BYPASS,
        "--account",
        "aclaude",
    ];
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        [
            format!("claude:fable:high retired {}", world.dir("aclaude")),
            format!("codex:gpt-6.1-sol:high no-record {}", world.dir("aclaude"))
        ]
    );
    assert_eq!(strings(&result["unread"]), ["codex:gpt-6.1-sol:high"]);
    let mut open = World::new(&[(PREFERENCE, "claude:fable:high,codex:gpt-6.1-sol:high")]);
    open.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
    let result = open.answered(&args);
    assert_eq!(
        result["chosen"]["entry"],
        json!("claude:fable:high"),
        "{result}"
    );
    assert_eq!(result["chosen"]["account"], json!(open.dir("aclaude")));
    assert_eq!(
        result["chosen"]["record"]["projected_window"]["bucket"],
        json!("weekly")
    );
    let (key, fields) = open.refused(&["--source-harness", "claude", "--account", "/nowhere/.x"]);
    assert_eq!(key, "lane-unknown");
    assert_eq!(fields[0], ("lane".to_owned(), "/nowhere/.x".to_owned()));
}

/// An entry whose provider nobody here can read is passed over with its host
/// and cause and the walk goes on to this machine's entry; a walk whose every
/// entry went unread judged none and refuses, naming each host and cause,
/// where `none` would read as no room; a walk that judged an entry and found
/// no room answers `none` with the unread rows beside it.
#[test]
fn an_unread_hosts_entries_are_passed_over_and_a_walk_judging_none_refuses() {
    let args = ["--source-harness", "claude", "--source-flags", BYPASS];
    let mut world = World::new(&[(
        PREFERENCE,
        "claude@vm:fable:high,codex@vm:gpt-6.1-sol:high,codex:gpt-6.1-sol:high",
    )]);
    world.plant_listing(&[measured("aclaude", 10, 5), codex("codex", 20)]);
    let result = world.answered(&args);
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex:gpt-6.1-sol:high"),
        "{result}"
    );
    assert_eq!(
        skipped(&result),
        [
            "claude@vm:fable:high host-unread none",
            "codex@vm:gpt-6.1-sol:high host-unread none"
        ]
    );
    for row in result["skipped"].as_array().unwrap() {
        assert_eq!(
            (&row["host"], &row["cause"]),
            (&json!("vm"), &json!("no-provider"))
        );
    }
    let mut hosted = World::new(&[(
        PREFERENCE,
        "claude@vm:fable:high,codex@vm2:gpt-6.1-sol:high",
    )]);
    hosted.plant_listing(&[measured("aclaude", 10, 5), codex("codex", 20)]);
    let (key, fields) = hosted.refused(&args);
    assert_eq!(key, "account-unjudged");
    let pair = |k: &str, v: &str| (k.to_owned(), v.to_owned());
    assert_eq!(
        fields,
        [
            pair("step", "host"),
            pair("host", "vm"),
            pair("cause", "no-provider"),
            pair("host", "vm2"),
            pair("cause", "no-provider")
        ]
    );
    let mut walled = World::new(&[(PREFERENCE, "claude@vm:fable:high,claude:fable:high")]);
    walled.plant_listing(&[measured("aclaude", 96, 5)]);
    let result = walled.answered(&args);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        [
            "claude@vm:fable:high host-unread none".to_owned(),
            format!("claude:fable:high walled {}", walled.dir("aclaude"))
        ]
    );
    assert_eq!(strings(&result["unread"]), ["claude@vm:fable:high"]);
}

/// A class kendex leaves on a Codex or Copilot harness's default, where
/// nothing lists the models the account may run, is passed over by name with
/// its class and harness, in either walk and as a numeric entry's default
/// class, and the walk goes on; it holds no `:last` entry back, since no
/// reading would answer it.
#[test]
fn a_class_no_listed_model_verifies_is_skipped_class_unverified_and_the_walk_goes_on() {
    let lane = ["--source-harness", "claude", "--source-flags", BYPASS];
    let controller = ["--controller", "--source-harness", "claude"];
    for (preference, args, entry, word, class, harness) in [
        (
            "codex:standard:high,claude:standard:high",
            &lane[..],
            "codex:standard:high",
            "standard",
            "standard",
            "codex",
        ),
        (
            "copilot:fast:high,claude:standard:high",
            &lane[..],
            "copilot:fast:high",
            "fast",
            "fast",
            "copilot",
        ),
        (
            "codex:standard:high,claude:standard:high:last",
            &lane[..],
            "codex:standard:high",
            "standard",
            "standard",
            "codex",
        ),
        (
            "codex:standard:high,claude:standard:high",
            &controller[..],
            "codex:standard:high",
            "standard",
            "standard",
            "codex",
        ),
        (
            "codex:2:high,claude:standard:high",
            &controller[..],
            "codex:2:high",
            "standard",
            "standard",
            "codex",
        ),
    ] {
        let key = if args.contains(&"--controller") {
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE"
        } else {
            PREFERENCE
        };
        let mut world = World::new(&[(key, preference)]);
        world.plant_listing(&[measured("aclaude", 20, 5), codex("codex", 20)]);
        let result = world.answered(args);
        assert_eq!(result["answer"], json!("lane"), "{preference}: {result}");
        let chosen = &result["chosen"];
        assert_eq!(
            chosen["entry"],
            json!(
                preference
                    .split(',')
                    .nth(1)
                    .unwrap()
                    .trim_end_matches(":last")
            ),
            "{preference}: {result}"
        );
        assert_eq!(chosen["model"], json!("opus"), "{preference}");
        assert_eq!(
            skipped(&result),
            [format!("{entry} class-unverified none")],
            "{preference}"
        );
        let row = &result["skipped"][0];
        assert_eq!(
            (&row["class"], &row["harness"]),
            (&json!(class), &json!(harness)),
            "{preference}"
        );
        assert_eq!(result["unread"], json!([]), "{preference}");
        let calls = world.kendex_calls();
        assert!(
            calls[0].starts_with(&format!(
                "tier-model {harness} --model {word} --json --runtime-context-json"
            )),
            "{preference}: {calls:?}"
        );
    }
}

/// A walk that judged no entry because none it reached had evidence, a class
/// no listed model verifies or a provider nobody here reads, refuses naming
/// each under its step, where `none` would read as no room; an entry judged
/// and refused for room keeps `none`, the class skip beside it.
#[test]
fn a_walk_that_judged_no_entry_for_want_of_evidence_refuses_by_name() {
    let args = ["--source-harness", "claude", "--source-flags", BYPASS];
    let pair = |k: &str, v: &str| (k.to_owned(), v.to_owned());
    let mut classes = World::new(&[(PREFERENCE, "codex:standard:high,copilot:fast:high")]);
    classes.plant_listing(&[codex("codex", 20)]);
    let (key, fields) = classes.refused(&args);
    assert_eq!(key, "account-unjudged");
    assert_eq!(
        fields,
        [
            pair("step", "class"),
            pair("entry", "codex:standard:high"),
            pair("class", "standard"),
            pair("harness", "codex"),
            pair("entry", "copilot:fast:high"),
            pair("class", "fast"),
            pair("harness", "copilot")
        ]
    );
    let mut overseer =
        World::new(&[("AGENT_RUNTIME_CONTROLLER_PREFERENCE", "codex:standard:high")]);
    overseer.plant_listing(&[codex("codex", 20)]);
    let (key, fields) = overseer.refused(&["--controller", "--source-harness", "claude"]);
    assert_eq!(key, "account-unjudged");
    assert_eq!(
        fields,
        [
            pair("step", "class"),
            pair("entry", "codex:standard:high"),
            pair("class", "standard"),
            pair("harness", "codex")
        ]
    );
    let mut mixed = World::new(&[(PREFERENCE, "claude@vm:fable:high,codex:standard:high")]);
    mixed.plant_listing(&[measured("aclaude", 10, 5), codex("codex", 20)]);
    let (key, fields) = mixed.refused(&args);
    assert_eq!(key, "account-unjudged");
    assert_eq!(
        fields,
        [
            pair("step", "host"),
            pair("host", "vm"),
            pair("cause", "no-provider"),
            pair("step", "class"),
            pair("entry", "codex:standard:high"),
            pair("class", "standard"),
            pair("harness", "codex")
        ]
    );
    let mut unbilled = World::new(&[(
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE",
        "pi:openai/gpt-5:high",
    )]);
    unbilled.plant_listing(&[measured("aclaude", 20, 5)]);
    let (key, fields) = unbilled.refused(&["--controller", "--source-harness", "pi"]);
    assert_eq!(key, "account-unjudged");
    assert_eq!(
        fields,
        [
            pair("step", "pick"),
            pair("entry", "pi:openai/gpt-5:high"),
            pair("cause", "unmeasured")
        ]
    );
    let mut unlisted = World::new(&[(PREFERENCE, "codex:gpt-6.1-sol:high")]);
    unlisted.plant_listing(&[measured("aclaude", 20, 5)]);
    let mut named = args.to_vec();
    named.extend(["--account", "aclaude"]);
    let (key, fields) = unlisted.refused(&named);
    assert_eq!(key, "account-unjudged");
    assert_eq!(
        fields,
        [
            pair("step", "pick"),
            pair("entry", "codex:gpt-6.1-sol:high"),
            pair("cause", "no-record")
        ]
    );
    let mut walled = World::new(&[(PREFERENCE, "codex:standard:high,claude:fable:high")]);
    walled.plant_listing(&[measured("aclaude", 96, 5)]);
    let result = walled.answered(&args);
    assert_eq!(result["answer"], json!("none"), "{result}");
    assert_eq!(
        skipped(&result),
        [
            "codex:standard:high class-unverified none".to_owned(),
            format!("claude:fable:high walled {}", walled.dir("aclaude"))
        ]
    );
}

/// The pick replies `tests/overseer-walk.sh` plants for the walk it runs,
/// one file per (harness, trigger, excluded account) its stand-in serves,
/// keyed as the stand-in keys them: orch's `tests/fixtures/accounts-pick`.
fn planted_pick_replies() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../orch/tests/fixtures/accounts-pick")
}

/// The epoch second the walk suite's pick replies are judged at: the
/// judgement takes its clock as an input, so the planted listing's sample
/// age and the score's reset bonus hold still between a capture and its
/// check.
const PICK_NOW: u64 = 1_769_700_000;

/// The walk suite's world as the verb reads it at [`PICK_NOW`]: the
/// controller's own Claude account at 57 percent of its weekly window (the
/// headroom trigger is 50), a second Claude account whose usage cannot be
/// read, and three Codex accounts at 22, 20 and 18 percent of their weekly
/// window, every reset far off, no burn, every usage sampled at that
/// second.
fn walk_suite_world() -> World {
    let mut world = World::new(&[("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "50")]);
    let far = "2099-08-01T06:00:00Z";
    let codex = |alias: &str, used: u64| {
        json!({"alias": alias, "harness": "codex", "config_dir": format!("/home/me/.{alias}"),
               "measured_through": "local", "status": "ok", "weekly_pct": used,
               "resets": {"weekly": "2099-01-01T00:00:00Z", "model": null, "monthly": null},
               "usage_age_s": 0})
    };
    world.plant_at(
        PICK_NOW,
        &[
            json!({"alias": "claude", "harness": "claude", "config_dir": "/home/me/.claude",
                   "measured_through": "local", "status": "ok", "plan": "max",
                   "weekly_pct": 57,
                   "model_buckets": [{"label": "Opus", "pct": 5, "resets_at": far}],
                   "resets": {"weekly": far, "model": far, "monthly": null},
                   "usage_age_s": 0}),
            json!({"alias": "unreadclaude", "harness": "claude", "config_dir": "/home/me/.unreadclaude",
                   "measured_through": "local", "status": "unreachable", "plan": "max", "usage_age_s": 0}),
            codex("codex", 22),
            codex("1codex", 20),
            codex("2codex", 18),
        ],
    );
    world.write_fleet(Some(&world.dir("claude")));
    world
}

/// A planted pick reply drifting from the verb's: the walk suite reads its
/// stand-in's replies as the verb's own, so each file it serves is the
/// reply `accounts pick --for-controller` prints over the suite's world, the
/// home as `@H@`. The judgement runs in process at [`PICK_NOW`], the one
/// input the executable adds from its own clock, and every field is
/// compared as printed; a difference names the file to re-capture from
/// this row's output.
#[test]
fn the_walk_suites_planted_pick_replies_are_the_verbs_own_over_its_world() {
    let world = walk_suite_world();
    let home = world.path().join("home").display().to_string();
    let loaded = world.settings();
    let env = loaded.env();
    let record = world.path().join(RECORD);
    let mut drifted = Vec::new();
    for (harness, trigger, excluded) in [
        (Harness::Claude, 50, "claude"),
        (Harness::Codex, 50, "claude"),
        (Harness::Claude, 90, "claude"),
        (Harness::Codex, 90, "claude"),
        (Harness::Codex, 50, "2codex"),
    ] {
        let request = PickRequest {
            harness,
            model: None,
            exclude: vec![world.dir(excluded)],
            for_overseer: true,
            lane: None,
            projected: false,
            max_pct: None,
            min_headroom_pct: Some(trigger),
            binding_floor: true,
            admit_unread_scope: false,
            opens_here: false,
        };
        let answer = here::pick(&env, world.path(), Some(&record), &request, PICK_NOW).unwrap();
        let verb = serde_json::to_value(Reply::ok(answer.reply())).unwrap();
        let key = format!("{harness}-{trigger}-{excluded}");
        let planted = std::fs::read_to_string(planted_pick_replies().join(format!("{key}.json")))
            .unwrap_or_default()
            .trim()
            .replace("@H@", &home);
        if verb != serde_json::from_str(&planted).unwrap_or(Value::Null) {
            drifted.push(format!(
                "{key}: the planted reply is not the verb's\nverb={}\nplanted={planted}",
                verb.to_string().replace(&home, "@H@")
            ));
        }
    }
    assert!(drifted.is_empty(), "{}", drifted.join("\n"));
}
