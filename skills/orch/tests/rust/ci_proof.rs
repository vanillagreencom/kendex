#![allow(
    clippy::disallowed_methods,
    reason = "isolated rows build their own fixture repositories, worlds and children"
)]
//! The change classifier's evidence on GitHub, read by the runtime: the
//! merged class the cycle records ([`ci_proof::merged_class`]) and the render
//! proof the `ci-proof` verb prints for a consumer refresh pull request,
//! each over one fixture repository and a `gh` answering what GitHub
//! documents, one case per kind of evidence.
mod support;

use std::path::{Path, PathBuf};

use orch_runtime::verify::ci_proof;
use serde_json::{Value, json};
use support::{
    copy_executable, fixtures, isolated, isolated_row, program, stderr, tool_path, write_executable,
};

const CHECK: &str = "Classify the diff";
const KENDEX: &str = "vanillagreencom/kendex";

fn git(dir: &Path, args: &[&str]) -> String {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// Whether the repository at `dir` holds `revision` as a commit.
fn holds(dir: &Path, revision: &str) -> bool {
    program("git")
        .arg("-C")
        .arg(dir)
        .args(["cat-file", "-e", &format!("{revision}^{{commit}}")])
        .output()
        .unwrap()
        .status
        .success()
}

/// The fixture repository the released producer measured: a root with
/// kendex's producer files and a product file, the product changed (the
/// measured base), a render on top (the head), each producer file altered
/// on a branch of its own over the head, and a base that advanced past the
/// measured one.
struct Repo {
    _dir: tempfile::TempDir,
    path: PathBuf,
    earlier: String,
    measured: String,
    head: String,
    base_tip: String,
}

impl Repo {
    fn new() -> Repo {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("repo");
        std::fs::create_dir_all(&path).unwrap();
        git(&path, &["init", "-q"]);
        for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
            git(&path, &["config", key, value]);
        }
        let catalog = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        for file in [
            ".github/workflows/skill-tests.yml",
            ".github/actions/change-class/action.yml",
            ".github/actions/change-class/classify",
        ] {
            let at = path.join(file);
            std::fs::create_dir_all(at.parent().unwrap()).unwrap();
            std::fs::copy(catalog.join(file), at).unwrap();
        }
        std::fs::write(path.join("product"), "old\n").unwrap();
        git(&path, &["add", "."]);
        git(&path, &["commit", "-qm", "root"]);
        let earlier = git(&path, &["rev-parse", "HEAD"]);
        std::fs::write(path.join("product"), "new\n").unwrap();
        git(&path, &["commit", "-qam", "product"]);
        let measured = git(&path, &["rev-parse", "HEAD"]);
        std::fs::create_dir_all(path.join(".agents")).unwrap();
        std::fs::write(path.join(".agents/render"), "render\n").unwrap();
        git(&path, &["add", ".agents"]);
        git(&path, &["commit", "-qm", "render"]);
        let head = git(&path, &["rev-parse", "HEAD"]);
        for part in ["action.yml", "classify"] {
            git(&path, &["checkout", "-q", "--detach", &head]);
            let file = path.join(".github/actions/change-class").join(part);
            let mut text = std::fs::read_to_string(&file).unwrap();
            text.push_str("\n# altered producer\n");
            std::fs::write(&file, text).unwrap();
            git(&path, &["commit", "-qam", &format!("alter {part}")]);
            git(
                &path,
                &["update-ref", &format!("refs/heads/alter-{part}"), "HEAD"],
            );
        }
        git(&path, &["checkout", "-q", "--detach", &measured]);
        std::fs::write(path.join("base-only"), "base advance\n").unwrap();
        git(&path, &["add", "base-only"]);
        git(&path, &["commit", "-qm", "base-advance"]);
        let base_tip = git(&path, &["rev-parse", "HEAD"]);
        git(&path, &["update-ref", "refs/heads/base", &base_tip]);
        git(&path, &["update-ref", "refs/heads/old-base", &earlier]);
        git(&path, &["update-ref", "refs/heads/refresh", &head]);
        git(
            &path,
            &["remote", "add", "origin", &path.display().to_string()],
        );
        Repo {
            _dir: dir,
            path,
            earlier,
            measured,
            head,
            base_tip,
        }
    }
}

