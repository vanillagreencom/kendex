//! A manifest naming one hook from two catalogs: the wrapper's catalog
//! carries a judge of its own, and the manifest declares the judge from
//! another. Where a hook lands is decided about the declaration the plan
//! writes, so the walk that withholds, the planner that writes and the
//! pass that takes an installed copy out cannot each pick a different
//! copy of the judge.

use super::hooks::{
    BOSS, DELIVER, EXTRA, HALT, JUDGE, LATE_JUDGE, NARROW as NARROW_CLAUDE, drift_details,
    findings_on, hook_fixture, hook_on_disk, messages, registered,
};
use super::*;

use kendex_core::apply::Op;
use kendex_core::engine::DriftState;
use kendex_core::source::declared_path_identity;

/// A hook above the wrapper: it requires deliver and nothing requires it.
const TOP: &str = "#!/usr/bin/env bash\n# ---\n# name: top\n# event: PreToolUse\n# description: run before a tool call with deliver\n# requires: [deliver]\n# ---\nexit 0\n";
/// The boss's narrow companion as the other catalog offers it, with no
/// harnesses line, so nothing but its catalog decides where it runs.
const NARROW: &str = "#!/usr/bin/env bash\n# ---\n# name: narrow\n# event: PreToolUse\n# description: run before a tool call\n# ---\nexit 0\n";
/// A control file that will not parse: the catalog opens and hides its
/// content.
const UNPARSABLE: &str = "is_source_catalog = [\n";

/// A chain below the boss's extra companion: extra requires mid and the
/// head of a chain x → y → z, or mid and y, one step shorter; z is the
/// hook the other catalog declares.
const EXTRA_MID_X: &str = "#!/usr/bin/env bash\n# ---\n# name: extra\n# event: PostToolUse\n# description: run after a tool call with mid and x\n# requires: [mid, x]\n# ---\nexit 0\n";
const EXTRA_MID_Y: &str = "#!/usr/bin/env bash\n# ---\n# name: extra\n# event: PostToolUse\n# description: run after a tool call with mid and y\n# requires: [mid, y]\n# ---\nexit 0\n";
const MID: &str = "#!/usr/bin/env bash\n# ---\n# name: mid\n# event: PostToolUse\n# description: run after a tool call\n# ---\nexit 0\n";
const X: &str = "#!/usr/bin/env bash\n# ---\n# name: x\n# event: PostToolUse\n# description: run after a tool call with y\n# requires: [y]\n# ---\nexit 0\n";
const Y: &str = "#!/usr/bin/env bash\n# ---\n# name: y\n# event: PostToolUse\n# description: run after a tool call with z\n# requires: [z]\n# ---\nexit 0\n";
const Z: &str = "#!/usr/bin/env bash\n# ---\n# name: z\n# event: PostToolUse\n# description: run after a tool call\n# ---\nexit 0\n";

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
/// the record, and takes nothing of the recorded copy to the trash — nor
/// of the judge and the other wrapper the kept copy runs with, which the
/// orphan pass keeps with it under `apply`'s options, records and all.
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
        "installed from {} but now set to come from {} — remove it first — {} does not install it on Codex",
        identity(&other),
        identity(&f.source),
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
    for name in ["judge", "halt"] {
        let key = format!("hook:{name}:codex");
        assert!(
            report.record.entries.contains_key(&key),
            "{key} lost its record: {:?}",
            drift_details(&report)
        );
    }
    apply::execute(&f.env, &report.plan).unwrap();
    for name in ["deliver", "judge", "halt"] {
        assert_eq!(landed(&f, name, HarnessId::Codex), (true, true), "{name}");
    }
}

/// A hook with no harnesses line, which the other catalog offers.
const SOLO: &str = "#!/usr/bin/env bash\n# ---\n# name: solo\n# event: PreToolUse\n# description: run before a tool call\n# ---\nexit 0\n";
/// The same hook as the wrapper's catalog offers it, on Claude Code alone.
const SOLO_CLAUDE: &str = "#!/usr/bin/env bash\n# ---\n# name: solo\n# event: PreToolUse\n# description: run before a tool call on Claude Code alone\n# harnesses: [claude]\n# ---\nexit 0\n";
/// An agent every tool loads, which the other catalog offers.
const CRITIC: &str = "---\nname: critic\ndescription: reviews a change\n---\nBody.\n";
/// The same agent as the wrapper's catalog offers it, at an effort level
/// Claude Code accepts and Codex refuses.
const CRITIC_MAX: &str =
    "---\nname: critic\ndescription: reviews a change\neffort: max\n---\nBody.\n";

