//! A manifest naming one hook from two catalogs: the wrapper's catalog
//! carries a judge of its own, and the manifest declares the judge from
//! another. Where a hook lands is decided about the declaration the plan
//! writes, so the walk that withholds, the planner that writes and the
//! pass that takes an installed copy out cannot each pick a different
//! copy of the judge.

use super::hooks::{
    DELIVER, HALT, JUDGE, LATE_JUDGE, drift_details, findings_on, hook_fixture, hook_on_disk,
    messages, registered,
};
use super::*;

use kendex_core::apply::Op;
use kendex_core::engine::DriftState;
use kendex_core::source::declared_path_identity;

/// The other catalog's judge: on an event Codex never fires, and needing
/// nothing back, so the question is about the judge alone.
const LATE_JUDGE_ALONE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: TaskCompleted\n# description: judge the task end\n# ---\nexit 0\n";

/// The hook fixture with a second catalog beside the first, offering the
/// same three hooks, and the manifest subscribed to both.
#[allow(clippy::unwrap_used)]
fn two_catalogs(declarations: &str) -> (Fixture, PathBuf) {
    let f = hook_fixture(declarations);
    let other = f.source.parent().unwrap().join("other");
    let hooks = other.join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(hooks.join("judge.sh"), JUDGE).unwrap();
    fs::write(hooks.join("deliver.sh"), DELIVER).unwrap();
    fs::write(hooks.join("halt.sh"), HALT).unwrap();
    fs::write(other.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    declare_two(&f, &other, declarations);
    (f, other)
}

/// The project's manifest rewritten around new declarations, both
/// catalogs subscribed.
#[allow(clippy::unwrap_used)]
fn declare_two(f: &Fixture, other: &Path, declarations: &str) {
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[sources.other]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&f.source),
            source_path(other)
        ),
    )
    .unwrap();
}

/// The provenance a path catalog is recorded under.
fn identity(path: &Path) -> String {
    declared_path_identity(&path.display().to_string())
}

/// Whether the wrapper and the judge are written and registered on each
/// tool, as `(written, registered)` per hook per tool.
fn landed(f: &Fixture, name: &str, harness: HarnessId) -> (bool, bool) {
    (
        hook_on_disk(f, harness, &format!("{name}.sh")),
        registered(f, harness, name),
    )
}

/// The wrapper's catalog carries a judge Codex can run; the manifest
/// declares the judge from the other catalog, whose judge Codex never
/// fires. The plan writes the declared judge, so on Codex it writes none,
/// and the wrapper is withheld there rather than registered beside a judge
/// its own catalog would have delivered.
#[test]
#[allow(clippy::unwrap_used)]
fn a_wrapper_is_withheld_where_the_judge_the_plan_writes_is_not() {
    let (f, other) =
        two_catalogs("[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\n");
    fs::write(other.join("hooks/judge.sh"), LATE_JUDGE_ALONE).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let found: Vec<(&str, Option<&str>)> = findings_on(&report, "deliver")
        .iter()
        .map(|w| (w.message.as_str(), w.remediation.as_deref()))
        .collect();
    assert_eq!(
        found,
        [(
            "missing required dependency: Codex runs deliver without judge, which cannot be delivered there: Codex never fires TaskCompleted",
            Some(
                "make judge deliverable on Codex, or list deliver's harnesses in kendex.toml without Codex"
            ),
        )],
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(landed(&f, "deliver", HarnessId::Claude), (true, true));
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (false, false));
    assert_eq!(landed(&f, "judge", HarnessId::Claude), (true, true));
    assert_eq!(landed(&f, "judge", HarnessId::Codex), (false, false));
}

/// A declared wrapper installed from one catalog and then set to come from
/// the other, whose judge Codex cannot run: on Codex the rebound wrapper is
/// withheld, and the recorded installation is still the other catalog's.
/// The plan says so as the provenance conflict a rebind always gets, keeps
/// the record, and takes nothing of the recorded copy to the trash.
#[test]
#[allow(clippy::unwrap_used)]
fn a_withheld_rebind_reaches_the_provenance_conflict_and_not_the_trash() {
    let (f, other) = two_catalogs("[hooks.deliver]\nsource = \"other\"\n");
    apply_now(&f);
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (true, true));
    assert_eq!(
        lock_of(&f).entries["hook:deliver:codex"].source_repo,
        identity(&other)
    );

    fs::write(f.source.join("hooks/judge.sh"), LATE_JUDGE).unwrap();
    declare_two(&f, &other, "[hooks.deliver]\nsource = \"cat\"\n");
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    let rows: Vec<(DriftState, &str)> = report
        .drift
        .iter()
        .filter(|row| row.name == "deliver" && row.harness == HarnessId::Codex)
        .map(|row| (row.state, row.detail.as_str()))
        .collect();
    let conflict = format!(
        "installed from {} but now set to come from {} — remove it first",
        identity(&other),
        identity(&f.source)
    );
    assert_eq!(
        rows,
        [(DriftState::Conflict, conflict.as_str())],
        "{:?}",
        drift_details(&report)
    );
    let recorded = f.project.join(".codex/hooks/deliver.sh");
    let trashed: Vec<&PathBuf> = report
        .plan
        .ops
        .iter()
        .filter_map(|op| match &op.op {
            Op::Trash { path, .. } if *path == recorded => Some(path),
            _ => None,
        })
        .collect();
    assert_eq!(
        trashed,
        Vec::<&PathBuf>::new(),
        "the recorded copy is trashed"
    );
    assert_eq!(
        report.record.entries["hook:deliver:codex"].source_repo,
        identity(&other),
        "the record was rebound"
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (true, true));
}

/// The judge declared from a catalog that will not open this pass — its
/// directory gone — while the wrapper's own catalog reads. A source that
/// cannot be read never uninstalls a working artifact: the wrapper keeps
/// its finding and its installed copy on every tool, as it would were both
/// hooks from the one unreadable catalog, and the judge's record stays.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_whose_catalog_will_not_open_keeps_the_wrapper_installed() {
    let (f, other) =
        two_catalogs("[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\n");
    apply_now(&f);
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (true, true));
    fs::remove_dir_all(&other).unwrap();

    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    let found: Vec<(&str, Option<&str>)> = findings_on(&report, "deliver")
        .iter()
        .map(|w| (w.message.as_str(), w.remediation.as_deref()))
        .collect();
    assert_eq!(
        found,
        [(
            "deliver requires judge, which is set to come from the catalog 'other', and that catalog cannot be read",
            Some(
                "settle the note on the catalog 'other', or declare judge from a catalog that reads"
            ),
        )],
        "{:?}",
        messages(&report)
    );
    let rows: Vec<(DriftState, &str)> = report
        .drift
        .iter()
        .filter(|row| row.name == "deliver")
        .map(|row| (row.state, row.detail.as_str()))
        .collect();
    assert_eq!(rows, Vec::new(), "{:?}", drift_details(&report));
    let trashed: Vec<&PathBuf> = report
        .plan
        .ops
        .iter()
        .filter_map(|op| match &op.op {
            Op::Trash { path, .. } if path.ends_with("hooks/deliver.sh") => Some(path),
            _ => None,
        })
        .collect();
    assert_eq!(trashed, Vec::<&PathBuf>::new(), "the wrapper is trashed");
    apply::execute(&f.env, &report.plan).unwrap();
    for harness in [HarnessId::Claude, HarnessId::Codex] {
        assert_eq!(landed(&f, "deliver", harness), (true, true), "{harness:?}");
        assert_eq!(landed(&f, "judge", harness), (true, true), "{harness:?}");
    }
}
