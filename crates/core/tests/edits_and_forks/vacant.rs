//! Names a fork cannot claim. Every refusal here is proven before the
//! first durable write, so a refused fork leaves the manifest
//! byte-identical and every neighbour's content as it was.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// The three places a name can already be taken, asked once each: this
/// scope's manifest, its lock — a dependency or bundle member installs
/// without a declaration of its own and its name is no less taken — and
/// the local source's own slot. A name no item may carry is refused
/// before any of them.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_the_scope_already_uses() {
    let w = world();
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::create_dir_all(gh.parent().unwrap()).unwrap();
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nParent.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    let helper = w.home.join("app/.agents/skills/helper/SKILL.md");
    assert!(helper.is_file(), "dependency installed without declaration");
    fs::write(skill_file(&w), "edited").unwrap();
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
    let declared = beside("docs");
    assert!(
        matches!(declared, CoreError::SourceCollision { .. }),
        "{declared:?}"
    );
    let installed = beside("helper");
    assert!(
        matches!(installed, CoreError::SourceCollision { .. }),
        "{installed:?}"
    );

    let local = w.home.join("app/.kendex-local/skills/mine");
    fs::create_dir_all(&local).unwrap();
    fs::write(local.join("SKILL.md"), "---\nname: mine\n---\nTheirs.\n").unwrap();
    let stranger = beside("mine");
    assert!(
        matches!(stranger, CoreError::SourceCollision { .. }),
        "{stranger:?}"
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

    // Nothing was written for any of them.
    assert_eq!(manifest_text(&w), before);
    assert_eq!(
        fs::read_to_string(local.join("SKILL.md")).unwrap(),
        "---\nname: mine\n---\nTheirs.\n"
    );
    assert!(fs::read_to_string(&helper).unwrap().contains("Helper."));
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

/// A rename proves its DESTINATION reachable, not only the slot it is
/// leaving. `Op::Rename`'s absence precondition follows a symlinked
/// ancestor, and the scope check catches only an escape past the scope
/// root, so a link inside the scope lands the bytes where no later read
/// of this source finds them and the declaration names a path that is
/// gone.
#[test]
#[allow(clippy::unwrap_used)]
fn rename_refuses_a_destination_reached_through_a_link() {
    let (w, _one, _two) = edited_world();
    let elsewhere = w.home.join("app/elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let local = w.home.join("app/.kendex-local/skills");
    std::os::unix::fs::symlink(&elsewhere, local.join("ns")).unwrap();
    let before = manifest_text(&w);

    let refused = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "ns/gh").unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(
        fs::read_dir(&elsewhere).unwrap().next().is_none(),
        "nothing was written through the link"
    );
    assert!(
        local.join("gh/SKILL.md").is_file(),
        "the fork it was leaving is still there"
    );
}

/// A slot the filesystem will not describe is not an empty slot. An
/// unsearchable directory above it answers neither yes nor no about what
/// is in the name's way, and a guard reading that as vacancy is a guard
/// that writes over what it exists to protect. The refusal reaches the
/// caller.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_slot_the_filesystem_will_not_describe() {
    use std::os::unix::fs::PermissionsExt;
    let (w, _one, _two) = edited_world();
    let local = w.home.join("app/.kendex-local/skills");
    fs::create_dir_all(&local).unwrap();
    fs::set_permissions(&local, fs::Permissions::from_mode(0o644)).unwrap();
    // Root probes any path whatever the mode, so there the denial under
    // test does not exist and the fork simply plans.
    let denied = fs::metadata(local.join("gh-mine")).is_err()
        && !matches!(
            fs::metadata(local.join("gh-mine")).unwrap_err().kind(),
            std::io::ErrorKind::NotFound
        );
    let asked = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    );
    fs::set_permissions(&local, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => assert!(
            matches!(asked, Err(CoreError::Io { .. })),
            "an unreadable render destination must reach the caller as a refusal: {asked:?}"
        ),
        false => assert!(asked.is_ok(), "{asked:?}"),
    }
}

