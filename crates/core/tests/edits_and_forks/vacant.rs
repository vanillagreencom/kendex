//! Names a fork cannot claim. Every refusal here is proven before the
//! first durable write, so a refused fork leaves the manifest
//! byte-identical and every neighbour's content as it was.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_the_scope_already_uses() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "edited").unwrap();

    let beside = |new_name: &str| {
        fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            new_name,
            None,
        )
        .unwrap_err()
    };
    let taken = beside("docs");
    assert!(
        matches!(taken, CoreError::SourceCollision { .. }),
        "{taken:?}"
    );

    let local = w.home.join("app/.kendex-local/skills/mine");
    fs::create_dir_all(&local).unwrap();
    fs::write(local.join("SKILL.md"), "---\nname: mine\n---\nTheirs.\n").unwrap();
    let stranger = beside("mine");
    assert!(
        matches!(stranger, CoreError::SourceCollision { .. }),
        "{stranger:?}"
    );
    assert_eq!(
        fs::read_to_string(local.join("SKILL.md")).unwrap(),
        "---\nname: mine\n---\nTheirs.\n"
    );

    let bad = beside("a/b/c");
    assert!(matches!(bad, CoreError::ForkNameUnusable { .. }), "{bad:?}");

    // The refusal prints the name, so an escape sequence in it reaches a
    // terminal: shown as its escape rather than run. The multi-slash arm
    // is the one that formats the whole name, so a clean first segment
    // is what carries the sequence this far.
    let said = beside("a/b\u{1b}[31m/c").to_string();
    assert!(!said.contains('\u{1b}'), "{said:?}");
    assert!(said.contains("\\u{1b}"), "{said:?}");
}

/// A derived install — a dependency or bundle member — has a lock entry
/// but no declaration of its own; its name is no less taken. A refusal
/// here writes nothing: the manifest stays byte-identical and the
/// dependency's install is untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_an_installed_dependency_holds() {
    let w = world();
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::create_dir_all(gh.parent().unwrap()).unwrap();
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nParent.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let helper = w.home.join("app/.agents/skills/helper/SKILL.md");
    assert!(helper.is_file(), "dependency installed without declaration");
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "helper",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(fs::read_to_string(&helper).unwrap().contains("Helper."));
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Mine.")
    );
}

/// Something already sitting where the fork would render — a directory
/// kendex never wrote — would make the render pass refuse after the fork
/// was recorded. It refuses up front instead, touching nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_destination_an_unmanaged_file_occupies() {
    let (w, _one, _two) = edited_world();
    let stray = w.home.join("app/.agents/skills/gh-mine");
    fs::create_dir_all(&stray).unwrap();
    fs::write(stray.join("notes.md"), "not kendex's").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/gh-mine").exists());
    assert_eq!(
        fs::read_to_string(stray.join("notes.md")).unwrap(),
        "not kendex's"
    );
}

/// A name a target tool's loader would reject records a fork and then
/// installs nothing — so the loader's own check runs first, and the
/// refusal names it.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_a_target_loader_refuses() {
    let (w, _one, _two) = edited_world();
    let before = manifest_text(&w);
    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "a..b",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/a..b").exists());
}

/// Names that fold together on a case- or composition-folding filesystem
/// are one slot: the planner would refuse both and sweep the old one, so
/// the fork refuses first. A dangling link is a taken slot too.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_and_rename_refuse_names_that_fold_onto_a_neighbour() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    write_skill(&w.upstream, "Docs", "Docs.");
    write_skill(&w.upstream, "caf\u{e9}", "Composed.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.Docs]\nsource = \"cat\"\n\n[skills.\"caf\u{e9}\"]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);
    let beside = |new_name: &str| {
        fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            new_name,
            None,
        )
        .unwrap_err()
    };
    let collides = |error: CoreError| {
        assert!(
            matches!(error, CoreError::SourceCollision { .. }),
            "{error:?}"
        );
    };

    // Case, and the decomposed spelling of a composed name.
    collides(beside("docs"));
    collides(beside("cafe\u{301}"));
    // A local-source sibling that folds the same way, and a dangling link.
    let local = w.home.join("app/.kendex-local/skills");
    fs::create_dir_all(local.join("Gh-Mine")).unwrap();
    collides(beside("gh-mine"));
    std::os::unix::fs::symlink("nowhere", local.join("gh-linked")).unwrap();
    collides(beside("gh-linked"));
    assert_eq!(manifest_text(&w), before);

    // The same rule guards a rename.
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    let renamed = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "DOCS").unwrap_err();
    collides(renamed);
    let linked =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "gh-linked").unwrap_err();
    collides(linked);
}

