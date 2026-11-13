//! `record-push`, `prune-round` and `record-qa-decision` through the built
//! binary. Each row builds a real repository with a bare origin and a lane
//! worktree the worktree skill's own `create` made, and runs the worktree
//! skill's real `push` and `cleanup` and the mailbox's real `lane-mail`; only
//! git's network transport, `df` and the lease holder are planted, each as
//! the row names. Item records are written as the store writes them.
#![allow(
    clippy::disallowed_methods,
    reason = "the process rows build fixture repositories and run the binary and its programs"
)]

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

use serde_json::{Value, json};
use support::{isolated, program, stderr, tool_path, write_executable};

fn skills() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn worktree_cli() -> PathBuf {
    skills().join("worktree/scripts/worktree")
}

/// `git -C dir args` under isolation: its stdout, the row failing where git
/// fails.
fn git(dir: &Path, args: &[&str]) -> String {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        dir.display(),
        stderr(&out)
    );
    String::from_utf8_lossy(&out.stdout).trim_end().to_owned()
}

fn commit(dir: &Path, file: &str, text: &str, message: &str) -> String {
    fs::write(dir.join(file), text).unwrap();
    git(dir, &["add", file]);
    git(dir, &["commit", "-qm", message]);
    git(dir, &["rev-parse", "HEAD"])
}

/// A main checkout on `main` with a bare origin, a lane worktree for `item`
/// made by the worktree skill's `create` on `ken-1`, one commit on it.
struct Repo {
    _dir: tempfile::TempDir,
    root: PathBuf,
    main: PathBuf,
    wt: PathBuf,
    state: PathBuf,
    item: String,
    /// The settings file's `[env]` pairs: the worktree skill reads the
    /// file, the runtime under `--no-private-env` its environment.
    env: Vec<(String, String)>,
}

impl Repo {
    fn new(item: &str, settings: &str) -> Repo {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        // gh's answer for a branch with no open pull request: nothing, exit 0.
        write_executable(
            &bin.join("gh"),
            "#!/bin/sh\nif [ \"$1 $2\" = 'pr list' ]; then exit 0; fi\nprintf 'gh: no fixture answers: %s\\n' \"$*\" >&2\nexit 4\n",
        );
        let origin = root.join("origin.git");
        let main = root.join("main");
        fs::create_dir_all(&main).unwrap();
        git(&root, &["init", "-q", "--bare", origin.to_str().unwrap()]);
        git(&main, &["init", "-q", "-b", "main"]);
        for (k, v) in [
            ("gc.auto", "0"),
            ("maintenance.auto", "false"),
            ("commit.gpgsign", "false"),
        ] {
            git(&main, &["config", k, v]);
        }
        fs::write(
            main.join("kendex.settings.toml"),
            format!("[env]\nWORKTREE_DEFAULT_BRANCH = \"main\"\nWORKTREE_BASE_DIR = \"../trees\"\n{settings}"),
        )
        .unwrap();
        // `.agents` without a slash: a row's install is a link, not a
        // directory, and an untracked link would dirty the checkout.
        fs::write(main.join(".gitignore"), "tmp/\n.agents\n").unwrap();
        fs::write(main.join("base"), "base\n").unwrap();
        git(&main, &["add", "."]);
        git(&main, &["commit", "-qm", "base"]);
        git(
            &main,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        git(&main, &["push", "-qu", "origin", "main"]);
        let out = program(worktree_cli())
            .args(["create", item])
            .env("PATH", tool_path(&[&bin]))
            .current_dir(&main)
            .output()
            .unwrap();
        assert!(out.status.success(), "worktree create: {}", stderr(&out));
        let wt = PathBuf::from(
            String::from_utf8_lossy(&out.stdout)
                .trim()
                .lines()
                .last()
                .unwrap(),
        );
        fs::create_dir_all(wt.join("tmp")).unwrap();
        commit(&wt, "feature", "feature\n", "feature");
        let state = root.join("state");
        fs::create_dir_all(&state).unwrap();
        let env = settings
            .lines()
            .filter_map(|l| l.split_once(" = "))
            .map(|(k, v)| (k.trim().to_owned(), v.trim().trim_matches('"').to_owned()))
            .collect();
        Repo {
            _dir: dir,
            root,
            main,
            wt,
            state,
            item: item.to_owned(),
            env,
        }
    }

    /// The orch install a validation run and the tier check read, the
    /// clone's rendered one, in both checkouts.
    fn link_agents(&self) {
        for dir in [&self.main, &self.wt] {
            std::os::unix::fs::symlink(skills().join("../.agents"), dir.join(".agents")).unwrap();
        }
    }

    fn head(&self) -> String {
        git(&self.wt, &["rev-parse", "HEAD"])
    }

    /// The commit-message gate the commit chain installs, commit-guards'
    /// own, as the repository's commit-msg hook: every commit after this,
    /// the fold's among them, passes it or is refused.
    fn arm_gate(&self) {
        write_executable(
            &self.main.join(".git/hooks/commit-msg"),
            format!(
                "#!/bin/sh\nexec '{}' \"$1\"\n",
                skills().join("commit-guards/scripts/commit-msg").display()
            ),
        );
    }

    fn message(&self) -> String {
        git(&self.wt, &["log", "-1", "--format=%B"])
    }

    fn record_path(&self, item: &str) -> PathBuf {
        self.state.join(format!("workflow-state-{item}.json"))
    }

    /// The item's record as the store writes it, with `extra` merged in.
    fn record(&self, extra: Value) {
        let mut doc = json!({
            "issue_id": self.item,
            "worktree": self.wt.display().to_string(),
            "branch": "ken-1",
        });
        for (k, v) in extra.as_object().unwrap() {
            doc[k] = v.clone();
        }
        fs::write(self.record_path(&self.item), doc.to_string()).unwrap();
    }

    fn read(&self) -> Value {
        serde_json::from_str(&fs::read_to_string(self.record_path(&self.item)).unwrap()).unwrap()
    }

    /// The base moved on origin: a commit on main, pushed.
    fn advance(&self, file: &str) -> String {
        let sha = commit(&self.main, file, &format!("{file}\n"), file);
        git(&self.main, &["push", "-q", "origin", "main"]);
        sha
    }

    fn map(&self) -> PathBuf {
        let path = git(&self.wt, &["rev-parse", "--git-path", "kendex-rebase-map"]);
        let path = PathBuf::from(path);
        if path.is_absolute() {
            path
        } else {
            self.wt.join(path)
        }
    }

    fn remote(&self, branch: &str) -> String {
        git(
            &self.main,
            &["ls-remote", "origin", &format!("refs/heads/{branch}")],
        )
        .split('\t')
        .next()
        .unwrap_or("")
        .to_owned()
    }

    fn op_env(&self, item: &str, request: &Value, env: &[(&str, &str)]) -> Output {
        let file = self.root.join("request.json");
        fs::write(&file, request.to_string()).unwrap();
        let mut command = isolated();
        command
            .args(["--state-dir", self.state.to_str().unwrap()])
            .args(["op", "--item", item, "--request", file.to_str().unwrap()])
            .env("WORKTREE_CLI", worktree_cli())
            .env("PATH", tool_path(&[&self.root.join("bin")]))
            .current_dir(&self.main);
        for (k, v) in &self.env {
            command.env(k, v);
        }
        for (k, v) in env {
            command.env(k, v);
        }
        command.output().unwrap()
    }

    fn op(&self, request: Value) -> Output {
        self.op_env(&self.item, &request, &[])
    }

    fn push(&self, mode: &str) -> Output {
        self.op(json!({"op": "record-push", "mode": mode, "worktree": self.wt}))
    }

    /// A `git` ahead of the real one whose `push` the row decides: `fail`
    /// refuses the transport as an unreachable remote does, `kill` ends the
    /// worktree skill's process with a signal so the push's answer is lost.
    fn planted_git(&self, behaviour: &str) -> String {
        let bin = self.root.join(format!("bin-{behaviour}"));
        fs::create_dir_all(&bin).unwrap();
        let real = String::from_utf8_lossy(
            &program("sh")
                .args(["-c", "command -v git"])
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_owned();
        let act = match behaviour {
            "fail" => "printf 'fatal: fixture transport down\\n' >&2; exit 128",
            "kill" => "pg=$(ps -o pgid= -p $$ | tr -d ' '); kill -KILL -- -$pg; exit 128",
            _ => unreachable!(),
        };
        write_executable(
            &bin.join("git"),
            format!(
                "#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = push ] && [ -e '{flag}' ]; then {act}; fi; done\nexec '{real}' \"$@\"\n",
                flag = self.root.join(format!("{behaviour}.on")).display()
            ),
        );
        fs::write(self.root.join(format!("{behaviour}.on")), "").unwrap();
        tool_path(&[&bin, &self.root.join("bin")])
    }

    fn lift(&self, behaviour: &str) {
        fs::remove_file(self.root.join(format!("{behaviour}.on"))).unwrap();
    }
}

fn result(out: &Output) -> Value {
    let reply = support::reply(out);
    assert!(reply["ok"].as_bool().unwrap(), "refused: {}", stderr(out));
    reply["result"].clone()
}

/// The keyed first line of a refusal: `orch-runtime: <key> ...`.
fn refusal(out: &Output) -> String {
    assert!(
        !out.status.success(),
        "answered: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    stderr(out).lines().next().unwrap_or("").to_owned()
}

fn exit(out: &Output) -> Option<i32> {
    out.status.code()
}

mod push {
    use super::*;

    #[test]
    fn a_field_the_mode_cannot_honour_refuses_before_any_push() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({}));
        let before = repo.remote("ken-1");
        for request in [
            json!({"op": "record-push", "mode": "check-live-round", "worktree": repo.wt, "args": ["--no-rebase"]}),
            json!({"op": "record-push", "mode": "record-restack-validation", "worktree": repo.wt, "run_dir": "x", "args": []}),
            json!({"op": "record-push", "mode": "branch", "worktree": repo.wt, "sate_dir": "/nowhere"}),
        ] {
            let out = repo.op(request.clone());
            assert!(
                refusal(&out).starts_with("orch-runtime: request-invalid"),
                "{request}: {}",
                stderr(&out)
            );
            assert_eq!(repo.remote("ken-1"), before, "{request} pushed");
        }
        let out = repo.op_env(
            "a..b",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[],
        );
        assert!(
            refusal(&out).starts_with("orch-runtime: invalid-issue"),
            "{}",
            stderr(&out)
        );
    }

    fn record_with_fixes(repo: &Repo, commit: &str) {
        repo.record(json!({
            "fixed_items": [{"description": "fix", "commit": &commit[..7], "source": "pr-review"}],
            "pr_comment_review": {"fixes": [{"description": "reply fix", "commit": &commit[..10], "source": "bot"}]},
        }));
    }

    #[test]
    fn a_bare_numeric_key_reconciles_only_its_own_record() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        fs::write(
            repo.record_path("issue-7"),
            json!({"issue_id": "issue-7", "fixed_items": [{"commit": &old[..7]}]}).to_string(),
        )
        .unwrap();
        let before = fs::read_to_string(repo.record_path("issue-7")).unwrap();
        repo.advance("moved");
        let out = repo.op_env(
            "7",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[],
        );
        let line = refusal(&out);
        assert!(
            line.starts_with("orch-runtime: restack-map-nostate issue=7"),
            "{line}"
        );
        assert!(line.contains("push-exit=0"), "the push itself ran: {line}");
        assert_eq!(
            fs::read_to_string(repo.record_path("issue-7")).unwrap(),
            before
        );
        assert!(fs::metadata(repo.map()).is_ok(), "the stranded map is kept");
    }

