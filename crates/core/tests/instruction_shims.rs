//! The shims that make a project's `AGENTS.md` files reachable: a
//! `CLAUDE.md` importing each tracked one for Claude Code, and Gemini's
//! settings naming `AGENTS.md`. Planned like any other scope write, bound
//! to what the plan read, and never over bytes kendex did not write.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply::{self, Op};
use kendex_core::engine::{
    CLAUDE_SHIM, DriftState, EngineReport, PlanOptions, ShimState, audit,
    observe_instruction_shims, plan_apply,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

/// A project declaring the given harnesses and nothing else, with a root
/// `AGENTS.md`. `git` says whether it is a repository; a repository has
/// the root file committed.
#[allow(clippy::unwrap_used)]
fn fixture(harnesses: &str, git: bool) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!("schema = 6\n\n[install]\nharnesses = [{harnesses}]\n"),
    )
    .unwrap();
    fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
    if git {
        // The lock already ignored, so the git posture has nothing to add
        // and every op in a plan here is a shim's.
        fs::write(project.join(".gitignore"), "/.kendex-lock.json\n").unwrap();
        run_git(&project, &["init", "-q", "-b", "main"]);
        commit(&project);
    }
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

/// git in a fixture: the hardened constructor clears every redirecting
/// variable, and a HOME of its own keeps the real global config out.
#[allow(clippy::unwrap_used)]
fn run_git(dir: &Path, args: &[&str]) {
    let home = dir.to_str().unwrap();
    let out = Hardened::git(args, Some(dir))
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn commit(dir: &Path) {
    run_git(dir, &["add", "-A"]);
    run_git(dir, &["commit", "-q", "--allow-empty", "-m", "files"]);
}

#[allow(clippy::unwrap_used)]
fn plan(f: &Fixture) -> EngineReport {
    audit(&f.env, &f.scope).unwrap()
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) -> EngineReport {
    let report = plan(f);
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

#[allow(clippy::unwrap_used)]
fn take_over(f: &Fixture) -> EngineReport {
    let options = PlanOptions {
        replace_unmanaged: true,
        ..PlanOptions::default()
    };
    plan_apply(&f.env, &f.scope, &options).unwrap()
}

/// The paths every op in the plan touches, relative to the project.
fn touched(f: &Fixture, report: &EngineReport) -> Vec<String> {
    report
        .plan
        .ops
        .iter()
        .flat_map(|planned| match &planned.op {
            Op::WriteFile { path, .. } | Op::Trash { path, .. } | Op::EditFile { path, .. } => {
                vec![path.clone()]
            }
            _ => Vec::new(),
        })
        .map(|path| {
            path.strip_prefix(&f.project)
                .map(|rel| rel.display().to_string())
                .unwrap_or_else(|_| path.display().to_string())
        })
        .collect()
}

#[allow(clippy::unwrap_used)]
fn standings(f: &Fixture, harnesses: &[HarnessId]) -> Vec<(String, ShimState)> {
    observe_instruction_shims(&f.env, &f.scope, harnesses)
        .unwrap()
        .into_iter()
        .map(|shim| (shim.name, shim.state))
        .collect()
}

#[allow(clippy::unwrap_used)]
fn shim_bytes(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_root_shim_is_written_once_and_verifies_clean_after() {
    let f = fixture("\"claude\"", true);
    let report = plan(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md"]);
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "CLAUDE.md" && row.state == DriftState::Missing),
        "{:?}",
        report.drift
    );
    let line = report.plan.ops[0].line();
    assert!(
        line.contains("CLAUDE.md") && line.contains("@AGENTS.md"),
        "{line}"
    );

    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(shim_bytes(&f.project.join("CLAUDE.md")), CLAUDE_SHIM);

    let again = plan(&f);
    assert!(again.plan.is_empty(), "{:?}", touched(&f, &again));
    assert!(again.drift.is_empty(), "{:?}", again.drift);
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [("CLAUDE.md".to_owned(), ShimState::InSync)]
    );
    assert!(again.instruction_shims.iter().all(|shim| !shim.failing()));
}

#[test]
fn a_nested_tracked_agents_file_gets_its_own_shim() {
    let f = fixture("\"claude\"", true);
    let nested = f.project.join("crates/core");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("AGENTS.md"), "# core\n").unwrap();
    commit(&f.project);

    let report = apply_now(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md", "crates/core/CLAUDE.md"]);
    assert_eq!(shim_bytes(&nested.join("CLAUDE.md")), CLAUDE_SHIM);
    assert!(plan(&f).plan.is_empty());
}

/// A directory git does not track is never walked: the nested file is
/// ignored, and only the root one is served.
#[test]
fn an_untracked_nested_agents_file_is_ignored() {
    let f = fixture("\"claude\"", true);
    let nested = f.project.join("ui");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("AGENTS.md"), "# ui\n").unwrap();

    let report = plan(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md"]);
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [("CLAUDE.md".to_owned(), ShimState::Missing)]
    );
}