/// One case's GitHub: the pull request (read twice, `live` the second
/// read), its changed files by page, the check runs, each job, run and
/// log, as GitHub documents each object.
struct GitHub {
    repo: String,
    head: String,
    pull: Value,
    live: Value,
    files: Vec<Value>,
    checks: Value,
    jobs: Vec<Value>,
    runs: Vec<Value>,
    logs: Vec<(u64, Option<String>)>,
}

fn check_run(id: u64, head: &str) -> Value {
    json!({"id": id, "node_id": format!("CR_{id}"), "name": CHECK, "head_sha": head,
        "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "success",
        "check_suite": {"id": 5}, "started_at": "2026-10-09T08:00:00Z", "completed_at": "2026-10-09T08:00:02Z",
        "html_url": format!("https://github.com/o/r/actions/runs/20/job/{id}"),
        "details_url": format!("https://github.com/o/r/actions/runs/20/job/{id}")})
}

fn job(id: u64, run: u64, head: &str, repo: &str) -> Value {
    json!({"id": id, "run_id": run, "name": CHECK, "head_sha": head, "status": "completed",
        "conclusion": "success", "started_at": "2026-10-09T08:00:00Z", "completed_at": "2026-10-09T08:00:01Z",
        "check_run_url": format!("https://api.github.com/repos/{repo}/check-runs/{id}"),
        "steps": [{"name": "classify", "status": "completed", "conclusion": "success", "number": 1,
                   "started_at": "2026-10-09T08:00:00Z", "completed_at": "2026-10-09T08:00:01Z"}]})
}

fn run(id: u64, head: &str, base: &str, repo: &str) -> Value {
    json!({"id": id, "path": ".github/workflows/ci.yml", "head_sha": head, "head_branch": "refresh",
        "status": "completed", "conclusion": "success", "workflow_id": 9, "event": "pull_request",
        "created_at": "2026-10-09T08:00:00Z", "updated_at": "2026-10-09T08:00:02Z",
        "repository": {"id": 7, "full_name": repo}, "head_repository": {"id": 7, "full_name": repo},
        "pull_requests": [{"id": 4200, "number": 42, "url": format!("https://api.github.com/repos/{repo}/pulls/42"),
            "head": {"ref": "refresh", "sha": head, "repo": {"id": 7, "url": "https://api.github.com/repos/o/r", "name": "r"}},
            "base": {"ref": "main", "sha": base, "repo": {"id": 7, "url": "https://api.github.com/repos/o/r", "name": "r"}}}]})
}

fn pull(head: &str, base: &str, body: &str, changed: u64) -> Value {
    json!({"number": 42, "state": "open", "title": "refresh", "body": body, "draft": false,
        "merged_at": null, "merge_commit_sha": null, "changed_files": changed, "author_association": "NONE",
        "head": {"sha": head, "ref": "refresh", "repo": null}, "base": {"ref": "main", "sha": base},
        "user": {"login": "kendex-refresh[bot]", "type": "Bot"}})
}

fn file(name: &str) -> Value {
    json!({"sha": "f00", "filename": name, "status": "modified", "additions": 1, "deletions": 0,
        "changes": 1, "blob_url": "https://x/b", "raw_url": "https://x/r", "contents_url": "https://x/c"})
}

/// The producer's job log: render-reach's range, then the classifier's
/// range, verifier and class, each line stamped and carriage-returned.
fn producer_log(base: &str, head: &str) -> String {
    let mut log =
        "2026-10-09T08:00:00.000Z ##[group]Run \u{1b}[36;1mrender-reach\u{1b}[0m\r\n".to_owned();
    let range = format!(
        "2026-10-09T08:00:00.000Z base-rev: {base}\r\n2026-10-09T08:00:00.000Z head-rev: {head}\r\n"
    );
    log.push_str(&range);
    for line in [
        "2026-10-09T08:00:00.000Z render_candidate=true",
        "2026-10-09T08:00:00.000Z ##[endgroup]",
        "2026-10-09T08:00:00.000Z ##[group]Run classify the diff",
    ] {
        log.push_str(line);
        log.push_str("\r\n");
    }
    log.push_str(&range);
    for line in [
        "2026-10-09T08:00:00.000Z render-verifier: verifier=path version=1.13.0",
        "2026-10-09T08:00:00.000Z render-proof: checked=1 failed=0",
        "2026-10-09T08:00:01.000Z class: class=render measured=true cause=render-proof",
        "2026-10-09T08:00:01.000Z ##[endgroup]",
    ] {
        log.push_str(line);
        log.push_str("\r\n");
    }
    log
}

