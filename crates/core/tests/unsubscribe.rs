//! Unsubscribe — remove: the closure of a source is what leaves with it
//! (declared items and their derived dependencies), computed by re-expansion,
//! and removing the source uninstalls exactly that.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::detach;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::{apply, remote, source_ops};

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, name: &str, body: &str) {
    let dir = catalog.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world(
    declarations: &str,
    extra_sources: &str,
) -> (tempfile::TempDir, Env, Scope, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n{extra_sources}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();
    (tmp, env, Scope::Project { root: project }, catalog)
}

#[allow(clippy::unwrap_used)]
fn apply_now(env: &Env, scope: &Scope) {
    let report = kendex_core::engine::audit(env, scope).unwrap();
    apply::execute(env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn manifest_of(env: &Env, scope: &Scope) -> manifest::Manifest {
    match manifest::load(&manifest::manifest_path(env, scope)).unwrap() {
        ManifestFile::Current(m) => *m,
        other => panic!("expected current manifest, got {other:?}"),
    }
}

/// A skill that requires another (a derived dependency) is part of the closure
/// even though the dependency never names the source in the manifest.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_source_takes_its_closure_including_derived_deps() {
    let (_tmp, env, scope, catalog) = world("[skills.gh]\nsource = \"cat\"\n", "");
    // gh declares a required dependency on `common`.
    skill(
        &catalog,
        "gh",
        "---\ndependencies:\n  required: [common]\n---\nbody",
    );
    // Re-write gh's SKILL.md with the dependency frontmatter (skill() wrote a
    // plain one first; overwrite it).
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: gh\ndependencies:\n  required: [common]\n---\nbody\n",
    )
    .unwrap();
    skill(&catalog, "common", "shared");
    apply_now(&env, &scope);
    assert!(scope_skill(&scope, "gh").exists());
    assert!(scope_skill(&scope, "common").exists());

    // The closure names both, and marks `common` as derived.
    let closure = detach::closure(&env, &scope, "cat", &manifest_of(&env, &scope)).unwrap();
    let names: Vec<&str> = closure.items.iter().map(|i| i.name.as_str()).collect();
    assert!(names.contains(&"gh"), "{names:?}");
    assert!(names.contains(&"common"), "{names:?}");
    assert!(
        closure
            .items
            .iter()
            .any(|i| i.name == "common" && i.derived),
        "the dependency is derived, not declared"
    );

    // Remove uninstalls the whole closure and drops the source.
    let report = detach::remove(&env, &scope, "cat", false).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    assert!(!scope_skill(&scope, "gh").exists());
    assert!(!scope_skill(&scope, "common").exists());
    assert!(!manifest_of(&env, &scope).sources.contains_key("cat"));
}

fn scope_skill(scope: &Scope, name: &str) -> std::path::PathBuf {
    let Scope::Project { root } = scope else {
        unreachable!()
    };
    root.join(".claude/skills").join(name)
}

/// Removing a source refuses while it cannot be read: a closure inferred from
/// an unreachable catalog could strand or over-sweep a derived dependency.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_an_unreachable_source_refuses() {
    let (_tmp, env, scope, catalog) = world("[skills.gh]\nsource = \"cat\"\n", "");
    skill(&catalog, "gh", "body");
    apply_now(&env, &scope);
    // Make the catalog unreadable by removing it.
    fs::remove_dir_all(&catalog).unwrap();
    let error = detach::remove(&env, &scope, "cat", false).unwrap_err();
    assert!(
        matches!(&error, CoreError::SourceMissing { name, .. } if name == "cat"),
        "{error:?}"
    );
    // The subscription is untouched by the refusal.
    assert!(manifest_of(&env, &scope).sources.contains_key("cat"));
}

/// Keeping a source's packages converts each to a local fork: the source's
/// bytes are copied into the local source, the declaration flips to `local`
/// with fork provenance, the subscription is gone, and the skill still renders
/// — now from the user's own copy.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_sources_packages_detaches_them_to_local() {
    let (_tmp, env, scope, catalog) = world("[skills.gh]\nsource = \"cat\"\n", "");
    skill(&catalog, "gh", "the gh skill");
    apply_now(&env, &scope);
    assert!(scope_skill(&scope, "gh").exists());

    let plan = detach::source(&env, &scope, "cat").unwrap();
    apply::execute(&env, &plan).unwrap();

    let manifest = manifest_of(&env, &scope);
    assert!(!manifest.sources.contains_key("cat"), "source removed");
    assert_eq!(manifest.skills["gh"].source, "local", "declared from local");
    assert!(
        manifest.forks[&ItemKind::Skill].contains_key("gh"),
        "recorded as a fork"
    );
    // The bytes landed in the local source, and the install still resolves.
    let local = kendex_core::source::local_source_root(&env, &scope);
    assert!(local.join("skills/gh/SKILL.md").exists(), "copied to local");
    // A re-plan is clean and the skill is still installed.
    let after = kendex_core::engine::audit(&env, &scope).unwrap();
    apply::execute(&env, &after.plan).unwrap();
    assert!(
        scope_skill(&scope, "gh").exists(),
        "still installed from local"
    );
}