    #[test]
    fn a_worktree_that_does_not_resolve_refuses_before_any_push() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({"worktree": ""}));
        let plain = repo.root.join("plain");
        fs::create_dir_all(&plain).unwrap();
        for (tree, key) in [
            (repo.root.join("absent"), "not-directory"),
            (plain, "not-worktree"),
        ] {
            let out = repo.op(json!({"op": "record-push", "mode": "branch", "worktree": tree}));
            let line = refusal(&out);
            assert!(line.starts_with(&format!("orch-runtime: {key}")), "{line}");
        }
        assert_eq!(repo.remote("ken-1"), "", "nothing was pushed");
    }

    #[test]
    fn an_unreadable_record_refuses_before_any_push() {
        let repo = Repo::new("KEN-1", "");
        fs::write(repo.record_path("KEN-1"), "{").unwrap();
        let out = repo.push("branch");
        assert!(
            refusal(&out).starts_with("orch-runtime: "),
            "{}",
            stderr(&out)
        );
        assert_eq!(repo.remote("ken-1"), "", "nothing was pushed");
    }

    #[test]
    fn a_record_naming_another_issue_or_worktree_refuses_before_any_push() {
        let repo = Repo::new("KEN-1", "");
        let other = repo.root.join("other");
        fs::create_dir_all(&other).unwrap();
        for (extra, key) in [
            (
                json!({"issue_id": "KEN-9"}),
                "issue-mismatch issue=KEN-1 recorded=KEN-9",
            ),
            (json!({"worktree": other}), "worktree-mismatch issue=KEN-1"),
            (
                json!({"worktree": repo.root.join("gone")}),
                "state-worktree issue=KEN-1",
            ),
        ] {
            repo.record(extra.clone());
            let line = refusal(&repo.push("branch"));
            assert!(
                line.starts_with(&format!("orch-runtime: {key}")),
                "{extra}: {line}"
            );
        }
        assert_eq!(repo.remote("ken-1"), "", "nothing was pushed");
    }

    #[test]
    fn a_live_fix_round_refuses_and_pushes_nothing() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({"dev_round_id": "1-1"}));
        fs::write(repo.wt.join("tmp/dev-round-KEN-1-1-1.json"), "{}").unwrap();
        let line = refusal(&repo.push("branch"));
        assert_eq!(
            line,
            format!(
                "orch-runtime: live-round round=1-1 worktree={}",
                repo.wt.display()
            )
        );
        assert_eq!(
            repo.remote("ken-1"),
            "",
            "the refusal lands before the push"
        );
        assert!(repo.read().get("rebase_map").is_none());
        let out = repo.push("check-live-round");
        assert_eq!(exit(&out), Some(3), "{}", stderr(&out));
        assert_eq!(result(&out)["live_round"], "1-1");
    }

    #[test]
    fn a_returned_or_unrecorded_round_permits_the_push() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({"dev_round_id": "1-1"}));
        fs::write(repo.wt.join("tmp/dev-round-KEN-1-1-1.json"), "{}").unwrap();
        fs::write(
            repo.wt
                .join("tmp/dev-return-KEN-1-1-1-20260101T000000Z-1.json"),
            "{}",
        )
        .unwrap();
        let out = repo.push("branch");
        assert_eq!(
            exit(&out),
            Some(0),
            "a run-keyed receipt ends the round: {}",
            stderr(&out)
        );
        repo.record(json!({"dev_round_id": "9-9"}));
        commit(&repo.wt, "more", "more\n", "more");
        let out = repo.push("branch");
        assert_eq!(
            exit(&out),
            Some(0),
            "a round with no record does not block: {}",
            stderr(&out)
        );
        assert_eq!(repo.remote("ken-1"), repo.head());
    }

    #[test]
    fn the_live_round_check_answers_alone_and_changes_nothing() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({}));
        let text = format!(
            "rebase-hop:\nrebase-map: {} {}\n",
            repo.head(),
            "c".repeat(40)
        );
        fs::write(repo.map(), &text).unwrap();
        let out = repo.push("check-live-round");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(
            fs::read_to_string(repo.map()).unwrap(),
            text,
            "the check consumes no map"
        );
        assert_eq!(repo.remote("ken-1"), "", "the check pushes nothing");
        assert!(repo.read().get("rebase_map").is_none());
    }

    #[test]
    fn a_push_that_never_started_refuses_with_nothing_pushed() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({}));
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("WORKTREE_CLI", "/nonexistent/worktree")],
        );
        assert!(
            refusal(&out).starts_with("orch-runtime: push-not-started"),
            "{}",
            stderr(&out)
        );
        assert!(
            repo.read().get("push_attempt").is_none(),
            "a push that never started left no attempt"
        );
    }

    #[test]
    fn push_arguments_reach_the_real_push_verbatim() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({}));
        let out = repo.op(json!({"op": "record-push", "mode": "branch", "worktree": repo.wt, "args": ["--sate-dir=/nowhere"]}));
        let reply = result(&out);
        assert_eq!(
            exit(&out),
            Some(1),
            "the real push's own refusal is the exit"
        );
        assert!(
            reply["push"]["stderr"]
                .as_str()
                .unwrap()
                .contains("--sate-dir=/nowhere"),
            "{reply}"
        );
        assert_eq!(repo.remote("ken-1"), "");
        let out = repo.op(json!({"op": "record-push", "mode": "branch", "worktree": repo.wt, "args": ["--set-upstream"]}));
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(
            git(&repo.wt, &["rev-parse", "--abbrev-ref", "@{upstream}"]),
            "origin/ken-1"
        );
    }

    #[test]
    fn a_failed_push_keeps_its_status_and_still_reconciles() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        repo.advance("moved");
        let path = repo.planted_git("fail");
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("PATH", &path)],
        );
        assert_eq!(
            exit(&out),
            Some(1),
            "the push's own status: {}",
            stderr(&out)
        );
        let reply = result(&out);
        assert_eq!(reply["push"]["status"], "failed");
        let new = repo.head();
        assert_ne!(new, old, "the push rebased before its transport failed");
        let record = repo.read();
        assert_eq!(
            record["fixed_items"][0]["commit"],
            &new[..7],
            "the map is applied whatever the push answered"
        );
        assert_eq!(record["rebase_map"][&old], new);
        assert_eq!(record["push_attempt"]["state"], "failed");
        assert!(
            record.get("stages").is_none(),
            "a failed push records no restack stage"
        );
        assert!(fs::metadata(repo.map()).is_err(), "the map is consumed");
    }

    #[test]
    fn the_pushs_own_hop_reconciles_after_the_push() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        repo.advance("moved");
        let out = repo.push("branch");
        let reply = result(&out);
        let new = repo.head();
        assert_eq!(
            reply["reconciled"],
            json!([{"key": "sha-reconcile", "map_entries": 1, "fixed_items": 1, "pr_fixes": 1}])
        );
        let record = repo.read();
        assert_eq!(record["fixed_items"][0]["commit"], &new[..7]);
        assert_eq!(
            record["pr_comment_review"]["fixes"][0]["commit"],
            &new[..10]
        );
        assert!(
            record.get("restacks").is_none(),
            "the push's own rebase is no restack"
        );
        assert_eq!(repo.remote("ken-1"), new);
    }

    #[test]
    fn a_recorded_prefix_follows_each_hop_and_a_dropped_commit_stays_marked() {
        let repo = Repo::new("KEN-1", "");
        let feature = repo.head();
        let dup = commit(&repo.wt, "dup", "same\n", "dup");
        repo.record(json!({
            "fixed_items": [{"commit": &dup[..8]}],
            "pr_comment_review": {"fixes": [{"commit": &feature[..10]}]},
        }));
        commit(&repo.main, "dup", "same\n", "dup upstream");
        git(&repo.main, &["push", "-q", "origin", "main"]);
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        let record = repo.read();
        assert_eq!(record["rebase_map"][&dup], "dropped");
        assert_eq!(
            record["fixed_items"][0]["commit"],
            format!("dropped:{}", &dup[..8])
        );
        let moved = repo.head();
        assert_eq!(
            record["pr_comment_review"]["fixes"][0]["commit"],
            &moved[..10]
        );
        repo.advance("again");
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        let record = repo.read();
        assert_eq!(
            record["fixed_items"][0]["commit"],
            format!("dropped:{}", &dup[..8]),
            "a dropped commit stays marked"
        );
        assert_eq!(
            record["pr_comment_review"]["fixes"][0]["commit"],
            &repo.head()[..10],
            "a moved prefix follows the next hop"
        );
    }

    #[test]
    fn a_map_that_is_not_a_hop_record_refuses_and_keeps_the_file() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        let new = "c".repeat(40);
        record_with_fixes(&repo, &old);
        let before = repo.read();
        for (text, cause, line) in [
            ("not a map line\n".to_owned(), "restack-map-grammar", 1),
            (
                format!("rebase-map: {old} {new}\n"),
                "restack-map-grammar",
                1,
            ),
            (
                format!("rebase-hop:\nrebase-hop:\nrebase-map: {old} {new}\n"),
                "restack-map-grammar",
                1,
            ),
            (
                format!("rebase-hop:\nrebase-map: not-a-sha {new}\n"),
                "map-sha",
                2,
            ),
            (
                format!("rebase-hop:\nrebase-map: {old} not-a-sha\n"),
                "map-sha",
                2,
            ),
            (
                format!("rebase-hop:\nrebase-map: {old} {new}\nrebase-hop:\nnot a map line\n"),
                "restack-map-grammar",
                4,
            ),
            (
                format!("rebase-hop:\nrebase-map: {old} {new}\nrebase-unmapped: {old}\n"),
                "rebase-unmapped",
                3,
            ),
        ] {
            fs::write(repo.map(), &text).unwrap();
            let got = refusal(&repo.push("branch"));
            assert_eq!(
                got,
                format!(
                    "orch-runtime: rebase-map-unreadable cause={cause} line={line} file={}",
                    repo.map().display()
                ),
                "{text}"
            );
            assert_eq!(
                fs::read_to_string(repo.map()).unwrap(),
                text,
                "the file is kept"
            );
            assert_eq!(
                repo.read(),
                before,
                "no hop applies from a map that does not parse whole: {text}"
            );
        }
        let map = repo.map();
        fs::write(&map, format!("rebase-hop:\nrebase-map: {old} {new}\n")).unwrap();
        let mode = |m: u32| {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&map, fs::Permissions::from_mode(m)).unwrap();
        };
        mode(0o000);
        let got = refusal(&repo.push("branch"));
        mode(0o644);
        assert!(
            got.starts_with(&format!(
                "orch-runtime: rebase-map-unreadable cause=map-read file={}",
                map.display()
            )),
            "{got}"
        );
        assert_eq!(repo.read(), before, "an unreadable map applies nothing");
        assert_eq!(
            repo.remote("ken-1"),
            "",
            "every refusal lands before the push"
        );
    }

    #[test]
    fn one_hop_never_chains_its_own_mappings() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        let mid = "c".repeat(40);
        let last = "d".repeat(40);
        fs::write(
            repo.map(),
            format!("rebase-hop:\nrebase-map: {old} {mid}\nrebase-map: {mid} {last}\n"),
        )
        .unwrap();
        let out = repo.push("branch");
        assert_eq!(
            repo.read()["fixed_items"][0]["commit"],
            &mid[..7],
            "{}",
            stderr(&out)
        );
    }

    #[test]
    fn a_map_with_no_record_refuses_keeps_the_file_and_reconciles_on_the_rerun() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        let new = "c".repeat(40);
        let text = format!("rebase-hop:\nrebase-map: {old} {new}\n");
        fs::write(repo.map(), &text).unwrap();
        let line = refusal(&repo.push("branch"));
        assert!(
            line.starts_with("orch-runtime: restack-map-nostate issue=KEN-1"),
            "{line}"
        );
        assert!(
            !line.contains("push-exit"),
            "it refuses before the push: {line}"
        );
        assert_eq!(fs::read_to_string(repo.map()).unwrap(), text);
        assert_eq!(repo.remote("ken-1"), "");
        record_with_fixes(&repo, &old);
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(
            repo.read()["fixed_items"][0]["commit"],
            &new[..7],
            "the kept map reconciles on the re-run"
        );
        assert!(
            fs::metadata(repo.map()).is_err(),
            "and goes once its hop is recorded"
        );
    }

    #[test]
    fn a_record_that_cannot_be_written_keeps_the_map() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        let before = repo.read();
        let text = format!("rebase-hop:\nrebase-map: {old} {}\n", "c".repeat(40));
        fs::write(repo.map(), &text).unwrap();
        let mode = |m: u32| {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&repo.state, fs::Permissions::from_mode(m)).unwrap();
        };
        mode(0o555);
        let out = repo.push("branch");
        mode(0o755);
        assert!(
            refusal(&out).starts_with("orch-runtime: restack-map-write issue=KEN-1"),
            "{}",
            stderr(&out)
        );
        assert_eq!(repo.read(), before);
        assert_eq!(fs::read_to_string(repo.map()).unwrap(), text);
        assert_eq!(repo.remote("ken-1"), "");
    }

    #[test]
    fn a_map_that_cannot_be_removed_fails_the_call() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        let map = repo.map();
        fs::write(
            &map,
            format!("rebase-hop:\nrebase-map: {old} {}\n", "c".repeat(40)),
        )
        .unwrap();
        let dir = map.parent().unwrap().to_path_buf();
        let mode = |m: u32| {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, fs::Permissions::from_mode(m)).unwrap();
        };
        mode(0o555);
        let out = repo.push("branch");
        mode(0o755);
        let line = refusal(&out);
        assert!(
            line.starts_with(&format!(
                "orch-runtime: restack-map-clear file={}",
                map.display()
            )),
            "{line}"
        );
        assert_eq!(repo.remote("ken-1"), "", "it refuses before the push");
    }

    /// A published branch, a base that moved, and the worktree skill's own
    /// guarded restack, which leaves its hop in the map.
    fn restacked(repo: &Repo) {
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        repo.advance("moved");
        let out = program(worktree_cli())
            .args(["create", &repo.item, "--restack"])
            .env("PATH", tool_path(&[&repo.root.join("bin")]))
            .current_dir(&repo.main)
            .output()
            .unwrap();
        assert!(out.status.success(), "restack: {}", stderr(&out));
        assert!(fs::metadata(repo.map()).is_ok(), "the restack left its hop");
    }

    #[test]
    fn two_hops_in_one_file_carry_a_record_through_both() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        let mid = "c".repeat(40);
        let last = "d".repeat(40);
        fs::write(
            repo.map(),
            format!(
                "rebase-hop:\nrebase-map: {old} {mid}\nrebase-hop:\nrebase-map: {mid} {last}\n"
            ),
        )
        .unwrap();
        // The planted SHAs name no commit the push could publish, so the
        // row reads the reconcile, which lands before the push.
        let out = repo.push("branch");
        let record = repo.read();
        assert_eq!(
            record["fixed_items"][0]["commit"],
            &last[..7],
            "{}",
            stderr(&out)
        );
        assert_eq!(
            record["pr_comment_review"]["fixes"][0]["commit"],
            &last[..10]
        );
        assert_eq!(record["restacks"], 2, "each hop is its own restack");
    }

    #[test]
    fn each_restack_hop_counts_once_and_the_push_hop_counts_none() {
        let repo = Repo::new("KEN-1", "");
        record_with_fixes(&repo, &repo.head());
        restacked(&repo);
        let hop = fs::read_to_string(repo.map()).unwrap();
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(repo.read()["restacks"], 1);
        fs::write(repo.map(), &hop).unwrap();
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(
            repo.read()["restacks"],
            1,
            "a hop the record holds whole counts no second restack"
        );
        repo.advance("again");
        let out = repo.push("branch");
        assert_eq!(result(&out)["reconciled"][0]["key"], "sha-reconcile");
        assert_eq!(repo.read()["restacks"], 1, "the push's own hop counts none");
    }

    /// One finished range validation at the worktree's head, through the
    /// runtime's own validation entry: its run directory.
    fn range_run(repo: &Repo) -> String {
        let mut command = isolated();
        for (k, v) in &repo.env {
            command.env(k, v);
        }
        let out = command
            .args(["validate", "entry", "--worktree", repo.wt.to_str().unwrap()])
            .args([
                "--validate-mode",
                "range",
                "--base",
                "origin/main",
                "--attached",
                "--poll",
                "1",
            ])
            .env("PATH", tool_path(&[&repo.root.join("bin")]))
            .current_dir(&repo.wt)
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        assert!(text.contains("validate=pass"), "{text}\n{}", stderr(&out));
        text.lines()
            .find_map(|l| l.strip_prefix("state=started run-dir="))
            .and_then(|l| l.split(' ').next())
            .unwrap()
            .to_owned()
    }

    const RANGE: &str = "DEV_VALIDATE_RANGE_CMD = \"true\"\nDEV_VALIDATE_CMD = \"true\"\nDEV_VALIDATE_TIMEOUT_SECS = \"30\"\n";

    #[test]
    fn the_restack_stage_records_the_newest_finished_run_for_its_head_once() {
        let repo = Repo::new("KEN-1", RANGE);
        repo.link_agents();
        repo.record(json!({}));
        let earlier = range_run(&repo);
        restacked(&repo);
        let run = range_run(&repo);
        let out = repo.push("branch");
        let reply = result(&out);
        assert_eq!(reply["stage"], run, "{reply}");
        let record = repo.read();
        let stages = record["stages"].as_array().unwrap();
        assert_eq!(stages.len(), 1, "{record}");
        let stage = &stages[0];
        assert_eq!(
            (
                stage["kind"].clone(),
                stage["reason"].clone(),
                stage["round_id"].clone(),
                stage["run_dir"].clone()
            ),
            (json!("validate"), json!("restack"), Value::Null, json!(run))
        );
        assert!(stage["start"].is_u64() && stage["end"].is_u64(), "{stage}");
        assert_eq!(stage["outcome"], "pass");
        assert_eq!(stage["proof"]["head"], repo.head());
        assert_ne!(
            stage["run_dir"], earlier,
            "a run for another head is no candidate"
        );
        let row = &record["validate_rounds"][0];
        assert_eq!(
            (row["kind"].clone(), row["mode"].clone()),
            (json!("restack"), json!("range"))
        );
        assert!(
            row["seconds"].is_u64() && row["round_id"].as_str().unwrap().starts_with("restack-")
        );
        let tree = git(&repo.wt, &["rev-parse", "HEAD^{tree}"]);
        let base = git(&repo.wt, &["merge-base", "HEAD", "origin/main"]);
        let proof = isolated()
            .args(["--state-dir", repo.state.to_str().unwrap()])
            .args([
                "read-proof",
                "--item",
                "KEN-1",
                "--need",
                "restack",
                "--tree",
                &tree,
                "--head",
                &repo.head(),
                "--base",
                &base,
            ])
            .env("PATH", tool_path(&[&repo.root.join("bin")]))
            .env("DEV_VALIDATE_RANGE_CMD", "true")
            .env("DEV_VALIDATE_CMD", "true")
            .current_dir(&repo.main)
            .output()
            .unwrap();
        assert_eq!(
            result(&proof)["proof"],
            "complete",
            "read-proof reads the restack stage"
        );
        let again = repo.push("branch");
        assert_eq!(exit(&again), Some(0), "{}", stderr(&again));
        assert_eq!(
            repo.read()["stages"].as_array().unwrap().len(),
            1,
            "once per run directory"
        );
    }

    #[test]
    fn an_unrecorded_timing_write_keeps_the_push_verdict_and_the_retry_identity() {
        let repo = Repo::new("KEN-1", RANGE);
        repo.link_agents();
        repo.record(json!({}));
        restacked(&repo);
        let run = range_run(&repo);
        fs::remove_file(Path::new(&run).join("paths")).ok();
        fs::create_dir_all(Path::new(&run).join("paths")).unwrap();
        let out = repo.push("branch");
        assert_eq!(
            exit(&out),
            Some(0),
            "the timing write is advisory: {}",
            stderr(&out)
        );
        let reply = result(&out);
        assert!(
            reply["stage"].as_str().unwrap().starts_with("unrecorded"),
            "{reply}"
        );
        let pending = repo.map().with_file_name("kendex-restack-validation");
        assert!(
            fs::read_to_string(pending).unwrap().contains(&run),
            "the run's identity is kept"
        );
    }

    #[test]
    fn a_publication_retry_keeps_the_restack_runs_identity() {
        let repo = Repo::new("KEN-1", RANGE);
        repo.link_agents();
        repo.record(json!({}));
        restacked(&repo);
        let run = range_run(&repo);
        let path = repo.planted_git("fail");
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("PATH", &path)],
        );
        assert_eq!(exit(&out), Some(1), "{}", stderr(&out));
        assert!(
            fs::metadata(repo.map()).is_err(),
            "the map was reconciled before the transport"
        );
        assert!(repo.read().get("stages").is_none());
        repo.lift("fail");
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("PATH", &path)],
        );
        assert_eq!(result(&out)["stage"], run, "{}", stderr(&out));
        let pending = repo.map().with_file_name("kendex-restack-validation");
        assert!(
            fs::metadata(pending).is_err(),
            "the identity goes once the stage is written"
        );
    }

    #[test]
    fn a_skip_or_a_push_time_rewrite_records_no_earlier_run() {
        let repo = Repo::new("KEN-1", RANGE);
        repo.link_agents();
        repo.record(json!({}));
        range_run(&repo);
        repo.advance("moved");
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert!(
            repo.read().get("stages").is_none(),
            "a push-time rewrite binds no earlier run"
        );
    }

    #[test]
    fn the_post_push_record_publishes_nothing_and_consumes_no_map() {
        let repo = Repo::new("KEN-1", RANGE);
        repo.link_agents();
        repo.record(json!({}));
        let run = range_run(&repo);
        let map = format!("rebase-unmapped: {}\n", repo.head());
        fs::write(repo.map(), &map).unwrap();
        let request = |dir: &str| json!({"op": "record-push", "mode": "record-restack-validation", "worktree": repo.wt, "run_dir": dir});
        let reply = result(&repo.op(request(&run)));
        assert_eq!(reply["stage"], run);
        assert_eq!(
            fs::read_to_string(repo.map()).unwrap(),
            map,
            "recording consumes no map"
        );
        assert_eq!(repo.remote("ken-1"), "", "recording publishes nothing");
        commit(&repo.wt, "later", "later\n", "later");
        let reply = result(&repo.op(request(&run)));
        assert_eq!(
            reply["stage"], "unrecorded cause=no-run",
            "a run for another head is unavailable"
        );
        assert_eq!(repo.read()["stages"].as_array().unwrap().len(), 1);
    }

    const BASE: &str = "ORCH_DELIVERY = \"push-base\"\n";

    #[test]
    fn the_delivery_setting_selects_the_publication_mode() {
        let repo = Repo::new("KEN-1", BASE);
        repo.record(json!({}));
        assert_eq!(
            refusal(&repo.push("branch")),
            "orch-runtime: delivery-phase phase=missing"
        );
        let bad = repo.op(json!({"op": "record-push", "mode": "publish", "worktree": repo.wt, "base": "abc", "head": repo.head()}));
        assert!(
            refusal(&bad).starts_with("orch-runtime: delivery-phase mode=publish"),
            "{}",
            stderr(&bad)
        );
        let pr = Repo::new("KEN-1", "");
        pr.record(json!({}));
        assert_eq!(
            refusal(&pr.push("prepare")),
            "orch-runtime: delivery-phase delivery=pr"
        );
        assert_eq!(
            repo.remote("main"),
            git(&repo.main, &["rev-parse", "HEAD"]),
            "no base publication"
        );
    }

    #[test]
    fn the_checkpoint_publishes_the_guarded_branch_under_either_delivery() {
        let repo = Repo::new("KEN-1", BASE);
        repo.record(json!({}));
        let base = repo.remote("main");
        let out = repo.push("checkpoint");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        assert_eq!(repo.remote("ken-1"), repo.head());
        assert_eq!(repo.remote("main"), base, "a checkpoint publishes no base");
    }

    fn prepared(repo: &Repo) -> Value {
        let out = repo.push("prepare");
        assert_eq!(
            exit(&out),
            Some(0),
            "{}{}",
            stderr(&out),
            String::from_utf8_lossy(&out.stdout)
        );
        result(&out)["prepared"].clone()
    }

    #[test]
    fn preparation_returns_its_receipt_before_validation_or_transport() {
        let repo = Repo::new(
            "KEN-1",
            &format!("{BASE}DEV_VALIDATE_RANGE_CMD = \"touch tmp/validated\"\n"),
        );
        repo.record(json!({}));
        let base = repo.remote("main");
        let receipt = prepared(&repo);
        assert_eq!(receipt["before"], base);
        assert_eq!(receipt["commit"], repo.head());
        assert_eq!(repo.message(), "feature", "one commit keeps its message");
        assert_eq!(repo.remote("main"), base, "preparation leaves the base");
        assert!(
            fs::metadata(repo.wt.join("tmp/validated")).is_err(),
            "preparation runs no validation"
        );
    }

    #[test]
    fn a_fold_names_the_item_and_carries_every_folded_subject_through_the_gate() {
        let repo = Repo::new("KEN-1", BASE);
        repo.record(json!({}));
        git(
            &repo.wt,
            &[
                "commit",
                "-q",
                "--amend",
                "-m",
                "docs: describe the feature",
            ],
        );
        repo.arm_gate();
        commit(&repo.wt, "flag", "flag\n", "feat(KEN-1): add the flag");
        let out = repo.push("checkpoint");
        assert_eq!(exit(&out), Some(0), "{}", stderr(&out));
        commit(&repo.wt, "path", "path\n", "fix(KEN-1): quote the path");
        let receipt = prepared(&repo);
        let before = receipt["before"].as_str().unwrap();
        assert_eq!(
            git(
                &repo.wt,
                &["rev-list", "--count", &format!("{before}..HEAD")]
            ),
            "1"
        );
        assert_eq!(
            repo.message(),
            "feat(KEN-1): add the flag\n\n- docs: describe the feature\n- feat(KEN-1): add the flag\n- fix(KEN-1): quote the path"
        );
        assert!(
            fs::metadata(repo.map().with_file_name("kendex-fold-message")).is_err(),
            "the message file is removed"
        );
    }

    #[test]
    fn a_fold_whose_headers_never_name_the_item_refuses_before_it_folds() {
        let repo = Repo::new("KEN-1", BASE);
        repo.record(json!({}));
        commit(&repo.wt, "child", "child\n", "feat(KEN-2): the first child");
        let head = repo.head();
        assert_eq!(
            refusal(&repo.push("prepare")),
            "orch-runtime: delivery-message item=KEN-1 cause=no-item-header commits=2"
        );
        assert_eq!(repo.head(), head, "nothing is folded");
        assert_eq!(repo.message(), "feat(KEN-2): the first child");
    }

    #[test]
    fn publication_validates_the_exact_prepared_head_then_transports_it() {
        let range = "DEV_VALIDATE_RANGE_CMD = \"test ! -e tmp/fail && git rev-parse HEAD > tmp/validated\"\nDEV_VALIDATE_CMD = \"true\"\nDEV_VALIDATE_TIMEOUT_SECS = \"30\"\n";
        let repo = Repo::new("KEN-1", &format!("{BASE}{range}"));
        repo.link_agents();
        repo.record(json!({}));
        let base = repo.remote("main");
        let publish = |receipt: &Value| {
            repo.op(
                json!({"op": "record-push", "mode": "publish", "worktree": repo.wt,
                "base": receipt["before"], "head": receipt["commit"]}),
            )
        };
        let receipt = prepared(&repo);
        commit(&repo.wt, "late", "late\n", "fix(KEN-1): late");
        assert!(refusal(&publish(&receipt)).starts_with("orch-runtime: delivery-validate"));
        assert_eq!(
            repo.remote("main"),
            base,
            "a changed head publishes nothing"
        );
        let receipt = prepared(&repo);
        fs::write(repo.wt.join("tmp/fail"), "").unwrap();
        assert!(refusal(&publish(&receipt)).starts_with("orch-runtime: delivery-validate"));
        assert_eq!(
            repo.remote("main"),
            base,
            "a failed validation publishes nothing"
        );
        fs::remove_file(repo.wt.join("tmp/fail")).unwrap();
        let out = publish(&receipt);
        let reply = result(&out);
        assert_eq!(
            fs::read_to_string(repo.wt.join("tmp/validated"))
                .unwrap()
                .trim(),
            receipt["commit"]
        );
        assert_eq!(
            repo.remote("main"),
            receipt["commit"],
            "the exact prepared head reaches the base"
        );
        assert_eq!(reply["delivery"]["commit"], receipt["commit"]);
        assert!(reply["delivery"]["at"].is_string(), "{reply}");
    }

    #[test]
    fn a_micro_publication_checks_the_tier_and_runs_no_validation() {
        let repo = Repo::new("KEN-1", BASE);
        repo.link_agents();
        repo.record(json!({"tier": "micro"}));
        let receipt = prepared(&repo);
        let out = repo.op(
            json!({"op": "record-push", "mode": "publish", "worktree": repo.wt,
            "base": receipt["before"], "head": receipt["commit"]}),
        );
        let reply = result(&out);
        assert!(
            reply.get("validation").is_none(),
            "micro starts no validation: {reply}"
        );
        assert_eq!(repo.remote("main"), receipt["commit"]);
    }

    /// Where the main checkout's committed stage list leaves out
    /// `git-hooks`, as a repository whose lanes validate through the runner
    /// commits it, the armed chain proves nothing: a micro publication
    /// validates its range through the runner, a red run publishing
    /// nothing; a list outside its form refuses before any transport.
    #[test]
    fn a_micro_publication_validates_its_range_where_the_policy_runs_no_git_hooks() {
        let range = "DEV_VALIDATE_RANGE_CMD = \"test ! -e tmp/fail && git rev-parse HEAD > tmp/validated\"\nDEV_VALIDATE_CMD = \"true\"\nDEV_VALIDATE_TIMEOUT_SECS = \"30\"\n";
        let stages = "ORCH_STAGES = \"external-review local-review preflight doc-limits\"\n";
        let repo = Repo::new("KEN-1", &format!("{BASE}{stages}{range}"));
        repo.link_agents();
        repo.record(json!({"tier": "micro"}));
        let base = repo.remote("main");
        let publish = |repo: &Repo, receipt: &Value| {
            repo.op(
                json!({"op": "record-push", "mode": "publish", "worktree": repo.wt,
                "base": receipt["before"], "head": receipt["commit"]}),
            )
        };
        let receipt = prepared(&repo);
        fs::write(repo.wt.join("tmp/fail"), "").unwrap();
        assert!(
            refusal(&publish(&repo, &receipt)).starts_with("orch-runtime: delivery-validate"),
            "a red range run refuses the publication"
        );
        assert_eq!(repo.remote("main"), base, "a red run publishes nothing");
        fs::remove_file(repo.wt.join("tmp/fail")).unwrap();
        let reply = result(&publish(&repo, &receipt));
        assert_eq!(reply["validation"]["exit"], 0, "{reply}");
        assert_eq!(
            fs::read_to_string(repo.wt.join("tmp/validated"))
                .unwrap()
                .trim(),
            receipt["commit"]
        );
        assert_eq!(repo.remote("main"), receipt["commit"]);

        let misspelt = Repo::new("KEN-1", &format!("{BASE}ORCH_STAGES = \"git-hook\"\n"));
        misspelt.link_agents();
        misspelt.record(json!({"tier": "micro"}));
        let base = misspelt.remote("main");
        let receipt = prepared(&misspelt);
        assert_eq!(
            refusal(&publish(&misspelt, &receipt)),
            "orch-runtime: setting-invalid key=ORCH_STAGES value=git-hook"
        );
        assert_eq!(
            misspelt.remote("main"),
            base,
            "an unread policy publishes nothing"
        );
    }

    /// The micro cycle's own check refuses the publication where change-scope
    /// cannot classify the prepared range (none installed beside the
    /// configured path reader), then where the range earns a wider cycle (an
    /// instruction file), and neither publishes.
    #[test]
    fn a_micro_publication_unclassified_or_earning_more_publishes_nothing() {
        let repo = Repo::new("KEN-1", BASE);
        repo.link_agents();
        repo.record(json!({"tier": "micro"}));
        let base = repo.remote("main");
        let absent = repo.root.join("absent/harness-only");
        let publish = |receipt: &Value, env: &[(&str, &str)]| {
            repo.op_env(
                &repo.item,
                &json!({"op": "record-push", "mode": "publish", "worktree": repo.wt,
                "base": receipt["before"], "head": receipt["commit"]}),
                env,
            )
        };
        let receipt = prepared(&repo);
        assert_eq!(
            refusal(&publish(
                &receipt,
                &[("CHANGE_SCOPE_PATHS_CLI", absent.to_str().unwrap())]
            )),
            format!(
                "orch-runtime: delivery-tier result=orch-runtime: tier cause=dependency-absent skill=change-scope path={}",
                repo.root.join("absent/change-scope").display()
            )
        );
        assert_eq!(
            repo.remote("main"),
            base,
            "an unclassified range publishes nothing"
        );
        commit(
            &repo.wt,
            "AGENTS.md",
            "# Instructions\n",
            "feat(KEN-1): instructions",
        );
        let receipt = prepared(&repo);
        assert_eq!(
            refusal(&publish(&receipt, &[])),
            "orch-runtime: delivery-tier result=tier=small brief=small cause=instruction-file path=AGENTS.md glob=AGENTS.md estimate=- delta=- paths=0"
        );
        assert_eq!(repo.remote("main"), base, "a wider cycle publishes nothing");
    }

    #[test]
    fn a_conflicting_history_refuses_with_the_worktree_key_and_publishes_nothing() {
        let repo = Repo::new("KEN-1", "");
        repo.record(json!({}));
        commit(&repo.wt, "base", "lane\n", "lane edit");
        commit(&repo.main, "base", "main\n", "main edit");
        git(&repo.main, &["push", "-q", "origin", "main"]);
        let out = repo.push("branch");
        assert_eq!(exit(&out), Some(1));
        let reply = result(&out);
        assert!(
            reply["push"]["stderr"]
                .as_str()
                .unwrap()
                .starts_with("worktree-push-rebase-failed:"),
            "{reply}"
        );
        assert_eq!(repo.remote("ken-1"), "");
    }

    #[test]
    fn a_push_whose_answer_is_lost_reads_unknown_and_keeps_the_map() {
        let repo = Repo::new("KEN-1", "");
        let old = repo.head();
        record_with_fixes(&repo, &old);
        repo.advance("moved");
        let path = repo.planted_git("kill");
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("PATH", &path)],
        );
        assert_eq!(exit(&out), Some(75), "{}", stderr(&out));
        assert_eq!(result(&out)["push"]["status"], "unknown");
        let record = repo.read();
        assert_eq!(
            record["push_attempt"]["state"], "attempted",
            "the attempt stays for the next call"
        );
        assert_eq!(
            record["fixed_items"][0]["commit"],
            &repo.head()[..7],
            "the rewrite's map is reconciled"
        );
        repo.lift("kill");
        let out = repo.op_env(
            "KEN-1",
            &json!({"op": "record-push", "mode": "branch", "worktree": repo.wt}),
            &[("PATH", &path)],
        );
        let reply = result(&out);
        assert_eq!(
            reply["previous"], "not-landed",
            "settled from the remote before the second push"
        );
        assert_eq!(repo.read()["push_attempt"]["state"], "confirmed");
        assert_eq!(repo.remote("ken-1"), repo.head());
    }
}