/// A namespaced declaration renders under a separator; a plain name that
/// spells the same rendered path is the same slot.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_that_renders_like_a_namespaced_neighbour() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.\"tools/lint\"]\nsource = \"local\"\n",
    );
    let local = w.home.join("app/.kendex-local/skills/tools/lint");
    fs::create_dir_all(&local).unwrap();
    fs::write(local.join("SKILL.md"), "---\nname: lint\n---\nLint.\n").unwrap();
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "tools-lint",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
}

/// A local-source sibling folding onto a namespaced name's own directory
/// slot is a collision too: the scan compares the slot's leaf against its
/// neighbours, not the full `plugin/item` spelling against a bare leaf.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_folding_sibling_of_a_namespaced_name() {
    let (w, _one, _two) = edited_world();
    fs::create_dir_all(w.home.join("app/.kendex-local/skills/ns/GH")).unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "ns/gh",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
}

/// A namespaced name is stored nested, so its plugin half names a
/// directory — and that directory may be a package of its own. Nothing
/// above says so: the leaf does not exist, the parent's entries are the
/// other package's own files, and `plugin` and `plugin/gh-edited` compare
/// as different names everywhere. Left to run, the capture would write the
/// fork inside that package's tree, and every later render of it would
/// carry the fork's files as its own content.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_nesting_inside_another_package() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.plugin]\nsource = \"local\"\n",
    );
    let theirs = w.home.join("app/.kendex-local/skills/plugin");
    fs::create_dir_all(&theirs).unwrap();
    let body = "---\nname: plugin\ndescription: theirs\n---\nTheirs.\n";
    fs::write(theirs.join("SKILL.md"), body).unwrap();
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "plugin/gh-edited",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert_eq!(fs::read_to_string(theirs.join("SKILL.md")).unwrap(), body);
    assert!(
        !theirs.join("gh-edited").exists(),
        "nothing was written inside the other package's tree"
    );

    // The rename path is guarded by the same rule.
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let renamed =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "plugin/gh").unwrap_err();
    assert!(
        matches!(renamed, CoreError::ForkNameUnusable { .. }),
        "{renamed:?}"
    );
}

/// A plugin directory that is only a namespace — it holds other namespaced
/// packages but is not one itself — is where namespaced forks are supposed
/// to land. The refusal above must not reach this.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_lands_a_namespaced_name_in_a_plain_namespace_directory() {
    let (w, _one, _two) = edited_world();
    let neighbour = w.home.join("app/.kendex-local/skills/ns/lint");
    fs::create_dir_all(&neighbour).unwrap();
    let body = "---\nname: lint\ndescription: lint\n---\nLint.\n";
    fs::write(neighbour.join("SKILL.md"), body).unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "ns/gh-edited",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();

    let own = fs::read_to_string(
        w.home
            .join("app/.kendex-local/skills/ns/gh-edited/SKILL.md"),
    )
    .unwrap();
    assert!(own.contains("My fork."), "{own}");
    assert_eq!(
        fs::read_to_string(neighbour.join("SKILL.md")).unwrap(),
        body
    );
}

/// A symlinked plugin directory is the same hole with an escape attached:
/// the leaf under it does not exist, so every check above passes, and the
/// capture would write the fork wherever the link points. The sealed
/// reader refuses to look through a link inside a source, so those bytes
/// would be bytes kendex could never read back.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_slot_reached_through_a_link() {
    let (w, _one, _two) = edited_world();
    let outside = w.home.join("outside");
    fs::create_dir_all(&outside).unwrap();
    let local = w.home.join("app/.kendex-local/skills");
    fs::create_dir_all(&local).unwrap();
    std::os::unix::fs::symlink(&outside, local.join("ns")).unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "ns/gh-edited",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(
        fs::read_dir(&outside).unwrap().next().is_none(),
        "nothing was written through the link"
    );
}
