//! Claude reads AGENTS.md natively. Its former shims stay with consumers
//! without generated-path records. Gemini keeps its settings shim.
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
use kendex_core::model::{HarnessId, Scope};
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
fn claude_declared_plans_no_root_or_nested_instruction_shim() {
    let f = fixture("\"claude\"", true);
    let nested = f.project.join("crates/core");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("AGENTS.md"), "# core\n").unwrap();
    commit(&f.project);

    let report = apply_now(&f);
    assert!(touched(&f, &report).is_empty());
    assert!(report.instruction_shims.is_empty());
    assert!(report.drift.is_empty());
    assert!(!f.project.join("CLAUDE.md").exists());
    assert!(!nested.join("CLAUDE.md").exists());
    assert!(standings(&f, &[HarnessId::Claude]).is_empty());
    assert!(plan(&f).plan.is_empty());
}

/// Seed the inventory an earlier kendex build wrote.
#[allow(clippy::unwrap_used)]
fn record_claude_shims(f: &Fixture, paths: &[&str]) {
    fs::write(
        f.project.join(".kendex-generated.json"),
        serde_json::to_string(paths).unwrap(),
    )
    .unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn recorded_claude_shims_stay_with_the_consumer_without_generated_records() {
    for (harnesses, remove_agents) in [
        ("\"claude\"", false),
        ("\"codex\"", false),
        ("\"claude\"", true),
    ] {
        let f = fixture(harnesses, true);
        let nested = f.project.join("crates/core");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("AGENTS.md"), "# core\n").unwrap();
        let paths = ["CLAUDE.md", "crates/core/CLAUDE.md"];
        for path in paths {
            fs::write(f.project.join(path), "@AGENTS.md\n").unwrap();
        }
        record_claude_shims(&f, &paths);
        commit(&f.project);
        if remove_agents {
            run_git(
                &f.project,
                &["rm", "--", "AGENTS.md", "crates/core/AGENTS.md"],
            );
        }

        let report = apply_now(&f);
        assert!(touched(&f, &report).is_empty());
        assert!(report.drift.is_empty());
        assert!(report.instruction_shims.is_empty());
        let inventory = report.generated.inventory(&f.project);
        let recorded: Vec<String> =
            serde_json::from_str(&shim_bytes(&f.project.join(".kendex-generated.json"))).unwrap();
        for path in paths {
            let position = f.project.join(path);
            assert_eq!(shim_bytes(&position), "@AGENTS.md\n");
            assert!(!inventory.contains(&position));
            assert!(!report.generated.owned(&f.project).contains(&position));
            assert!(!recorded.iter().any(|entry| entry == path));
        }
        assert!(kendex_core::trash::list(&f.env).unwrap().is_empty());
        if remove_agents {
            run_git(
                &f.project,
                &[
                    "restore",
                    "--staged",
                    "--worktree",
                    "--",
                    "AGENTS.md",
                    "crates/core/AGENTS.md",
                ],
            );
        }
        assert!(plan(&f).plan.is_empty());
        for path in paths {
            assert_eq!(shim_bytes(&f.project.join(path)), "@AGENTS.md\n");
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_former_claude_shim_position_is_not_read_or_removed() {
    let f = fixture("\"claude\"", true);
    let path = f.project.join("CLAUDE.md");
    record_claude_shims(&f, &["CLAUDE.md"]);
    // A directory at the former file position makes read fail even for
    // a privileged test runner, unlike mode bits denying read permission.
    fs::create_dir(&path).unwrap();
    let report = apply_now(&f);
    assert!(touched(&f, &report).is_empty());
    assert!(report.drift.is_empty());
    assert!(!report.generated.inventory(&f.project).contains(&path));
    assert!(!report.generated.owned(&f.project).contains(&path));
    assert!(path.is_dir());
    assert!(plan(&f).plan.is_empty());

    fs::remove_dir(&path).unwrap();
    fs::write(&path, "@AGENTS.md\n").unwrap();
    assert!(plan(&f).plan.is_empty());
    assert_eq!(shim_bytes(&path), "@AGENTS.md\n");
}

#[test]
#[allow(clippy::unwrap_used)]
fn personal_claude_files_stay_untouched_without_rows_or_takeover() {
    for (what, listed, linked, bytes) in [
        ("extra line", true, false, "@AGENTS.md\nmy own line\n"),
        ("symlink", true, true, CLAUDE_SHIM),
        ("unlisted import", false, false, CLAUDE_SHIM),
    ] {
        let f = fixture("\"claude\"", true);
        let path = f.project.join("CLAUDE.md");
        if linked {
            fs::write(f.project.join("personal.md"), bytes).unwrap();
            std::os::unix::fs::symlink("personal.md", &path).unwrap();
        } else {
            fs::write(&path, bytes).unwrap();
        }
        if listed {
            record_claude_shims(&f, &["CLAUDE.md"]);
        }
        commit(&f.project);
        for replace_unmanaged in [false, true] {
            let options = PlanOptions {
                replace_unmanaged,
                ..PlanOptions::current()
            };
            let report = plan_apply(&f.env, &f.scope, &options).unwrap();
            assert!(touched(&f, &report).is_empty(), "{what}");
            assert!(report.drift.is_empty(), "{what}");
            assert!(report.instruction_shims.is_empty(), "{what}");
            apply::execute(&f.env, &report.plan).unwrap();
            assert_eq!(shim_bytes(&path), bytes, "{what}");
            assert_eq!(path.is_symlink(), linked, "{what}");
        }
        assert!(plan(&f).plan.is_empty(), "{what}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_old_claude_link_retires_independently_of_the_root_file() {
    for (harnesses, root_bytes) in [
        ("\"claude\"", None),
        ("\"claude\"", Some("# personal\n")),
        ("\"codex\"", Some("# personal\n")),
    ] {
        let f = fixture(harnesses, true);
        let old = f.project.join(".claude/CLAUDE.md");
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        if let Some(bytes) = root_bytes {
            fs::write(f.project.join("CLAUDE.md"), bytes).unwrap();
        }
        std::os::unix::fs::symlink("../AGENTS.md", &old).unwrap();
        let report = apply_now(&f);
        assert_eq!(touched(&f, &report), [".claude/CLAUDE.md"]);
        assert_eq!(report.instruction_shims[0].state, ShimState::OldLink);
        assert!(!old.is_symlink());
        if let Some(bytes) = root_bytes {
            assert_eq!(shim_bytes(&f.project.join("CLAUDE.md")), bytes);
        } else {
            assert!(!f.project.join("CLAUDE.md").exists());
        }
        let trash = kendex_core::trash::list(&f.env).unwrap();
        assert!(
            trash
                .iter()
                .any(|entry| f.env.trash_dir().join(&entry.name).is_symlink())
        );
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        for bytes in ["# personal\n", "@AGENTS.md\n"] {
            fs::write(&old, bytes).unwrap();
            let again = apply_now(&f);
            assert!(again.plan.is_empty());
            assert!(again.drift.is_empty());
            assert!(again.instruction_shims.is_empty());
            assert_eq!(shim_bytes(&old), bytes);
        }
        fs::remove_file(&old).unwrap();
        fs::write(f.project.join("personal.md"), "# personal\n").unwrap();
        std::os::unix::fs::symlink("../personal.md", &old).unwrap();
        assert!(plan(&f).plan.is_empty());
        assert!(old.is_symlink());
    }
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
/// taken back. The refused retirement keeps its record, or takes it from
/// the inventory where the install record lacks it as a build from before
/// the record wrote it: once the person repairs the file, the next apply
/// takes the entry out and keeps their own key.
#[test]
#[allow(clippy::unwrap_used)]
fn unparseable_gemini_settings_are_refused_not_rewritten() {
    for (harnesses, declared, recorded) in [
        ("\"gemini\"", true, true),
        ("\"codex\"", false, true),
        ("\"codex\"", false, false),
    ] {
        let f = fixture("\"gemini\"", true);
        if !declared {
            apply_now(&f);
            if !recorded {
                let lock_path = f.project.join(".kendex-lock.json");
                let mut lock: serde_json::Value =
                    serde_json::from_str(&shim_bytes(&lock_path)).unwrap();
                lock.as_object_mut().unwrap().remove("shims").unwrap();
                fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
            }
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
            continue;
        }

        commit(&f.project);
        let theirs = "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n";
        fs::write(
            &settings,
            "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  },\n  \"context\": {\n    \"fileName\": [\"GEMINI.md\", \"AGENTS.md\"]\n  }\n}\n",
        )
        .unwrap();
        let report = apply_now(&f);
        let row = report
            .drift
            .iter()
            .find(|row| row.name == ".gemini/settings.json")
            .unwrap_or_else(|| {
                panic!(
                    "recorded={recorded}: the repaired file is not retired: {:?}",
                    report.drift
                )
            });
        assert_eq!(row.state, DriftState::Orphaned, "recorded={recorded}");
        assert_eq!(
            gemini_settings(&f),
            serde_json::from_str::<serde_json::Value>(theirs).unwrap(),
            "recorded={recorded}"
        );
        assert!(
            plan(&f).plan.is_empty(),
            "recorded={recorded}: the next pass plans again"
        );
    }
}

/// While Gemini is installed, its settings file is a key kendex writes in
/// a file of the person's: a restore never writes the committed copy over
/// the person's own change beside the shim, and a commit never takes it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_persons_key_beside_the_gemini_shim_stays_out_of_commit_and_restore() {
    let f = fixture("\"gemini\"", true);
    let settings = f.project.join(".gemini/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(
        &settings,
        "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n",
    )
    .unwrap();
    commit(&f.project);
    apply_now(&f);
    commit(&f.project);
    let edited = shim_bytes(&settings).replace("Dark", "Light");
    fs::write(&settings, &edited).unwrap();

    let report = plan(&f);
    assert!(report.generated.shared.contains(&settings));
    assert!(!report.generated.owned(&f.project).contains(&settings));
    let chosen: std::collections::BTreeSet<String> =
        [".gemini/settings.json".to_owned()].into_iter().collect();
    let restored =
        kendex_core::commit_offer::restore(&f.env, &f.scope, &report.generated, &chosen).unwrap();
    assert_eq!(restored.restored, Vec::<String>::new());
    assert_eq!(restored.dropped, vec![".gemini/settings.json".to_owned()]);
    assert_eq!(shim_bytes(&settings), edited);
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
            dropped: vec![".gemini/settings.json".to_owned()],
        }
    );
    assert_eq!(shim_bytes(&settings), edited);
}

/// Gemini off the list in a project with no `.git` of its own, nested in a
/// larger repository or outside git: no inventory is written there, so the
/// install record alone takes the shim back, and the person's own key stays.
#[test]
#[allow(clippy::unwrap_used)]
fn the_gemini_shim_goes_where_the_project_has_no_repository_of_its_own() {
    let theirs = "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n";
    for (what, outer_repository) in [
        ("nested in a larger repository", true),
        ("outside any repository", false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let outer = home.join("outer");
        let project = outer.join("app");
        fs::create_dir_all(project.join(".gemini")).unwrap();
        if outer_repository {
            run_git(&outer, &["init", "-q", "-b", "main"]);
        }
        let f = Fixture {
            env: Env::fake(&home, FakeOs::Linux),
            scope: Scope::Project {
                root: project.clone(),
            },
            project,
            _tmp: tmp,
        };
        let declare = |harnesses: &str| {
            fs::write(
                f.project.join("kendex.toml"),
                format!("schema = 6\n\n[install]\nharnesses = [{harnesses}]\n"),
            )
            .unwrap();
        };
        let settings = f.project.join(".gemini/settings.json");
        declare("\"gemini\"");
        fs::write(f.project.join("AGENTS.md"), "# app\n").unwrap();
        fs::write(&settings, theirs).unwrap();
        if outer_repository {
            commit(&outer);
        }
        apply_now(&f);
        assert!(shim_bytes(&settings).contains("AGENTS.md"), "{what}");
        assert!(!f.project.join(".kendex-generated.json").exists(), "{what}");

        declare("\"codex\"");
        let report = apply_now(&f);
        let rows: Vec<DriftState> = report
            .drift
            .iter()
            .filter(|row| row.name == ".gemini/settings.json")
            .map(|row| row.state)
            .collect();
        assert_eq!(rows, vec![DriftState::Orphaned], "{what}");
        assert_eq!(
            gemini_settings(&f),
            serde_json::from_str::<serde_json::Value>(theirs).unwrap(),
            "{what}"
        );
        let again = plan(&f);
        assert!(again.plan.is_empty(), "{what}: {:?}", touched(&f, &again));
    }
}

/// Gemini off the list: a settings file kendex named `AGENTS.md` in, which
/// its install record names, and that still names it the way the shim's edit
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

/// The keyed shims `.kendex-lock.json` records, `Null` where it records
/// none or there is no record.
#[allow(clippy::unwrap_used)]
fn recorded_shims(f: &Fixture) -> serde_json::Value {
    fs::read_to_string(f.project.join(".kendex-lock.json"))
        .ok()
        .map_or(serde_json::Value::Null, |text| {
            serde_json::from_str::<serde_json::Value>(&text).unwrap()["shims"].take()
        })
}

/// A Gemini shim an earlier build wrote left no install record, as does a
/// record an older build wrote again. Dropping Gemini still takes it back
/// and keeps the person's own keys: in the very next apply, off the
/// inventory listing the settings file, or after an apply with Gemini
/// still listed, which records the key standing in sync. The record at
/// `HEAD`, or the inventory there where that record lacks the shim, keeps
/// the file one kendex writes a key in until the retirement is committed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_gemini_shim_written_before_the_record_was_kept_is_recorded_then_retired() {
    let theirs = "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n";
    for (what, recorded_first) in [
        ("dropped in the very next apply", false),
        ("an apply with Gemini still listed between", true),
    ] {
        let f = fixture("\"gemini\"", true);
        let settings = f.project.join(".gemini/settings.json");
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, theirs).unwrap();
        apply_now(&f);
        let lock_path = f.project.join(".kendex-lock.json");
        let mut lock: serde_json::Value = serde_json::from_str(&shim_bytes(&lock_path)).unwrap();
        assert_eq!(
            lock["shims"],
            serde_json::json!(["gemini-context-file"]),
            "{what}"
        );
        lock.as_object_mut().unwrap().remove("shims");
        fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
        commit(&f.project);

        if recorded_first {
            let report = apply_now(&f);
            assert!(
                touched(&f, &report).is_empty(),
                "{what}: {:?}",
                touched(&f, &report)
            );
            assert_eq!(
                recorded_shims(&f),
                serde_json::json!(["gemini-context-file"]),
                "{what}"
            );
            commit(&f.project);
        }
        fs::write(
            f.project.join("kendex.toml"),
            "schema = 6\n\n[install]\nharnesses = [\"codex\"]\n",
        )
        .unwrap();
        let report = apply_now(&f);
        assert!(
            touched(&f, &report).contains(&".gemini/settings.json".to_owned()),
            "{what}"
        );
        let rows: Vec<DriftState> = report
            .drift
            .iter()
            .filter(|row| row.name == ".gemini/settings.json")
            .map(|row| row.state)
            .collect();
        assert_eq!(rows, vec![DriftState::Orphaned], "{what}");
        assert_eq!(
            gemini_settings(&f),
            serde_json::from_str::<serde_json::Value>(theirs).unwrap(),
            "{what}"
        );
        assert_eq!(recorded_shims(&f), serde_json::Value::Null, "{what}");
        let again = plan(&f);
        assert!(again.plan.is_empty(), "{what}: {:?}", touched(&f, &again));
        // Uncommitted, a reading after the retirement still takes the file
        // as one kendex writes a key in: off the record at `HEAD`, or off
        // the inventory there where that record lacks the shim. A deletion
        // of it is then the person's, which neither a restore nor a commit
        // takes as a render's.
        assert!(
            again.generated.beside(&f.project).contains(&settings),
            "{what}"
        );
        fs::remove_file(&settings).unwrap();
        let after = plan(&f);
        let chosen: std::collections::BTreeSet<String> =
            [".gemini/settings.json".to_owned()].into_iter().collect();
        let restored =
            kendex_core::commit_offer::restore(&f.env, &f.scope, &after.generated, &chosen)
                .unwrap();
        assert_eq!(restored.restored, Vec::<String>::new(), "{what}");
        assert_eq!(
            restored.dropped,
            vec![".gemini/settings.json".to_owned()],
            "{what}"
        );
        assert!(!settings.exists(), "{what}");
        let committed = kendex_core::commit_offer::commit(
            &f.project,
            &after.generated,
            "renders",
            &kendex_core::commit_offer::Selection::Only(chosen),
            &kendex_core::commit_offer::Before::Untaken,
        )
        .unwrap();
        assert_eq!(
            committed,
            kendex_core::commit_offer::Committed::Nothing {
                dropped: vec![".gemini/settings.json".to_owned()],
            },
            "{what}"
        );
    }
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
/// person's content: Gemini's context entry, a JSON
/// document and a TOML document a removal would otherwise empty. Each row
/// lets kendex write the file where the row installs for the tool, gives it
/// content of the person's, then drops the tool. The file stays holding
/// that content, no orphaned row names it, and the next pass plans nothing.
/// A file of the person's in a project kendex never installed Gemini for
/// stays even when it holds exactly what the shim would write.
///
/// Each guard turns its own row red: the context entry's exact-value
/// check and the emptied-document check for each document kind. A settled Gemini
/// retirement that kept its record turns the extended-entry row red. The
/// Gemini record's two halves are pinned apart: the install record by
/// `the_gemini_shim_goes_where_the_project_has_no_repository_of_its_own`,
/// the inventory seed by
/// `a_gemini_shim_written_before_the_record_was_kept_is_recorded_then_retired`.
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
                ..PlanOptions::current()
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
        // A settled retirement keeps no record, so a value of exactly the
        // shim's the person sets later is never taken as kendex's.
        assert_eq!(recorded_shims(&f), serde_json::Value::Null, "{what}");
        let again = dropping();
        assert!(again.plan.is_empty(), "{what}: {:?}", touched(&f, &again));
    }
}

/// Only Gemini needs a shim, including when Claude Code is also declared.
#[test]
fn shims_follow_the_declared_harnesses() {
    let f = fixture("\"codex\"", true);
    let report = plan(&f);
    assert!(report.plan.is_empty() && report.drift.is_empty());
    assert!(report.instruction_shims.is_empty());
    assert_eq!(standings(&f, &[HarnessId::Codex]), []);

    let both = fixture("\"claude\", \"gemini\"", true);
    let report = apply_now(&both);
    assert_eq!(touched(&both, &report), [".gemini/settings.json"]);
    assert!(!both.project.join("CLAUDE.md").exists());
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
    for rendered in [".agents/skills/generated/SKILL.md", ".gemini/settings.json"] {
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
    assert!(!f.project.join(".kendex-generated.json").exists());
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