/// Outside a repository nothing can be tracked, so the root file alone is
/// considered — and only where it is a regular file.
#[test]
fn a_project_outside_any_repository_serves_its_root_file_only() {
    let f = fixture("\"claude\"", false);
    let nested = f.project.join("ui");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("AGENTS.md"), "# ui\n").unwrap();

    let report = apply_now(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md"]);
    assert!(!nested.join("CLAUDE.md").exists());

    fs::remove_file(f.project.join("AGENTS.md")).unwrap();
    std::os::unix::fs::symlink("ui/AGENTS.md", f.project.join("AGENTS.md")).unwrap();
    assert_eq!(standings(&f, &[HarnessId::Claude]), []);
}

/// Other bytes at the shim's position are the person's: a conflict naming
/// both exits, no write, and the take-over trashes them bound to the
/// bytes the plan read before the shim lands.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_claude_file_is_a_conflict_the_take_over_settles() {
    let f = fixture("\"claude\"", true);
    let shim = f.project.join("CLAUDE.md");
    fs::write(&shim, "# hand-written\n").unwrap();

    let report = plan(&f);
    assert!(report.plan.is_empty(), "{:?}", touched(&f, &report));
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "CLAUDE.md")
        .unwrap();
    assert_eq!(row.state, DriftState::Conflict);
    assert_eq!(row.kind, ItemKind::Skill);
    assert_eq!(row.harness, HarnessId::Claude);
    assert!(
        row.detail.contains("not the shim")
            && row.detail.contains("move its content into AGENTS.md")
            && row.detail.contains("--replace-unmanaged"),
        "{}",
        row.detail
    );
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [("CLAUDE.md".to_owned(), ShimState::Foreign)]
    );

    let taken = take_over(&f);
    assert_eq!(touched(&f, &taken), ["CLAUDE.md", "CLAUDE.md"]);
    assert!(matches!(taken.plan.ops[0].op, Op::Trash { .. }));
    let row = taken
        .drift
        .iter()
        .find(|row| row.name == "CLAUDE.md")
        .unwrap();
    assert_eq!(row.state, DriftState::Missing);

    // The bytes moved between plan and apply: the trash binds to what the
    // plan read, so the apply refuses rather than trashing an edit nobody
    // looked at (invariant 7).
    fs::write(&shim, "# edited since\n").unwrap();
    assert!(apply::execute(&f.env, &taken.plan).is_err());
    assert_eq!(shim_bytes(&shim), "# edited since\n");

    let taken = take_over(&f);
    apply::execute(&f.env, &taken.plan).unwrap();
    assert_eq!(shim_bytes(&shim), CLAUDE_SHIM);
    let trashed: Vec<PathBuf> = fs::read_dir(f.env.trash_dir())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(trashed.len(), 1, "{trashed:?}");
    assert_eq!(shim_bytes(&trashed[0]), "# edited since\n");
}

