//! The shims that make a project's `AGENTS.md` files reachable: a
//! `CLAUDE.md` importing each tracked one for Claude Code, and Gemini's
//! settings naming `AGENTS.md`. Planned like any other scope write, bound
//! to what the plan read, and never over bytes kendex did not write.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply::{self, Op};
use kendex_core::engine::{
    CLAUDE_SHIM, DriftState, EngineReport, PlanOptions, ShimState, audit,
    observe_instruction_shims, plan_apply,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
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
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Project {
        root: project.clone(),
    };
    if git {
        // Settle project housekeeping before the shim fixture is written.
        fs::write(
            project.join("kendex.toml"),
            "schema = 6\n[install]\nharnesses = []\n",
        )
        .unwrap();
        run_git(&project, &["init", "-q", "-b", "main"]);
        let report = audit(&env, &scope).unwrap();
        apply::execute(&env, &report.plan).unwrap();
    }
    fs::write(
        project.join("kendex.toml"),
        format!("schema = 6\n\n[install]\nharnesses = [{harnesses}]\n"),
    )
    .unwrap();
    fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
    if git {
        commit(&project);
    }
    Fixture {
        env,
        scope,
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
        .filter(|path| {
            path.file_name()
                .is_none_or(|name| name != ".kendex-generated.json")
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

/// A render tree is a harness's, and an `AGENTS.md` inside a rendered
/// skill is that skill's content: tracked or not, it gets no shim.
#[test]
fn an_agents_file_inside_a_render_tree_gets_no_shim() {
    let f = fixture("\"claude\"", true);
    let rendered = f.project.join(".agents/skills/vendored");
    fs::create_dir_all(&rendered).unwrap();
    fs::write(rendered.join("AGENTS.md"), "# a skill's own file\n").unwrap();
    commit(&f.project);

    let report = apply_now(&f);
    assert_eq!(touched(&f, &report), ["CLAUDE.md"]);
    assert!(!rendered.join("CLAUDE.md").exists());
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
    let error = apply::execute(&f.env, &taken.plan).unwrap_err();
    assert!(
        matches!(&error, CoreError::RolledBack { cause, .. }
            if matches!(**cause, CoreError::PlanStale { .. })),
        "{error:?}"
    );
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
    // convention, so neither is planned nor reported. The link was all
    // `.claude` held, so its folder went with it.
    assert!(!old.parent().unwrap().exists());
    fs::create_dir_all(old.parent().unwrap()).unwrap();
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

/// A settings file kendex cannot parse is refused, never rewritten: where
/// Gemini is declared and the shim would be written, and where kendex
/// wrote the shim and Gemini has since left the list, so the shim would be
/// taken back.
#[test]
#[allow(clippy::unwrap_used)]
fn unparseable_gemini_settings_are_refused_not_rewritten() {
    for (harnesses, declared) in [("\"gemini\"", true), ("\"codex\"", false)] {
        let f = fixture("\"gemini\"", true);
        if !declared {
            apply_now(&f);
            commit(&f.project);
            fs::write(
                f.project.join("kendex.toml"),
                format!("schema = 6\n\n[install]\nharnesses = [{harnesses}]\n"),
            )
            .unwrap();
        }
        let settings = f.project.join(".gemini/settings.json");
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, "{ \"context\": { \"fileName\": ").unwrap();

        let report = apply_now(&f);
        let touched = touched(&f, &report);
        assert!(touched.is_empty(), "{harnesses}: {touched:?}");
        let row = report
            .drift
            .iter()
            .find(|row| row.name == ".gemini/settings.json")
            .unwrap_or_else(|| panic!("{harnesses}: no row names the file"));
        assert_eq!(row.state, DriftState::Conflict, "{harnesses}");
        assert!(row.detail.contains("could not be edited"), "{}", row.detail);
        assert_eq!(shim_bytes(&settings), "{ \"context\": { \"fileName\": ");
        if declared {
            assert!(matches!(
                standings(&f, &[HarnessId::Gemini])[0].1,
                ShimState::Refused(_)
            ));
        }
    }
}

/// Claude Code leaving the list takes back the `CLAUDE.md` shim kendex
/// wrote, which its inventory names. A file of the person's at that place
/// stays: `every_retirement_leaves_a_file_holding_the_persons_content`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_claude_shim_goes_with_claude_only_where_kendex_wrote_it() {
    let f = fixture("\"claude\"", true);
    apply_now(&f);
    commit(&f.project);
    fs::write(
        f.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"codex\"]\n",
    )
    .unwrap();
    let report = apply_now(&f);
    assert!(touched(&f, &report).contains(&"CLAUDE.md".to_owned()));
    assert!(!f.project.join("CLAUDE.md").exists());
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "CLAUDE.md")
        .unwrap();
    assert_eq!(row.state, DriftState::Orphaned);
    assert!(plan(&f).plan.is_empty(), "the next pass plans again");
}

/// Gemini off the list: a settings file kendex named `AGENTS.md` in, which
/// its inventory names, and that still names it the way the shim's edit
/// wrote it, loses that entry once and keeps the person's own keys, and no
/// pass after it names the file again. The same value where kendex never
/// installed Gemini, and a file holding only the person's keys, are rows of
/// `every_retirement_leaves_a_file_holding_the_persons_content`.
#[test]
#[allow(clippy::unwrap_used)]
fn the_gemini_shim_goes_once_and_a_file_of_the_persons_stays_quiet() {
    let theirs = "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n";
    let f = fixture("\"gemini\"", true);
    let settings = f.project.join(".gemini/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, theirs).unwrap();
    commit(&f.project);
    apply_now(&f);
    commit(&f.project);
    assert!(shim_bytes(&settings).contains("AGENTS.md"));
    fs::write(
        f.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"codex\"]\n",
    )
    .unwrap();

    let report = apply_now(&f);
    let named = |report: &EngineReport| {
        report
            .drift
            .iter()
            .filter(|row| row.name == ".gemini/settings.json")
            .map(|row| row.state)
            .collect::<Vec<_>>()
    };
    assert!(touched(&f, &report).contains(&".gemini/settings.json".to_owned()));
    assert_eq!(named(&report), vec![DriftState::Orphaned]);
    let left: serde_json::Value = serde_json::from_str(&shim_bytes(&settings)).unwrap();
    let wanted: serde_json::Value = serde_json::from_str(theirs).unwrap();
    assert_eq!(left, wanted);
    let again = plan(&f);
    assert!(again.plan.is_empty(), "{:?}", touched(&f, &again));
    assert_eq!(named(&again), Vec::new());
}

/// What a retired file holds after the tool leaves.
enum Left {
    /// Exactly the bytes the person left there.
    Bytes,
    /// This JSON document: the person's own keys, kendex's entry gone.
    Json(&'static str),
    /// This TOML document: the person's own keys, kendex's table gone.
    Toml(&'static str),
}

/// Every retirement a tool leaving the list makes keeps a file holding the
/// person's content: the `CLAUDE.md` shim, Gemini's context entry, a JSON
/// document and a TOML document a removal would otherwise empty. Each row
/// lets kendex write the file where the row installs for the tool, gives it
/// content of the person's, then drops the tool. The file stays holding
/// that content, no orphaned row names it, and the next pass plans nothing.
/// Three rows are a file of the person's in a project kendex never
/// installed the tool for, two of them holding exactly what the shim would.
///
/// Each guard turns its own row red: the shim's bytes check, the context
/// entry's exact-value check, the inventory check for each shim, and the
/// emptied-document check for each document kind.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: every retirement a dropped tool makes, each row a write, an edit of the person's and a drop of its own"
)]
fn every_retirement_leaves_a_file_holding_the_persons_content() {
    struct Row {
        what: &'static str,
        /// The tools declared first, and after the drop.
        first: &'static str,
        then: &'static str,
        /// The project declares the catalog's `gh` server.
        mcp: bool,
        target: &'static str,
        /// The person's content, from what kendex wrote there (empty where
        /// it wrote nothing).
        theirs: fn(&str) -> String,
        left: Left,
    }
    let rows = [
        Row {
            what: "a Claude shim kendex wrote, then the person added to",
            first: "\"claude\"",
            then: "\"codex\"",
            mcp: false,
            target: "CLAUDE.md",
            theirs: |ours| format!("{ours}my own line\n"),
            left: Left::Bytes,
        },
        Row {
            what: "a Claude shim the person wrote where Claude Code was never installed",
            first: "\"codex\"",
            then: "\"codex\"",
            mcp: false,
            target: "CLAUDE.md",
            theirs: |_| CLAUDE_SHIM.to_owned(),
            left: Left::Bytes,
        },
        Row {
            what: "a Gemini context entry the person extended",
            first: "\"gemini\"",
            then: "\"codex\"",
            mcp: false,
            target: ".gemini/settings.json",
            theirs: |_| {
                "{\n  \"context\": {\n    \"fileName\": [\"GEMINI.md\", \"AGENTS.md\", \"NOTES.md\"]\n  }\n}\n"
                    .to_owned()
            },
            left: Left::Bytes,
        },
        Row {
            what: "Gemini settings naming AGENTS.md as the shim does where Gemini was never installed",
            first: "\"codex\"",
            then: "\"codex\"",
            mcp: false,
            target: ".gemini/settings.json",
            theirs: |_| {
                "{\n  \"context\": {\n    \"fileName\": [\"GEMINI.md\", \"AGENTS.md\"]\n  }\n}\n"
                    .to_owned()
            },
            left: Left::Bytes,
        },
        Row {
            what: "Gemini settings holding the person's keys where Gemini was never installed",
            first: "\"codex\"",
            then: "\"codex\"",
            mcp: false,
            target: ".gemini/settings.json",
            theirs: |_| "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n".to_owned(),
            left: Left::Bytes,
        },
        Row {
            what: "a JSON document kendex wrote, then the person added a server to",
            first: "\"claude\"",
            then: "\"codex\"",
            mcp: true,
            target: ".mcp.json",
            theirs: |ours| {
                let mut value: serde_json::Value = serde_json::from_str(ours).unwrap();
                value["mcpServers"]["mine"] = serde_json::json!({"command": "mine"});
                serde_json::to_string_pretty(&value).unwrap()
            },
            left: Left::Json("{\"mcpServers\": {\"mine\": {\"command\": \"mine\"}}}"),
        },
        Row {
            what: "a TOML document kendex wrote, then the person added a key to",
            first: "\"codex\"",
            then: "\"claude\"",
            mcp: true,
            target: ".codex/config.toml",
            theirs: |ours| format!("model = \"o3\"\n{ours}"),
            left: Left::Toml("model = \"o3\"\n"),
        },
    ];
    for row in rows {
        let what = row.what;
        let f = fixture(row.first, true);
        let catalog = f.project.parent().unwrap().join("catalog");
        fs::create_dir_all(catalog.join("mcp")).unwrap();
        fs::write(catalog.join("mcp/gh.toml"), "command = \"gh-mcp\"\n").unwrap();
        fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        let declare = |harnesses: &str| {
            let server = match row.mcp {
                true => "\n[mcp-servers.gh]\nsource = \"cat\"\n",
                false => "",
            };
            fs::write(
                f.project.join("kendex.toml"),
                format!(
                    "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\n{server}",
                    test_util::source_path(&catalog)
                ),
            )
            .unwrap();
        };
        let target = f.project.join(row.target);
        declare(row.first);
        apply_now(&f);
        commit(&f.project);
        let ours = fs::read_to_string(&target).unwrap_or_default();
        let theirs = (row.theirs)(&ours);
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, &theirs).unwrap();
        commit(&f.project);

        // As `apply` plans it: what the dropped tool's copies leave behind
        // is taken away.
        let dropping = || {
            let options = PlanOptions {
                remove_orphans: true,
                ..PlanOptions::default()
            };
            plan_apply(&f.env, &f.scope, &options).unwrap()
        };
        declare(row.then);
        let report = dropping();
        apply::execute(&f.env, &report.plan).unwrap();
        let held = fs::read_to_string(&target)
            .unwrap_or_else(|error| panic!("{what}: {} is gone: {error}", row.target));
        match row.left {
            Left::Bytes => assert_eq!(held, theirs, "{what}"),
            Left::Json(wanted) => assert_eq!(
                serde_json::from_str::<serde_json::Value>(&held).unwrap(),
                serde_json::from_str::<serde_json::Value>(wanted).unwrap(),
                "{what}: {held}"
            ),
            Left::Toml(wanted) => assert_eq!(
                held.parse::<toml::Table>().unwrap(),
                wanted.parse::<toml::Table>().unwrap(),
                "{what}: {held}"
            ),
        }
        let orphaned: Vec<&str> = report
            .drift
            .iter()
            .filter(|one| one.name == row.target && one.state == DriftState::Orphaned)
            .map(|one| one.detail.as_str())
            .collect();
        assert!(orphaned.is_empty(), "{what}: {orphaned:?}");
        let again = dropping();
        assert!(again.plan.is_empty(), "{what}: {:?}", touched(&f, &again));
    }
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

#[test]
#[allow(clippy::unwrap_used)]
fn generated_inventory_tracks_renders_and_excludes_source() {
    let f = fixture("\"claude\", \"gemini\"", true);
    let catalog = f.project.join("catalog");
    fs::create_dir_all(catalog.join("skills/generated")).unwrap();
    fs::write(
        catalog.join("skills/generated/SKILL.md"),
        "---\nname: generated\ndescription: fixture\n---\nBody.\n",
    )
    .unwrap();
    fs::create_dir_all(f.project.join(".agents/skills/authored")).unwrap();
    fs::write(
        f.project.join(".agents/skills/authored/SKILL.md"),
        "---\nname: authored\ndescription: fixture\n---\nSource.\n",
    )
    .unwrap();
    fs::create_dir_all(f.project.join(".pi/packages/example/extensions")).unwrap();
    fs::write(
        f.project.join(".pi/packages/example/extensions/main.ts"),
        "export {};\n",
    )
    .unwrap();
    let manifest_path = f.project.join("kendex.toml");
    let mut manifest = fs::read_to_string(&manifest_path).unwrap();
    manifest.push_str(&format!("\n[sources.catalog]\n{}\n[skills.generated]\nsource = \"catalog\"\n[skills.authored]\nsource = \"in-place\"\n", test_util::source_path(&catalog)));
    fs::write(manifest_path, manifest).unwrap();
    apply_now(&f);
    let read_paths = || -> Vec<String> {
        serde_json::from_str(&fs::read_to_string(f.project.join(".kendex-generated.json")).unwrap())
            .unwrap()
    };
    let paths = read_paths();
    for rendered in [
        ".agents/skills/generated/SKILL.md",
        "CLAUDE.md",
        ".gemini/settings.json",
    ] {
        assert!(
            paths.iter().any(|path| path == rendered),
            "missing {rendered}: {paths:?}"
        );
    }
    assert!(!paths.iter().any(|path| path.contains("authored")
        || path.starts_with("catalog/")
        || path.starts_with(".pi/packages/")));
    fs::write(catalog.join("skills/generated/helper.sh"), "true\n").unwrap();
    apply_now(&f);
    assert!(
        read_paths()
            .iter()
            .any(|path| path == ".agents/skills/generated/helper.sh")
    );
    fs::write(f.project.join("kendex.toml"), "schema = 6\n[install]\nharnesses = [\"codex\"]\n[skills.authored]\nsource = \"in-place\"\n").unwrap();
    apply_now(&f);
    assert_eq!(
        read_paths(),
        vec![
            ".kendex-generated.json".to_owned(),
            ".kendex-lock.json".to_owned()
        ],
        "nothing rendered leaves the two companions"
    );
}

#[test]
fn refused_outputs_stay_out_of_inventory_and_later_ownership() {
    let f = fixture("\"claude\"", true);
    let catalog = f.project.join("catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/work.md"),
        "---\nname: work\ndescription: fixture\n---\nGenerated.\n",
    )
    .unwrap();
    fs::create_dir_all(f.project.join(".claude/agents")).unwrap();
    let occupied = f.project.join(".claude/agents/work.md");
    fs::write(&occupied, "User-written instructions.\n").unwrap();
    let manifest = f.project.join("kendex.toml");
    fs::write(
        &manifest,
        format!(
            "{}\n[sources.cat]\n{}\n[agents.work]\nsource = \"cat\"\n",
            fs::read_to_string(&manifest).unwrap(),
            test_util::source_path(&catalog)
        ),
    )
    .unwrap();
    let report = apply_now(&f);
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "work" && row.state == DriftState::Conflict)
    );
    let paths: Vec<String> = serde_json::from_str(
        &fs::read_to_string(f.project.join(".kendex-generated.json")).unwrap(),
    )
    .unwrap();
    assert!(!paths.iter().any(|path| path == ".claude/agents/work.md"));
    assert!(!report.generated.owned(&f.project).contains(&occupied));
    assert_eq!(
        fs::read_to_string(&occupied).unwrap(),
        "User-written instructions.\n"
    );

    // A person commits their file and the refresh, then removes the
    // declaration and their file. Its deletion must remain theirs too.
    commit(&f.project);
    fs::write(
        &manifest,
        "schema = 6\n[install]\nharnesses = [\"claude\"]\n",
    )
    .unwrap();
    fs::remove_file(&occupied).unwrap();
    let report = apply_now(&f);
    let chosen = [".claude/agents/work.md".to_owned()].into_iter().collect();
    let committed = kendex_core::commit_offer::commit(
        &f.project,
        &report.generated,
        "renders",
        &kendex_core::commit_offer::Selection::Only(chosen),
        &kendex_core::commit_offer::Before::Untaken,
    )
    .unwrap();
    assert_eq!(
        committed,
        kendex_core::commit_offer::Committed::Nothing {
            dropped: vec![".claude/agents/work.md".to_owned()],
        }
    );
    let chosen = [".claude/agents/work.md".to_owned()].into_iter().collect();
    let restored =
        kendex_core::commit_offer::restore(&f.env, &f.scope, &report.generated, &chosen).unwrap();
    assert_eq!(restored.restored, Vec::<String>::new());
    assert_eq!(restored.dropped, vec![".claude/agents/work.md".to_owned()]);
    assert!(!occupied.exists());
}