/// Detach refuses while a package is edited, naming it: keeping it from
/// source form would silently drop the edit. One row per artifact: a
/// skill's file, and a hook script (detach compares the installed script
/// to what apply wrote, so keeping from source form cannot silently revert
/// a hook the user changed by hand).
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_an_edited_package_refuses_naming_it() {
    type Plant = fn(&Path);
    type Installed = fn(&Path) -> PathBuf;
    let rows: [(&str, &str, Plant, Installed, &str); 2] = [
        (
            "a skill",
            "[skills.gh]\nsource = \"cat\"\n",
            |catalog| skill(catalog, "gh", "the gh skill"),
            |root| root.join(".claude/skills/gh/SKILL.md"),
            "skill gh",
        ),
        (
            "a hook",
            "[hooks.guard]\nsource = \"cat\"\n",
            |catalog| {
                fs::create_dir_all(catalog.join("hooks")).unwrap();
                fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
                fs::write(
                    catalog.join("hooks/guard.sh"),
                    "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check\n# ---\nexit 0\n",
                )
                .unwrap();
            },
            |root| root.join(".claude/hooks/guard.sh"),
            "hook guard",
        ),
    ];
    for (what, declaration, plant, installed, named) in rows {
        let (_tmp, env, scope, catalog) = world(declaration, "");
        plant(&catalog);
        apply_now(&env, &scope);
        let Scope::Project { root } = &scope else {
            unreachable!()
        };
        let file = installed(root);
        assert!(file.exists(), "{what}: not installed");
        let edited = fs::read_to_string(&file).unwrap() + "\nhand edit\n";
        fs::write(&file, edited).unwrap();

        let error = detach::source(&env, &scope, "cat").unwrap_err();

        let CoreError::DetachEdited { names } = &error else {
            panic!("{what}: {error:?}");
        };
        assert_eq!(names, &[named.to_owned()], "{what}");
        assert!(
            manifest_of(&env, &scope).sources.contains_key("cat"),
            "{what}: the subscription was touched"
        );
    }
}

/// A member another marketplace's bundle still carries is not in the closure:
/// removing one source leaves a package the other keeps, because the closure is
/// the difference between the two expansions, not a read of one source's names.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_another_bundle_carries_survives_removal() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    // Two catalogs, each a bundle carrying the shared skill; cat also carries gh.
    let cat = home.join("cat");
    skill(&cat, "shared", "s");
    skill(&cat, "gh", "g");
    fs::write(
        cat.join("kendex.toml"),
        "[bundles.core]\nskills = [\"shared\", \"gh\"]\n",
    )
    .unwrap();
    let other = home.join("other");
    skill(&other, "shared", "s");
    fs::write(
        other.join("kendex.toml"),
        "[bundles.also]\nskills = [\"shared\"]\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n[sources.other]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[bundles.core]\nsource = \"cat\"\n[bundles.also]\nsource = \"other\"\n",
            source_path(&cat),
            source_path(&other)
        ),
    )
    .unwrap();
    let scope = Scope::Project { root: project };
    apply_now(&env, &scope);
    assert!(scope_skill(&scope, "shared").exists());
    assert!(scope_skill(&scope, "gh").exists());

    // cat's closure has gh but NOT shared — other's bundle still carries it.
    let closure = detach::closure(&env, &scope, "cat", &manifest_of(&env, &scope)).unwrap();
    let names: Vec<&str> = closure.items.iter().map(|i| i.name.as_str()).collect();
    assert!(names.contains(&"gh"), "{names:?}");
    assert!(
        !names.contains(&"shared"),
        "shared is kept by other: {names:?}"
    );

    let report = detach::remove(&env, &scope, "cat", false).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    assert!(!scope_skill(&scope, "gh").exists(), "gh removed with cat");
    assert!(scope_skill(&scope, "shared").exists(), "shared stays");
}

/// How an unsubscribe row leaves the source.
#[derive(Debug, Clone, Copy)]
enum Leave {
    /// `--remove-packages`: the closure is uninstalled.
    Remove,
    /// `--keep-packages`: the closure converts to local, then re-syncs.
    Keep,
}

/// How another marketplace's bundle gained a member after the install.
#[derive(Debug, Clone, Copy)]
enum Gained {
    /// A new commit on top of the recorded one: the record still places
    /// the bundle, at a commit that does not carry the member.
    PastTheRecord,
    /// The recorded commit amended away and this mirror cloned again: the
    /// record names a commit nothing here serves, so a locked write reads
    /// the bundle at the rewritten tip, which carries the member.
    RewrittenHistory,
}