/// A link at the shim's position is never a clobber target, take-over or
/// not (invariant 6).
#[test]
fn a_symlinked_shim_is_a_conflict_the_take_over_leaves_alone() {
    let f = fixture("\"claude\"", true);
    let shim = f.project.join("CLAUDE.md");
    std::os::unix::fs::symlink("AGENTS.md", &shim).unwrap();

    for report in [plan(&f), take_over(&f)] {
        assert!(report.plan.is_empty(), "{:?}", touched(&f, &report));
        let row = report
            .drift
            .iter()
            .find(|row| row.name == "CLAUDE.md")
            .unwrap();
        assert_eq!(row.state, DriftState::Conflict);
        assert!(row.detail.contains("is a link"), "{}", row.detail);
    }
    assert!(shim.is_symlink());
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [("CLAUDE.md".to_owned(), ShimState::Symlinked)]
    );
}

/// The old convention is retired by the plan that writes the root shim;
/// any other `.claude/CLAUDE.md` is the person's and goes unmentioned.
#[test]
#[allow(clippy::unwrap_used)]
fn the_old_claude_link_is_retired_and_any_other_file_there_is_left_alone() {
    let f = fixture("\"claude\"", true);
    let claude = f.project.join(".claude");
    fs::create_dir_all(&claude).unwrap();
    let old = claude.join("CLAUDE.md");
    std::os::unix::fs::symlink("../AGENTS.md", &old).unwrap();

    let report = plan(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md", ".claude/CLAUDE.md"]);
    assert!(matches!(report.plan.ops[1].op, Op::Trash { .. }));
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [
            ("CLAUDE.md".to_owned(), ShimState::Missing),
            (".claude/CLAUDE.md".to_owned(), ShimState::OldLink)
        ]
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!old.exists() && !old.is_symlink());
    assert_eq!(shim_bytes(&f.project.join("CLAUDE.md")), CLAUDE_SHIM);
    assert!(f.project.join("AGENTS.md").is_file());

    // A plain file there, and a link elsewhere: neither is the retired
    // convention, so neither is planned nor reported.
    fs::write(&old, "# my own\n").unwrap();
    let report = plan(&f);
    assert!(report.plan.is_empty() && report.drift.is_empty());
    assert_eq!(
        standings(&f, &[HarnessId::Claude]),
        [("CLAUDE.md".to_owned(), ShimState::InSync)]
    );
    fs::remove_file(&old).unwrap();
    fs::write(claude.join("OTHER.md"), "# other\n").unwrap();
    std::os::unix::fs::symlink("OTHER.md", &old).unwrap();
    let report = plan(&f);
    assert!(report.plan.is_empty() && report.drift.is_empty());
    assert!(old.is_symlink());
}

/// A root shim the plan cannot settle keeps the old link: Claude Code
/// goes on reading the root file one way while the conflict stands.
#[test]
fn the_old_link_stays_while_the_root_shim_is_a_conflict() {
    let f = fixture("\"claude\"", true);
    fs::create_dir_all(f.project.join(".claude")).unwrap();
    let old = f.project.join(".claude/CLAUDE.md");
    std::os::unix::fs::symlink("../AGENTS.md", &old).unwrap();
    fs::write(f.project.join("CLAUDE.md"), "# hand-written\n").unwrap();

    let report = plan(&f);
    assert!(report.plan.is_empty(), "{:?}", touched(&f, &report));
    let taken = take_over(&f);
    assert_eq!(
        touched(&f, &taken),
        ["CLAUDE.md", "CLAUDE.md", ".claude/CLAUDE.md"]
    );
}

#[allow(clippy::unwrap_used)]
fn gemini_settings(f: &Fixture) -> serde_json::Value {
    serde_json::from_str(&shim_bytes(&f.project.join(".gemini/settings.json"))).unwrap()
}

#[test]
fn gemini_settings_are_created_naming_geminis_own_file_first() {
    let f = fixture("\"gemini\"", true);
    let report = apply_now(&f);
    assert_eq!(touched(&f, &report), [".gemini/settings.json"]);
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == ".gemini/settings.json"
                && row.harness == HarnessId::Gemini
                && row.state == DriftState::Missing),
        "{:?}",
        report.drift
    );
    assert_eq!(
        gemini_settings(&f)["context"]["fileName"],
        serde_json::json!(["GEMINI.md", "AGENTS.md"])
    );
    assert!(plan(&f).plan.is_empty());
    assert_eq!(
        standings(&f, &[HarnessId::Gemini]),
        [(".gemini/settings.json".to_owned(), ShimState::InSync)]
    );
}

