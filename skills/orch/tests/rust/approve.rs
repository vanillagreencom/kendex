#![allow(
    clippy::disallowed_methods,
    reason = "isolated process rows create their own fixture files and children"
)]
mod support;

use agent_runtime::clock::Clock;
use agent_runtime::record::Locking;
use agent_runtime::settings::Roots;
use orch_runtime::ops::approve::{self, ApproveHead, Status};
use orch_runtime::settings::{self, Flags};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const MOVED: &str = "01234567fedcba9876543210fedcba9876543210";
const TOKEN: &str = "ghs_fixtureApprovalFileToken";
const LANE_TOKEN: &str = "ghs_fixtureLaneToken";

fn world() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let catalog = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    fs::create_dir_all(root.join(".agents/skills")).unwrap();
    symlink(catalog.join("github"), root.join(".agents/skills/github")).unwrap();
    fs::create_dir(root.join("bin")).unwrap();
    support::write_executable(&root.join("bin/gh"), include_str!("fixtures/approve-gh"));
    // The planted gh answers GraphQL through the shared closed projector.
    fs::write(
        root.join("select.jq"),
        include_str!("fixtures/gh/select.jq"),
    )
    .unwrap();
    fs::write(root.join("token"), format!("{TOKEN}\n")).unwrap();
    fs::set_permissions(root.join("token"), fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(root.join("body"), "Each decline holds.\n\"Quoted\" line\n").unwrap();
    fs::write(
        root.join("item.json"),
        include_str!("fixtures/workflow-state-KEN-4687.json"),
    )
    .unwrap();
    answer(root, json!({}));
    dir
}

fn answer(root: &Path, value: Value) {
    fs::write(root.join("answer.json"), value.to_string()).unwrap();
}

fn request(root: &Path) -> ApproveHead {
    ApproveHead {
        repo: "o/r".into(),
        pr: 42,
        head: HEAD[..8].into(),
        body_file: root.join("body"),
        hold_copilot: false,
        comment_file: None,
    }
}

fn posts(root: &Path) -> usize {
    fs::read_to_string(root.join("posts"))
        .unwrap_or_default()
        .lines()
        .count()
}

