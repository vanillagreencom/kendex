//! `review-artifact path` and `review-artifact check`: each row runs the
//! built binary through `--text`, the form every workflow fence runs, over a
//! table of artifacts in a git worktree of its own, and asserts the exit
//! status, the result's reason and the detail's keyed first line a workflow
//! relays. The wait row drives the library on the injected clock.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write their own artifacts and item records and wait on the injected clock's thread"
)]

mod support;

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use orch_runtime::ops::artifact::Answer;
use orch_runtime::ops::review_artifact::{self as review, CheckArtifact};
use serde_json::{Value, json};
use support::{isolated, program, stderr};

const DELEG: u64 = 1_750_000_000;
const BEFORE: u64 = DELEG - 100;
const AFTER: u64 = DELEG + 100;
const LATER: u64 = DELEG + 200;
const LATER2: u64 = DELEG + 300;
const BLK: &str = "src/x.rs (`f`)";
const SUG: &str = "src/y.rs (`g`)";

struct World {
    _dir: tempfile::TempDir,
    root: PathBuf,
    wt: PathBuf,
    head: String,
}

struct Out {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Out {
    fn value(&self) -> Value {
        serde_json::from_str(self.stdout.trim()).unwrap_or_else(|e| {
            panic!(
                "stdout is no result object: {e}\n{}\n{}",
                self.stdout, self.stderr
            )
        })
    }

    fn reason(&self) -> String {
        self.value()["reason"].as_str().unwrap_or("").to_owned()
    }

    /// The detail's keyed first line, or `-` where the result carries none.
    fn first(&self) -> String {
        self.value()["detail"].as_str().map_or("-".to_owned(), |d| {
            d.lines().next().unwrap_or("").to_owned()
        })
    }

    fn refusal(&self) -> String {
        self.stderr.lines().next().unwrap_or("").to_owned()
    }
}

impl World {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let wt = root.join("wt");
        fs::create_dir_all(wt.join("tmp")).unwrap();
        for args in [
            &["init", "-q"][..],
            &["config", "gc.auto", "0"][..],
            &["config", "maintenance.auto", "false"][..],
            &["commit", "-q", "--allow-empty", "-m", "seed"][..],
        ] {
            let out = program("git")
                .arg("-C")
                .arg(&wt)
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        }
        let out = program("git")
            .arg("-C")
            .arg(&wt)
            .args(["rev-parse", "HEAD"])
            .output()
            .unwrap();
        let head = String::from_utf8(out.stdout).unwrap().trim().to_owned();
        World {
            _dir: dir,
            root,
            wt,
            head,
        }
    }

    /// `body` with the reviewed tree a reviewer records: this worktree's
    /// HEAD and no dirty path.
    fn stamped(&self, body: &str) -> String {
        let mut v: Value = serde_json::from_str(body).unwrap();
        v["head"] = json!(self.head);
        v["dirty_paths"] = json!([]);
        v.to_string()
    }

    /// `text` at `tmp/<name>` under the worktree, modified at `mtime`.
    fn put(&self, name: &str, text: &str, mtime: Option<u64>) -> PathBuf {
        let path = self.wt.join("tmp").join(name);
        fs::write(&path, text).unwrap();
        if let Some(mtime) = mtime {
            File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(UNIX_EPOCH + Duration::from_secs(mtime))
                .unwrap();
        }
        path
    }

    fn run<S: AsRef<std::ffi::OsStr>>(&self, args: &[S]) -> Out {
        let out = isolated()
            .args(["review-artifact", "--text"])
            .args(args)
            .output()
            .unwrap();
        Out {
            code: out.status.code(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }

    fn file(&self, path: &Path, extra: &[&str]) -> Out {
        let mut args: Vec<String> = vec![
            "check".into(),
            "--file".into(),
            path.display().to_string(),
            "--worktree".into(),
            self.wt.display().to_string(),
        ];
        args.extend(extra.iter().map(|s| (*s).to_owned()));
        self.run(&args)
    }

    /// One stamped artifact checked by `--file` with no boundary.
    fn body(&self, body: &str) -> Out {
        let path = self.put("review-external-F.json", &self.stamped(body), None);
        self.file(&path, &[])
    }

    fn glob(&self, agent: &str, extra: &[&str]) -> Out {
        let mut args: Vec<String> = vec![
            "check".into(),
            "--worktree".into(),
            self.wt.display().to_string(),
            "--agent".into(),
            agent.into(),
            "--delegated-at".into(),
            DELEG.to_string(),
        ];
        args.extend(extra.iter().map(|s| (*s).to_owned()));
        self.run(&args)
    }

    fn tmp(&self, name: &str) -> String {
        self.wt.join("tmp").join(name).display().to_string()
    }
}

/// Each case: label, artifact body (stamped with the reviewed tree), exit,
/// reason, the detail's first line (`-` none).
fn table(w: &World, rows: &[(&str, &str, i32, &str, &str)]) {
    for (label, body, code, reason, first) in rows {
        let out = w.body(body);
        assert_eq!(
            (out.code, out.reason(), out.first()),
            (Some(*code), (*reason).to_owned(), (*first).to_owned()),
            "{label}: {}",
            out.stdout
        );
    }
}

const PASS: &str = r#"{"verdict":"pass","items":[]}"#;
const QA_OK: &str = r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{}}"#;
const NOT_JSON: &str = "not json";

#[test]
fn path_mints_the_canonical_name_under_tmp_and_refuses_an_unsafe_agent_or_a_missing_worktree() {
    let w = World::new();
    fs::remove_dir(w.wt.join("tmp")).unwrap();
    let wt = w.wt.display().to_string();
    let out = w.run(&["path", "--worktree", &wt, "--agent", "reviewer-test"]);
    assert_eq!(out.code, Some(0), "{}", out.stderr);
    let printed = out.stdout.trim();
    let name = printed
        .strip_prefix(&format!("{wt}/tmp/review-reviewer-test-"))
        .and_then(|n| n.strip_suffix(".json"))
        .unwrap_or_else(|| panic!("not the canonical path: {printed}"));
    assert!(
        name.len() == 15
            && name.as_bytes()[8] == b'-'
            && name
                .bytes()
                .enumerate()
                .all(|(i, b)| i == 8 || b.is_ascii_digit()),
        "not YYYYMMDD-HHMMSS: {name}"
    );
    assert!(fs::metadata(w.wt.join("tmp")).unwrap().is_dir());
    let rows: [(&str, String, &str, String); 3] = [
        (
            "a path-unsafe agent name",
            wt.clone(),
            "evil/../name",
            "review-artifact-check: agent value=evil/../name".into(),
        ),
        (
            "an empty agent name",
            wt.clone(),
            "",
            "review-artifact-check: agent value=".into(),
        ),
        (
            "a missing worktree",
            format!("{wt}/nope"),
            "reviewer-test",
            format!("review-artifact-check: worktree path={wt}/nope"),
        ),
    ];
    for (label, worktree, agent, refusal) in rows {
        let out = w.run(&["path", "--worktree", &worktree, "--agent", agent]);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.refusal()),
            (Some(2), "", refusal),
            "{label}"
        );
    }
    let dotted = w.run(&["path", "--worktree", &wt, "--agent", "a..b"]);
    assert_eq!(
        dotted.code,
        Some(0),
        "the released grammar admits dots: {}",
        dotted.stderr
    );
}