/// A declared item installed from the other catalog on both tools, then
/// set to come from the wrapper's catalog, whose copy plans nothing on
/// Codex: a hook that catalog does not derive there, and an agent Codex
/// refuses. The Codex record is still the other catalog's, so the plan
/// says so as the provenance conflict a rebind always gets, with why
/// nothing replaces it there, keeps the record, and takes nothing to the
/// trash, on either tool.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rebind_planning_nothing_on_a_tool_reaches_the_provenance_conflict_and_not_the_trash() {
    /// The declaration's kind, its catalog file, the other catalog's
    /// bytes, the wrapper catalog's bytes, and the record line of Codex's
    /// refusal, where it refuses.
    type Row = (
        ItemKind,
        &'static str,
        &'static str,
        &'static str,
        Option<&'static str>,
    );
    let rows: [Row; 2] = [
        (ItemKind::Hook, "hooks/solo.sh", SOLO, SOLO_CLAUDE, None),
        (
            ItemKind::Agent,
            "agents/critic.md",
            CRITIC,
            CRITIC_MAX,
            Some("kendex-effort-rejected: harness=codex key=model_reasoning_effort value=max "),
        ),
    ];
    for (kind, file, from_other, from_cat, refusal) in rows {
        let name = Path::new(file).file_stem().unwrap().to_str().unwrap();
        let declaration =
            |source: &str| format!("[{}s.{name}]\nsource = \"{source}\"\n", kind.name());
        let (f, other) = two_catalogs(&declaration("other"));
        for (catalog, bytes) in [(&other, from_other), (&f.source, from_cat)] {
            fs::create_dir_all(catalog.join(file).parent().unwrap()).unwrap();
            fs::write(catalog.join(file), bytes).unwrap();
        }
        apply_now(&f);
        let key = format!("{}:{name}:codex", kind.name());
        assert_eq!(
            lock_of(&f).entries[&key].source_repo,
            identity(&other),
            "{key}"
        );

        declare_two(&f, &other, &declaration("cat"));
        let report = plan_apply(
            &f.env,
            &f.scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::default()
            },
        )
        .unwrap();
        let conflict = format!(
            "installed from {} but now set to come from {} — remove it first",
            identity(&other),
            identity(&f.source)
        );
        let rows = |harness| -> Vec<(DriftState, &str)> {
            report
                .drift
                .iter()
                .filter(|row| row.name == name && row.harness == harness)
                .map(|row| (row.state, row.detail.as_str()))
                .collect()
        };
        assert_eq!(
            rows(HarnessId::Claude),
            [(DriftState::Conflict, conflict.as_str())],
            "{key}: {:?}",
            drift_details(&report)
        );
        let codex = rows(HarnessId::Codex);
        let [(DriftState::Conflict, detail)] = codex.as_slice() else {
            panic!("{key}: {:?}", drift_details(&report));
        };
        let explained = match refusal {
            Some(record) => {
                detail.starts_with(record) && detail.ends_with(&format!(" — {conflict}"))
            }
            None => {
                *detail
                    == format!(
                        "{conflict} — {} does not install it on Codex",
                        identity(&f.source)
                    )
            }
        };
        assert!(explained, "{key}: {detail}");
        let trashed: Vec<&PathBuf> = report
            .plan
            .ops
            .iter()
            .filter_map(|op| match &op.op {
                Op::Trash { path, .. } => Some(path),
                _ => None,
            })
            .collect();
        assert_eq!(trashed, Vec::<&PathBuf>::new(), "{key}");
        assert_eq!(
            report.record.entries[&key].source_repo,
            identity(&other),
            "{key}'s record was rebound or dropped"
        );
    }
}