impl GitHub {
    fn new(repo: &str, head: &str, base_tip: &str, measured: &str) -> GitHub {
        let pull = pull(head, base_tip, "Engine version: `kendex 1.13.0`.", 1);
        GitHub {
            repo: repo.to_owned(),
            head: head.to_owned(),
            live: pull.clone(),
            pull,
            files: vec![json!([file(".agents/skills/orch/SKILL.md")])],
            checks: json!({"total_count": 1, "check_runs": [check_run(72, head)]}),
            jobs: vec![job(72, 20, head, repo)],
            runs: vec![run(20, head, base_tip, repo)],
            logs: vec![(72, Some(producer_log(measured, head)))],
        }
    }

    fn log(&mut self) -> &mut String {
        self.logs[0].1.as_mut().unwrap()
    }

    /// The map the fake `gh` answers from.
    fn map(&self) -> Value {
        let repo = &self.repo;
        let mut map = json!({
            format!("repos/{repo}/pulls/42#1"): {"body": self.pull},
            format!("repos/{repo}/pulls/42#2"): {"body": self.live},
            format!("repos/{repo}/commits/{}/check-runs?check_name=Classify%20the%20diff&filter=latest&per_page=100&page=1", self.head):
                {"body": self.checks},
        });
        for (n, page) in self.files.iter().enumerate() {
            map[format!("repos/{repo}/pulls/42/files?per_page=100&page={}", n + 1)] =
                json!({"body": page});
        }
        // Each job is read by its check's id and each run by its job's run
        // id, whatever the object read answers.
        let checks = self.checks["check_runs"].as_array().unwrap();
        for (check, job) in checks.iter().zip(&self.jobs) {
            map[format!("repos/{repo}/actions/jobs/{}", check["id"])] = json!({"body": job});
        }
        for (job, run) in self.jobs.iter().zip(&self.runs) {
            map[format!("repos/{repo}/actions/runs/{}", job["run_id"])] = json!({"body": run});
        }
        for (id, log) in &self.logs {
            map[format!("repos/{repo}/actions/jobs/{id}/logs")] = match log {
                Some(text) => json!({"text": text}),
                None => json!({"exit": 1}),
            };
        }
        map
    }
}

/// A case's world: the fake `gh` and a `git` that fails `fetch` where the
/// case asks, before the real one on `PATH`, and the checkout the read runs
/// from with the harness-ci, change-scope and github packages installed in
/// it.
struct World {
    dir: tempfile::TempDir,
    checkout: PathBuf,
}