#[test]
fn file_mode_checks_existence_then_freshness_then_one_json_value_with_a_verdict() {
    let w = World::new();
    let deleg = DELEG.to_string();
    let file = |name: &str, text: &str, mtime: Option<u64>, boundary: bool| {
        let path = w.put(name, text, mtime);
        let out = if boundary {
            w.file(&path, &["--delegated-at", &deleg])
        } else {
            w.file(&path, &[])
        };
        (path, out)
    };
    let pass = w.stamped(PASS);
    let two = format!("{pass}\n{pass}");
    let no_verdict = w.stamped(r#"{"items":[]}"#);
    let stale = format!("review-artifact-check: stale mtime={BEFORE} delegated_at={DELEG}");
    let verdict = "review-artifact-check: verdict field=verdict state=missing_or_null";
    for (label, text, mtime, boundary, code, reason, first) in [
        ("a valid file", pass.as_str(), None, false, 0, "valid", "-"),
        (
            "two complete values",
            &two,
            None,
            false,
            1,
            "invalid",
            "review-artifact-check: value_count count=2",
        ),
        (
            "an old mtime without a boundary",
            &pass,
            Some(BEFORE),
            false,
            0,
            "valid",
            "-",
        ),
        (
            "an mtime before the boundary",
            &pass,
            Some(BEFORE),
            true,
            1,
            "stale",
            stale.as_str(),
        ),
        (
            "an mtime after the boundary",
            &pass,
            Some(AFTER),
            true,
            0,
            "valid",
            "-",
        ),
        (
            "an mtime equal to the boundary",
            &pass,
            Some(DELEG),
            true,
            0,
            "valid",
            "-",
        ),
        (
            "fresh but without a verdict",
            &no_verdict,
            Some(AFTER),
            true,
            1,
            "invalid",
            verdict,
        ),
        (
            "a false verdict",
            &w.stamped(r#"{"verdict":false}"#),
            None,
            false,
            1,
            "invalid",
            verdict,
        ),
        (
            "a null verdict",
            &w.stamped(r#"{"verdict":null}"#),
            None,
            false,
            1,
            "invalid",
            verdict,
        ),
        (
            "any other verdict value is one",
            &w.stamped(r#"{"verdict":"action_required"}"#),
            None,
            false,
            0,
            "valid",
            "-",
        ),
        (
            "a JSON value that is no object",
            "[1]",
            None,
            false,
            1,
            "invalid",
            verdict,
        ),
    ] {
        let (_, out) = file("review-external-F.json", text, mtime, boundary);
        assert_eq!(
            (out.code, out.reason(), out.first()),
            (Some(code), reason.to_owned(), first.to_owned()),
            "{label}: {}",
            out.stdout
        );
    }
    let (path, out) = file("review-external-F.json", &pass, None, false);
    assert_eq!(out.value()["path"], json!(path), "the path as given");
    for (label, text) in [
        ("not JSON", NOT_JSON),
        ("an empty file", ""),
        ("a value then garbage", "{\"verdict\":\"pass\"} x"),
    ] {
        let (path, out) = file("review-external-F.json", text, None, false);
        assert_eq!(
            (out.code, out.reason(), out.first()),
            (
                Some(1),
                "invalid".to_owned(),
                format!("review-artifact-check: unparsable path={}", path.display())
            ),
            "{label}"
        );
    }
    let full = w.stamped(r#"{"agent":"r","verdict":"pass","summary":"s","blockers":[{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":1}],"suggestions":[],"qa_metadata":{"x":1}}"#);
    for pct in [20, 40, 60, 80, 90, 95, 99] {
        let (_, out) = file("trunc.json", &full[..full.len() * pct / 100], None, false);
        assert_eq!(
            (out.code, out.reason()),
            (Some(1), "invalid".to_owned()),
            "a prefix truncation at {pct}%"
        );
    }
    for (label, missing, boundary) in [
        ("a missing file", w.tmp("nope.json"), false),
        ("a missing file with a boundary", w.tmp("nope.json"), true),
        ("a directory", w.wt.display().to_string(), false),
    ] {
        let mut extra = vec![];
        if boundary {
            extra = vec!["--delegated-at", deleg.as_str()];
        }
        let out = w.file(Path::new(&missing), &extra);
        assert_eq!(
            (
                out.code,
                out.value()["path"].clone(),
                out.reason(),
                out.first()
            ),
            (
                Some(1),
                Value::Null,
                "missing".to_owned(),
                format!("review-artifact-check: missing path={missing}")
            ),
            "{label}"
        );
    }
    let out = w.body(r#"{"verdict":"pass","qa_metadata":{"review_performed":false}}"#);
    assert_eq!(
        (out.code, out.value()["path"].clone(), out.reason()),
        (
            Some(1),
            json!(w.tmp("review-external-F.json")),
            "no_review".to_owned()
        ),
        "a content gate's rejection names its file"
    );
}

#[test]
fn glob_mode_answers_the_newest_fresh_artifact_and_falls_back_only_past_stale_or_unparsable_siblings()
 {
    let pass = |w: &World| w.stamped(QA_OK);
    let noverdict = |w: &World| w.stamped(r#"{"items":[]}"#);
    let noreview = |w: &World| {
        w.stamped(r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":false}}"#)
    };
    let zeroed = |w: &World| w.stamped(r#"{"verdict":"pass","summary":"mutation: killed 0/0"}"#);
    let two = |w: &World| format!("{}\n{}", w.stamped(QA_OK), w.stamped(QA_OK));
    let notjson = |_: &World| NOT_JSON.to_owned();
    type Body = fn(&World) -> String;
    /// label, files (name, body, mtime), exit, reason, the reported file
    type Row<'a> = (
        &'a str,
        Vec<(&'a str, Body, u64)>,
        i32,
        &'a str,
        Option<&'a str>,
    );
    let rows: Vec<Row> = vec![
        ("no artifact at all", vec![], 1, "missing", None),
        (
            "another agent's fresh artifact",
            vec![("review-other-1.json", pass, AFTER)],
            1,
            "missing",
            None,
        ),
        (
            "an artifact older than the boundary",
            vec![("review-q-1.json", pass, BEFORE)],
            1,
            "stale",
            Some("review-q-1.json"),
        ),
        (
            "an mtime equal to the boundary",
            vec![("review-q-1.json", pass, DELEG)],
            0,
            "valid",
            Some("review-q-1.json"),
        ),
        (
            "two values are terminal over an older valid sibling",
            vec![
                ("review-q-0.json", pass, AFTER),
                ("review-q-1.json", two, LATER),
            ],
            1,
            "invalid",
            Some("review-q-1.json"),
        ),
        (
            "the newest failure is reported",
            vec![
                ("review-q-1.json", pass, BEFORE),
                ("review-q-2.json", noverdict, AFTER),
            ],
            1,
            "invalid",
            Some("review-q-2.json"),
        ),
        (
            "a fresh valid artifact wins over stale and invalid ones",
            vec![
                ("review-q-1.json", pass, BEFORE),
                ("review-q-2.json", noverdict, AFTER),
                ("review-q-3.json", pass, LATER),
            ],
            0,
            "valid",
            Some("review-q-3.json"),
        ),
        (
            "an unparsable newest falls back to an older valid one",
            vec![
                ("review-q-3.json", pass, LATER),
                ("review-q-4.json", notjson, LATER2),
            ],
            0,
            "valid",
            Some("review-q-3.json"),
        ),
        (
            "modification time, not the name, orders the files",
            vec![
                ("review-q-9.json", noverdict, AFTER),
                ("review-q-1.json", pass, LATER),
            ],
            0,
            "valid",
            Some("review-q-1.json"),
        ),
        (
            "a no-review report is terminal",
            vec![
                ("review-q-0.json", pass, AFTER),
                ("review-q-1.json", noreview, LATER),
            ],
            1,
            "no_review",
            Some("review-q-1.json"),
        ),
        (
            "a stale no-review report blocks nothing",
            vec![
                ("review-q-0.json", pass, AFTER),
                ("review-q-1.json", noreview, BEFORE),
            ],
            0,
            "valid",
            Some("review-q-0.json"),
        ),
        (
            "a zero sample is terminal",
            vec![
                ("review-q-0.json", pass, AFTER),
                ("review-q-1.json", zeroed, LATER),
            ],
            1,
            "zero_sample",
            Some("review-q-1.json"),
        ),
        (
            "a stale zero sample blocks nothing",
            vec![
                ("review-q-0.json", pass, AFTER),
                ("review-q-1.json", zeroed, BEFORE),
            ],
            0,
            "valid",
            Some("review-q-0.json"),
        ),
    ];
    for (label, files, code, reason, reported) in rows {
        let w = World::new();
        for (name, body, mtime) in files {
            w.put(name, &body(&w), Some(mtime));
        }
        let out = w.glob("q", &[]);
        assert_eq!(
            (out.code, out.reason(), out.value()["path"].clone()),
            (
                Some(code),
                reason.to_owned(),
                reported.map_or(Value::Null, |n| json!(w.tmp(n)))
            ),
            "{label}: {}",
            out.stdout
        );
    }
    let w = World::new();
    let missing = w.glob("ghost-agent", &[]);
    assert_eq!(
        missing.first(),
        format!(
            "review-artifact-check: missing_glob pattern={}/tmp/review-ghost-agent-*.json",
            w.wt.display()
        )
    );
    w.put("review-staleonly-1.json", &pass(&w), Some(BEFORE));
    assert_eq!(
        w.glob("staleonly", &[]).first(),
        format!("review-artifact-check: stale mtime={BEFORE} delegated_at={DELEG}")
    );
}

#[test]
fn the_artifact_must_name_the_worktree_head_with_no_dirty_paths() {
    let w = World::new();
    let h = &w.head;
    for (label, body, first) in [
        (
            "a dirty starting tree",
            json!({"verdict":"pass","head":h,"dirty_paths":["src/changed.rs"]}),
            format!(
                "review-artifact-check: moving_tree head=\"{h}\" expected={h} dirty_paths=[\"src/changed.rs\"]"
            ),
        ),
        (
            "a different starting head",
            json!({"verdict":"pass","head":"previous-commit","dirty_paths":[]}),
            format!(
                "review-artifact-check: moving_tree head=\"previous-commit\" expected={h} dirty_paths=[]"
            ),
        ),
        (
            "a missing starting head",
            json!({"verdict":"pass","dirty_paths":[]}),
            format!("review-artifact-check: moving_tree head=null expected={h} dirty_paths=[]"),
        ),
        (
            "missing dirty paths",
            json!({"verdict":"pass","head":h}),
            format!(
                "review-artifact-check: moving_tree head=\"{h}\" expected={h} dirty_paths=null"
            ),
        ),
    ] {
        let path = w.put("review-external-F.json", &body.to_string(), None);
        let file = w.file(&path, &[]);
        let glob_name = w.put("review-ext-1.json", &body.to_string(), Some(AFTER));
        let glob = w.glob("ext", &[]);
        fs::remove_file(glob_name).unwrap();
        for out in [file, glob] {
            assert_eq!(
                (out.code, out.reason(), out.first()),
                (Some(1), "moving_tree".to_owned(), first.clone()),
                "{label}"
            );
        }
    }
    let bare = w.root.join("bare");
    fs::create_dir_all(&bare).unwrap();
    let path = w.put("review-external-F.json", &w.stamped(PASS), None);
    let out = w.run(&[
        "check",
        "--file",
        &path.display().to_string(),
        "--worktree",
        &bare.display().to_string(),
    ]);
    assert_eq!(
        (out.code, out.reason(), out.first()),
        (
            Some(1),
            "invalid".to_owned(),
            format!(
                "review-artifact-check: head_read worktree={}",
                bare.display()
            )
        ),
        "a worktree whose HEAD cannot be read"
    );
}

#[test]
fn a_self_reported_no_review_is_refused() {
    let w = World::new();
    let flag = "review-artifact-check: no_review review_performed=false";
    table(
        &w,
        &[
            (
                "review_performed false",
                r#"{"verdict":"pass","summary":"No review was actually performed","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}"#,
                1,
                "no_review",
                flag,
            ),
            (
                "a no-review reason alone",
                r#"{"verdict":"pass","qa_metadata":{"reason":"no_scope_provided"}}"#,
                1,
                "no_review",
                r#"review-artifact-check: no_review review_reason="no_scope_provided""#,
            ),
            (
                "review_performed false, arrays present",
                r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":false}}"#,
                1,
                "no_review",
                flag,
            ),
            (
                "a reason in any case and spelling",
                r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"reason":"Not-Reviewed"}}"#,
                1,
                "no_review",
                r#"review-artifact-check: no_review review_reason="Not-Reviewed""#,
            ),
            (
                "no review written apart",
                r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"reason":"there was no review"}}"#,
                1,
                "no_review",
                r#"review-artifact-check: no_review review_reason="there was no review""#,
            ),
            (
                "a reason that admits nothing",
                r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"reason":"reviewed in full"}}"#,
                0,
                "valid",
                "-",
            ),
            (
                "an empty qa_metadata with the arrays",
                QA_OK,
                0,
                "valid",
                "-",
            ),
            (
                "review_performed true",
                r#"{"verdict":"pass","blockers":[],"suggestions":[],"qa_metadata":{"review_performed":true}}"#,
                0,
                "valid",
                "-",
            ),
        ],
    );
}

#[test]
fn a_qa_shaped_artifact_carries_both_finding_arrays() {
    let w = World::new();
    let arrays = |bad: &str| format!("review-artifact-check: finding_arrays {bad}");
    let rows: Vec<(&str, &str, i32, &str, String)> = vec![
        (
            "qa-shaped without the arrays",
            r#"{"agent":"external-codex","verdict":"pass","summary":"looks fine","qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("blockers=absent suggestions=absent"),
        ),
        (
            "a null blockers",
            r#"{"verdict":"pass","blockers":null,"suggestions":[],"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("blockers=null"),
        ),
        (
            "an object blockers",
            r#"{"verdict":"pass","blockers":{},"suggestions":[],"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("blockers=object"),
        ),
        (
            "a string blockers",
            r#"{"verdict":"pass","blockers":"none","suggestions":[],"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("blockers=string"),
        ),
        (
            "a number blockers",
            r#"{"verdict":"pass","blockers":3,"suggestions":[],"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("blockers=number"),
        ),
        (
            "missing suggestions alone",
            r#"{"verdict":"pass","blockers":[],"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("suggestions=absent"),
        ),
        (
            "a null suggestions",
            r#"{"verdict":"pass","blockers":[],"suggestions":null,"qa_metadata":{}}"#,
            1,
            "incomplete",
            arrays("suggestions=null"),
        ),
        (
            "questions[] is not required",
            QA_OK,
            0,
            "valid",
            "-".to_owned(),
        ),
        (
            "no qa_metadata needs no arrays",
            r#"{"verdict":"pass"}"#,
            0,
            "valid",
            "-".to_owned(),
        ),
        (
            "a qa_metadata that is no object needs no arrays",
            r#"{"verdict":"pass","qa_metadata":"see summary"}"#,
            0,
            "valid",
            "-".to_owned(),
        ),
    ];
    for (label, body, code, reason, first) in rows {
        table(&w, &[(label, body, code, reason, &first)]);
    }
}

#[test]
fn every_finding_item_carries_the_schema_fields_and_the_first_offender_is_named() {
    let w = World::new();
    let item = |path: &str, missing: &str, invalid: &str| {
        format!(
            "review-artifact-check: finding_item path={path} missing={missing} invalid={invalid}"
        )
    };
    let ok = r#"{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2}"#;
    let with = |blockers: &str, suggestions: &str| {
        format!(
            r#"{{"verdict":"pass","blockers":[{blockers}],"suggestions":[{suggestions}],"qa_metadata":{{}}}}"#
        )
    };
    let sug = |extra: &str| {
        format!(
            r#"{{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":3,"estimate":2{extra}}}"#
        )
    };
    let rows: Vec<(&str, String, i32, &str, String)> = vec![
        (
            "the issue's malformed suggestion",
            with(
                "",
                r#"{"title":"Two resolvers coexist","location":"/abs/x.rs (f)","detail":"...","severity":"low"}"#,
            ),
            1,
            "incomplete",
            item(
                "suggestions[0]",
                "id,description,recommendation,priority,estimate,category",
                "",
            ),
        ),
        (
            "a fully compliant artifact",
            with(ok, &sug(r#","category":"fix""#)),
            0,
            "valid",
            "-".into(),
        ),
        (
            "a suggestion missing only category",
            with("", &sug("")),
            1,
            "incomplete",
            item("suggestions[0]", "category", ""),
        ),
        (
            "a category outside fix and issue",
            with("", &sug(r#","category":"low""#)),
            1,
            "incomplete",
            item("suggestions[0]", "", "category:enum"),
        ),
        (
            "a blocker missing a base field",
            with(
                r#"{"id":1,"title":"t","location":"l","recommendation":"r","priority":1,"estimate":2}"#,
                "",
            ),
            1,
            "incomplete",
            item("blockers[0]", "description", ""),
        ),
        (
            "a blocker needs no category",
            with(ok, ""),
            0,
            "valid",
            "-".into(),
        ),
        (
            "a priority above 4",
            with(
                "",
                r#"{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":5,"estimate":2,"category":"fix"}"#,
            ),
            1,
            "incomplete",
            item("suggestions[0]", "", "priority:range[1,4]"),
        ),
        (
            "a string estimate",
            with(
                "",
                r#"{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":2,"estimate":"2","category":"fix"}"#,
            ),
            1,
            "incomplete",
            item("suggestions[0]", "", "estimate:range[1,5]"),
        ),
        (
            "a blocker priority below 1",
            with(
                r#"{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":0,"estimate":3}"#,
                "",
            ),
            1,
            "incomplete",
            item("blockers[0]", "", "priority:range[1,4]"),
        ),
        (
            "priority 4 and estimate 5 are in range",
            with(
                "",
                r#"{"id":1,"title":"t","location":"l","description":"d","recommendation":"r","priority":4,"estimate":5,"category":"fix"}"#,
            ),
            0,
            "valid",
            "-".into(),
        ),
        (
            "an issue finding without impact",
            with("", &sug(r#","category":"issue""#)),
            1,
            "incomplete",
            item("suggestions[0]", "impact", ""),
        ),
        (
            "an issue finding with a blank impact",
            with("", &sug(r#","category":"issue","impact":" ""#)),
            1,
            "incomplete",
            item("suggestions[0]", "", "impact:blank"),
        ),
        (
            "an issue finding with its impact",
            with(
                "",
                &sug(r#","category":"issue","impact":"nightly importers hit it""#),
            ),
            0,
            "valid",
            "-".into(),
        ),
        (
            "a null field is missing",
            with(
                r#"{"id":null,"title":"t","location":"l","description":"d","recommendation":"r","priority":1,"estimate":2}"#,
                "",
            ),
            1,
            "incomplete",
            item("blockers[0]", "id", ""),
        ),
        (
            "a finding that is no object",
            with(r#""see the thread""#, ""),
            1,
            "incomplete",
            item(
                "blockers[0]",
                "id,title,location,description,recommendation,priority,estimate",
                "",
            ),
        ),
        (
            "blockers are judged before suggestions",
            with(r#"{"id":1}"#, r#"{"id":1}"#),
            1,
            "incomplete",
            item(
                "blockers[0]",
                "title,location,description,recommendation,priority,estimate",
                "",
            ),
        ),
        (
            "the first offending item is named",
            with("", &format!("{},{}", sug(r#","category":"fix""#), sug(""))),
            1,
            "incomplete",
            item("suggestions[1]", "category", ""),
        ),
        (
            "malformed items without qa_metadata stay tolerant",
            r#"{"verdict":"pass","suggestions":[{"title":"t","location":"l"}]}"#.into(),
            0,
            "valid",
            "-".into(),
        ),
    ];
    for (label, body, code, reason, first) in rows {
        table(&w, &[(label, &body, code, reason, &first)]);
    }
}

#[test]
fn a_zero_sample_citation_is_refused_and_a_zero_result_is_not() {
    let w = World::new();
    let mutation = "review-artifact-check: zero_sample measurement=mutation samples=0";
    let stability = "review-artifact-check: zero_sample measurement=stability samples=0";
    let threads = "review-artifact-check: zero_sample measurement=stability threads=0";
    table(
        &w,
        &[
            (
                "a zero-mutant citation",
                r#"{"verdict":"pass","summary":"validated: mutation: killed 0/0; stability: 10/10 at 16 threads"}"#,
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a zero-run stability citation",
                r#"{"verdict":"pass","summary":"mutation: killed 3/3; stability: 0/0 at 16 threads"}"#,
                1,
                "zero_sample",
                stability,
            ),
            (
                "zero threads",
                r#"{"verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 0 threads"}"#,
                1,
                "zero_sample",
                threads,
            ),
            (
                "stability 0/10 is ten measured runs",
                r#"{"verdict":"action_required","summary":"mutation: killed 3/3; stability: 0/10 at 16 threads"}"#,
                0,
                "valid",
                "-",
            ),
            (
                "killed 0/3 is three measured mutants",
                r#"{"verdict":"action_required","summary":"mutation: killed 0/3; stability: 10/10 at 16 threads"}"#,
                0,
                "valid",
                "-",
            ),
            (
                "a partial kill and partial stability",
                r#"{"verdict":"action_required","summary":"mutation: killed 2/3; stability: 9/10 at 16 threads"}"#,
                0,
                "valid",
                "-",
            ),
            (
                "a citation quoted in a blocker",
                r#"{"verdict":"action_required","summary":"s","blockers":[{"id":1,"title":"t","location":"l","description":"the fixture proves mutation: killed 0/0","recommendation":"r","priority":2,"estimate":2}],"suggestions":[],"qa_metadata":{}}"#,
                0,
                "valid",
                "-",
            ),
            (
                "a citation quoted in a question",
                r#"{"verdict":"pass","summary":"s","blockers":[],"suggestions":[],"questions":[{"id":1,"question":"is mutation: killed 0/0 expected?"}],"qa_metadata":{}}"#,
                0,
                "valid",
                "-",
            ),
            (
                "the same text in .summary",
                r#"{"verdict":"pass","summary":"the fixture proves mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{}}"#,
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a citation nested in qa_metadata",
                r#"{"verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"test_qa":{"notes":["x","mutation: killed 0/0"]}}}"#,
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a citation wrapped across a newline",
                "{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/\\n0\"}",
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a newline after stability:",
                "{\"verdict\":\"pass\",\"summary\":\"stability:\\n0/0 at 16 threads\"}",
                1,
                "zero_sample",
                stability,
            ),
            (
                "a newline before a zero thread count",
                "{\"verdict\":\"pass\",\"summary\":\"stability: 10/10 at\\n0 threads\"}",
                1,
                "zero_sample",
                threads,
            ),
            (
                "the citation read case-blind",
                r#"{"verdict":"pass","summary":"Mutation: KILLED 00/00"}"#,
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a zero sample count before a zero thread count",
                r#"{"verdict":"pass","summary":"stability: 10/10 at 0 threads; mutation: killed 0/0"}"#,
                1,
                "zero_sample",
                mutation,
            ),
            (
                "a nonzero citation",
                r#"{"verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}"#,
                0,
                "valid",
                "-",
            ),
            (
                "an artifact citing no measurement",
                r#"{"verdict":"pass","summary":"no measurement was needed"}"#,
                0,
                "valid",
                "-",
            ),
        ],
    );
    let out = w.body(r#"{"verdict":"pass","summary":"mutation: killed 0/0"}"#);
    let detail = out.value()["detail"].as_str().unwrap().to_owned();
    assert!(
        detail.starts_with(&format!(
            "{mutation}\nThe citation \"killed 0/0\" reports no samples.\n"
        )) && detail.contains("TOP-LEVEL measurement_failed"),
        "the rejection quotes the citation and teaches the declaration: {detail}"
    );
}

#[test]
fn a_perf_payload_carries_the_evidence_its_metric_kind_produces() {
    let w = World::new();
    let perf = |pq: &str| {
        format!(
            r#"{{"verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{{"perf_qa":{pq}}}}}"#
        )
    };
    let at = |field: &str, rest: &str| {
        format!("review-artifact-check: perf_evidence field=qa_metadata.perf_qa{field} {rest}")
    };
    let ic = r#"{"bench_a":{"baseline":1204883,"current":1204883}}"#;
    let pc = r#"{"halt":{"mailboxes":[1,10,40],"baseline":[19,37,97],"changed":[13,13,13]}}"#;
    let rows: Vec<(&str, String, i32, &str, String)> = vec![
        (
            "percentiles missing",
            perf(r#"{"regression_pct":0}"#),
            1,
            "zero_sample",
            at(".percentiles", "state=missing"),
        ),
        (
            "percentiles null",
            perf(r#"{"percentiles":null}"#),
            1,
            "zero_sample",
            at(".percentiles", "state=missing"),
        ),
        (
            "percentiles an empty object",
            perf(r#"{"percentiles":{}}"#),
            1,
            "zero_sample",
            at(".percentiles", "count=0"),
        ),
        (
            "percentiles an empty array",
            perf(r#"{"percentiles":[]}"#),
            1,
            "zero_sample",
            at(".percentiles", "count=0"),
        ),
        (
            "percentiles all zero",
            perf(r#"{"percentiles":{"p50":0,"p99":0}}"#),
            1,
            "zero_sample",
            at(".percentiles", "positive_values=0"),
        ),
        (
            "percentiles zero-valued strings",
            perf(r#"{"percentiles":{"p50":"0ms"}}"#),
            1,
            "zero_sample",
            at(".percentiles", "positive_values=0"),
        ),
        (
            "percentiles null leaves",
            perf(r#"{"percentiles":{"p50":null}}"#),
            1,
            "zero_sample",
            at(".percentiles", "positive_values=0"),
        ),
        (
            "percentiles a bare string",
            perf(r#"{"percentiles":"none recorded"}"#),
            1,
            "zero_sample",
            at(".percentiles", "type=string"),
        ),
        (
            "perf_qa itself not an object",
            perf(r#""benchmarks ran""#),
            1,
            "zero_sample",
            at("", "type=string"),
        ),
        (
            "one real number among zeros",
            perf(r#"{"percentiles":{"p50":0,"p99":4.2}}"#),
            0,
            "valid",
            "-".into(),
        ),
        (
            "a nested positive number",
            perf(r#"{"percentiles":[[0,1.5]]}"#),
            0,
            "valid",
            "-".into(),
        ),
        ("no perf_qa payload", perf("null"), 0, "valid", "-".into()),
        (
            "an explicit latency kind still requires percentiles",
            perf(&format!(
                r#"{{"metric_kind":"latency","percentiles":{{}},"instruction_counts":{ic}}}"#
            )),
            1,
            "zero_sample",
            at(".percentiles", "count=0"),
        ),
        (
            "an explicit latency kind with a measured percentile",
            perf(r#"{"metric_kind":"latency","percentiles":{"p99":4.2}}"#),
            0,
            "valid",
            "-".into(),
        ),
        (
            "an unknown metric kind",
            perf(r#"{"metric_kind":"throughput","percentiles":{"p99":4.2}}"#),
            1,
            "zero_sample",
            at(".metric_kind", r#"value="throughput""#),
        ),
        (
            "a non-string metric kind",
            perf(r#"{"metric_kind":1,"percentiles":{"p99":4.2}}"#),
            1,
            "zero_sample",
            at(".metric_kind", "type=number"),
        ),
        (
            "percentiles do not stand in for instruction counts",
            perf(r#"{"metric_kind":"instruction_count","percentiles":{"p99":4.2}}"#),
            1,
            "zero_sample",
            at(".instruction_counts", "state=missing"),
        ),
        (
            "measured instruction counts with empty percentiles",
            perf(&format!(
                r#"{{"metric_kind":"instruction_count","percentiles":{{}},"instruction_counts":{ic}}}"#
            )),
            0,
            "valid",
            "-".into(),
        ),
        (
            "instruction counts an empty object",
            perf(r#"{"metric_kind":"instruction_count","instruction_counts":{}}"#),
            1,
            "zero_sample",
            at(".instruction_counts", "count=0"),
        ),
        (
            "instruction counts all zero",
            perf(
                r#"{"metric_kind":"instruction_count","instruction_counts":{"a":{"baseline":0}}}"#,
            ),
            1,
            "zero_sample",
            at(".instruction_counts", "positive_values=0"),
        ),
        (
            "instruction counts a bare string",
            perf(r#"{"metric_kind":"instruction_count","instruction_counts":"12"}"#),
            1,
            "zero_sample",
            at(".instruction_counts", "type=string"),
        ),
        (
            "measured process counts",
            perf(&format!(
                r#"{{"metric_kind":"process_count","percentiles":{{}},"process_counts":{pc}}}"#
            )),
            0,
            "valid",
            "-".into(),
        ),
        (
            "percentiles do not replace process counts",
            perf(r#"{"metric_kind":"process_count","percentiles":{"p99":4.2}}"#),
            1,
            "zero_sample",
            at(".process_counts", "state=missing"),
        ),
        (
            "process counts an empty array",
            perf(r#"{"metric_kind":"process_count","process_counts":[]}"#),
            1,
            "zero_sample",
            at(".process_counts", "count=0"),
        ),
        (
            "process counts all zero",
            perf(r#"{"metric_kind":"process_count","process_counts":{"halt":{"baseline":[0,0]}}}"#),
            1,
            "zero_sample",
            at(".process_counts", "positive_values=0"),
        ),
        (
            "process_counts is not a metric kind",
            perf(&format!(
                r#"{{"metric_kind":"process_counts","process_counts":{pc}}}"#
            )),
            1,
            "zero_sample",
            at(".metric_kind", r#"value="process_counts""#),
        ),
        (
            "bytes per minute as a measure",
            perf(
                r#"{"metric_kind":"measure","name":"tui_bytes","unit":"bytes/min","values":{"on":2584784.2,"off":24542.8},"samples":2}"#,
            ),
            0,
            "valid",
            "-".into(),
        ),
        (
            "a measured zero result",
            perf(
                r#"{"metric_kind":"measure","name":"dropped_frames","unit":"frames","values":{"changed":0},"samples":10}"#,
            ),
            0,
            "valid",
            "-".into(),
        ),
        (
            "samples zero",
            perf(
                r#"{"metric_kind":"measure","name":"n","unit":"ns mean","values":{"b":412.7},"samples":0}"#,
            ),
            1,
            "zero_sample",
            at(".samples", "value=0"),
        ),
        (
            "samples missing",
            perf(r#"{"metric_kind":"measure","name":"n","unit":"ns mean","values":{"b":412.7}}"#),
            1,
            "zero_sample",
            at(".samples", "value=null"),
        ),
        (
            "samples a string",
            perf(
                r#"{"metric_kind":"measure","name":"n","unit":"ns mean","values":{"b":412.7},"samples":"10000"}"#,
            ),
            1,
            "zero_sample",
            at(".samples", r#"value="10000""#),
        ),
        (
            "no numeric value",
            perf(
                r#"{"metric_kind":"measure","name":"n","unit":"u","values":{"on":"2.5 MB"},"samples":2}"#,
            ),
            1,
            "zero_sample",
            at(".values", "numeric_values=0"),
        ),
        (
            "values not an object",
            perf(
                r#"{"metric_kind":"measure","name":"n","unit":"u","values":2584784.2,"samples":2}"#,
            ),
            1,
            "zero_sample",
            at(".values", "numeric_values=0"),
        ),
        (
            "name missing",
            perf(r#"{"metric_kind":"measure","unit":"u","values":{"on":1},"samples":2}"#),
            1,
            "zero_sample",
            at(".name", "value=null"),
        ),
        (
            "unit missing",
            perf(r#"{"metric_kind":"measure","name":"n","values":{"on":1},"samples":2}"#),
            1,
            "zero_sample",
            at(".unit", "value=null"),
        ),
        (
            "unit blank",
            perf(
                r#"{"metric_kind":"measure","name":"n","unit":" ","values":{"on":1},"samples":2}"#,
            ),
            1,
            "zero_sample",
            at(".unit", r#"value=" ""#),
        ),
    ];
    for (label, body, code, reason, first) in rows {
        table(&w, &[(label, &body, code, reason, &first)]);
    }
}

#[test]
fn a_declaration_names_its_instrument_and_silences_only_the_measurement_gate_visibly() {
    let w = World::new();
    let declared = |m: &str| {
        format!(
            r#"{{"verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":{m}}}"#
        )
    };
    let refused = |what: &str| format!("review-artifact-check: measurement_declaration {what}");
    let rows: Vec<(&str, String, i32, &str, String)> = vec![
        ("a single period", declared(r#"".""#), 1, "invalid_declaration", refused("state=punctuation")),
        ("n/a", declared(r#""n/a""#), 1, "invalid_declaration", refused(r#"state=null_token value="n/a""#)),
        ("N/A with punctuation", declared(r#""N/A.""#), 1, "invalid_declaration", refused(r#"state=null_token value="N/A.""#)),
        ("none", declared(r#""none""#), 1, "invalid_declaration", refused(r#"state=null_token value="none""#)),
        ("unknown", declared(r#""unknown""#), 1, "invalid_declaration", refused(r#"state=null_token value="unknown""#)),
        ("unavailable", declared(r#""unavailable""#), 1, "invalid_declaration", refused(r#"state=null_token value="unavailable""#)),
        ("tbd", declared(r#""tbd""#), 1, "invalid_declaration", refused(r#"state=null_token value="tbd""#)),
        ("bare punctuation", declared(r#""---""#), 1, "invalid_declaration", refused("state=punctuation")),
        ("long bare punctuation", declared(r#""---------------------------""#), 1, "invalid_declaration", refused("state=punctuation")),
        ("whitespace only", declared(r#""   ""#), 1, "invalid_declaration", refused("state=blank")),
        ("one long word", declared(r#""instrumentfailedbadly""#), 1, "invalid_declaration", refused("words=1 minimum=3")),
        ("two words past the length floor", declared(r#""cargo-mutants produced-no-samples-at-all""#), 1, "invalid_declaration", refused("words=2 minimum=3")),
        ("three tiny words", declared(r#""a b c""#), 1, "invalid_declaration", refused("characters=5 minimum=20")),
        ("19 characters, 3 words", declared(r#""aa bbbb ccccccccccc""#), 1, "invalid_declaration", refused("characters=19 minimum=20")),
        ("a boolean", declared("true"), 1, "invalid_declaration", refused("type=boolean")),
        ("a number", declared("0"), 1, "invalid_declaration", refused("type=number")),
        ("an object", declared(r#"{"why":"broke"}"#), 1, "invalid_declaration", refused("type=object")),
        ("an array", declared(r#"["broke"]"#), 1, "invalid_declaration", refused("type=array")),
        ("null is no declaration", declared("null"), 1, "zero_sample", "review-artifact-check: zero_sample measurement=mutation samples=0".into()),
        ("a declaration does not suppress the no-review gate", r#"{"verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file","qa_metadata":{"review_performed":false}}"#.into(), 1, "no_review", "review-artifact-check: no_review review_performed=false".into()),
        ("nor the finding-item gate", r#"{"verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[{"title":"t"}],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file","qa_metadata":{}}"#.into(), 1, "incomplete", "review-artifact-check: finding_item path=suggestions[0] missing=id,location,description,recommendation,priority,estimate,category invalid=".into()),
        ("nor the qa-shape gate", r#"{"verdict":"pass","summary":"mutation: killed 0/0","measurement_failed":"cargo-mutants selected 0 mutants for the changed file","qa_metadata":{}}"#.into(), 1, "incomplete", "review-artifact-check: finding_arrays blockers=absent suggestions=absent".into()),
        ("nor the missing verdict", r#"{"summary":"mutation: killed 0/0","measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}"#.into(), 1, "invalid", "review-artifact-check: verdict field=verdict state=missing_or_null".into()),
    ];
    for (label, body, code, reason, first) in rows {
        let out = w.body(&body);
        assert_eq!(
            (
                out.code,
                out.reason(),
                out.first(),
                out.value().get("measurement_failed").cloned()
            ),
            (Some(code), reason.to_owned(), first, None),
            "{label}: {}",
            out.stdout
        );
    }
    let decl = "cargo-mutants selected 0 mutants for the changed file";
    for (label, body, echoed, silenced) in [
        (
            "a declaration is echoed and records the citation it silenced",
            declared(&format!("{decl:?}")),
            decl,
            Some("review-artifact-check: zero_sample measurement=mutation samples=0"),
        ),
        (
            "the echo is the declaration trimmed",
            declared(&format!("\"  {decl}  \"")),
            decl,
            Some("review-artifact-check: zero_sample measurement=mutation samples=0"),
        ),
        (
            "exactly the bar",
            declared(r#""aa bbbb cccccccccccc""#),
            "aa bbbb cccccccccccc",
            Some("review-artifact-check: zero_sample measurement=mutation samples=0"),
        ),
        (
            "three words past the floor",
            declared(r#""cargo-mutants selected zero-mutants""#),
            "cargo-mutants selected zero-mutants",
            Some("review-artifact-check: zero_sample measurement=mutation samples=0"),
        ),
        (
            "the tolerant shape adopts it without qa_metadata",
            format!(
                r#"{{"verdict":"pass","summary":"mutation: killed 0/0","measurement_failed":{decl:?}}}"#
            ),
            decl,
            Some("review-artifact-check: zero_sample measurement=mutation samples=0"),
        ),
        (
            "a declaration covers an empty perf payload",
            format!(
                r#"{{"verdict":"pass","summary":"s","blockers":[],"suggestions":[],"measurement_failed":{decl:?},"qa_metadata":{{"perf_qa":{{"percentiles":{{"p50":0}}}}}}}}"#
            ),
            decl,
            Some(
                "review-artifact-check: perf_evidence field=qa_metadata.perf_qa.percentiles positive_values=0",
            ),
        ),
        (
            "with nothing to silence it records nothing",
            format!(
                r#"{{"verdict":"pass","summary":"mutation: killed 3/3","measurement_failed":{decl:?}}}"#
            ),
            decl,
            None,
        ),
    ] {
        let out = w.body(&body);
        let v = out.value();
        assert_eq!(
            (
                out.code,
                out.reason(),
                v["measurement_failed"].clone(),
                v.get("measurement_suppressed").map(|s| s
                    .as_str()
                    .unwrap_or("")
                    .lines()
                    .next()
                    .unwrap_or("")
                    .to_owned()),
            ),
            (
                Some(0),
                "valid_undermeasured".to_owned(),
                json!(echoed),
                silenced.map(str::to_owned)
            ),
            "{label}: {}",
            out.stdout
        );
    }
}

/// An item record as the store writes it, with `declined_items`.
fn record(dir: &Path, issue: &str, declined: Value) {
    fs::create_dir_all(dir).unwrap();
    fs::write(
        dir.join(format!("workflow-state-{issue}.json")),
        json!({"issue": issue, "declined_items": declined}).to_string(),
    )
    .unwrap();
}

#[test]
fn repeats_carry_every_decline_at_an_accepted_findings_location() {
    let finding = |location: &str, category: Option<&str>| {
        let mut f = json!({"id":1,"title":"t","location":location,"description":"d","recommendation":"r","priority":3,"estimate":2});
        if let Some(c) = category {
            f["category"] = json!(c);
        }
        f
    };
    let standard = json!({"verdict":"action_required","blockers":[finding(BLK, None)],"suggestions":[finding(SUG, Some("fix"))],"qa_metadata":{}});
    let twin = json!({"verdict":"action_required","blockers":[finding(BLK, None), finding(BLK, None)],"suggestions":[],"qa_metadata":{}});
    let loose =
        json!({"verdict":"action_required","blockers":["see the thread", finding(BLK, None)]});
    let d = |location: &str, description: &str, reason: &str| json!({"location":location,"description":description,"reason":reason,"source":"review"});
    let hit = |array: &str, index: usize, declined: Value| json!({"array":array,"index":index,"location":if array == "blockers" {BLK} else {SUG},"declined":declined});
    /// label, glob mode, artifact, declined items, --issue, exit, repeats (None: absent)
    type Row<'a> = (
        &'a str,
        bool,
        Option<&'a Value>,
        Value,
        bool,
        i32,
        Option<Value>,
    );
    let rows: Vec<Row> = vec![
        (
            "a re-raised declined blocker",
            false,
            Some(&standard),
            json!([d(BLK, "d", "r1")]),
            true,
            0,
            Some(json!([hit(
                "blockers",
                0,
                json!([{"description":"d","reason":"r1"}])
            )])),
        ),
        (
            "a re-raised declined suggestion, glob mode",
            true,
            Some(&standard),
            json!([d(SUG, "d", "r2")]),
            true,
            0,
            Some(json!([hit(
                "suggestions",
                0,
                json!([{"description":"d","reason":"r2"}])
            )])),
        ),
        (
            "another defect at a declined location",
            false,
            Some(&standard),
            json!([d(BLK, "another defect", "r3")]),
            true,
            0,
            Some(json!([hit(
                "blockers",
                0,
                json!([{"description":"another defect","reason":"r3"}])
            )])),
        ),
        (
            "two findings at one location keep their indexes",
            false,
            Some(&twin),
            json!([d(BLK, "d", "r4")]),
            true,
            0,
            Some(json!([
                hit("blockers", 0, json!([{"description":"d","reason":"r4"}])),
                hit("blockers", 1, json!([{"description":"d","reason":"r4"}]))
            ])),
        ),
        (
            "an undeclined location",
            false,
            Some(&standard),
            json!([d("src/z.rs", "d", "r")]),
            true,
            0,
            Some(json!([])),
        ),
        (
            "no declined items",
            true,
            Some(&standard),
            json!([]),
            true,
            0,
            Some(json!([])),
        ),
        (
            "without --issue no repeats field",
            false,
            Some(&standard),
            json!([d(BLK, "d", "r")]),
            false,
            0,
            None,
        ),
        (
            "a malformed artifact has no repeats",
            false,
            None,
            json!([d(BLK, "d", "r")]),
            true,
            1,
            None,
        ),
        (
            "every decline at the location, in order, and no other",
            false,
            Some(&standard),
            json!([
                d(BLK, "d", "r5"),
                d("src/z.rs", "d", "r6"),
                d(BLK, "another defect", "r7")
            ]),
            true,
            0,
            Some(json!([hit(
                "blockers",
                0,
                json!([{"description":"d","reason":"r5"},{"description":"another defect","reason":"r7"}])
            )])),
        ),
        (
            "a string finding is skipped, its sibling keeps its index",
            false,
            Some(&loose),
            json!([d(BLK, "d", "r8")]),
            true,
            0,
            Some(json!([hit(
                "blockers",
                1,
                json!([{"description":"d","reason":"r8"}])
            )])),
        ),
    ];
    for (label, glob, artifact, declined, issue, code, repeats) in rows {
        let w = World::new();
        let state = w.root.join("state");
        record(&state, "KEN-1", declined);
        let text = artifact.map_or(NOT_JSON.to_owned(), |a| w.stamped(&a.to_string()));
        let path = w.put("review-rev-20260101-000000.json", &text, Some(AFTER));
        let mut args: Vec<String> = vec!["--state-dir".into(), state.display().to_string()];
        args.extend(["review-artifact", "--text", "check", "--worktree"].map(String::from));
        args.push(w.wt.display().to_string());
        if glob {
            args.extend(["--agent", "rev", "--delegated-at", "0"].map(String::from));
        } else {
            args.push("--file".into());
            args.push(path.display().to_string());
        }
        if issue {
            args.extend(["--issue", "KEN-1"].map(String::from));
        }
        let out = isolated().args(&args).output().unwrap();
        let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
        assert_eq!(
            (out.status.code(), v.get("repeats").cloned()),
            (Some(code), repeats),
            "{label}: {}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}

#[test]
fn an_unreadable_declined_state_refuses_before_any_artifact() {
    let w = World::new();
    let state = w.root.join("state");
    record(&state, "KEN-2", json!("not a list"));
    record(&state, "KEN-3", json!([d_entry()]));
    let wt = w.wt.display().to_string();
    let missing = w.tmp("nope.json");
    let run = |issue: &str, env: &[(&str, &str)], flag: bool| {
        let mut command = isolated();
        if flag {
            command.arg("--state-dir").arg(&state);
        }
        command
            .args([
                "review-artifact",
                "--text",
                "check",
                "--worktree",
                &wt,
                "--file",
                &missing,
                "--issue",
                issue,
            ])
            .envs(env.iter().copied());
        command.output().unwrap()
    };
    for (label, issue, refusal) in [
        (
            "an item with no record",
            "KEN-404",
            "review-artifact-check: declined_state issue=KEN-404",
        ),
        (
            "declined_items that are no list",
            "KEN-2",
            "review-artifact-check: declined_state issue=KEN-2",
        ),
        (
            "a blank item",
            "",
            "review-artifact-check: declined_state issue=",
        ),
    ] {
        let out = run(issue, &[], true);
        assert_eq!(
            (
                out.status.code(),
                out.stdout.is_empty(),
                stderr(&out).lines().next().unwrap_or("").to_owned()
            ),
            (Some(2), true, refusal.to_owned()),
            "{label}"
        );
    }
    let state_text = state.display().to_string();
    for (label, env, flag) in [
        ("the flag names the directory", vec![], true),
        (
            "the caller's ORCH_STATE_DIR names it",
            vec![("ORCH_STATE_DIR", state_text.as_str())],
            false,
        ),
        (
            "an unrelated invalid setting refuses nothing",
            vec![
                ("ORCH_STATE_DIR", state_text.as_str()),
                ("ORCH_LANE_MAX_PCT", "not-a-number"),
            ],
            false,
        ),
    ] {
        let out = run("KEN-3", &env, flag);
        assert_eq!(
            out.status.code(),
            Some(1),
            "{label}: the missing artifact is judged: {}",
            stderr(&out)
        );
    }
}

fn d_entry() -> Value {
    json!({"location": BLK, "description": "d", "reason": "r", "source": "review"})
}

#[test]
fn refusals_exit_two_with_the_keyed_line_and_no_result() {
    let w = World::new();
    let wt = w.wt.display().to_string();
    let early = w.put("review-early-1.json", &w.stamped(PASS), None);
    File::options()
        .write(true)
        .open(&early)
        .unwrap()
        .set_modified(UNIX_EPOCH - Duration::from_secs(100))
        .unwrap();
    let early = early.display().to_string();
    let deleg = DELEG.to_string();
    for (label, args, refusal) in [
        (
            "a nonexistent worktree",
            vec![
                "check",
                "--worktree",
                &format!("{wt}/does-not-exist"),
                "--agent",
                "q",
                "--delegated-at",
                "1",
            ],
            format!("review-artifact-check: worktree path={wt}/does-not-exist"),
        ),
        (
            "a path-unsafe agent in glob mode",
            vec![
                "check",
                "--worktree",
                &wt,
                "--agent",
                "a*",
                "--delegated-at",
                "1",
            ],
            "review-artifact-check: agent value=a*".to_owned(),
        ),
        (
            "an mtime before the epoch, with a boundary",
            vec![
                "check",
                "--worktree",
                &wt,
                "--file",
                &early,
                "--delegated-at",
                &deleg,
            ],
            format!("review-artifact-check: mtime path={early}"),
        ),
        (
            "an mtime before the epoch, in glob mode",
            vec![
                "check",
                "--worktree",
                &wt,
                "--agent",
                "early",
                "--delegated-at",
                &deleg,
            ],
            format!("review-artifact-check: mtime path={early}"),
        ),
    ] {
        let out = w.run(&args);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.refusal()),
            (Some(2), "", refusal),
            "{label}"
        );
    }
    let out = w.run(&["check", "--worktree", &wt, "--file", &early]);
    assert_eq!(
        out.code,
        Some(0),
        "without a boundary the time is not read: {}",
        out.stderr
    );
}

#[test]
fn the_text_reply_is_the_result_object_with_the_status_of_its_verdict() {
    let w = World::new();
    let accepted = w.body(PASS);
    assert_eq!(accepted.code, Some(0));
    assert_eq!(
        accepted.stdout.lines().count(),
        1,
        "one line: {}",
        accepted.stdout
    );
    let keys: Vec<String> = accepted
        .value()
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(
        keys,
        ["ok", "path", "reason"],
        "an accepted result carries no detail"
    );
    assert_eq!(accepted.value()["ok"], json!(true));
    let rejected = w.body(r#"{"verdict":"pass","qa_metadata":{"review_performed":false}}"#);
    assert_eq!(
        (rejected.code, rejected.value()["ok"].clone()),
        (Some(1), json!(false))
    );
    let keys: Vec<String> = rejected
        .value()
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(keys, ["ok", "path", "reason", "detail"]);
}

/// Advance the fake clock a second at a time until the check returns, at
/// most `bound` fake seconds: its answer and the fake time it took.
fn finish(
    clock: &support::FakeClock,
    thread: std::thread::JoinHandle<orch_runtime::error::Result<Answer>>,
    bound: u64,
) -> (orch_runtime::error::Result<Answer>, Duration) {
    for _ in 0..=bound {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !thread.is_finished() && !clock.asleep() {
            assert!(
                Instant::now() < deadline,
                "the check neither returned nor slept"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        if thread.is_finished() {
            return (thread.join().unwrap(), clock.elapsed());
        }
        clock.release(Duration::from_secs(1));
    }
    panic!("the wait did not end within {bound} fake seconds");
}

#[test]
fn the_wait_polls_past_missing_and_stale_confirms_a_fresh_rejection_once_and_ends_at_its_deadline()
{
    // A worktree that is no repository: no case here reaches the content
    // gates, so no git runs in this process.
    let w = World::new();
    let plain = w.root.join("plain");
    fs::create_dir_all(plain.join("tmp")).unwrap();
    let request = |agent: &str, wait: u64, interval: u64| CheckArtifact {
        worktree: plain.clone(),
        agent: Some(agent.to_owned()),
        file: None,
        delegated_at: Some(DELEG),
        wait,
        interval,
        issue: None,
    };
    let start = |r: CheckArtifact| {
        let clock = Arc::new(support::FakeClock::new());
        let c = clock.clone();
        let thread = std::thread::spawn(move || review::check_review(&r, None, &*c));
        (clock, thread)
    };
    let at = |path: &Path, text: &str, mtime: SystemTime| {
        fs::write(path, text).unwrap();
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
    };

    // Nothing lands: sleeps of the interval, then the time left, to the
    // deadline, and the answer is missing.
    let (clock, thread) = start(request("ghost", 5, 2));
    let (answer, took) = finish(&clock, thread, 30);
    let answer = answer.unwrap();
    assert_eq!(
        (answer.value["reason"].clone(), answer.status, took),
        (json!("missing"), 1, Duration::from_secs(5))
    );

    // A stale artifact keeps the wait polling; a fresh unparsable one that
    // lands is read once more after an interval, then returned.
    at(
        &plain.join("tmp/review-cyc-1.json"),
        "{}",
        UNIX_EPOCH + Duration::from_secs(BEFORE),
    );
    let (clock, thread) = start(request("cyc", 60, 3));
    clock.await_sleepers(1);
    let fresh = plain.join("tmp/review-cyc-2.json");
    at(&fresh, NOT_JSON, UNIX_EPOCH + Duration::from_secs(AFTER));
    let (answer, took) = finish(&clock, thread, 90);
    let answer = answer.unwrap();
    assert_eq!(
        (
            answer.value["reason"].clone(),
            answer.value["path"].clone(),
            took
        ),
        (json!("invalid"), json!(fresh), Duration::from_secs(6)),
        "confirmed once after one interval, never run to the deadline"
    );

    // A refusal ends the wait at once.
    at(
        &plain.join("tmp/review-early-1.json"),
        "{}",
        UNIX_EPOCH - Duration::from_secs(100),
    );
    let (clock, thread) = start(request("early", 60, 3));
    let (answer, took) = finish(&clock, thread, 90);
    assert_eq!(
        (answer.err().map(|e| e.key()), took),
        (Some("mtime"), Duration::ZERO)
    );

    // An accepted artifact ends a real wait at once, through the binary.
    let accepted = w.put("review-done-1.json", &w.stamped(QA_OK), Some(AFTER));
    let began = Instant::now();
    let out = w.glob("done", &["--wait", "60", "--interval", "30"]);
    assert_eq!(
        (out.code, out.value()["path"].clone()),
        (Some(0), json!(accepted))
    );
    assert!(
        began.elapsed() < Duration::from_secs(15),
        "{:?}",
        began.elapsed()
    );
}