/// An agent installed from the other catalog, then set to come from the
/// wrapper's catalog, which cannot say what it would install: it does not
/// carry the agent, its control file will not parse, or its copy of the
/// agent will not read. A declaration that planned nothing is skipped with
/// its note, not judged: the record stays the other catalog's on both
/// tools, with no row and nothing taken to the trash.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rebind_to_a_catalog_that_cannot_answer_keeps_the_record_without_a_row() {
    /// What the wrapper's catalog holds: its copy of the agent, if any,
    /// and whether its control file parses.
    type Row = (&'static str, Option<&'static str>, bool);
    let rows: [Row; 3] = [
        ("not carried", None, true),
        ("control file unparsable", Some(CRITIC), false),
        ("item unreadable", Some("Body.\n"), true),
    ];
    for (case, from_cat, parses) in rows {
        let (f, other) = two_catalogs("[agents.critic]\nsource = \"other\"\n");
        fs::create_dir_all(other.join("agents")).unwrap();
        fs::write(other.join("agents/critic.md"), CRITIC).unwrap();
        apply_now(&f);
        if let Some(bytes) = from_cat {
            fs::create_dir_all(f.source.join("agents")).unwrap();
            fs::write(f.source.join("agents/critic.md"), bytes).unwrap();
        }
        if !parses {
            fs::write(f.source.join("kendex.toml"), UNPARSABLE).unwrap();
        }
        declare_two(&f, &other, "[agents.critic]\nsource = \"cat\"\n");

        let report = plan_apply(
            &f.env,
            &f.scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::default()
            },
        )
        .unwrap();
        let rows: Vec<(HarnessId, DriftState, &str)> = report
            .drift
            .iter()
            .filter(|row| row.name == "critic")
            .map(|row| (row.harness, row.state, row.detail.as_str()))
            .collect();
        assert_eq!(rows, Vec::new(), "{case}");
        let trashed: Vec<&PathBuf> = report
            .plan
            .ops
            .iter()
            .filter_map(|op| match &op.op {
                Op::Trash { path, .. } => Some(path),
                _ => None,
            })
            .collect();
        assert_eq!(trashed, Vec::<&PathBuf>::new(), "{case}");
        for harness in [HarnessId::Claude, HarnessId::Codex] {
            let key = format!("agent:critic:{}", harness.name());
            assert_eq!(
                report.record.entries[&key].source_repo,
                identity(&other),
                "{case}: {key}"
            );
        }
    }
}