/// Every gh call so far, as the fixture logged it: the `GH_TOKEN` it ran
/// under and its arguments.
fn calls(root: &Path) -> Vec<(Value, Vec<String>)> {
    fs::read_to_string(root.join("gh.log"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Run the named row again as a child of this test binary, in a fresh
/// world, under the approval's settings in its environment and `extra`;
/// `None` in the child itself, which then runs the row's body.
fn child_with(name: &str, extra: &[(&str, &str)]) -> Option<tempfile::TempDir> {
    if std::env::var("APPROVE_CHILD").ok().as_deref() == Some(name) {
        return None;
    }
    let dir = world();
    let tools = dir.path().join("tools");
    fs::create_dir(&tools).unwrap();
    for name in [
        "bash", "env", "git", "jq", "dirname", "mktemp", "cat", "rm", "sed", "grep", "tr", "sleep",
        "date", "wc", "head", "sh", "chmod",
    ] {
        symlink(Path::new("/usr/bin").join(name), tools.join(name)).unwrap();
    }
    // Rows that remove the planted gh mid-call run with no host gh behind it.
    let child_path = if [
        "an_unstarted_post_clears_its_claim_and_can_retry",
        COMMENT_ROW,
    ]
    .contains(&name)
    {
        std::env::join_paths([dir.path().join("bin"), tools]).unwrap()
    } else {
        support::tool_path(&[&dir.path().join("bin")]).into()
    };
    let mut command = support::program(std::env::current_exe().unwrap());
    command
        .args(["--exact", name, "--nocapture"])
        .env("APPROVE_CHILD", name)
        .env("APPROVE_ROOT", dir.path())
        .env("PATH", child_path)
        .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", dir.path().join("token"))
        .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
        .env("GH_TOKEN", LANE_TOKEN)
        .current_dir(dir.path());
    for (key, value) in extra {
        command.env(key, value);
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Some(dir)
}

fn child(name: &str) -> Option<tempfile::TempDir> {
    child_with(name, &[])
}

fn root() -> PathBuf {
    PathBuf::from(std::env::var_os("APPROVE_ROOT").unwrap())
}

/// A clock whose sleep passes at once: each sleep adds its time, counts
/// itself and hands the row its number, to rewrite GitHub's answers.
struct Stepped<'a> {
    now: Mutex<(Instant, u32)>,
    between: &'a (dyn Fn(u32) + Sync),
}

impl Clock for Stepped<'_> {
    fn now(&self) -> Instant {
        self.now.lock().unwrap().0
    }

    fn wall(&self) -> SystemTime {
        SystemTime::UNIX_EPOCH
    }

    fn sleep(&self, d: Duration) {
        let count = {
            let mut now = self.now.lock().unwrap();
            now.0 += d;
            now.1 += 1;
            now.1
        };
        (self.between)(count);
    }
}

/// One approval in the row's process, over its settings and environment,
/// on a stepped clock: `between` sees each sleep's number. The sleeps it
/// took come back beside the answer.
fn run_stepped(
    root: &Path,
    request: &ApproveHead,
    between: &(dyn Fn(u32) + Sync),
) -> (orch_runtime::Result<approve::ApprovedHead>, u32) {
    run_in(
        root,
        request,
        &std::env::vars_os().collect::<Vec<_>>(),
        between,
    )
}

fn run_in(
    root: &Path,
    request: &ApproveHead,
    vars: &[(std::ffi::OsString, std::ffi::OsString)],
    between: &(dyn Fn(u32) + Sync),
) -> (orch_runtime::Result<approve::ApprovedHead>, u32) {
    let settings = settings::load(
        &Roots {
            project: root.into(),
            common: root.into(),
        },
        vars,
        &Flags {
            state_dir: None,
            private_env: true,
        },
    )
    .unwrap();
    let clock = Stepped {
        now: Mutex::new((Instant::now(), 0)),
        between,
    };
    let answer = approve::run(
        &root.join("item.json"),
        request,
        &settings,
        Locking::FLOCK,
        &clock,
    );
    let sleeps = clock.now.lock().unwrap().1;
    (answer, sleeps)
}

fn run(root: &Path, request: &ApproveHead) -> orch_runtime::Result<approve::ApprovedHead> {
    run_stepped(root, request, &|_| {}).0
}

/// One approval under the row's environment with `ORCH_OVERSEER_REVIEW_LOGIN`
/// set to `login`, or absent where it is `None`.
fn run_as(
    root: &Path,
    request: &ApproveHead,
    login: Option<&str>,
) -> orch_runtime::Result<approve::ApprovedHead> {
    let mut vars: Vec<_> = std::env::vars_os()
        .filter(|(key, _)| key != "ORCH_OVERSEER_REVIEW_LOGIN")
        .collect();
    if let Some(login) = login {
        vars.push(("ORCH_OVERSEER_REVIEW_LOGIN".into(), login.into()));
    }
    run_in(root, request, &vars, &|_| {}).0
}

/// The head's `head_approvals` entry, replaced by `entry`.
fn plant_entry(root: &Path, entry: Value) {
    let mut record: Value =
        serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
    record["head_approvals"] = json!({"o/r#42": {HEAD: entry}});
    fs::write(root.join("item.json"), record.to_string()).unwrap();
}

fn refusal_fields(e: &orch_runtime::Error) -> (&'static str, Vec<(String, String)>) {
    (e.key(), e.fields())
}

#[test]
fn a_prefix_approval_persists_before_post_and_replays_once() {
    let dir = world();
    let root = dir.path();
    fs::write(root.join("request.json"), serde_json::to_vec(&json!({"op":"approve-head","repo":"o/r","pr":42,"head":&HEAD[..8],"body_file":root.join("body")})).unwrap()).unwrap();
    for repo in ["o/r", "O/R"] {
        let mut request: Value =
            serde_json::from_slice(&fs::read(root.join("request.json")).unwrap()).unwrap();
        request["repo"] = json!(repo);
        fs::write(root.join("request.json"), request.to_string()).unwrap();
        let output = support::isolated()
            .current_dir(root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
            .env("GH_TOKEN", LANE_TOKEN)
            .args(["op", "--file"])
            .arg(root.join("item.json"))
            .arg("--request")
            .arg(root.join("request.json"))
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(reply["result"]["status"], "confirmed");
        assert_eq!(reply["result"]["head"], HEAD);
        assert!(!String::from_utf8_lossy(&output.stdout).contains(TOKEN));
    }
    assert_eq!(posts(root), 1);
    let payload: Value =
        serde_json::from_str(&fs::read_to_string(root.join("payload.json")).unwrap()).unwrap();
    assert_eq!(
        payload,
        json!({"event":"APPROVE","commit_id":HEAD,"body":"Each decline holds.\n\"Quoted\" line\n"})
    );
    let log = fs::read_to_string(root.join("gh.log")).unwrap();
    assert!(
        log.lines()
            .any(|l| l.contains(LANE_TOKEN) && l.contains("graphql"))
    );
    assert!(log.lines().any(|l| l.contains(TOKEN) && l.contains("POST")));
}

/// A refusal names what it judged beside its key, in the reply the op
/// prints: head-moved the given and the live head, credential the token
/// file and the reader's cause.
#[test]
fn a_refusal_names_what_it_judged() {
    let dir = world();
    let root = dir.path();
    fs::write(
        root.join("request.json"),
        serde_json::to_vec(&json!({"op":"approve-head","repo":"o/r","pr":42,"head":HEAD,"body_file":root.join("body")})).unwrap(),
    )
    .unwrap();
    let refusal = || -> Value {
        let output = support::isolated()
            .current_dir(root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
            .args(["op", "--file"])
            .arg(root.join("item.json"))
            .arg("--request")
            .arg(root.join("request.json"))
            .output()
            .unwrap();
        assert!(!output.status.success());
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["refusal"].clone()
    };
    answer(root, json!({ "head": MOVED }));
    let moved = refusal();
    assert_eq!(moved["key"], "head-moved", "{moved}");
    assert_eq!(moved["fields"], json!([["given", HEAD], ["live", MOVED]]));
    fs::set_permissions(root.join("token"), fs::Permissions::from_mode(0o640)).unwrap();
    let credential = refusal();
    assert_eq!(credential["key"], "credential", "{credential}");
    assert_eq!(
        credential["fields"],
        json!([["file", root.join("token")], ["cause", "mode-640"]])
    );
    assert_eq!(posts(root), 0);
}

const COMMENT_ROW: &str =
    "a_named_comment_lands_before_the_approval_and_an_unposted_one_approves_nothing";

/// The comment a request names lands as the app before the approval is
/// claimed. A comment GitHub refused or that never started approves
/// nothing and clears its claim; one whose answer was lost approves
/// nothing until a complete read-back settles it, and no repeat posts it
/// twice.
#[test]
fn a_named_comment_lands_before_the_approval_and_an_unposted_one_approves_nothing() {
    if child(COMMENT_ROW).is_some() {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.comment_file = Some(root.join("comment"));
    let count = |name: &str| {
        fs::read_to_string(root.join(name))
            .unwrap_or_default()
            .lines()
            .count()
    };
    let record = || -> Value {
        serde_json::from_slice::<Value>(&fs::read(root.join("item.json")).unwrap()).unwrap()
            ["head_approvals"]["o/r#42"][HEAD]
            .clone()
    };
    let fresh = || {
        let mut doc: Value =
            serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
        doc.as_object_mut().unwrap().remove("head_approvals");
        fs::write(root.join("item.json"), doc.to_string()).unwrap();
        for file in ["landed.json", "comments.json"] {
            if root.join(file).exists() {
                fs::remove_file(root.join(file)).unwrap();
            }
        }
    };
    // An absent or blank comment refuses before any GitHub call.
    assert_eq!(run(&root, &r).unwrap_err().key(), "comment-file");
    fs::write(root.join("comment"), " \n").unwrap();
    assert_eq!(run(&root, &r).unwrap_err().key(), "comment-file");
    assert!(!root.join("gh.log").exists());
    let text = "Each decline holds at this head.\n";
    fs::write(root.join("comment"), text).unwrap();

    // Posted as the app, then the approval.
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!((count("comment_posts"), count("posts")), (1, 1));
    let acts: Vec<_> = calls(&root)
        .into_iter()
        .filter(|(_, args)| args.iter().any(|a| a == "POST"))
        .collect();
    assert_eq!(
        acts.iter()
            .map(|(token, args)| (token.clone(), args[3].clone()))
            .collect::<Vec<_>>(),
        [
            (json!(TOKEN), "repos/o/r/issues/42/comments".to_owned()),
            (json!(TOKEN), "repos/o/r/pulls/42/reviews".to_owned()),
        ]
    );
    let landed: Value =
        serde_json::from_slice(&fs::read(root.join("comments.json")).unwrap()).unwrap();
    assert_eq!(landed[0]["body"], text);

    // GitHub refuses the comment: nothing is approved, the claim clears and
    // the repeat posts both.
    fresh();
    answer(&root, json!({"comment":"forbidden"}));
    let refused = run(&root, &r).unwrap();
    assert!(
        refused
            .detail
            .as_deref()
            .is_some_and(|d| d.contains("HTTP 403")),
        "{refused:?}"
    );
    assert_eq!(
        (refused.status, refused.reason.as_str()),
        (Status::Refused, "comment-failed")
    );
    assert_eq!((count("comment_posts"), count("posts")), (2, 1));
    assert!(record()["comment"].is_null() && record()["attempt"].is_null());
    answer(&root, json!({}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!((count("comment_posts"), count("posts")), (3, 2));

    // The comment's answer is lost: nothing is approved while the comments
    // stay unread, and the read-back that finds it posts no second comment.
    fresh();
    answer(&root, json!({"comment":"lost"}));
    let lost = run(&root, &r).unwrap();
    assert_eq!(
        (lost.status, lost.reason.as_str()),
        (Status::Unknown, "comment-unconfirmed")
    );
    answer(&root, json!({"comment_read":"fail"}));
    let unread = run(&root, &r).unwrap();
    assert_eq!(
        (unread.status, unread.reason.as_str()),
        (Status::Unknown, "comment-unconfirmed")
    );
    assert_eq!((count("comment_posts"), count("posts")), (4, 2));
    answer(&root, json!({}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!((count("comment_posts"), count("posts")), (4, 3));

    // The comment's POST never starts: nothing is approved and the claim
    // clears.
    fresh();
    answer(&root, json!({"remove_gh_after_replies":true}));
    let unstarted = run(&root, &r).unwrap();
    assert_eq!(
        (unstarted.status, unstarted.reason.as_str()),
        (Status::Refused, "comment-not-started")
    );
    assert_eq!((count("comment_posts"), count("posts")), (4, 3));
    assert!(record()["comment"].is_null());
}

#[test]
fn a_moved_or_unread_head_never_posts() {
    if child("a_moved_or_unread_head_never_posts").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for (head, exit, key) in [
        (MOVED, 0, "head-moved"),
        ("junk", 0, "head-read-failed"),
        (HEAD, 1, "head-read-failed"),
    ] {
        answer(&root, json!({"head":head,"head_exit":exit}));
        let mut r = r.clone();
        r.head = HEAD.into();
        let refused = run(&root, &r).unwrap_err();
        assert_eq!(refused.key(), key);
        if exit != 0 {
            // gh's words ride the refusal.
            assert!(
                refused
                    .fields()
                    .contains(&("detail".to_owned(), "gh: Not Found (HTTP 404)".to_owned())),
                "{:?}",
                refused.fields()
            );
        }
        assert_eq!(posts(&root), 0);
    }
}

#[test]
fn a_lost_answer_is_read_back_and_posts_again_only_where_nothing_landed() {
    if let Ok(mode) = std::env::var("APPROVE_CHILD") {
        let root = root();
        let r = request(&root);
        if mode.ends_with("landed") {
            for _ in 0..2 {
                assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
            }
            assert_eq!(posts(&root), 1);
            return;
        }
        // A login set without the app's `[bot]` suffix: the POST's own
        // answer confirms, naming both logins, and nothing posts again.
        if mode == "login-differs" {
            let first = run(&root, &r).unwrap();
            assert_eq!(
                (first.status, first.detail.as_deref()),
                (
                    Status::Confirmed,
                    Some("login-differs configured=review-app review=review-app[bot]")
                )
            );
            let standing = run(&root, &r).unwrap();
            assert_eq!(
                (standing.status, standing.detail.as_deref()),
                (
                    Status::Confirmed,
                    Some("login-differs configured=review-app review=review-app[bot]")
                )
            );
            // The setting corrected: the approval it confirmed stands.
            let corrected = run_as(&root, &r, Some("review-app[bot]")).unwrap();
            assert_eq!(
                (corrected.status, corrected.detail.as_deref()),
                (Status::Confirmed, None)
            );
            assert_eq!(posts(&root), 1);
            // An attempt still unsettled under another login is not read
            // back under the corrected one, even where no read-back answers.
            answer(&root, json!({"read_back": "fail"}));
            plant_entry(
                &root,
                json!({"login": "review-app", "attempt": {"state": "attempted"}}),
            );
            let refused = run_as(&root, &r, Some("review-app[bot]")).unwrap_err();
            assert_eq!(
                refusal_fields(&refused),
                (
                    "approval-login-changed",
                    vec![
                        ("recorded".to_owned(), "review-app".to_owned()),
                        ("configured".to_owned(), "review-app[bot]".to_owned())
                    ]
                )
            );
            assert_eq!(posts(&root), 1);
            return;
        }
        let first = run(&root, &r).unwrap();
        assert_eq!(
            (first.status, first.reason.as_str()),
            (Status::Refused, "not-landed")
        );
        let doc: Value =
            serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
        assert!(doc["head_approvals"]["o/r#42"][HEAD]["attempt"].is_null());
        assert_eq!(posts(&root), 1);
        answer(&root, json!({}));
        assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
        assert_eq!(posts(&root), 2);
        return;
    }
    for mode in [
        "lost",
        "transport",
        "server-quoted",
        "unread",
        "lost-landed",
        "refused-landed",
        "login-differs",
    ] {
        let dir = world();
        let root = dir.path();
        let (post, login) = match mode {
            "login-differs" => ("ok", "review-app"),
            _ => (mode, "review-app[bot]"),
        };
        answer(root, json!({"post":post}));
        let output = support::program(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "a_lost_answer_is_read_back_and_posts_again_only_where_nothing_landed",
                "--nocapture",
            ])
            .env("APPROVE_CHILD", mode)
            .env("APPROVE_ROOT", root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", login)
            .env("GH_TOKEN", LANE_TOKEN)
            .current_dir(root)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{mode}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn a_refused_post_clears_its_claim_so_the_next_request_posts_again() {
    if child("a_refused_post_clears_its_claim_so_the_next_request_posts_again").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for (n, mode) in ["refused", "auth", "scopes"].into_iter().enumerate() {
        answer(&root, json!({"post":mode}));
        let refused = run(&root, &r).unwrap();
        assert_eq!(
            (refused.status, refused.reason.as_str()),
            (Status::Refused, "post-failed"),
            "{mode}"
        );
        if mode == "refused" {
            assert_eq!(
                refused.detail.as_deref(),
                Some("gh: Unprocessable Entity (HTTP 422)")
            );
        }
        assert_eq!(posts(&root), 2 * n + 1, "{mode}");
        // GitHub now takes the approval: the repeat posts and confirms.
        answer(&root, json!({}));
        assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed, "{mode}");
        assert_eq!(posts(&root), 2 * n + 2, "{mode}");
        fs::remove_file(root.join("landed.json")).unwrap();
        let mut record: Value =
            serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
        record.as_object_mut().unwrap().remove("head_approvals");
        fs::write(root.join("item.json"), record.to_string()).unwrap();
    }
    // The entry a refused POST left under the login's earlier spelling holds
    // no act, so the corrected login takes it and the request posts.
    let mut record: Value =
        serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
    record["head_approvals"] = json!({"o/r#42": {HEAD: {"login": "review-app", "attempt": null}}});
    fs::write(root.join("item.json"), record.to_string()).unwrap();
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!(posts(&root), 7);
    // A comment that stands under the earlier spelling is an act: it refuses.
    plant_entry(
        &root,
        json!({"login": "review-app", "attempt": null, "comment": {"state": "posted", "id": 9}}),
    );
    let refused = run(&root, &r).unwrap_err();
    assert_eq!(
        refusal_fields(&refused),
        (
            "approval-login-changed",
            vec![
                ("recorded".to_owned(), "review-app".to_owned()),
                ("configured".to_owned(), "review-app[bot]".to_owned())
            ]
        )
    );
    assert_eq!(posts(&root), 7);
}

#[test]
fn copilot_work_that_ends_inside_the_hold_approves_nothing_and_the_retry_checks_replies() {
    if child("copilot_work_that_ends_inside_the_hold_approves_nothing_and_the_retry_checks_replies")
        .is_some()
    {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.hold_copilot = true;
    answer(&root, json!({"work":"in_progress", "reply":"bad"}));
    let ends = |count: u32| {
        if count == 2 {
            answer(&root, json!({"reply":"bad"}));
        }
    };
    let (finished, sleeps) = run_stepped(&root, &r, &ends);
    assert_eq!(finished.unwrap().status, Status::Finished);
    assert_eq!(sleeps, 2);
    assert_eq!(posts(&root), 0);
    // Every Copilot read ran as the app, not the lane the caller's
    // environment names.
    let copilot: Vec<_> = calls(&root)
        .into_iter()
        .filter(|(_, args)| {
            args.first().is_some_and(|a| a == "pr")
                || args.iter().any(|a| {
                    a.contains("/check-runs")
                        || a.contains("/timeline")
                        || a.ends_with("/reviews?per_page=100&page=1")
                })
        })
        .collect();
    assert!(copilot.len() >= 4, "{copilot:?}");
    assert!(
        copilot.iter().all(|(token, _)| token == TOKEN),
        "{copilot:?}"
    );
    // Queued work that ends inside the hold approves nothing either.
    answer(&root, json!({"work":"queued", "reply":"bad"}));
    let (queued, _) = run_stepped(&root, &r, &ends);
    assert_eq!(queued.unwrap().status, Status::Finished);
    assert_eq!(run(&root, &r).unwrap_err().key(), "review-replies");
    assert_eq!(posts(&root), 0);
    // Without the flag a running review holds nothing: the call reads no
    // Copilot work and goes on to the reply check.
    r.hold_copilot = false;
    answer(&root, json!({"work":"in_progress", "reply":"bad"}));
    let before = calls(&root).len();
    assert_eq!(run(&root, &r).unwrap_err().key(), "review-replies");
    assert!(
        !calls(&root)[before..]
            .iter()
            .any(|(_, args)| args.iter().any(|a| a.contains("/check-runs"))),
        "{:?}",
        calls(&root)
    );
    r.hold_copilot = true;
    answer(&root, json!({}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
}

#[test]
fn an_expired_hold_approves_only_the_original_full_head() {
    if child_with(
        "an_expired_hold_approves_only_the_original_full_head",
        &[("ORCH_COPILOT_HOLD_SECS", "30")],
    )
    .is_some()
    {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.hold_copilot = true;
    // The live head re-read after the bound has moved.
    answer(&root, json!({"work":"queued", "head_move_on":2}));
    let (moved, sleeps) = run_stepped(&root, &r, &|_| {});
    assert_eq!(moved.unwrap_err().key(), "head-moved");
    assert_eq!(sleeps, 3);
    assert_eq!(posts(&root), 0);
    // The re-read after the bound fails: nothing is approved.
    fs::remove_file(root.join("head_reads")).unwrap();
    answer(&root, json!({"work":"queued", "head_fail_on":2}));
    let (unread, _) = run_stepped(&root, &r, &|_| {});
    assert_eq!(unread.unwrap_err().key(), "head-read-failed");
    assert_eq!(posts(&root), 0);
    // The head moved while the wait ran.
    fs::remove_file(root.join("head_reads")).unwrap();
    answer(&root, json!({"work":"queued"}));
    let moves = |count: u32| {
        if count == 1 {
            answer(&root, json!({"view_head":MOVED}));
        }
    };
    let (followed, _) = run_stepped(&root, &r, &moves);
    assert_eq!(followed.unwrap_err().key(), "head-moved");
    assert_eq!(posts(&root), 0);
    // Work still in flight at the bound on the same head approves it.
    fs::remove_file(root.join("head_reads")).unwrap();
    answer(&root, json!({"work":"queued"}));
    let (expired, _) = run_stepped(&root, &r, &|_| {});
    let expired = expired.unwrap();
    assert_eq!(
        (expired.status, expired.head),
        (Status::Confirmed, HEAD.into())
    );
    assert_eq!(posts(&root), 1);
}

#[test]
fn a_running_check_its_review_answered_holds_nothing() {
    if child("a_running_check_its_review_answered_holds_nothing").is_some() {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.hold_copilot = true;
    answer(&root, json!({"work":"settled"}));
    let (approved, sleeps) = run_stepped(&root, &r, &|_| {});
    assert_eq!(approved.unwrap().status, Status::Confirmed);
    assert_eq!(sleeps, 0);
    assert_eq!(posts(&root), 1);
}

#[test]
fn unread_copilot_work_and_reply_heads_refuse_before_the_claim() {
    if child("unread_copilot_work_and_reply_heads_refuse_before_the_claim").is_some() {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.hold_copilot = true;
    // A failed first read or a failed read inside the wait, and each answer
    // GitHub never gives, is unread work, never none.
    for work in ["fail", "later-fail", "empty", "malformed", "invalid"] {
        let _ = fs::remove_file(root.join("check_reads"));
        answer(&root, json!({ "work": work }));
        let unread = run(&root, &r).unwrap_err();
        assert_eq!(unread.key(), "copilot-read-failed", "{work}");
        if work == "fail" {
            // The read's cause and gh's words ride the refusal.
            let fields = unread.fields();
            assert!(
                fields.contains(&("reason".to_owned(), "check-runs-read-failed".to_owned())),
                "{fields:?}"
            );
            assert!(
                fields
                    .iter()
                    .any(|(key, value)| key == "detail" && value.contains("HTTP 403")),
                "{fields:?}"
            );
        }
    }
    r.hold_copilot = false;
    answer(&root, json!({"reply_head":MOVED}));
    assert_eq!(run(&root, &r).unwrap_err().key(), "review-replies");
    assert_eq!(posts(&root), 0);
}

#[test]
fn only_the_exact_apps_approval_confirms_a_lost_post() {
    if child("only_the_exact_apps_approval_confirms_a_lost_post").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for (state, login, head) in [
        ("COMMENTED", "review-app[bot]", HEAD),
        ("APPROVED", "other[bot]", HEAD),
        ("APPROVED", "review-app[bot]", MOVED),
    ] {
        answer(
            &root,
            json!({"post":"lost", "reviews":[{"state":state,"user":{"login":login},"commit_id":head}]}),
        );
        let missed = run(&root, &r).unwrap();
        assert_eq!(
            (missed.status, missed.reason.as_str()),
            (Status::Refused, "not-landed"),
            "{state} {login} {head}"
        );
    }
    answer(
        &root,
        json!({"post":"lost", "reviews":[{"state":"APPROVED","user":{"login":"review-app[bot]"},"commit_id":HEAD}]}),
    );
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!(posts(&root), 4);
}

#[test]
fn invalid_credentials_refuse_without_any_github_call() {
    if child("invalid_credentials_refuse_without_any_github_call").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for login in [None, Some("")] {
        assert_eq!(
            run_as(&root, &r, login).unwrap_err().key(),
            "approval-login",
            "{login:?}"
        );
    }
    fs::set_permissions(root.join("token"), fs::Permissions::from_mode(0o640)).unwrap();
    assert_eq!(run(&root, &r).unwrap_err().key(), "credential");
    assert!(!root.join("gh.log").exists());
}

#[test]
fn an_unstarted_post_clears_its_claim_and_can_retry() {
    if child("an_unstarted_post_clears_its_claim_and_can_retry").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    answer(&root, json!({"remove_gh_after_replies":true}));
    let refused = run(&root, &r).unwrap();
    assert_eq!(
        (refused.status, refused.reason.as_str()),
        (Status::Refused, "not-started")
    );
    assert_eq!(posts(&root), 0);
    support::write_executable(&root.join("bin/gh"), include_str!("fixtures/approve-gh"));
    answer(&root, json!({}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!(posts(&root), 1);
}

#[test]
fn a_lost_post_is_read_back_after_the_live_head_moves() {
    if child("a_lost_post_is_read_back_after_the_live_head_moves").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    answer(&root, json!({"post":"lost", "read_back":"fail"}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Unknown);
    answer(
        &root,
        json!({"head":MOVED, "reviews":[{"state":"APPROVED","user":{"login":"review-app[bot]"},"commit_id":HEAD}]}),
    );
    let result = run(&root, &r).unwrap();
    assert_eq!(result.status, Status::Confirmed);
    assert_eq!(result.head, HEAD);
    assert_eq!(posts(&root), 1);
}

#[test]
fn invalid_requests_and_unread_bodies_never_read_github() {
    if child("invalid_requests_and_unread_bodies_never_read_github").is_some() {
        return;
    }
    let root = root();
    for (repo, pr, head, file, key) in [
        ("o/r", 0, HEAD, "body", "approval-request"),
        ("o/r/more", 42, HEAD, "body", "approval-request"),
        ("o/r", 42, "ABCDEF1", "body", "approval-request"),
        ("o/r", 42, "123456", "body", "approval-request"),
        (
            "o/r",
            42,
            "0123456789abcdef0123456789abcdef012345670",
            "body",
            "approval-request",
        ),
        ("o/r", 42, HEAD, "absent", "body-file"),
        // GitHub's classes: an owner never takes a dot or an underscore, a
        // name is never dots alone.
        ("o.x/r", 42, HEAD, "body", "approval-request"),
        ("./r", 42, HEAD, "body", "approval-request"),
        ("o_x/r", 42, HEAD, "body", "approval-request"),
        ("o/..", 42, HEAD, "body", "approval-request"),
        ("o/.", 42, HEAD, "body", "approval-request"),
        ("o/r/", 42, HEAD, "body", "approval-request"),
        ("not-a-repo", 42, HEAD, "body", "approval-request"),
    ] {
        let mut r = request(&root);
        r.repo = repo.into();
        r.pr = pr;
        r.head = head.into();
        r.body_file = root.join(file);
        assert_eq!(run(&root, &r).unwrap_err().key(), key);
    }
    // A record the approvals cannot be read from refuses before any call.
    let r = request(&root);
    for approvals in [
        json!([]),
        json!({"o/r#42": []}),
        json!({"o/r#42": {HEAD: {"login": 5}}}),
    ] {
        let mut record: Value =
            serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
        record["head_approvals"] = approvals.clone();
        fs::write(root.join("item.json"), record.to_string()).unwrap();
        assert_eq!(
            run(&root, &r).unwrap_err().key(),
            "approval-record",
            "{approvals}"
        );
    }
    assert!(!root.join("gh.log").exists());
}

#[test]
fn unread_review_evidence_never_claims_an_attempt() {
    if child("unread_review_evidence_never_claims_an_attempt").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for mode in ["bad", "unavailable", "malformed", "body-findings"] {
        answer(&root, json!({"reply":mode}));
        let refused = run(&root, &r).unwrap_err();
        assert_eq!(refused.key(), "review-replies");
        // The checker's words and the remedy ride the refusal: its stdout
        // as `result`, its stderr as `detail` beside a failed exit.
        let fields = refused.fields();
        assert!(
            fields.iter().any(|(key, value)| {
                matches!(key.as_str(), "result" | "detail")
                    && (value.starts_with("review-replies: ")
                        || value.starts_with("check-review-replies: "))
            }),
            "{mode}: {fields:?}"
        );
        assert!(
            fields
                .iter()
                .any(|(key, value)| key == "fix" && value.starts_with("Restore the github reader")),
            "{mode}: {fields:?}"
        );
        assert_eq!(posts(&root), 0);
        let doc: Value =
            serde_json::from_slice(&fs::read(root.join("item.json")).unwrap()).unwrap();
        assert!(doc["head_approvals"]["o/r#42"][HEAD]["attempt"].is_null());
    }
    // No github skill in the project's install: the checker never starts,
    // and the refusal names it unavailable.
    answer(&root, json!({}));
    fs::remove_file(root.join(".agents/skills/github")).unwrap();
    let missing = run(&root, &r).unwrap_err();
    assert_eq!(missing.key(), "review-replies");
    assert!(
        missing
            .fields()
            .contains(&("result".to_owned(), "unavailable".to_owned())),
        "{:?}",
        missing.fields()
    );
    assert_eq!(posts(&root), 0);
}

#[test]
fn reader_absence_uses_the_file_and_keyring_preserves_the_viewer() {
    if let Ok(mode) = std::env::var("APPROVE_CHILD") {
        let root = root();
        let answer = run(&root, &request(&root));
        if mode != "reference" {
            assert_eq!(answer.unwrap().status, Status::Confirmed);
        }
        return;
    }
    // A configured reader credential that does not resolve is no absence:
    // the checker reads under it and never under the file token.
    for (mode, keyring, reader) in [
        ("file", false, None),
        ("keyring", true, None),
        ("reference", false, Some("op://fixture/refused/token")),
    ] {
        let dir = world();
        let root = dir.path();
        answer(root, json!({ "keyring": keyring }));
        support::write_executable(&root.join("bin/op"), "#!/bin/sh\nexit 1\n");
        let mut command = support::program(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "reader_absence_uses_the_file_and_keyring_preserves_the_viewer",
                "--nocapture",
            ])
            .env("APPROVE_CHILD", mode)
            .env("APPROVE_ROOT", root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
            .current_dir(root);
        if let Some(reader) = reader {
            command.env("GH_BOT_TOKEN", reader);
        }
        let out = command.output().unwrap();
        assert!(
            out.status.success(),
            "{mode}: {} {}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let reads: Vec<_> = calls(root)
            .into_iter()
            .filter(|(_, args)| {
                args.get(1).is_some_and(|a| a == "graphql")
                    || args == &["api", "user", "--jq", ".login"]
                    || args == &["api", "repos/o/r/pulls/42"]
            })
            .collect();
        if mode == "reference" {
            assert!(
                reads.iter().all(|(token, _)| token != &json!(TOKEN)),
                "{reads:?}"
            );
            continue;
        }
        let (token, _) = reads
            .iter()
            .find(|(_, args)| args.get(1).is_some_and(|a| a == "graphql"))
            .unwrap();
        assert_eq!(token, &if keyring { Value::Null } else { json!(TOKEN) });
    }
}

#[test]
fn a_lost_post_stays_unknown_until_a_complete_read_back_settles_it() {
    if child("a_lost_post_stays_unknown_until_a_complete_read_back_settles_it").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    for read in ["fail", "malformed"] {
        answer(&root, json!({"post":"lost", "read_back":read}));
        for _ in 0..2 {
            assert_eq!(run(&root, &r).unwrap().status, Status::Unknown);
        }
    }
    assert_eq!(posts(&root), 1);
    // The reviews read whole and hold no approval: the POST did not land, the
    // claim clears, and the next request posts once more.
    answer(&root, json!({"post":"lost"}));
    let settled = run(&root, &r).unwrap();
    assert_eq!(
        (settled.status, settled.reason.as_str()),
        (Status::Refused, "not-landed")
    );
    assert_eq!(posts(&root), 1);
    answer(&root, json!({}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!(posts(&root), 2);
}

#[test]
fn settings_load_the_token_and_login_from_data_files() {
    let dir = world();
    let root = dir.path();
    fs::write(
        root.join("kendex.settings.toml"),
        "[env]\nORCH_OVERSEER_REVIEW_LOGIN = 'settings-app[bot]'\nORCH_COPILOT_HOLD_SECS = '12'\n",
    )
    .unwrap();
    fs::write(
        root.join(".env.local"),
        format!(
            "ORCH_OVERSEER_REVIEW_TOKEN_FILE='{}'\nORCH_OVERSEER_REVIEW_LOGIN='review-app[bot]'\n",
            root.join("token").display()
        ),
    )
    .unwrap();
    let loaded = settings::load(
        &Roots {
            project: root.into(),
            common: root.into(),
        },
        &[],
        &Flags {
            state_dir: None,
            private_env: true,
        },
    )
    .unwrap();
    assert_eq!(
        loaded.review.approval_login.as_deref(),
        Some("review-app[bot]")
    );
    assert_eq!(
        loaded.review.approval_token_file.as_deref(),
        Some(root.join("token").as_path())
    );
    assert_eq!(loaded.review.copilot_hold, "12");
}

#[test]
fn the_hold_bound_is_read_by_the_one_settings_reader() {
    if child("the_hold_bound_is_read_by_the_one_settings_reader").is_some() {
        return;
    }
    let root = root();
    let mut r = request(&root);
    r.hold_copilot = true;
    for value in ["0", "01", "+1", "invalid", "1.0"] {
        fs::write(
            root.join("kendex.settings.toml"),
            format!("[env]\nORCH_COPILOT_HOLD_SECS='{value}'\n"),
        )
        .unwrap();
        assert_eq!(
            run(&root, &r).unwrap_err().key(),
            "copilot-hold-setting",
            "{value}"
        );
    }
    assert_eq!(posts(&root), 0);
    // An empty value declares nothing: the default bound holds.
    fs::write(
        root.join("kendex.settings.toml"),
        "[env]\nORCH_COPILOT_HOLD_SECS=''\n",
    )
    .unwrap();
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
}

#[test]
fn the_configured_viewer_can_answer_a_body_only_finding() {
    if child("the_configured_viewer_can_answer_a_body_only_finding").is_some() {
        return;
    }
    let root = root();
    let r = request(&root);
    answer(&root, json!({"reply":"lane-disposition"}));
    assert_eq!(run(&root, &r).unwrap().status, Status::Confirmed);
    assert_eq!(posts(&root), 1);
}

#[test]
fn a_private_reader_identity_survives_the_approval_file_credential() {
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_BOT_TOKEN"] {
        let dir = world();
        let root = dir.path();
        fs::write(root.join(".env.local"), format!("{key}='{LANE_TOKEN}'\n")).unwrap();
        answer(root, json!({"reply":"lane-disposition"}));
        fs::write(root.join("request.json"),serde_json::to_vec(&json!({"op":"approve-head","repo":"o/r","pr":42,"head":HEAD,"body_file":root.join("body")})).unwrap()).unwrap();
        let out = support::program(support::binary())
            .current_dir(root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
            .args(["op", "--file"])
            .arg(root.join("item.json"))
            .arg("--request")
            .arg(root.join("request.json"))
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{key}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let result: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(result["result"]["status"], "confirmed", "{key}: {result}");
        assert_eq!(posts(root), 1);
    }
}

#[test]
fn an_approval_key_only_a_shell_reads_refuses_the_approval_before_any_call() {
    let dir = world();
    let root = dir.path();
    let op = |root: &Path| {
        support::program(support::binary())
            .current_dir(root)
            .env("PATH", support::tool_path(&[&root.join("bin")]))
            .env("ORCH_OVERSEER_REVIEW_TOKEN_FILE", root.join("token"))
            .env("ORCH_OVERSEER_REVIEW_LOGIN", "review-app[bot]")
            .args(["op", "--file"])
            .arg(root.join("item.json"))
            .arg("--request")
            .arg(root.join("request.json"))
            .output()
            .unwrap()
    };
    // A reader credential in a shell's form in a checkout's private file: no
    // reader reads it, the github router's loader refusing it as data.
    let init = support::program("git")
        .args(["init", "-q"])
        .current_dir(root)
        .output()
        .unwrap();
    assert!(init.status.success());
    fs::write(root.join(".env.local"), "GH_TOKEN=$(gh auth token)\n").unwrap();
    answer(root, json!({"reply":"lane-disposition"}));
    fs::write(root.join("request.json"),serde_json::to_vec(&json!({"op":"approve-head","repo":"o/r","pr":42,"head":HEAD,"body_file":root.join("body")})).unwrap()).unwrap();
    let inspect = support::program(support::binary())
        .current_dir(root)
        .env("PATH", support::tool_path(&[&root.join("bin")]))
        .args(["state", "inspect", "--file"])
        .arg(root.join("item.json"))
        .output()
        .unwrap();
    assert!(
        inspect.status.success(),
        "{}",
        String::from_utf8_lossy(&inspect.stderr)
    );
    assert!(String::from_utf8_lossy(&inspect.stderr).contains("key=GH_TOKEN reason=shell-form"));
    let out = op(root);
    assert!(!out.status.success());
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        reply["refusal"]["key"],
        "approval-setting-unread",
        "{reply} {:?}",
        calls(root)
    );
    assert!(!root.join("gh.log").exists(), "{:?}", calls(root));
    // A host the approval cannot read refuses the approval, before any call.
    let dir = world();
    let root = dir.path();
    fs::write(root.join(".env.local"), "GH_HOST=$(cat host)\n").unwrap();
    fs::write(root.join("request.json"),serde_json::to_vec(&json!({"op":"approve-head","repo":"o/r","pr":42,"head":HEAD,"body_file":root.join("body")})).unwrap()).unwrap();
    let out = op(root);
    assert!(!out.status.success());
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        reply["refusal"]["key"], "approval-setting-unread",
        "{reply}"
    );
    assert!(!root.join("gh.log").exists());
}