impl World {
    fn new(checkout: Option<PathBuf>, repo: &Repo, caller: bool, fetch_fails: bool) -> World {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink(fixtures().join("ci-proof-gh"), bin.join("gh")).unwrap();
        let real_git = String::from_utf8(
            program("sh")
                .args(["-c", "command -v git"])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap();
        write_executable(
            &bin.join("git"),
            format!(
                "#!/bin/sh\n[ \"$1\" != fetch ] || [ ! -e '{}' ] || exit 1\nexec '{}' \"$@\"\n",
                dir.path().join("fetch-fails").display(),
                real_git.trim()
            ),
        );
        if fetch_fails {
            std::fs::write(dir.path().join("fetch-fails"), "").unwrap();
        }
        let checkout = checkout.unwrap_or_else(|| repo.path.clone());
        let catalog = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let skills = checkout.join(".agents/skills");
        std::fs::create_dir_all(skills.join("harness-ci/scripts/lib")).unwrap();
        for package in ["change-scope", "github"] {
            let link = skills.join(package);
            if !link.exists() {
                std::os::unix::fs::symlink(catalog.join(package), link).unwrap();
            }
        }
        copy_executable(
            &catalog.join("harness-ci/scripts/harness-only"),
            &skills.join("harness-ci/scripts/harness-only"),
        );
        let library = skills.join("harness-ci/scripts/lib/change-class.sh");
        if caller {
            std::fs::copy(
                catalog.join("harness-ci/scripts/lib/change-class.sh"),
                &library,
            )
            .unwrap();
        } else if library.exists() {
            std::fs::remove_file(&library).unwrap();
        }
        World { dir, checkout }
    }

    fn bin(&self) -> PathBuf {
        self.dir.path().join("bin")
    }

    fn plant(&self, github: &GitHub) {
        std::fs::write(self.bin().join("gh.json"), github.map().to_string()).unwrap();
    }

    /// What the checkout holds that no read may move.
    fn held(&self) -> Vec<String> {
        let c = &self.checkout;
        vec![
            git(c, &["rev-parse", "HEAD"]),
            git(c, &["show-ref"]),
            git(c, &["status", "--porcelain"]),
            git(c, &["config", "--local", "--list"]),
            std::fs::read_to_string(c.join(".git/FETCH_HEAD")).unwrap_or_default(),
        ]
    }
}

/// Each case's world, built from the producer's ordinary evidence with the
/// one change the case names, as GitHub would answer it.
fn shape(case: &str, repo: &Repo, github: &mut GitHub) {
    let head = github.head.clone();
    match case {
        "absent" => github.checks = json!({"total_count": 0, "check_runs": []}),
        "head-repository" => github.runs[0]["head_repository"]["full_name"] = json!("other/r"),
        "run-failed" => github.runs[0]["conclusion"] = json!("failure"),
        "run-pending" => github.runs[0]["status"] = json!("in_progress"),
        "job-link" => {
            github.jobs[0]["check_run_url"] =
                json!("https://api.github.com/repos/other/r/check-runs/72");
        }
        "workflow-origin" => github.runs[0]["path"] = json!(".github/workflows/other.yml"),
        "duplicate-class" => github
            .log()
            .push_str("class: class=render measured=true cause=render-proof\n"),
        "single-range" => {
            let (mut bases, mut heads) = (0, 0);
            let kept: Vec<&str> = github.logs[0]
                .1
                .as_deref()
                .unwrap()
                .split_inclusive('\n')
                .filter(|line| {
                    let seen = if line.contains("base-rev:") {
                        bases += 1;
                        bases
                    } else if line.contains("head-rev:") {
                        heads += 1;
                        heads
                    } else {
                        0
                    };
                    seen < 2
                })
                .collect();
            let kept = kept.concat();
            *github.log() = kept;
        }
        "caller" => github.files = vec![json!([file(".github/workflows/kendex-refresh.yml")])],
        "workflow" => github.files = vec![json!([file(".github/workflows/ci.yml")])],
        "renamed-workflow" => {
            let mut renamed = file("elsewhere.yml");
            renamed["previous_filename"] = json!(".github/workflows/ci.yml");
            github.files = vec![json!([renamed])];
        }
        "partial-files" => github.files = vec![json!([])],
        "later-workflow" => {
            let first: Vec<Value> = (0..100)
                .map(|n| file(&format!(".agents/skills/p{n}/SKILL.md")))
                .collect();
            github.files = vec![json!(first), json!([file(".github/workflows/ci.yml")])];
            github.pull["changed_files"] = json!(101);
        }
        "engine" => *github.log() = github.log().replace("version=1.13.0", "version=1.14.0"),
        "body-missing" => github.pull["body"] = json!(""),
        "body-ambiguous" => {
            github.pull["body"] =
                json!("Engine version: `kendex 1.13.0`.\nEngine version: `kendex 1.13.0`.");
        }
        "standard" => *github.log() = github.log().replace("class=render", "class=standard"),
        "off-table" => *github.log() = github.log().replace("class=render", "class=huge"),
        "unmeasured" => *github.log() = github.log().replace("measured=true", "measured=false"),
        "log-failed" => github.logs[0].1 = None,
        "log-empty" => *github.log() = String::new(),
        "pending" => {
            github.checks["check_runs"][0]["status"] = json!("in_progress");
            github.checks["check_runs"][0]["conclusion"] = Value::Null;
        }
        "failed" => github.checks["check_runs"][0]["conclusion"] = json!("failure"),
        "wrong-head" => github.checks["check_runs"][0]["head_sha"] = json!("old"),
        "wrong-app" => github.checks["check_runs"][0]["app"]["slug"] = json!("other-app"),
        "partial-checks" => github.checks["total_count"] = json!(2),
        "job-pending" => {
            github.jobs[0]["status"] = json!("in_progress");
            github.jobs[0]["conclusion"] = Value::Null;
        }
        "job-head" => github.jobs[0]["head_sha"] = json!("old"),
        "caller-origin" => github.runs[0]["path"] = json!(".github/workflows/kendex-refresh.yml"),
        "wrong-run-head" => github.runs[0]["head_sha"] = json!("old"),
        "wrong-run-event" => github.runs[0]["event"] = json!("push"),
        "wrong-run-repo" => github.runs[0]["repository"]["full_name"] = json!("other/r"),
        "wrong-run-id" => github.runs[0]["id"] = json!(30),
        "multiple-green" | "latest-pending" | "latest-failed" | "forged-caller" => {
            github.checks["total_count"] = json!(2);
            let mut later = check_run(74, &head);
            let mut later_job = job(74, 30, &head, &github.repo);
            let mut later_run = github.runs[0].clone();
            later_run["id"] = json!(30);
            match case {
                "latest-pending" => {
                    for value in [&mut later, &mut later_job] {
                        value["status"] = json!("in_progress");
                        value["conclusion"] = Value::Null;
                    }
                }
                "latest-failed" => {
                    later["conclusion"] = json!("failure");
                    later_job["conclusion"] = json!("failure");
                }
                "forged-caller" => {
                    github.files = vec![json!([
                        file(".github/workflows/kendex-refresh.yml"),
                        file("src/product.ts")
                    ])];
                    github.pull["changed_files"] = json!(2);
                    later_run["path"] = json!(".github/workflows/kendex-refresh.yml");
                    *github.log() = github.log().replace("class=render", "class=standard");
                }
                _ => {}
            }
            let log = github.logs[0].1.clone();
            github.checks["check_runs"]
                .as_array_mut()
                .unwrap()
                .push(later);
            github.jobs.push(later_job);
            github.runs.push(later_run);
            github.logs.push((74, log));
        }
        "different-pr" => github.runs[0]["pull_requests"][0]["number"] = json!(43),
        "link-head" => github.runs[0]["pull_requests"][0]["head"]["sha"] = json!("old"),
        "empty-links" => github.runs[0]["pull_requests"] = json!([]),
        "missing-links" => {
            github.runs[0]
                .as_object_mut()
                .unwrap()
                .remove("pull_requests");
        }
        "different-range" => {
            *github.log() = github.log().replace(
                &format!("base-rev: {}", repo.measured),
                &format!("base-rev: {}", repo.earlier),
            );
        }
        "measured-head" => {
            *github.log() = github.log().replace(
                &format!("head-rev: {head}"),
                &format!("head-rev: {}", repo.earlier),
            );
        }
        "range-missing" => {
            let kept: String = github
                .log()
                .split_inclusive('\n')
                .filter(|line| !line.contains("base-rev:"))
                .collect();
            *github.log() = kept;
        }
        "conflicting-base" | "conflicting-head" => {
            let (field, original) = if case == "conflicting-base" {
                ("base-rev: ", repo.measured.clone())
            } else {
                ("head-rev: ", head.clone())
            };
            let from = format!("{field}{original}");
            let at = github.log().find(&from).unwrap();
            let to = format!("{field}{}", repo.earlier);
            github.log().replace_range(at..at + from.len(), &to);
        }
        "stale-head" => github.pull["head"]["sha"] = json!(repo.earlier),
        "body-carriage" => github.pull["body"] = json!("Engine version: kendex 1.13.0.\r"),
        "unnamed-base" => github.pull["base"]["ref"] = json!(""),
        "retargeted" => {
            github.pull["base"] = json!({"sha": repo.earlier, "ref": "earlier"});
            github.runs[0]["pull_requests"][0]["base"]["sha"] = json!(repo.earlier);
        }
        _ => {}
    }
    github.live = github.pull.clone();
    match case {
        "moved" => github.live["head"]["sha"] = json!(repo.earlier),
        "base-moved" => github.live["base"]["sha"] = json!(repo.earlier),
        "ref-moved" => github.live["base"]["ref"] = json!("other"),
        "body-updated" => github.live["body"] = json!("Engine version: `kendex 1.14.0`."),
        "live-body-missing" => github.live["body"] = json!(""),
        "live-body-ambiguous" => {
            github.live["body"] =
                json!("Engine version: `kendex 1.13.0`.\nEngine version: `kendex 1.13.0`.");
        }
        "live-body-equivalent" => {
            github.live["body"] =
                json!("Engine version: kendex 1.13.0.\r\nUpdated by scheduled refresh.\r\n");
        }
        _ => {}
    }
}

/// The merged class `merge`'s merge-group run measured, read from
/// kendex's producer alone, from a checkout holding both ends of the
/// range: the measured class with its cause and evidence, or the one
/// cause the evidence fails by; no read moves the checkout.
#[test]
fn the_merged_class_is_read_from_trusted_merge_group_evidence_alone() {
    if !isolated_row("the_merged_class_is_read_from_trusted_merge_group_evidence_alone") {
        return;
    }
    let repo = Repo::new();
    for (case, expected) in [
        ("render", Ok("render")),
        ("absent", Err("ci-proof-missing")),
        ("log-failed", Err("ci-proof-missing")),
        ("unmeasured", Err("class-unmeasured")),
        ("log-empty", Err("ci-proof-missing")),
        ("standard", Ok("standard")),
        ("action.yml", Err("origin-untrusted")),
        ("classify", Err("origin-untrusted")),
        ("workflow-origin", Err("ci-proof-missing")),
        ("head-repository", Err("ci-proof-missing")),
        ("wrong-run-repo", Err("ci-proof-missing")),
        ("wrong-head", Err("ci-proof-missing")),
        ("job-head", Err("ci-proof-missing")),
        ("wrong-run-head", Err("ci-proof-missing")),
        ("job-link", Err("ci-proof-missing")),
        ("run-pending", Err("ci-proof-missing")),
        ("run-failed", Err("ci-proof-missing")),
        ("wrong-run-event", Err("ci-proof-missing")),
        ("different-range", Err("ci-proof-missing")),
        ("measured-head", Err("ci-proof-missing")),
        ("conflicting-base", Err("ci-proof-missing")),
        ("conflicting-head", Err("ci-proof-missing")),
        ("duplicate-class", Err("class-unmeasured")),
        // Only kendex's own merge-group producer is supported.
        ("other-repository", Err("origin-untrusted")),
        ("off-table", Err("class-unmeasured")),
    ] {
        // A producer file altered on the range: the head is that branch's,
        // whose parent is the render head, as its log names it.
        let (merge, base) = match case {
            "action.yml" | "classify" => (
                git(
                    &repo.path,
                    &["rev-parse", &format!("refs/heads/alter-{case}")],
                ),
                repo.head.clone(),
            ),
            _ => (repo.head.clone(), repo.measured.clone()),
        };
        let mut github = GitHub::new(KENDEX, &merge, &repo.base_tip, &base);
        github.runs[0]["event"] = json!("merge_group");
        github.runs[0]["path"] = json!(".github/workflows/skill-tests.yml");
        shape(case, &repo, &mut github);
        let world = World::new(None, &repo, true, false);
        world.plant(&github);
        std::fs::write(repo.path.join(".git/FETCH_HEAD"), "held fetch record\n").unwrap();
        let held = world.held();
        let parent = git(&repo.path, &["rev-parse", &format!("{merge}^1")]);
        let named = if case == "other-repository" {
            "o/r"
        } else {
            KENDEX
        };
        let read =
            ci_proof::merged_class(&world.bin().join("gh"), &repo.path, &parent, &merge, named);
        assert_eq!(
            read.as_ref()
                .map(|m| m.class.as_str())
                .map_err(|r| r.cause()),
            expected,
            "{case}"
        );
        if let Ok(measured) = read {
            assert_eq!(
                (measured.cause.as_str(), measured.evidence.as_str()),
                ("render-proof", "render-proof"),
                "{case}"
            );
        }
        assert_eq!(world.held(), held, "{case}: the checkout stands as it was");
    }
}

/// The verb's answer for one case: its status, stdout and stderr.
fn prove(world: &World, head: &str) -> (Option<i32>, String, String) {
    let out = isolated()
        .args(["ci-proof", "42", head, "--repo", "o/r"])
        .current_dir(&world.checkout)
        .env("PATH", tool_path(&[&world.bin()]))
        .output()
        .unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// The render proof of a consumer refresh pull request, read from its own
/// consumer run alone: the latest trusted check on the head and its job
/// completed with success, the run linking the pull request and the head,
/// the log's one measured render and verifier version against the body's
/// engine, read before and after, its range the pull request's merge-base
/// range, no workflow changed but the refresh caller. Every other kind of
/// evidence is its one cause on stderr at exit 1 with nothing on stdout; no
/// read moves the checkout, its refs, files, configuration or `FETCH_HEAD`,
/// and a head or base the checkout lacks is fetched as objects alone; the
/// log's control bytes reach neither stream.
#[test]
fn a_refresh_proof_is_read_from_the_consumer_pull_requests_own_run_alone() {
    let repo = Repo::new();
    for (case, expected) in [
        ("render", Ok(72)),
        ("single-range", Ok(72)),
        ("remote-head", Ok(72)),
        ("remote-base", Ok(72)),
        ("fetch-failed", Err("ci-proof-missing")),
        ("fetch-status", Err("ci-proof-missing")),
        ("caller", Ok(72)),
        ("workflow", Err("workflow-changed")),
        ("renamed-workflow", Err("workflow-changed")),
        ("later-workflow", Err("workflow-changed")),
        ("partial-files", Err("ci-proof-missing")),
        ("engine", Err("engine-mismatch")),
        ("body-missing", Err("engine-mismatch")),
        ("body-ambiguous", Err("engine-mismatch")),
        ("body-updated", Err("engine-mismatch")),
        ("live-body-missing", Err("engine-mismatch")),
        ("live-body-ambiguous", Err("engine-mismatch")),
        ("live-body-equivalent", Ok(72)),
        // A declaration whose line ends in a carriage return alone.
        ("body-carriage", Ok(72)),
        // A base that names no branch.
        ("unnamed-base", Err("ci-proof-missing")),
        ("standard", Err("class-not-render")),
        ("unmeasured", Err("class-not-render")),
        ("log-failed", Err("ci-proof-missing")),
        ("log-empty", Err("class-not-render")),
        ("pending", Err("ci-proof-missing")),
        ("failed", Err("ci-proof-missing")),
        ("wrong-head", Err("ci-proof-missing")),
        ("wrong-app", Err("ci-proof-missing")),
        ("partial-checks", Err("ci-proof-missing")),
        ("job-pending", Err("ci-proof-missing")),
        ("job-head", Err("ci-proof-missing")),
        ("caller-origin", Err("ci-proof-missing")),
        ("wrong-run-head", Err("ci-proof-missing")),
        ("wrong-run-event", Err("ci-proof-missing")),
        ("wrong-run-repo", Err("ci-proof-missing")),
        ("wrong-run-id", Err("ci-proof-missing")),
        ("multiple-green", Ok(74)),
        ("latest-pending", Err("ci-proof-missing")),
        ("latest-failed", Err("ci-proof-missing")),
        ("forged-caller", Err("class-not-render")),
        ("different-pr", Err("ci-proof-missing")),
        ("link-head", Err("ci-proof-missing")),
        ("empty-links", Err("ci-proof-missing")),
        ("missing-links", Err("ci-proof-missing")),
        ("different-range", Err("ci-proof-missing")),
        ("measured-head", Err("ci-proof-missing")),
        ("range-missing", Err("ci-proof-missing")),
        ("conflicting-base", Err("ci-proof-missing")),
        ("conflicting-head", Err("ci-proof-missing")),
        ("retargeted", Err("ci-proof-missing")),
        // The pull request's head is no longer the one asked for.
        ("stale-head", Err("ci-proof-missing")),
        ("moved", Err("ci-proof-missing")),
        ("base-moved", Err("ci-proof-missing")),
        ("ref-moved", Err("ci-proof-missing")),
        ("missing-caller", Err("ci-proof-missing")),
    ] {
        let scratch = tempfile::tempdir().unwrap();
        // A base checkout that has not fetched the refresh head (and, for
        // remote-base, not the advanced base either).
        let checkout = match case {
            "remote-head" | "remote-base" | "fetch-failed" => {
                let branch = if case == "remote-base" {
                    "old-base"
                } else {
                    "base"
                };
                let clone = scratch.path().join("base-checkout");
                let out = program("git")
                    .args([
                        "clone",
                        "-q",
                        "--no-local",
                        "--single-branch",
                        "--branch",
                        branch,
                    ])
                    .arg(&repo.path)
                    .arg(&clone)
                    .output()
                    .unwrap();
                assert!(out.status.success(), "{}", stderr(&out));
                for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
                    git(&clone, &["config", key, value]);
                }
                if case == "fetch-failed" {
                    let absent = scratch.path().join("absent-remote").display().to_string();
                    git(&clone, &["remote", "set-url", "origin", &absent]);
                }
                Some(clone)
            }
            _ => None,
        };
        let world = World::new(
            checkout,
            &repo,
            case != "missing-caller",
            case == "fetch-status",
        );
        let mut github = GitHub::new("o/r", &repo.head, &repo.base_tip, &repo.measured);
        shape(case, &repo, &mut github);
        world.plant(&github);
        let fetches = matches!(case, "remote-head" | "remote-base");
        if fetches {
            assert!(
                !holds(&world.checkout, &repo.head),
                "{case} begins without the head"
            );
            assert_eq!(
                holds(&world.checkout, &repo.base_tip),
                case == "remote-head",
                "{case} begins with the base it names"
            );
        }
        std::fs::write(
            world.checkout.join(".git/FETCH_HEAD"),
            "held fetch record\n",
        )
        .unwrap();
        let held = world.held();
        let (code, out, err) = prove(&world, &repo.head);
        match expected {
            Ok(job) => assert_eq!(
                (code, out.as_str()),
                (
                    Some(0),
                    format!(
                        "ci-proof: head={} class=render measured=true version=1.13.0 job={job}\n",
                        repo.head
                    )
                    .as_str()
                ),
                "{case}: {err}"
            ),
            Err(cause) => assert_eq!(
                (code, out.as_str(), err.as_str()),
                (Some(1), "", format!("ci-proof: cause={cause}\n").as_str()),
                "{case}"
            ),
        }
        if fetches {
            for revision in [&repo.base_tip, &repo.head] {
                assert!(
                    holds(&world.checkout, revision),
                    "{case} fetches {revision}"
                );
            }
        }
        assert_eq!(world.held(), held, "{case}: the checkout stands as it was");
        assert!(
            !out.contains('\u{1b}') && !err.contains('\u{1b}'),
            "{case}: the log's control bytes stay in the reader"
        );
    }
}

/// A repository GitHub never issues names no proof: the verb refuses
/// `ci-proof-missing` at exit 1 before any read, for a login holding an
/// underscore and a name of dots alone.
#[test]
fn a_repository_github_never_issues_is_refused_before_any_read() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("gh.log");
    std::fs::write(dir.path().join("gh.json"), "{}").unwrap();
    // The packages the proof reads before GitHub, installed as a world's
    // are, so a repository the check let through would reach gh.
    let catalog = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let skills = dir.path().join(".agents/skills");
    std::fs::create_dir_all(skills.join("harness-ci/scripts/lib")).unwrap();
    for package in ["change-scope", "github"] {
        std::os::unix::fs::symlink(catalog.join(package), skills.join(package)).unwrap();
    }
    for file in ["scripts/harness-only", "scripts/lib/change-class.sh"] {
        copy_executable(
            &catalog.join("harness-ci").join(file),
            &skills.join("harness-ci").join(file),
        );
    }
    let head = "0".repeat(40);
    for repo in ["own_er/r", "o/.."] {
        let out = isolated()
            .args(["ci-proof", "42", &head, "--repo", repo])
            .current_dir(dir.path())
            .env("PATH", tool_path(&[&fixtures().join("gh")]))
            .env("GH_FAKE_LOG", &log)
            .env("GH_FAKE_REPLIES", dir.path().join("gh.json"))
            .output()
            .unwrap();
        assert_eq!(
            (out.status.code(), stderr(&out)),
            (Some(1), "ci-proof: cause=ci-proof-missing\n".to_owned()),
            "{repo}"
        );
        assert!(!log.exists(), "{repo}: gh was asked");
    }
}