/// A row the plan leaves on a hook, spelled before the fixture exists:
/// the conflict names the fixture's catalogs.
#[derive(Clone, Copy)]
enum Expected {
    Conflict,
    Withheld,
    Removed,
    KeptBy(&'static str),
}

impl Expected {
    /// The row as the plan writes it, for a record from `other` set to
    /// come from `source`.
    fn spelled(self, other: &Path, source: &Path) -> (DriftState, String) {
        match self {
            Expected::Conflict => (
                DriftState::Conflict,
                format!(
                    "installed from {} but now set to come from {} — remove it first — {} does not install it on Codex",
                    identity(other),
                    identity(source),
                    identity(source)
                ),
            ),
            Expected::Withheld => (
                DriftState::Orphaned,
                "withheld: a hook it requires will not run here — will be removed".to_owned(),
            ),
            Expected::Removed => (
                DriftState::Orphaned,
                "no longer wanted — will be removed".to_owned(),
            ),
            Expected::KeptBy(by) => (
                DriftState::Orphaned,
                format!("needed by {by}, which stays installed — kept with it"),
            ),
        }
    }
}

/// A hook above the wrapper, installed from the other catalog, with the
/// wrapper declared from its own; then the wrapper's judge stops running
/// on Codex. Rebound to the wrapper's catalog, the hook above is kept on
/// Codex as the provenance conflict, and a record kept as is keeps what
/// it requires: the wrapper it runs with, though withheld for a judge
/// that will not run, and the judge below it, stay with it, on disk,
/// registered and recorded. Not rebound, the hook above is withheld like
/// the wrapper, and all three leave Codex.
#[test]
#[allow(clippy::unwrap_used)]
fn a_kept_rebind_keeps_the_withheld_wrapper_it_requires() {
    /// Whether the hook above is rebound; the rows the plan leaves on each
    /// of the three on Codex; and whether the three stay on Codex.
    type Row = (bool, [&'static [Expected]; 3], (bool, bool));
    let rows: [Row; 2] = [
        (
            true,
            [
                &[Expected::Conflict],
                &[Expected::KeptBy("top")],
                &[Expected::KeptBy("deliver")],
            ],
            (true, true),
        ),
        (
            false,
            [
                &[Expected::Withheld],
                &[Expected::Withheld],
                &[Expected::Removed],
            ],
            (false, false),
        ),
    ];
    for (rebound, expected, codex) in rows {
        let (f, other) =
            two_catalogs("[hooks.top]\nsource = \"other\"\n\n[hooks.deliver]\nsource = \"cat\"\n");
        // Both catalogs carry the hook above: the rebind is to one that
        // offers it.
        fs::write(other.join("hooks/top.sh"), TOP).unwrap();
        fs::write(f.source.join("hooks/top.sh"), TOP).unwrap();
        apply_now(&f);
        for name in ["top", "deliver", "judge"] {
            assert_eq!(landed(&f, name, HarnessId::Codex), (true, true), "{name}");
        }
        fs::write(f.source.join("hooks/judge.sh"), LATE_JUDGE).unwrap();
        if rebound {
            declare_two(
                &f,
                &other,
                "[hooks.top]\nsource = \"cat\"\n\n[hooks.deliver]\nsource = \"cat\"\n",
            );
        }

        let report = plan_apply(
            &f.env,
            &f.scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::default()
            },
        )
        .unwrap();
        for (name, expected) in ["top", "deliver", "judge"].into_iter().zip(expected) {
            let rows: Vec<(DriftState, String)> = report
                .drift
                .iter()
                .filter(|row| row.name == name && row.harness == HarnessId::Codex)
                .map(|row| (row.state, row.detail.clone()))
                .collect();
            let expected: Vec<(DriftState, String)> = expected
                .iter()
                .map(|row| row.spelled(&other, &f.source))
                .collect();
            assert_eq!(
                rows,
                expected,
                "{rebound}: {name}: {:?}",
                drift_details(&report)
            );
            assert_eq!(
                report
                    .record
                    .entries
                    .contains_key(&format!("hook:{name}:codex")),
                codex.0,
                "{rebound}: {name}'s record"
            );
        }
        apply::execute(&f.env, &report.plan).unwrap();
        for name in ["top", "deliver", "judge"] {
            assert_eq!(
                landed(&f, name, HarnessId::Codex),
                codex,
                "{rebound}: {name}"
            );
        }
    }
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

/// The judge declared from a catalog that never opened — its directory
/// gone before the first apply. The plan cannot tell whether the judge
/// would run, so it writes the wrapper nowhere, and the hook above the
/// wrapper nowhere either, since a wrapper not written is a wrapper it
/// lacks: a fresh machine gets none of the three, and the findings say
/// why.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_whose_catalog_never_opened_withholds_a_fresh_install() {
    let (f, other) = two_catalogs(
        "[hooks.top]\nsource = \"cat\"\n\n[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\n",
    );
    fs::write(f.source.join("hooks/top.sh"), TOP).unwrap();
    fs::remove_dir_all(&other).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let found: Vec<(&str, &str)> = report
        .warnings
        .iter()
        .map(|w| (w.name.as_str(), w.message.as_str()))
        .collect();
    assert_eq!(
        found,
        [
            (
                "deliver",
                "deliver requires judge, which is set to come from the catalog 'other', and that catalog cannot be read"
            ),
            (
                "top",
                "missing required dependency: top requires deliver, which is withheld from Claude Code and Codex"
            ),
        ],
        "{:?}",
        messages(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    for harness in [HarnessId::Claude, HarnessId::Codex] {
        for name in ["top", "deliver", "judge"] {
            assert_eq!(
                landed(&f, name, harness),
                (false, false),
                "{name} on {harness:?}"
            );
        }
    }
}

/// The judge's catalog opens but hides its content — its own kendex.toml
/// will not parse — after the hooks were installed. The same silence as a
/// catalog that will not open: the wrapper keeps its finding, its
/// installed copy and its record on every tool, and so do the judge and
/// the hook above the wrapper.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_whose_catalog_hides_its_content_keeps_the_wrapper_installed() {
    let (f, other) = two_catalogs(
        "[hooks.top]\nsource = \"cat\"\n\n[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\n",
    );
    fs::write(f.source.join("hooks/top.sh"), TOP).unwrap();
    apply_now(&f);
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (true, true));
    fs::write(other.join("kendex.toml"), UNPARSABLE).unwrap();

    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    let found: Vec<(&str, &str)> = report
        .warnings
        .iter()
        .map(|w| (w.name.as_str(), w.message.as_str()))
        .collect();
    assert_eq!(
        found,
        [
            (
                "deliver",
                "deliver requires judge, which is set to come from the catalog 'other', and that catalog cannot be read"
            ),
            (
                "top",
                "missing required dependency: top requires deliver, which is withheld from Claude Code and Codex"
            ),
        ],
        "{:?}",
        messages(&report)
    );
    assert_eq!(report.drift, Vec::new(), "{:?}", drift_details(&report));
    assert_eq!(trash_ops(&report), Vec::<&PathBuf>::new());
    for harness in [HarnessId::Claude, HarnessId::Codex] {
        for name in ["top", "deliver", "judge"] {
            let key = format!("hook:{name}:{}", harness.name());
            assert!(
                report.record.entries.contains_key(&key),
                "{key} lost its record"
            );
        }
    }
    apply::execute(&f.env, &report.plan).unwrap();
    for harness in [HarnessId::Claude, HarnessId::Codex] {
        for name in ["top", "deliver", "judge"] {
            assert_eq!(
                landed(&f, name, harness),
                (true, true),
                "{name} on {harness:?}"
            );
        }
    }
}

/// Every hook file a plan moves to the trash.
fn trash_ops(report: &kendex_core::engine::EngineReport) -> Vec<&PathBuf> {
    report
        .plan
        .ops
        .iter()
        .filter_map(|op| match &op.op {
            Op::Trash { path, .. } if path.extension().is_some_and(|ext| ext == "sh") => Some(path),
            _ => None,
        })
        .collect()
}

/// The judge from the silent catalog switched off in kendex.toml after the
/// hooks were installed. What the manifest says holds without a catalog:
/// the judge will not run, so the wrapper is withheld for a companion it
/// lacks, its finding names the switch, and its installed copy comes out.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_refusal_holds_when_the_companion_catalog_is_silent() {
    let (f, other) =
        two_catalogs("[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\n");
    apply_now(&f);
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (true, true));
    fs::write(other.join("kendex.toml"), UNPARSABLE).unwrap();
    declare_two(
        &f,
        &other,
        "[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"other\"\nenabled = false\n",
    );