/// A copy delivery writes a skill into each tool's own directory, not the
/// shared `.agents/skills` tree, so that is where an unmanaged file stands
/// in the fork's way. Asking the shared tree alone would record the fork
/// and leave the render pass to meet the occupant — the very sequence the
/// destination check exists to prevent, reached through a delivery method
/// rather than through a name. opencode is the fixture because it reads
/// both trees; a tool with one surface cannot tell the two apart.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_an_occupant_of_a_copy_deliverys_destination() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let own = w.home.join("app/.opencode/skills/gh");
    assert!(
        own.join("SKILL.md").is_file(),
        "the fixture proves nothing unless a copy lands in the tool's own directory"
    );
    assert!(
        !w.home.join("app/.agents/skills/gh").exists(),
        "and nothing unless the shared tree is a different path"
    );
    fs::write(own.join("SKILL.md"), "edited").unwrap();

    let stray = w.home.join("app/.opencode/skills/gh-mine");
    fs::create_dir_all(&stray).unwrap();
    fs::write(stray.join("notes.md"), "not kendex's").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Opencode,
        "gh-mine",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(&refused, CoreError::ForkNameUnusable { problem, .. }
            if problem.contains(".opencode/skills/gh-mine")),
        "the refusal must name the copy destination, not some other path: {refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert_eq!(
        fs::read_to_string(stray.join("notes.md")).unwrap(),
        "not kendex's"
    );
}

/// A render destination the filesystem will not describe is not a
/// destination proven empty, for the same reason the slot above is not.
/// An unsearchable parent answers neither yes nor no, and the refusal
/// reaches the caller rather than passing the check.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_render_destination_it_cannot_describe() {
    use std::os::unix::fs::PermissionsExt;
    let (w, _one, _two) = edited_world();
    let shared = w.home.join("app/.agents/skills");
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o644)).unwrap();
    // Root probes any path whatever the mode, so there the denial under
    // test does not exist and the fork simply plans.
    let denied = fs::metadata(shared.join("gh-mine"))
        .err()
        .is_some_and(|e| e.kind() != std::io::ErrorKind::NotFound);
    let asked = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    );
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => assert!(
            matches!(asked, Err(CoreError::Io { .. })),
            "an unreadable render destination must reach the caller as a refusal: {asked:?}"
        ),
        false => assert!(asked.is_ok(), "{asked:?}"),
    }
}

/// A kind with no fork path is refused before its name is judged. Every
/// question `vacant_name` asks is asked in terms of how the kind renders,
/// so a hook answered in a skill's vocabulary is answered wrongly — and
/// the capture that would have refused it runs several statements later.
/// The hook is declared, so the lookup before `vacant_name` is satisfied
/// and the ordering is what the case observes: ungated, the refusal that
/// comes back is about the name.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_an_unsupported_kind_before_it_judges_the_name() {
    let w = world();
    let hook = w.upstream.join("hooks/deploy.sh");
    fs::create_dir_all(hook.parent().unwrap()).unwrap();
    fs::write(&hook, "#!/bin/sh\necho ship\n").unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    commit(&w.upstream, "one");
    declare(&w, "[hooks.deploy]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Hook,
        "deploy",
        HarnessId::Claude,
        // An illegal name, so a refusal about the name is the one that
        // comes back if the kind is judged second.
        "a/b/c",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(&refused, CoreError::ItemNotInSource { source_name, .. }
            if source_name.contains("fork does not support")),
        "{refused:?}"
    );
}