mod prune {
    use super::*;

    /// A checkout with a linked worktree on `branch` holding one Cargo
    /// profile, leased to `owner` as start-worktree claims it, and a `df`
    /// answering the row's use for a path ending in `/target`, the outside
    /// use for one ending in `/cargo-out`, 10 for any other, in `df -P`'s
    /// form.
    struct Lane {
        _dir: tempfile::TempDir,
        root: PathBuf,
        main: PathBuf,
        wt: PathBuf,
        state: PathBuf,
        key: String,
    }

    fn fill(path: &Path, bytes: usize) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![0u8; bytes]).unwrap();
    }

    impl Lane {
        fn new(key: &str, branch: &str, owner: Option<&str>) -> Lane {
            let dir = tempfile::tempdir().unwrap();
            let root = fs::canonicalize(dir.path()).unwrap();
            let main = root.join("main");
            let wt = root.join("trees/topic");
            fs::create_dir_all(&main).unwrap();
            git(&main, &["init", "-q", "-b", "main"]);
            for (k, v) in [
                ("gc.auto", "0"),
                ("maintenance.auto", "false"),
                ("commit.gpgsign", "false"),
            ] {
                git(&main, &["config", k, v]);
            }
            fs::write(main.join("Cargo.toml"), "[package]\nname = \"x\"\n").unwrap();
            fs::write(main.join(".gitignore"), "/target\n").unwrap();
            git(&main, &["add", "-A"]);
            git(&main, &["commit", "-qm", "base"]);
            git(
                &main,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    branch,
                    wt.to_str().unwrap(),
                    "main",
                ],
            );
            fill(&wt.join("target/debug/.cargo-lock"), 0);
            fill(&wt.join("target/debug/deps/unit-0.rlib"), 65536);
            if let Some(owner) = owner {
                let out = program(skills().join("worktree/scripts/worktree-session-guard"))
                    .args(["claim", wt.to_str().unwrap(), "--owner", owner])
                    .output()
                    .unwrap();
                assert!(out.status.success(), "claim: {}", stderr(&out));
            }
            let bin = root.join("bin");
            fs::create_dir_all(&bin).unwrap();
            write_executable(
                &bin.join("df"),
                "#!/bin/sh\n[ -z \"$DF_FAIL\" ] || exit 1\nused=10\nfor a in \"$@\"; do last=$a; done\ncase \"$last\" in */target) used=$DF_TARGET_USED ;; */cargo-out) used=$DF_OUTSIDE_USED ;; esac\n[ -z \"$DF_JUNK\" ] || used=unknown\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/fake 1000 1 1 %s%% /\\n' \"$used\"\n",
            );
            let state = root.join("state");
            fs::create_dir_all(&state).unwrap();
            Lane {
                _dir: dir,
                root,
                main,
                wt,
                state,
                key: key.to_owned(),
            }
        }

        fn record(&self, doc: Value) {
            fs::write(
                self.state.join(format!("workflow-state-{}.json", self.key)),
                doc.to_string(),
            )
            .unwrap();
        }

        fn lane_record(&self, round: &str) {
            self.record(json!({"worktree": self.wt, "branch": "ken-1", "dev_round_id": round}));
        }

        fn read(&self) -> Value {
            serde_json::from_str(
                &fs::read_to_string(self.state.join(format!("workflow-state-{}.json", self.key)))
                    .unwrap(),
            )
            .unwrap()
        }

        fn prune(&self, field: &str, used: &str, env: &[(&str, &str)]) -> Output {
            let file = self.root.join("request.json");
            fs::write(
                &file,
                json!({"op": "prune-round", "field": field}).to_string(),
            )
            .unwrap();
            let mut command = isolated();
            command
                .args(["--state-dir", self.state.to_str().unwrap()])
                .args([
                    "op",
                    "--item",
                    &self.key,
                    "--request",
                    file.to_str().unwrap(),
                ])
                .env("WORKTREE_CLI", worktree_cli())
                .env("PATH", tool_path(&[&self.root.join("bin")]))
                .env("DF_TARGET_USED", used)
                .env("ORCH_ROUND_PRUNE_DISK_PCT", "75")
                .current_dir(&self.main);
            for (k, v) in env {
                command.env(k, v);
            }
            command.output().unwrap()
        }

        fn artifacts(&self) -> Vec<String> {
            let mut found = Vec::new();
            let base = self.wt.join("target/debug");
            let mut stack = vec![base.clone()];
            while let Some(dir) = stack.pop() {
                for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        stack.push(path);
                    } else {
                        found.push(path.strip_prefix(&base).unwrap().display().to_string());
                    }
                }
            }
            found.sort();
            found
        }
    }

    const KEPT: [&str; 2] = [".cargo-lock", "deps/unit-0.rlib"];

    /// The reply's action, use and bytes, and what the record holds.
    fn answer(lane: &Lane, out: &Output, round: &str) -> (String, u64, bool) {
        let reply = support::reply(out);
        assert!(reply["ok"].as_bool().unwrap(), "refused: {}", stderr(out));
        let r = &reply["result"];
        let recorded = &lane.read()["round_prunes"][round];
        assert_eq!(
            recorded["action"], r["action"],
            "the record says what the reply says"
        );
        assert_eq!(recorded["bytes"], r["bytes"]);
        (
            r["action"].as_str().unwrap().to_owned(),
            r["used_pct"].as_u64().unwrap(),
            r["bytes"].as_u64().unwrap() > 0,
        )
    }

    #[test]
    fn a_record_with_no_round_refuses_naming_the_field() {
        let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
        let out = lane.prune("dev", "80", &[]);
        assert_eq!(
            refusal(&out),
            "orch-runtime: state-missing field=dev_round_id"
        );
        lane.record(json!({"worktree": lane.wt, "branch": "ken-1"}));
        let out = lane.prune("dev", "80", &[]);
        assert_eq!(
            refusal(&out),
            "orch-runtime: state-missing field=dev_round_id"
        );
        assert_eq!(lane.artifacts(), KEPT, "nothing is pruned");
    }

    #[test]
    fn the_prune_resolves_its_lane_worktree_or_records_none() {
        let lane = Lane::new("pr-5", "ken-1", Some("KEN-1"));
        lane.record(json!({"branch": "ken-1", "dev_round_id": "1-1"}));
        let out = lane.prune("dev", "80", &[]);
        assert_eq!(
            answer(&lane, &out, "1-1").0,
            "pruned",
            "a branch alone names the worktree holding it"
        );
        for (doc, why) in [
            (
                json!({"branch": "gone-branch", "dev_round_id": "2-2"}),
                "a branch no worktree holds",
            ),
            (
                json!({"worktree": lane.main, "branch": "main", "dev_round_id": "3-3"}),
                "the main checkout",
            ),
        ] {
            lane.record(doc.clone());
            let out = lane.prune("dev", "80", &[]);
            let round = doc["dev_round_id"].as_str().unwrap();
            assert_eq!(
                answer(&lane, &out, round),
                ("no-worktree".to_owned(), 0, false),
                "{why}"
            );
            assert_eq!(exit(&out), Some(0), "{why}: the round goes ahead");
        }
        fs::remove_dir_all(&lane.wt).unwrap();
        lane.record(json!({"branch": "ken-1", "dev_round_id": "4-4"}));
        let out = lane.prune("dev", "80", &[]);
        assert_eq!(
            answer(&lane, &out, "4-4").0,
            "no-worktree",
            "a registered tree whose directory is gone"
        );
        let bin = lane.root.join("bin-list");
        fs::create_dir_all(&bin).unwrap();
        let real = String::from_utf8_lossy(
            &program("sh")
                .args(["-c", "command -v git"])
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_owned();
        write_executable(
            &bin.join("git"),
            format!(
                "#!/bin/sh\ncase \"$*\" in *'worktree list'*) echo 'fatal: planted' >&2; exit 128 ;; esac\nexec '{real}' \"$@\"\n"
            ),
        );
        let path = tool_path(&[&bin, &lane.root.join("bin")]);
        let out = lane.prune("dev", "80", &[("PATH", &path)]);
        assert!(
            refusal(&out).starts_with("orch-runtime: worktree-list branch=ken-1"),
            "{}",
            stderr(&out)
        );
        assert!(
            lane.read()["round_prunes"].get("4-4").is_some()
                && lane.read()["round_prunes"].get("5-5").is_none()
        );
    }

    #[test]
    fn a_mark_outside_one_to_a_hundred_refuses_before_any_prune() {
        for bad in ["0", "101", "abc"] {
            let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
            lane.lane_record("1-1");
            let out = lane.prune("dev", "80", &[("ORCH_ROUND_PRUNE_DISK_PCT", bad)]);
            assert_eq!(
                refusal(&out),
                format!("orch-runtime: setting-invalid key=ORCH_ROUND_PRUNE_DISK_PCT value={bad}")
            );
            assert_eq!(lane.artifacts(), KEPT, "{bad}");
            assert!(lane.read().get("round_prunes").is_none(), "{bad}");
        }
    }

    #[test]
    fn the_prune_runs_under_the_owner_its_branch_names() {
        for (key, branch, setup) in [
            ("pr-5", "ken-1", ""),
            ("KEN-1", "topic", ""),
            ("local-1-1-1", "ken-1", "merge"),
            ("local-1-1-1", "ken-1", "apply"),
        ] {
            let lane = Lane::new(key, branch, Some("KEN-1"));
            if !setup.is_empty() {
                commit(&lane.main, "f", "main\n", "main");
                commit(&lane.wt, "f", "topic\n", "topic");
                let out = program("git")
                    .arg("-C")
                    .arg(&lane.wt)
                    .args(["rebase", &format!("--{setup}"), "main"])
                    .output()
                    .unwrap();
                assert!(!out.status.success(), "the rebase pauses on its conflict");
            }
            lane.record(json!({"worktree": lane.wt, "branch": branch, "dev_round_id": "1-1"}));
            let out = lane.prune("dev", "80", &[]);
            assert_eq!(
                answer(&lane, &out, "1-1").0,
                "pruned",
                "{key} on {branch} {setup}: {}",
                stderr(&out)
            );
            assert_eq!(lane.artifacts(), [".cargo-lock"], "{key} {setup}");
        }
    }

    #[test]
    fn the_prune_reads_the_volume_of_the_target_the_build_uses() {
        for (target, used, outside, action) in [
            ("target", "80", "", "pruned"),
            ("ABS", "80", "", "pruned"),
            ("OUT", "10", "80", "target-elsewhere"),
            ("OUT", "80", "74", "below-mark"),
        ] {
            let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
            lane.lane_record("1-1");
            let outside_dir = lane.root.join("outside/cargo-out");
            fill(&outside_dir.join("debug/deps/unit-9.rlib"), 4096);
            let value = match target {
                "ABS" => lane.wt.join("target").display().to_string(),
                "OUT" => outside_dir.display().to_string(),
                t => t.to_owned(),
            };
            let out = lane.prune(
                "dev",
                used,
                &[("CARGO_TARGET_DIR", &value), ("DF_OUTSIDE_USED", outside)],
            );
            let (got, _, _) = answer(&lane, &out, "1-1");
            assert_eq!(got, action, "{target}");
            if action == "target-elsewhere" {
                assert_eq!(
                    exit(&out),
                    Some(1),
                    "past the mark a target outside the worktree fails closed"
                );
                assert_eq!(lane.artifacts(), KEPT);
                assert!(fs::metadata(outside_dir.join("debug/deps/unit-9.rlib")).is_ok());
            }
        }
    }

    #[test]
    fn a_disk_read_that_fails_refuses_with_nothing_recorded() {
        for knob in ["DF_FAIL", "DF_JUNK"] {
            let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
            lane.lane_record("1-1");
            let out = lane.prune("dev", "80", &[(knob, "1")]);
            assert_eq!(
                refusal(&out),
                format!(
                    "orch-runtime: disk probe={}",
                    lane.wt.join("target").display()
                )
            );
            assert!(lane.read().get("round_prunes").is_none(), "{knob}");
            assert_eq!(lane.artifacts(), KEPT);
        }
    }

    #[test]
    fn past_the_mark_the_lanes_own_target_is_pruned_and_below_it_nothing() {
        for (used, action) in [("80", "pruned"), ("75", "pruned"), ("74", "below-mark")] {
            let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
            fill(&lane.wt.join("pkg/node_modules/left-pad/index.js"), 4096);
            lane.lane_record("1-1");
            let out = lane.prune("dev", used, &[]);
            let (got, pct, bytes) = answer(&lane, &out, "1-1");
            assert_eq!(
                (got.as_str(), pct.to_string(), bytes),
                (action, used.to_owned(), action == "pruned")
            );
            let left = if action == "pruned" {
                vec![".cargo-lock"]
            } else {
                KEPT.to_vec()
            };
            assert_eq!(lane.artifacts(), left, "{used}");
            assert!(
                fs::metadata(lane.wt.join("pkg/node_modules/left-pad/index.js")).is_ok(),
                "node_modules survives"
            );
            assert_eq!(exit(&out), Some(0));
        }
        let foreign = Lane::new("KEN-1", "ken-1", Some("KEN-9"));
        foreign.lane_record("1-1");
        let out = foreign.prune("dev", "80", &[]);
        assert_eq!(
            answer(&foreign, &out, "1-1"),
            ("failed".to_owned(), 80, false),
            "another session's lease"
        );
        assert_eq!(exit(&out), Some(1));
        assert_eq!(foreign.artifacts(), KEPT);
        let summary = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
        summary.lane_record("1-1");
        let cli = summary.root.join("summary-then-fail");
        write_executable(
            &cli,
            "#!/bin/sh\nprintf 'worktree-output-prune-summary: worktree=x mode=apply units=1 bytes=4096 uninspected-processes=0\\n'\nexit 1\n",
        );
        let out = summary.prune("dev", "80", &[("WORKTREE_CLI", cli.to_str().unwrap())]);
        assert_eq!(
            answer(&summary, &out, "1-1"),
            ("failed".to_owned(), 80, true),
            "a summary then a failure is failed"
        );
        assert_eq!(exit(&out), Some(1));
    }

    /// The runtime itself dies during the cleanup: a stand-in for the
    /// worktree skill that ends the process that started it, the one way a
    /// row loses the answer across the runtime's own death.
    #[test]
    fn a_prune_whose_answer_is_lost_reads_unknown_on_the_next_call() {
        let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
        lane.lane_record("1-1");
        let cli = lane.root.join("ends-its-caller");
        write_executable(&cli, "#!/bin/sh\nkill -KILL $PPID\nsleep 1\n");
        let out = lane.prune("dev", "80", &[("WORKTREE_CLI", cli.to_str().unwrap())]);
        assert_eq!(
            out.status.code(),
            None,
            "the runtime died with the cleanup's answer unread"
        );
        assert_eq!(
            lane.read()["round_prunes"]["1-1"]["action"],
            "pruning",
            "the record written before the cleanup stands"
        );
        let out = lane.prune("dev", "80", &[]);
        assert_eq!(support::reply(&out)["result"]["previous"], "unknown");
        assert_eq!(answer(&lane, &out, "1-1").0, "pruned");
    }

    /// A prune whose worktree program is gone refuses `unready` naming the
    /// package's install before it writes its round's `pruning` mark.
    #[test]
    fn a_prune_with_no_worktree_program_refuses_before_its_mark() {
        let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
        lane.lane_record("1-1");
        let gone = lane.root.join("gone/worktree");
        let out = lane.prune("dev", "80", &[("WORKTREE_CLI", gone.to_str().unwrap())]);
        assert_eq!(exit(&out), Some(1), "{}", stderr(&out));
        assert_eq!(
            stderr(&out).lines().next(),
            Some("orch-runtime: unready duty=prune program=worktree cause=absent fix=kendex-apply")
        );
        assert!(
            lane.read()["round_prunes"].get("1-1").is_none(),
            "the round's mark was written before the prune asked"
        );
    }

    #[test]
    fn a_ci_round_records_under_its_own_token_and_keeps_the_dev_round() {
        let lane = Lane::new("KEN-1", "ken-1", Some("KEN-1"));
        lane.record(json!({"worktree": lane.wt, "branch": "ken-1", "dev_round_id": "1-1", "ci_round_id": "2-2",
            "round_prunes": {"1-1": {"action": "below-mark", "used_pct": 74, "mark_pct": 75, "bytes": 0}},
            "stages": []}));
        let out = lane.prune("ci", "80", &[]);
        assert_eq!(answer(&lane, &out, "2-2").0, "pruned");
        let record = lane.read();
        assert_eq!(record["dev_round_id"], "1-1");
        assert_eq!(
            record["round_prunes"]["1-1"]["action"], "below-mark",
            "the dev round's record stands"
        );
        assert_eq!(record["stages"], json!([]));
    }
}