    let report = audit(&f.env, &f.scope).unwrap();
    let found: Vec<&str> = findings_on(&report, "deliver")
        .iter()
        .map(|w| w.message.as_str())
        .collect();
    assert_eq!(
        found,
        ["missing required dependency: deliver requires judge, which is switched off"],
        "{:?}",
        messages(&report)
    );
    let rows: Vec<(DriftState, &str)> = report
        .drift
        .iter()
        .filter(|row| row.name == "deliver" && row.harness == HarnessId::Codex)
        .map(|row| (row.state, row.detail.as_str()))
        .collect();
    assert_eq!(
        rows,
        [(
            DriftState::Orphaned,
            "withheld: a hook it requires will not run here — will be removed"
        )],
        "{:?}",
        drift_details(&report)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(landed(&f, "deliver", HarnessId::Codex), (false, false));
}

/// A hook with one companion from the other catalog and one from its own,
/// installed, and then the other catalog falls silent. The hook is
/// withheld for what cannot be told and keeps its copy; the companion its
/// own catalog offers is not orphaned by that, since a withholding that
/// takes nothing leaves nothing behind, and stays installed under
/// `apply`'s options. Where the own companion goes missing as well, what
/// is known outranks what is not: the hook lacks a companion, and its copy
/// comes out.
#[test]
#[allow(clippy::unwrap_used)]
fn a_silent_companion_catalog_takes_nothing_and_yields_to_a_missing_one() {
    /// Whether the hook's own catalog still offers `extra`; the rows the
    /// plan leaves on the hook; and whether the hook and `extra` stay on
    /// Codex.
    type Row = (
        bool,
        &'static [(DriftState, &'static str)],
        (bool, bool),
        (bool, bool),
    );
    let rows: [Row; 2] = [
        (true, &[], (true, true), (true, true)),
        (
            false,
            &[(
                DriftState::Orphaned,
                "withheld: a hook it requires will not run here — will be removed",
            )],
            (false, false),
            (false, false),
        ),
    ];
    for (extra_offered, expected, boss, extra) in rows {
        let (f, other) =
            two_catalogs("[hooks.boss]\nsource = \"cat\"\n\n[hooks.narrow]\nsource = \"other\"\n");
        fs::write(f.source.join("hooks/boss.sh"), BOSS).unwrap();
        fs::write(f.source.join("hooks/extra.sh"), EXTRA).unwrap();
        // Both catalogs carry narrow, as both carry the judge above: the
        // hook's own copy is the one the plan does not write.
        fs::write(f.source.join("hooks/narrow.sh"), NARROW).unwrap();
        fs::write(other.join("hooks/narrow.sh"), NARROW).unwrap();
        apply_now(&f);
        for name in ["boss", "narrow", "extra"] {
            assert_eq!(landed(&f, name, HarnessId::Codex), (true, true), "{name}");
        }
        fs::write(other.join("kendex.toml"), UNPARSABLE).unwrap();
        if !extra_offered {
            fs::remove_file(f.source.join("hooks/extra.sh")).unwrap();
        }

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
            .filter(|row| row.name == "boss" && row.harness == HarnessId::Codex)
            .map(|row| (row.state, row.detail.as_str()))
            .collect();
        assert_eq!(
            rows,
            expected,
            "{extra_offered}: {:?}",
            drift_details(&report)
        );
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(
            landed(&f, "boss", HarnessId::Codex),
            boss,
            "{extra_offered}: boss"
        );
        assert_eq!(
            landed(&f, "extra", HarnessId::Codex),
            extra,
            "{extra_offered}: extra"
        );
        assert_eq!(
            landed(&f, "narrow", HarnessId::Codex),
            (true, true),
            "{extra_offered}: narrow"
        );
    }
}