/// A fork entry does not prove the kind. Detach writes one for every kind
/// it converts, so a command carries `[forks.command.<name>]` without the
/// fork path ever running — and a rename has no capture step behind it to
/// refuse the kind later. Left ungated, the rename judges a Gemini
/// command's destinations as if they were an agent's `.md`, misses the
/// stranger at the `.toml` the render actually writes, and records a name
/// that installs nowhere while stranding the old file.
#[test]
#[allow(clippy::unwrap_used)]
fn rename_refuses_a_kind_no_fork_path_supports() {
    let w = world();
    let command = w.upstream.join("commands/deploy.md");
    fs::create_dir_all(command.parent().unwrap()).unwrap();
    fs::write(&command, "---\ndescription: deploy\n---\nShip it.\n").unwrap();
    // Commands install only from a catalog that declares kendex's layout.
    fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[commands.deploy]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let rendered = w.home.join("app/.gemini/commands/deploy.toml");
    assert!(
        rendered.is_file(),
        "the fixture proves nothing unless the command renders to a .toml, \
         which is not the spelling render_targets would derive for it"
    );

    // Detach converts it to a local package and records the fork entry.
    let plan = kendex_core::engine::detach::source(&w.env, &w.scope, "cat").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    assert!(
        manifest_text(&w).contains("[forks.command.deploy]"),
        "the fixture proves nothing unless detach wrote a command fork entry: {}",
        manifest_text(&w)
    );

    // A stranger sits where the renamed command would render.
    let stray = w.home.join("app/.gemini/commands/renamed.toml");
    fs::write(&stray, "not kendex's").unwrap();
    let before = manifest_text(&w);

    let refused =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Command, "deploy", "renamed").unwrap_err();
    assert!(
        matches!(&refused, CoreError::ItemNotInSource { source_name, .. }
            if source_name.contains("fork does not support")),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before, "nothing was recorded");
    assert_eq!(fs::read_to_string(&stray).unwrap(), "not kendex's");
    assert!(rendered.is_file(), "the original was left where it was");
}

/// All three fork verbs answer an unforkable kind the same way. `fork`
/// reached the refusal from inside its capture step, several statements
/// after two other refusals could have spoken first, so the same
/// two-way-wrong input got a different answer from each verb.
#[test]
#[allow(clippy::unwrap_used)]
fn every_fork_verb_refuses_an_unsupported_kind_alike() {
    let (w, _one, _two) = edited_world();
    let says_kind = |error: &CoreError| {
        matches!(error, CoreError::ItemNotInSource { source_name, .. }
            if source_name.contains("fork does not support"))
    };
    // Undeclared under that kind, so a verb judging declaration first
    // answers NotDeclared instead.
    let forked = fork::fork(&w.env, &w.scope, ItemKind::Hook, "gh", HarnessId::Claude).unwrap_err();
    assert!(says_kind(&forked), "{forked:?}");
    let beside = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Hook,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    )
    .unwrap_err();
    assert!(says_kind(&beside), "{beside:?}");
    let renamed = fork::rename_fork(&w.env, &w.scope, ItemKind::Hook, "gh", "gh-mine").unwrap_err();
    assert!(says_kind(&renamed), "{renamed:?}");
}

/// A copy delivery writes into each tool's own directory and never into
/// the shared tree, so the shared tree is not one of the fork's
/// destinations and a stranger sitting there is not in its way. Probing it
/// anyway refuses a fork that would have landed cleanly — the same
/// distinction `unmanaged.rs` draws when it asks what a declaration owns.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_ignores_the_shared_tree_for_a_copy_delivery() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let own = w.home.join("app/.claude/skills/gh");
    assert!(
        own.join("SKILL.md").is_file(),
        "the fixture proves nothing unless the copy lands in the tool's own directory"
    );
    fs::write(
        own.join("SKILL.md"),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();

    // A stranger in the shared tree, which this delivery never writes.
    let shared = w.home.join("app/.agents/skills/gh-mine");
    fs::create_dir_all(&shared).unwrap();
    fs::write(shared.join("notes.md"), "not kendex's").unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    )
    .unwrap_or_else(|error| panic!("a path this delivery never writes refused the fork: {error}"));
    apply::execute(&w.env, &plan).unwrap();
    assert!(
        w.home
            .join("app/.kendex-local/skills/gh-mine/SKILL.md")
            .is_file()
    );
    assert_eq!(
        fs::read_to_string(shared.join("notes.md")).unwrap(),
        "not kendex's"
    );
}
