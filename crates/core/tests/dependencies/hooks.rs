//! A hook requiring another: the `requires:` line of its header goes through
//! the same walk a skill's `dependencies` do, so declaring one hook of a set
//! installs the set. Where the walk finds a companion that will not be
//! written beside its parent, the consequence is the hook's own: a wrapper
//! run beside no judge refuses every call it guards, so the parent is
//! withheld from that tool and its finding says why.

use super::*;

/// A wrapper that runs the judge from beside itself, and the judge that
/// names both wrappers back: the same knot the catalog's lane-mail hooks
/// tie, with the smallest bodies that parse.
const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: Stop\n# description: judge the turn end\n# requires: [deliver, halt]\n# ---\nexit 0\n";
const DELIVER: &str = "#!/usr/bin/env bash\n# ---\n# name: deliver\n# event: PostToolUse\n# description: hand mail over after a tool call\n# requires: [judge]\n# ---\nexit 0\n";
const HALT: &str = "#!/usr/bin/env bash\n# ---\n# name: halt\n# event: PreToolUse\n# description: refuse a tool call while a halt stands\n# requires: [judge]\n# ---\nexit 0\n";
/// A hook naming a companion the catalog does not offer.
const LONELY: &str = "#!/usr/bin/env bash\n# ---\n# name: lonely\n# event: PreToolUse\n# description: run beside a hook that is not there\n# requires: [absent]\n# ---\nexit 0\n";
/// The judge with its header gone: the plan cannot read it.
const BROKEN_JUDGE: &str = "#!/usr/bin/env bash\nexit 0\n";
/// The judge and the wrapper each with a harnesses line of its own that
/// leaves Codex out.
const NARROW_JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: Stop\n# description: judge the turn end\n# harnesses: [claude]\n# requires: [deliver, halt]\n# ---\nexit 0\n";
const NARROW_DELIVER: &str = "#!/usr/bin/env bash\n# ---\n# name: deliver\n# event: PostToolUse\n# description: hand mail over after a tool call\n# harnesses: [claude]\n# requires: [judge]\n# ---\nexit 0\n";

/// The skill fixture's catalog with the hooks added, installing for two
/// tools so a companion declared for one of them leaves the other short.
#[allow(clippy::unwrap_used)]
fn hook_fixture(declarations: &str) -> Fixture {
    let f = fixture(declarations);
    let hooks = f.source.join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(hooks.join("judge.sh"), JUDGE).unwrap();
    fs::write(hooks.join("deliver.sh"), DELIVER).unwrap();
    fs::write(hooks.join("halt.sh"), HALT).unwrap();
    fs::write(hooks.join("lonely.sh"), LONELY).unwrap();
    // Executable kinds resolve only in a catalog that declares kendex's
    // layout; the skill fixture is discovered, so this one says so.
    fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    declare(&f, declarations);
    f
}

/// The project's manifest rewritten around new declarations.
#[allow(clippy::unwrap_used)]
fn declare(f: &Fixture, declarations: &str) {
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&f.source)
        ),
    )
    .unwrap();
}

/// Where one tool keeps a hook's script and its registration.
fn hook_paths(harness: HarnessId) -> (&'static str, &'static str) {
    match harness {
        HarnessId::Claude => (".claude/hooks", ".claude/settings.json"),
        HarnessId::Codex => (".codex/hooks", ".codex/hooks.json"),
        other => unreachable!("the fixture installs for Claude and Codex, not {other:?}"),
    }
}

fn hook_on_disk(f: &Fixture, harness: HarnessId, file: &str) -> bool {
    f.project.join(hook_paths(harness).0).join(file).exists()
}

/// Whether the tool's settings run the hook: a script kept on disk but not
/// registered, or registered but not on disk, is a half the plan never
/// leaves.
fn registered(f: &Fixture, harness: HarnessId, name: &str) -> bool {
    fs::read_to_string(f.project.join(hook_paths(harness).1))
        .is_ok_and(|settings| settings.contains(&format!("{name}.sh")))
}

fn required_by_hook(name: &str) -> Reason {
    Reason::RequiredBy {
        by: kendex_core::lock::InstallRef {
            source: "cat".to_owned(),
            kind: ItemKind::Hook,
            name: name.to_owned(),
            harness: HarnessId::Claude,
        },
    }
}