/// What becomes of `shared` once the source has left.
#[derive(Debug, Clone, Copy)]
enum Shared {
    /// Uninstalled: no entry, no file.
    Uninstalled,
    /// Converted to the local source and installed from there.
    Converted,
    /// Still installed under another source's bundle, not converted.
    Kept,
}

/// A project whose bundle `core` from `cat` installed `shared`, beside
/// `other`'s bundle `also`, recorded at a commit carrying `extra` alone,
/// which then gained `shared` as `gained` says, fetched here.
#[allow(clippy::unwrap_used)]
fn installed_then_gained(gained: Gained) -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let cat = home.join("cat");
    skill(&cat, "shared", "s");
    fs::write(
        cat.join("kendex.toml"),
        "[bundles.core]\nskills = [\"shared\"]\n",
    )
    .unwrap();
    // `other` is a git catalog, so the record places its bundle at a
    // commit; at that commit the bundle carries `extra` alone.
    let other = home.join("other");
    skill(&other, "extra", "e");
    fs::write(
        other.join("kendex.toml"),
        "[bundles.also]\nskills = [\"extra\"]\n",
    )
    .unwrap();
    test_util::git(&other, &["init", "--quiet", "-b", "main"]);
    test_util::git(&other, &["add", "-A"]);
    test_util::git(&other, &["commit", "--quiet", "-m", "also carries extra"]);
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n[sources.other]\nrepo = \"file://{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[bundles.core]\nsource = \"cat\"\n[bundles.also]\nsource = \"other\"\n",
            source_path(&cat),
            other.display()
        ),
    )
    .unwrap();
    let scope = Scope::Project { root: project };
    remote::sync_sources(&env, &manifest_of(&env, &scope)).unwrap();
    apply_now(&env, &scope);
    assert!(scope_skill(&scope, "shared").exists());

    skill(&other, "shared", "s");
    fs::write(
        other.join("kendex.toml"),
        "[bundles.also]\nskills = [\"extra\", \"shared\"]\n",
    )
    .unwrap();
    test_util::git(&other, &["add", "-A"]);
    match gained {
        Gained::PastTheRecord => {
            test_util::git(&other, &["commit", "--quiet", "-m", "also carries shared"]);
        }
        Gained::RewrittenHistory => {
            test_util::git(&other, &["commit", "--quiet", "--amend", "-m", "rewritten"]);
            test_util::git(&other, &["reflog", "expire", "--expire=now", "--all"]);
            test_util::git(&other, &["gc", "--quiet", "--prune=now"]);
            fs::remove_dir_all(env.source_cache_dir()).unwrap();
        }
    }
    assert!(remote::fetch_all(&env, &manifest_of(&env, &scope)).is_empty());
    (tmp, env, scope)
}

/// A member another marketplace's bundle gained leaves with the source as
/// the removal and the re-sync after a keep read that bundle: held where the
/// record places it, which does not carry the member, so the member leaves;
/// read at the tip where the record's commit is gone, which carries it, so
/// the member stays under that bundle. A closure that reads the bundle
/// anywhere else leaves the member installed under the source that is gone,
/// or uninstalls one the plan keeps.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_another_bundle_gains_leaves_as_the_plan_reads_that_bundle() {
    struct Row {
        leave: Leave,
        gained: Gained,
        closure: &'static [&'static str],
        shared: Shared,
    }
    let rows = [
        Row {
            leave: Leave::Remove,
            gained: Gained::PastTheRecord,
            closure: &["shared"],
            shared: Shared::Uninstalled,
        },
        Row {
            leave: Leave::Keep,
            gained: Gained::PastTheRecord,
            closure: &["shared"],
            shared: Shared::Converted,
        },
        Row {
            leave: Leave::Remove,
            gained: Gained::RewrittenHistory,
            closure: &[],
            shared: Shared::Kept,
        },
    ];
    for row in rows {
        let case = format!("{:?} {:?}", row.leave, row.gained);
        let (_tmp, env, scope) = installed_then_gained(row.gained);

        let closure = detach::closure(&env, &scope, "cat", &manifest_of(&env, &scope)).unwrap();
        let names: Vec<&str> = closure.items.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, row.closure, "{case}");

        match row.leave {
            Leave::Remove => {
                let report = detach::remove(&env, &scope, "cat", false).unwrap();
                apply::execute(&env, &report.plan).unwrap();
            }
            Leave::Keep => {
                let plan = detach::source(&env, &scope, "cat").unwrap();
                apply::execute(&env, &plan).unwrap();
                let resync = detach::resync_kept(&env, &scope).unwrap();
                apply::execute(&env, &resync.plan).unwrap();
            }
        }
        let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope)).unwrap();
        let recorded: Vec<&str> = lock
            .entries
            .values()
            .filter(|entry| entry.name == "shared")
            .map(|entry| entry.source.as_str())
            .collect();
        let declared = manifest_of(&env, &scope)
            .skills
            .get("shared")
            .map(|decl| decl.source.clone());
        let installed = scope_skill(&scope, "shared").exists();
        match row.shared {
            Shared::Uninstalled => {
                assert!(recorded.is_empty(), "{case}: {recorded:?}");
                assert!(!installed, "{case}");
                assert_eq!(declared, None, "{case}");
            }
            Shared::Converted => {
                assert_eq!(recorded, ["local"], "{case}");
                assert!(installed, "{case}");
                assert_eq!(declared.as_deref(), Some("local"), "{case}");
            }
            Shared::Kept => {
                assert!(
                    recorded.len() == 1 && recorded[0] != "local",
                    "{case}: {recorded:?}"
                );
                assert!(installed, "{case}");
                assert_eq!(declared, None, "{case}");
            }
        }
        assert!(scope_skill(&scope, "extra").exists(), "{case}");
    }
}