mod qa {
    use super::*;

    /// A repository on `item` over `main` whose one commit writes each of
    /// `files`, and the item's record carrying `labels`.
    struct Change {
        _dir: tempfile::TempDir,
        root: PathBuf,
        repo: PathBuf,
        state: PathBuf,
    }

    impl Change {
        fn new(files: &[(&str, &str)], labels: Option<Value>) -> Change {
            let dir = tempfile::tempdir().unwrap();
            let root = fs::canonicalize(dir.path()).unwrap();
            let repo = root.join("repo");
            fs::create_dir_all(&repo).unwrap();
            git(&repo, &["init", "-q", "-b", "main"]);
            for (k, v) in [
                ("gc.auto", "0"),
                ("maintenance.auto", "false"),
                ("commit.gpgsign", "false"),
            ] {
                git(&repo, &["config", k, v]);
            }
            fs::write(repo.join(".gitignore"), "tmp/\n").unwrap();
            git(&repo, &["add", ".gitignore"]);
            git(&repo, &["commit", "-qm", "base"]);
            git(&repo, &["checkout", "-qb", "item"]);
            for (path, text) in files {
                let file = repo.join(path);
                fs::create_dir_all(file.parent().unwrap()).unwrap();
                fs::write(&file, format!("{text}\n")).unwrap();
                git(&repo, &["add", path]);
            }
            git(&repo, &["commit", "-qm", "change"]);
            let state = root.join("state");
            fs::create_dir_all(&state).unwrap();
            if let Some(labels) = labels {
                fs::write(
                    state.join("workflow-state-ISSUE-1.json"),
                    json!({"issue_id": "ISSUE-1", "worktree": repo, "branch": "item", "qa_labels": labels}).to_string(),
                )
                .unwrap();
            }
            Change {
                _dir: dir,
                root,
                repo,
                state,
            }
        }