/// The findings on one item.
fn findings_on<'a>(
    report: &'a kendex_core::engine::EngineReport,
    parent: &str,
) -> Vec<&'a kendex_core::engine::ItemWarning> {
    report
        .warnings
        .iter()
        .filter(|w| w.name == parent)
        .collect()
}

/// One wrapper declared alone brings in the judge it runs, and the judge
/// brings in the other wrapper: the whole set installs and registers, each
/// record saying which hook wanted it, and the manifest still holds only
/// the one choice.
#[test]
#[allow(clippy::unwrap_used)]
fn declaring_one_hook_of_a_set_installs_its_companions() {
    let f = hook_fixture("[hooks.deliver]\nsource = \"cat\"\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.warnings.is_empty(), "{:?}", report.warnings);
    assert!(
        report
            .notes
            .iter()
            .any(|note| note == "installing deliver also installs halt, judge (required)"),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();

    for name in ["judge", "deliver", "halt"] {
        for harness in [HarnessId::Claude, HarnessId::Codex] {
            assert!(
                hook_on_disk(&f, harness, &format!("{name}.sh")) && registered(&f, harness, name),
                "{name} is not installed and registered for {harness:?}"
            );
        }
    }
    let lock = lock_of(&f);
    assert_eq!(
        lock.entries["hook:deliver:claude"].reasons,
        BTreeSet::from([Reason::Requested, required_by_hook("judge")])
    );
    assert_eq!(
        lock.entries["hook:judge:claude"].reasons,
        BTreeSet::from([required_by_hook("deliver"), required_by_hook("halt")])
    );
    assert_eq!(
        lock.entries["hook:halt:claude"].reasons,
        BTreeSet::from([required_by_hook("judge")])
    );
    let manifest = manifest_of(&f);
    assert!(manifest.hooks.contains_key("deliver"));
    assert!(!manifest.hooks.contains_key("judge") && !manifest.hooks.contains_key("halt"));
}

/// A declared set is a plan with nothing to add: every hook is asked for,
/// and the walk only records that each also requires the others.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fully_declared_set_proceeds_with_nothing_missing() {
    let f = hook_fixture(
        "[hooks.judge]\nsource = \"cat\"\n\n[hooks.deliver]\nsource = \"cat\"\n\n[hooks.halt]\nsource = \"cat\"\n",
    );
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.warnings.is_empty(), "{:?}", report.warnings);
    apply::execute(&f.env, &report.plan).unwrap();

    let lock = lock_of(&f);
    assert_eq!(
        lock.entries["hook:judge:claude"].reasons,
        BTreeSet::from([
            Reason::Requested,
            required_by_hook("deliver"),
            required_by_hook("halt")
        ])
    );
    assert_eq!(
        lock.entries["hook:deliver:claude"].reasons,
        BTreeSet::from([Reason::Requested, required_by_hook("judge")])
    );
}

/// The declarations and the catalog bytes of the judge and the deliver
/// wrapper; the wrapper judged, and the message and remedy of the one
/// finding on it, if any; and whether the wrapper lands on Claude Code and
/// on Codex.
struct Row {
    declarations: &'static str,
    judge: &'static str,
    deliver: &'static str,
    parent: &'static str,
    finding: Option<(&'static str, &'static str)>,
    lands: [bool; 2],
}
fn rows() -> [Row; 8] {
    [
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n\n[suppressed]\nhook = [\"judge\"]\n",
            judge: JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: deliver requires judge, which is kept removed",
                "add the hook judge again to restore it, or drop it from deliver's dependencies",
            )),
            lands: [false, false],
        },
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"cat\"\nenabled = false\n",
            judge: JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: deliver requires judge, which is switched off",
                "set enabled = true on judge's declaration in kendex.toml, or drop it from deliver's dependencies",
            )),
            lands: [false, false],
        },
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n",
            judge: BROKEN_JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: deliver requires judge, whose header cannot be read: hook script has no `# ---` frontmatter block",
                "repair judge's header in the catalog 'cat', or drop it from deliver's dependencies",
            )),
            lands: [false, false],
        },
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
            judge: JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: Codex runs deliver without judge, which it requires",
                "declare judge for Codex too",
            )),
            lands: [true, false],
        },
        Row {
            declarations: "[hooks.lonely]\nsource = \"cat\"\n",
            judge: JUDGE,
            deliver: DELIVER,
            parent: "lonely",
            finding: Some((
                "lonely requires absent, which the catalog 'cat' does not offer",
                "add absent to that catalog, or drop it from lonely's dependencies",
            )),
            lands: [false, false],
        },
        // The judge is withheld for the other wrapper's sake, and this one
        // requires the judge: the withholding reaches it through the knot.
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n\n[suppressed]\nhook = [\"halt\"]\n",
            judge: JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: deliver requires judge, which is withheld from Claude Code and Codex",
                "settle the finding on judge",
            )),
            lands: [false, false],
        },
        // The judge's own harnesses line leaves Codex out, so the plan
        // never writes it there, whatever the manifest says.
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n",
            judge: NARROW_JUDGE,
            deliver: DELIVER,
            parent: "deliver",
            finding: Some((
                "missing required dependency: Codex runs deliver without judge, whose own harnesses line leaves Codex out",
                "add Codex to judge's harnesses line in the catalog, or list deliver's harnesses in kendex.toml without Codex",
            )),
            lands: [true, false],
        },
        // The wrapper's own harnesses line leaves Codex out: it never runs
        // there, so a judge declared for Claude Code alone is not missing.
        Row {
            declarations: "[hooks.deliver]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
            judge: JUDGE,
            deliver: NARROW_DELIVER,
            parent: "deliver",
            finding: None,
            lands: [true, false],
        },
    ]
}