/// A `plugin/item` name round-trips through the local source: detaching a
/// nested-name package writes it to the nested local path, the declaration
/// keeps its `plugin/item` spelling, and the local reader lists and resolves it
/// so the install re-renders from the user's own copy.
#[test]
#[allow(clippy::unwrap_used)]
fn a_nested_name_round_trips_through_detach() {
    let (_tmp, env, scope, catalog) = world("[skills.\"plugin/item\"]\nsource = \"cat\"\n", "");
    // An explicit-layout catalog with a nested skill at skills/plugin/item.
    let dir = catalog.join("skills/plugin/item");
    fs::create_dir_all(&dir).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(dir.join("SKILL.md"), "---\nname: item\n---\nnested\n").unwrap();
    apply_now(&env, &scope);

    let plan = detach::source(&env, &scope, "cat").unwrap();
    apply::execute(&env, &plan).unwrap();

    let manifest = manifest_of(&env, &scope);
    assert_eq!(manifest.skills["plugin/item"].source, "local");
    let local = kendex_core::source::local_source_root(&env, &scope);
    assert!(
        local.join("skills/plugin/item/SKILL.md").exists(),
        "written to the nested local path"
    );
    // The local reader lists and resolves the nested name, so a re-plan reads
    // it back cleanly — no drift conflict, the round-trip closed.
    let after = kendex_core::engine::audit(&env, &scope).unwrap();
    assert!(
        !after
            .drift
            .iter()
            .any(|row| row.state == kendex_core::engine::DriftState::Conflict),
        "the detached nested name reads back without conflict: {:?}",
        after.drift
    );
    apply::execute(&env, &after.plan).unwrap();
}

/// Keeping both a parent skill and a nested one under it does not write the
/// child's bytes twice: the parent's captured tree excludes the nested skill,
/// so the two land as separate local packages instead of clashing on apply.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_parent_and_a_nested_skill_does_not_clash() {
    let (_tmp, env, scope, catalog) = world(
        "[skills.plugin]\nsource = \"cat\"\n[skills.\"plugin/item\"]\nsource = \"cat\"\n",
        "",
    );
    let plugin = catalog.join("skills/plugin");
    fs::create_dir_all(plugin.join("item")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(plugin.join("SKILL.md"), "---\nname: plugin\n---\nparent\n").unwrap();
    fs::write(
        plugin.join("item/SKILL.md"),
        "---\nname: item\n---\nchild\n",
    )
    .unwrap();
    apply_now(&env, &scope);

    let plan = detach::source(&env, &scope, "cat").unwrap();
    apply::execute(&env, &plan).unwrap();

    let local = kendex_core::source::local_source_root(&env, &scope);
    assert!(local.join("skills/plugin/SKILL.md").exists());
    assert!(local.join("skills/plugin/item/SKILL.md").exists());
    // The parent's own SKILL.md says "parent"; the child was not folded in over
    // it, and both declarations now read from local.
    assert_eq!(
        fs::read_to_string(local.join("skills/plugin/SKILL.md")).unwrap(),
        "---\nname: plugin\n---\nparent\n"
    );
    let manifest = manifest_of(&env, &scope);
    assert_eq!(manifest.skills["plugin"].source, "local");
    assert_eq!(manifest.skills["plugin/item"].source, "local");
}

/// The plain "nothing installed" case still works through the ordinary source
/// removal path — a subscription with no installations just drops.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_an_empty_subscription_drops_it() {
    let (_tmp, env, scope, catalog) = world("", "");
    skill(&catalog, "gh", "body");
    let report = source_ops::remove_source(&env, &scope, "cat").unwrap();
    apply::execute(&env, &report.plan).unwrap();
    assert!(!manifest_of(&env, &scope).sources.contains_key("cat"));
}