        fn op(&self, request: Value, env: &[(&str, &str)]) -> Output {
            let file = self.root.join("request.json");
            fs::write(&file, request.to_string()).unwrap();
            let mut command = isolated();
            command
                .args(["--state-dir", self.state.to_str().unwrap()])
                .args([
                    "op",
                    "--item",
                    "ISSUE-1",
                    "--request",
                    file.to_str().unwrap(),
                ])
                .current_dir(&self.repo);
            for (k, v) in env {
                command.env(k, v);
            }
            command.output().unwrap()
        }

        fn scan(&self, base: &str, judgments: Value, env: &[(&str, &str)]) -> Output {
            self.op(
                json!({"op": "record-qa-decision", "step": "scan", "worktree": self.repo, "base": base, "judgments": judgments}),
                env,
            )
        }

        fn decision(&self) -> Value {
            let doc: Value = serde_json::from_str(
                &fs::read_to_string(self.state.join("workflow-state-ISSUE-1.json")).unwrap(),
            )
            .unwrap();
            doc["qa_decision"].clone()
        }
    }

    fn signals(decision: &Value) -> Vec<String> {
        decision["signals"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn a_signal_outside_the_four_refuses() {
        let change = Change::new(&[("a.rs", "x")], Some(json!([])));
        let out = change.scan(
            "main",
            json!([{"judge": "add", "signal": "needs-coffee", "reason": "r"}]),
            &[],
        );
        assert!(
            refusal(&out).starts_with("orch-runtime: request-invalid"),
            "{}",
            stderr(&out)
        );
        let labelled = Change::new(&[("a.rs", "x")], Some(json!(["needs-coffee"])));
        let out = labelled.scan("main", json!([]), &[]);
        assert_eq!(
            refusal(&out),
            "orch-runtime: unknown-signal signal=needs-coffee source=dev"
        );
        assert_eq!(
            labelled.decision(),
            Value::Null,
            "a refusal records nothing"
        );
    }

    #[test]
    fn a_judgment_without_its_reason_refuses() {
        let change = Change::new(&[("a.rs", "x")], Some(json!([])));
        let out = change.scan(
            "main",
            json!([{"judge": "drop", "signal": "needs-ui-review", "reason": " "}]),
            &[],
        );
        assert_eq!(
            refusal(&out),
            "orch-runtime: judgment-reason signal=needs-ui-review"
        );
        let out = change.scan(
            "main",
            json!([{"judge": "drop", "signal": "needs-ui-review"}]),
            &[],
        );
        assert!(
            refusal(&out).starts_with("orch-runtime: request-invalid"),
            "{}",
            stderr(&out)
        );
        assert_eq!(change.decision(), Value::Null);
    }

    #[test]
    fn a_signal_judged_twice_refuses() {
        let change = Change::new(&[("a.rs", "x")], Some(json!([])));
        let out = change.scan(
            "main",
            json!([{"judge": "add", "signal": "needs-ui-review", "reason": "a"}, {"judge": "drop", "signal": "needs-ui-review", "reason": "b"}]),
            &[],
        );
        assert_eq!(
            refusal(&out),
            "orch-runtime: judgment-conflict signal=needs-ui-review"
        );
    }

    #[test]
    fn a_missing_record_refuses_and_records_nothing() {
        let change = Change::new(&[("a.rs", "x")], None);
        let out = change.scan("main", json!([]), &[]);
        assert!(
            refusal(&out).starts_with("orch-runtime: record-missing"),
            "{}",
            stderr(&out)
        );
        assert!(fs::metadata(change.state.join("workflow-state-ISSUE-1.json")).is_err());
        let held = Change::new(&[("a.rs", "x")], Some(json!([])));
        let mode = |m: u32| {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&held.state, fs::Permissions::from_mode(m)).unwrap();
        };
        mode(0o555);
        let out = held.scan("main", json!([]), &[]);
        mode(0o755);
        assert!(
            refusal(&out).starts_with("orch-runtime: "),
            "a write that does not land refuses"
        );
        assert_eq!(held.decision(), Value::Null, "and records nothing");
    }

    #[test]
    fn the_scan_records_each_signal_with_its_cause() {
        let change = Change::new(
            &[
                ("crates/core/lib.rs", "unsafe { x() }"),
                ("ui/src/a.tsx", "view"),
            ],
            Some(json!(["needs-review"])),
        );
        let out = change.scan("main", json!([]), &[("QA_UI_PATHS", "ui/src/*")]);
        let reply = result(&out);
        assert_eq!(reply, change.decision(), "the reply is the record");
        assert_eq!(
            signals(&reply),
            ["needs-review", "needs-safety-audit", "needs-ui-review"]
        );
        assert_eq!(
            reply["agents"],
            json!({"needs-review": "reviewer-correctness", "needs-safety-audit": "reviewer-safety", "needs-ui-review": "reviewer-quality"})
        );
        assert_eq!(
            reply["rationale"],
            "dev needs-review; safety-scan match; QA_UI_PATHS path=ui/src/a.tsx glob=ui/src/*"
        );
        let out = change.scan("no-such-ref", json!([]), &[("QA_UI_PATHS", "ui/src/*")]);
        let reply = result(&out);
        assert_eq!(
            signals(&reply),
            ["needs-review", "needs-safety-audit", "needs-ui-review"],
            "a failed read never reads as no signal"
        );
        assert!(
            reply["rationale"]
                .as_str()
                .unwrap()
                .contains("safety-scan exit=128"),
            "{reply}"
        );
        assert!(
            reply["rationale"]
                .as_str()
                .unwrap()
                .contains("QA_UI_PATHS paths-unread exit=128"),
            "{reply}"
        );
        let quiet = Change::new(&[("README", "docs")], Some(json!([])));
        let reply = result(&quiet.scan("main", json!([]), &[("QA_UI_PATHS", "ui/src/*")]));
        assert_eq!(
            (signals(&reply), reply["rationale"].clone()),
            (Vec::<String>::new(), json!("scan: no signal"))
        );
    }

    #[test]
    fn path_globs_match_as_the_bash_pattern_did() {
        use orch_runtime::ops::qa::glob_matches;
        for (glob, path, hit) in [
            ("ui/src/*", "ui/src/view/Panel.tsx", true),
            ("ui/src/*", "crates/core/lib.rs", false),
            ("docs/*", "ui/src/a.css", false),
            ("ui/src/**/*.tsx", "ui/src/Root.tsx", true),
            ("ui/src/**/*.tsx", "ui/src/view/a/Panel.tsx", true),
            ("ui/src/**/*.tsx", "ui/src/App.ts", false),
            ("ui/src", "ui/src/view/Panel.tsx", true),
            ("ui/src/", "ui/src/view/Panel.tsx", true),
            ("ui/src", "ui/srcx/Panel.tsx", false),
            ("ui/index.html", "ui/index.html", true),
            ("ui/[ab].css", "ui/b.css", true),
            ("ui/?.css", "ui/ab.css", false),
        ] {
            assert_eq!(glob_matches(glob, path), hit, "{glob} against {path}");
        }
    }

    #[test]
    fn judgments_apply_in_order_and_keep_their_reasons() {
        let change = Change::new(&[("ui/src/a.tsx", "view")], Some(json!(["needs-review"])));
        let env = [("QA_UI_PATHS", "ui/src/*")];
        let reply = result(&change.scan(
            "main",
            json!([{"judge": "drop", "signal": "needs-review", "reason": "small-tier"}, {"judge": "drop", "signal": "needs-ui-review", "reason": "test-only"}]),
            &env,
        ));
        assert_eq!(signals(&reply), Vec::<String>::new());
        let rationale = reply["rationale"].as_str().unwrap();
        assert!(
            rationale.ends_with("judgment drop=needs-review reason=small-tier; judgment drop=needs-ui-review reason=test-only"),
            "{rationale}"
        );
        let reply = result(&change.scan(
            "main",
            json!([{"judge": "drop", "signal": "needs-ui-review", "reason": "test-only"}, {"judge": "add", "signal": "needs-safety-audit", "reason": "risky"}]),
            &env,
        ));
        assert_eq!(signals(&reply), ["needs-review", "needs-safety-audit"]);
    }

    #[test]
    fn a_perf_signal_with_no_declared_runner_is_recorded_advisory() {
        let change = Change::new(&[("crates/core/lib.rs", "fast")], Some(json!([])));
        let perf = ("QA_PERF_PATHS", "crates/*");
        let reply = result(&change.scan("main", json!([]), &[perf]));
        assert_eq!(
            signals(&reply),
            Vec::<String>::new(),
            "no runner, no gating signal"
        );
        assert_eq!(
            reply["advisory"],
            json!([{"signal": "needs-perf-test", "agent": "reviewer-perf", "cause": "review-unproducible key=QA_PERF_RUNNER"}])
        );
        let reply = result(&change.scan(
            "main",
            json!([]),
            &[perf, ("QA_PERF_RUNNER", "bench"), ("QA_PERF_WORKLOAD", "w")],
        ));
        assert_eq!(
            reply["advisory"][0]["cause"],
            "review-unproducible key=QA_PERF_BASELINE"
        );
        let reply = result(&change.scan(
            "main",
            json!([]),
            &[
                perf,
                ("QA_PERF_RUNNER", "bench"),
                ("QA_PERF_WORKLOAD", "w"),
                ("QA_PERF_BASELINE", "main"),
            ],
        ));
        assert_eq!(
            signals(&reply),
            ["needs-perf-test"],
            "a declared review gates"
        );
        assert_eq!(reply["agents"]["needs-perf-test"], "reviewer-perf");
        assert!(reply.get("advisory").is_none());
    }

    /// The user's skip replaces the scanned routing with one that names no
    /// signal, the record the review's QA step reads as nothing to run.
    #[test]
    fn a_user_skip_replaces_the_routing_with_one_naming_no_signal() {
        let change = Change::new(&[("a.rs", "x")], Some(json!(["needs-review"])));
        result(&change.scan("main", json!([]), &[]));
        assert_eq!(signals(&change.decision()), ["needs-review"]);
        let skipped = result(&change.op(json!({"op": "record-qa-decision", "step": "skip"}), &[]));
        let routing = json!({"signals": [], "agents": {}, "rationale": "user skip"});
        assert_eq!(change.decision(), routing);
        assert_eq!(skipped, routing);
    }
}