/// Each way a companion fails to land beside the wrapper that needs it:
/// kept removed, switched off, a header the plan cannot read, declared for
/// fewer tools, not in the catalog at all, or itself withheld because a
/// hook it requires is. The finding on the wrapper names the companion and
/// the state, the plan is incomplete, and the wrapper is neither written
/// nor registered on the tools the companion misses — and stays installed
/// where it does not.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_that_will_not_land_withholds_the_hook_that_needs_it() {
    for Row {
        declarations,
        judge,
        deliver,
        parent,
        finding,
        lands: [on_claude, on_codex],
    } in rows()
    {
        let f = hook_fixture(declarations);
        fs::write(f.source.join("hooks/judge.sh"), judge).unwrap();
        fs::write(f.source.join("hooks/deliver.sh"), deliver).unwrap();
        let report = audit(&f.env, &f.scope).unwrap();
        let findings = findings_on(&report, parent);
        let found: Vec<(&str, Option<&str>)> = findings
            .iter()
            .map(|w| (w.message.as_str(), w.remediation.as_deref()))
            .collect();
        let expected: Vec<(&str, Option<&str>)> = finding
            .iter()
            .map(|(message, remediation)| (*message, Some(*remediation)))
            .collect();
        assert_eq!(found, expected, "{declarations}: {:?}", report.warnings);
        assert!(
            findings.iter().all(|w| w.kind == ItemKind::Hook),
            "{declarations}"
        );
        let status = match finding {
            Some(_) => kendex_core::engine::DeclarationStatus::Incomplete,
            None => kendex_core::engine::DeclarationStatus::Complete,
        };
        assert_eq!(report.declaration_status, status, "{declarations}");
        if finding.is_some() {
            assert!(
                !report
                    .notes
                    .iter()
                    .any(|note| note.contains("also installs")),
                "{declarations}: a co-install note claims what was withheld: {:?}",
                report.notes
            );
        }
        apply::execute(&f.env, &report.plan).unwrap();
        let file = format!("{parent}.sh");
        for (harness, lands) in [(HarnessId::Claude, on_claude), (HarnessId::Codex, on_codex)] {
            assert_eq!(
                (
                    hook_on_disk(&f, harness, &file),
                    registered(&f, harness, parent)
                ),
                (lands, lands),
                "{declarations}: {parent} on {harness:?} (written, registered)"
            );
        }
        assert!(
            !hook_on_disk(&f, HarnessId::Claude, "absent.sh"),
            "{declarations}: a name the catalog lacks was written"
        );
    }
}

/// A skill keeps the walk's older consequence: the parent installs and the
/// finding is the whole answer, in the words the skill rows already pin.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_whose_dependency_is_kept_removed_still_installs() {
    let f = hook_fixture("[skills.dev]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"github\"]\n");
    let report = audit(&f.env, &f.scope).unwrap();
    let found: Vec<(&str, Option<&str>)> = findings_on(&report, "dev")
        .iter()
        .map(|w| (w.message.as_str(), w.remediation.as_deref()))
        .collect();
    assert_eq!(
        found,
        [(
            "missing required dependency: dev requires github, which is kept removed",
            Some("add the skill github again to restore it, or drop it from dev's dependencies"),
        )]
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "dev") && !installed(&f, "github"));
}