/// The silence reaches the boss's extra companion up a chain, one step per
/// pass of the spread, while the boss itself is withheld from Codex at
/// once, its narrow companion's harnesses line having dropped Codex since
/// the install. Whether extra's own companion mid is orphaned on Codex is
/// read off extra's final withholding — a silence, which takes nothing —
/// and never off the orphaning that a shorter chain would have let extra
/// hold first: mid stays on Codex whatever the chain's length.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_is_orphaned_only_by_its_requirers_final_withholding() {
    for (label, extra) in [("three steps", EXTRA_MID_X), ("one step", EXTRA_MID_Y)] {
        let (f, other) =
            two_catalogs("[hooks.boss]\nsource = \"cat\"\n\n[hooks.z]\nsource = \"other\"\n");
        for (file, body) in [
            ("boss.sh", BOSS),
            ("narrow.sh", NARROW),
            ("extra.sh", extra),
            ("mid.sh", MID),
            ("x.sh", X),
            ("y.sh", Y),
            ("z.sh", Z),
        ] {
            fs::write(f.source.join("hooks").join(file), body).unwrap();
        }
        fs::write(other.join("hooks/z.sh"), Z).unwrap();
        apply_now(&f);
        for name in ["extra", "mid", "y", "z"] {
            assert_eq!(
                landed(&f, name, HarnessId::Codex),
                (true, true),
                "{label}: {name}"
            );
        }
        fs::write(f.source.join("hooks/narrow.sh"), NARROW_CLAUDE).unwrap();
        fs::write(other.join("kendex.toml"), UNPARSABLE).unwrap();

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
            .filter(|row| row.name == "mid")
            .map(|row| (row.state, row.detail.as_str()))
            .collect();
        assert_eq!(rows, Vec::new(), "{label}: {:?}", drift_details(&report));
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(
            landed(&f, "extra", HarnessId::Codex),
            (true, true),
            "{label}: extra"
        );
        assert_eq!(
            landed(&f, "mid", HarnessId::Codex),
            (true, true),
            "{label}: mid"
        );
    }
}