/// A string becomes a two-element list keeping the string first; a list
/// lacking the name is appended to; one carrying it is in sync. Every
/// unrelated key survives byte for byte outside the edited one.
#[test]
#[allow(clippy::unwrap_used)]
fn gemini_settings_are_edited_around_what_they_already_hold() {
    let f = fixture("\"gemini\"", true);
    let settings = f.project.join(".gemini/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();

    fs::write(
        &settings,
        "{\n  \"theme\": \"Dark\",\n  \"context\": {\n    \"fileName\": \"TEAM.md\"\n  },\n  \"mcpServers\": {\n    \"gh\": {\n      \"command\": \"gh-mcp\"\n    }\n  }\n}\n",
    )
    .unwrap();
    let report = plan(&f);
    let row = report
        .drift
        .iter()
        .find(|row| row.name == ".gemini/settings.json")
        .unwrap();
    assert_eq!(row.state, DriftState::Stale);
    apply::execute(&f.env, &report.plan).unwrap();
    let text = shim_bytes(&settings);
    assert_eq!(
        text,
        "{\n  \"theme\": \"Dark\",\n  \"context\": {\n    \"fileName\": [\n      \"TEAM.md\",\n      \"AGENTS.md\"\n    ]\n  },\n  \"mcpServers\": {\n    \"gh\": {\n      \"command\": \"gh-mcp\"\n    }\n  }\n}\n"
    );
    assert!(plan(&f).plan.is_empty());

    fs::write(
        &settings,
        "{\n  \"context\": {\n    \"fileName\": [\n      \"GEMINI.md\"\n    ]\n  }\n}\n",
    )
    .unwrap();
    apply_now(&f);
    assert_eq!(
        gemini_settings(&f)["context"]["fileName"],
        serde_json::json!(["GEMINI.md", "AGENTS.md"])
    );

    fs::write(
        &settings,
        "{\n  \"context\": {\n    \"fileName\": [\n      \"AGENTS.md\",\n      \"GEMINI.md\"\n    ]\n  }\n}\n",
    )
    .unwrap();
    let report = plan(&f);
    assert!(report.plan.is_empty() && report.drift.is_empty());
}

/// A settings file kendex cannot parse is refused, never rewritten.
#[test]
#[allow(clippy::unwrap_used)]
fn unparseable_gemini_settings_are_refused_not_rewritten() {
    let f = fixture("\"gemini\"", true);
    let settings = f.project.join(".gemini/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "{ \"context\": { \"fileName\": ").unwrap();

    let report = apply_now(&f);
    assert!(report.plan.is_empty(), "{:?}", touched(&f, &report));
    let row = report
        .drift
        .iter()
        .find(|row| row.name == ".gemini/settings.json")
        .unwrap();
    assert_eq!(row.state, DriftState::Conflict);
    assert!(row.detail.contains("could not be edited"), "{}", row.detail);
    assert_eq!(shim_bytes(&settings), "{ \"context\": { \"fileName\": ");
    assert!(matches!(
        standings(&f, &[HarnessId::Gemini])[0].1,
        ShimState::Refused(_)
    ));
}

/// Both shims ride on the harness list: a project declaring neither owes
/// nothing, and one declaring both owes both.
#[test]
fn shims_follow_the_declared_harnesses() {
    let f = fixture("\"codex\"", true);
    let report = plan(&f);
    assert!(report.plan.is_empty() && report.drift.is_empty());
    assert!(report.instruction_shims.is_empty());
    assert_eq!(standings(&f, &[HarnessId::Codex]), []);

    let both = fixture("\"claude\", \"gemini\"", true);
    let report = apply_now(&both);
    assert_eq!(
        touched(&both, &report),
        ["CLAUDE.md", ".gemini/settings.json"]
    );
    assert_eq!(shim_bytes(&both.project.join("CLAUDE.md")), CLAUDE_SHIM);
    assert!(plan(&both).plan.is_empty());
}