/// Switching the judge off switches off the wrappers that exist only
/// because of it: every file lands under its `.disabled` name, nothing is
/// registered, and nothing is missing, since a hook that is off arms
/// nothing beside its judge.
#[test]
#[allow(clippy::unwrap_used)]
fn switching_a_hook_off_switches_off_the_companions_it_brought_in() {
    let f = hook_fixture("[hooks.judge]\nsource = \"cat\"\nenabled = false\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.warnings.is_empty(), "{:?}", report.warnings);
    apply::execute(&f.env, &report.plan).unwrap();
    for name in ["judge", "deliver", "halt"] {
        for harness in [HarnessId::Claude, HarnessId::Codex] {
            assert!(
                hook_on_disk(&f, harness, &format!("{name}.sh.disabled")),
                "{name} is not parked as disabled for {harness:?}"
            );
            assert!(
                !hook_on_disk(&f, harness, &format!("{name}.sh")),
                "{name} was written switched on for {harness:?}"
            );
            assert!(
                !registered(&f, harness, name),
                "{name} is registered for {harness:?}"
            );
        }
    }
}

/// An installed set whose judge is then switched off loses its wrappers
/// under every set of plan options a shipped command uses, and under the
/// toggle the app calls: the next plan takes their scripts and
/// registrations away rather than leaving a gate armed beside a judge that
/// no longer runs, and never leaves them to a sweep an option may skip.
#[test]
#[allow(clippy::unwrap_used)]
fn the_wrappers_come_out_once_the_judge_is_switched_off() {
    type Switch = fn(&Fixture) -> kendex_core::engine::EngineReport;
    const FULL: &str = "[hooks.judge]\nsource = \"cat\"\n\n[hooks.deliver]\nsource = \"cat\"\n\n[hooks.halt]\nsource = \"cat\"\n";
    const JUDGE_OFF: &str = "[hooks.judge]\nsource = \"cat\"\nenabled = false\n\n[hooks.deliver]\nsource = \"cat\"\n\n[hooks.halt]\nsource = \"cat\"\n";
    // How the judge is switched off and the plan made: a hand edit followed
    // by each shipped option set, and the app's toggle.
    let rows: [(&str, Switch); 4] = [
        ("audit after a hand edit", |f| {
            declare(f, JUDGE_OFF);
            audit(&f.env, &f.scope).unwrap()
        }),
        ("apply's options after a hand edit", |f| {
            declare(f, JUDGE_OFF);
            plan_apply(
                &f.env,
                &f.scope,
                &PlanOptions {
                    remove_orphans: true,
                    ..PlanOptions::default()
                },
            )
            .unwrap()
        }),
        ("refresh's options after a hand edit", |f| {
            declare(f, JUDGE_OFF);
            plan_apply(
                &f.env,
                &f.scope,
                &PlanOptions {
                    sweep_unneeded: true,
                    ..PlanOptions::default()
                },
            )
            .unwrap()
        }),
        ("the toggle", |f| {
            ops::toggle(
                &f.env,
                &f.scope,
                &["judge".to_owned()],
                Some(ItemKind::Hook),
                false,
            )
            .unwrap()
        }),
    ];
    for (label, switch) in rows {
        let f = hook_fixture(FULL);
        apply_now(&f);
        assert!(
            hook_on_disk(&f, HarnessId::Claude, "halt.sh")
                && registered(&f, HarnessId::Claude, "halt"),
            "{label}: the set did not install"
        );

        let report = switch(&f);
        assert_eq!(
            report.declaration_status,
            kendex_core::engine::DeclarationStatus::Incomplete,
            "{label}"
        );
        apply::execute(&f.env, &report.plan).unwrap();
        for harness in [HarnessId::Claude, HarnessId::Codex] {
            for name in ["deliver", "halt"] {
                assert!(
                    !hook_on_disk(&f, harness, &format!("{name}.sh")),
                    "{label}: {name} stayed written for {harness:?}"
                );
                assert!(
                    !registered(&f, harness, name),
                    "{label}: {name} stayed registered for {harness:?}"
                );
            }
            assert!(
                hook_on_disk(&f, harness, "judge.sh.disabled"),
                "{label}: the judge is not parked for {harness:?}"
            );
        }
    }
}
