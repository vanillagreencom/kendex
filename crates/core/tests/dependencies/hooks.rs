//! A hook requiring another: the `requires:` line of its header goes through
//! the same walk a skill's `dependencies` do, so declaring one hook of a set
//! installs the set, and keeping one of them removed is a refusal on the
//! hook that needs it, named the way a skill's is.

use super::*;

/// A wrapper that runs the judge from beside itself, and the judge that
/// names both wrappers back: the same knot the catalog's lane-mail hooks
/// tie, with the smallest bodies that parse.
const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: Stop\n# description: judge the turn end\n# requires: [deliver, halt]\n# ---\nexit 0\n";
const DELIVER: &str = "#!/usr/bin/env bash\n# ---\n# name: deliver\n# event: PostToolUse\n# description: hand mail over after a tool call\n# requires: [judge]\n# ---\nexit 0\n";
const HALT: &str = "#!/usr/bin/env bash\n# ---\n# name: halt\n# event: PreToolUse\n# description: refuse a tool call while a halt stands\n# requires: [judge]\n# ---\nexit 0\n";

#[allow(clippy::unwrap_used)]
fn hook_fixture(declarations: &str) -> Fixture {
    let f = fixture(declarations);
    let hooks = f.source.join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(hooks.join("judge.sh"), JUDGE).unwrap();
    fs::write(hooks.join("deliver.sh"), DELIVER).unwrap();
    fs::write(hooks.join("halt.sh"), HALT).unwrap();
    // Executable kinds resolve only in a catalog that declares kendex's
    // layout; the skill fixture is discovered, so this one says so.
    fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    f
}

fn hook_installed(f: &Fixture, name: &str) -> bool {
    f.project
        .join(".claude/hooks")
        .join(format!("{name}.sh"))
        .exists()
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

/// One wrapper declared alone brings in the judge it runs, and the judge
/// brings in the other wrapper: the whole set installs, each record saying
/// which hook wanted it, and the manifest still holds only the one choice.
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
        assert!(hook_installed(&f, name), "{name} is not installed");
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

/// The refusal is the one the skill walk owns, word for word, on the hook
/// that needs what is kept removed and naming both hooks; the plan is
/// marked incomplete and the companion is never written. The skill row
/// beside it pins the same sentence for a skill, so a change to either
/// wording turns one row red.
#[test]
#[allow(clippy::unwrap_used)]
fn a_companion_kept_removed_is_refused_naming_both() {
    // Declarations, the parent's kind and name, the companion kept removed,
    // and the message and remediation the parent's finding carries.
    let rows: [(&str, ItemKind, &str, &str, &str, &str); 2] = [
        (
            "[hooks.deliver]\nsource = \"cat\"\n\n[suppressed]\nhook = [\"judge\"]\n",
            ItemKind::Hook,
            "deliver",
            "judge",
            "missing required dependency: deliver requires judge, which is kept removed",
            "add the hook judge again to restore it, or drop it from deliver's dependencies",
        ),
        (
            "[skills.dev]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"github\"]\n",
            ItemKind::Skill,
            "dev",
            "github",
            "missing required dependency: dev requires github, which is kept removed",
            "add the skill github again to restore it, or drop it from dev's dependencies",
        ),
    ];
    for (declarations, kind, parent, companion, message, remediation) in rows {
        let f = hook_fixture(declarations);
        let report = audit(&f.env, &f.scope).unwrap();
        let refusals: Vec<_> = report
            .warnings
            .iter()
            .filter(|w| w.message.starts_with("missing required dependency"))
            .collect();
        assert_eq!(refusals.len(), 1, "{declarations}: {:?}", report.warnings);
        assert_eq!(refusals[0].kind, kind, "{declarations}");
        assert_eq!(refusals[0].name, parent, "{declarations}");
        assert_eq!(refusals[0].message, message, "{declarations}");
        assert_eq!(
            refusals[0].remediation.as_deref(),
            Some(remediation),
            "{declarations}"
        );
        assert_eq!(
            report.declaration_status,
            kendex_core::engine::DeclarationStatus::Incomplete,
            "{declarations}"
        );
        apply::execute(&f.env, &report.plan).unwrap();
        let on_disk = |name: &str| match kind {
            ItemKind::Hook => hook_installed(&f, name),
            ItemKind::Skill => installed(&f, name),
            other => unreachable!("the rows hold hooks and skills, not {other:?}"),
        };
        assert!(
            on_disk(parent),
            "{declarations}: {parent} was not installed"
        );
        assert!(
            !on_disk(companion),
            "{declarations}: {companion} was written"
        );
    }
}
