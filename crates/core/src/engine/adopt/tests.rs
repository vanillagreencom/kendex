use std::fs;

use super::*;

mod links;
mod slots;

/// Nothing has been moved into the trash. Its directory is created on
/// demand, so an absent one counts.
pub(super) fn trash_is_empty(env: &Env) -> bool {
    fs::read_dir(env.trash_dir()).is_ok_and(|mut d| d.next().is_none()) || !env.trash_dir().exists()
}
use crate::engine::audit;
use crate::env::FakeOs;

#[test]
fn adopting_a_handmade_skill_moves_merges_and_round_trips() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(
        project.join(".claude/skills/handmade/SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
    )
    .unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    // The real directory moved into the shared tree — the content of
    // record, not a copy of it — and nothing was left where it was.
    assert!(project.join(".agents/skills/handmade/SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(!project.join(".claude/skills/handmade").exists());

    // Follow-up apply renders the managed replacement, drift-clean.
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    let link = project.join(".claude/skills/handmade");
    assert!(link.is_symlink());
    let rendered = fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md")).unwrap();
    assert!(rendered.contains("My content."));
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// The shared tree already held something under that name: it is trashed,
/// never written over, so nothing adoption replaces is gone for good.
#[test]
fn an_earlier_copy_at_the_home_goes_to_the_trash_not_under_the_new_one() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let earlier = project.join(".agents/skills/handmade");
    fs::create_dir_all(&earlier).unwrap();
    fs::write(earlier.join("SKILL.md"), "earlier").unwrap();
    fs::write(earlier.join("notes.md"), "kept only here").unwrap();
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(project.join(".claude/skills/handmade/SKILL.md"), "observed").unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    assert_eq!(
        fs::read_to_string(earlier.join("SKILL.md")).unwrap(),
        "observed"
    );
    assert!(!earlier.join("notes.md").exists());
    let trashed: Vec<_> = fs::read_dir(env.trash_dir()).unwrap().flatten().collect();
    assert!(trashed.iter().any(|e| e.path().join("notes.md").is_file()));
}

/// The [install] defaults name more tools than the one the item was
/// adopted from: the declaration pins to what was actually observed, so
/// the follow-up apply never installs it somewhere the user never put it.
#[test]
fn adoption_binds_only_the_harnesses_that_had_the_item() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(
        project.join(".claude/skills/handmade/SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
    )
    .unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.handmade]"));
    assert!(
        manifest.contains("harnesses = [\"claude\"]"),
        "the declaration must pin to the adopted harness alone:\n{manifest}"
    );

    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    assert!(project.join(".claude/skills/handmade").is_symlink());
    assert!(!project.join(".opencode/skills/handmade").exists());
}

/// Proven where a test can make a symlink without a privilege.
#[cfg(unix)]
#[test]
fn foreign_symlinks_are_conflicts_never_clobbered() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let elsewhere = tmp.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/linked")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "linked",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(project.join(".claude/skills/linked").is_symlink());
}

/// A skill's position is the tool's own spelling of the name, and the
/// separator is the tool's, not one hard-coded here: Claude joins with
/// `__`, Copilot's lower-kebab rule with `-`.
#[test]
fn a_skills_position_takes_each_tools_own_separator() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project {
        root: tmp.path().join("app"),
    };
    let at =
        |harness| position(&env, &scope, ItemKind::Skill, "data-science/eda", harness).unwrap();

    assert!(at(HarnessId::Claude).ends_with("data-science__eda"));
    assert!(at(HarnessId::Copilot).ends_with("data-science-eda"));
}

/// The guard on `position` itself, not on the verb above it. Without it
/// the rendered join turns `../notes` into `..__notes` and hands back a
/// position, so every surface reading this would offer a keep for a name
/// adoption refuses.
#[test]
fn a_refused_name_has_no_position_to_offer() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project {
        root: tmp.path().join("app"),
    };

    assert!(position(&env, &scope, ItemKind::Skill, "../notes", HarnessId::Claude).is_none());
}

/// A legal name still spells a path. With `.agents/skills` a link at
/// somebody else's folder, the home sits outside the sealed tree, and the
/// move would land on a directory adoption was never pointed at. Proven
/// where a test can make a symlink without a privilege.
#[cfg(unix)]
#[test]
fn a_symlinked_shared_skills_directory_refuses_the_move() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let outside = tmp.path().join("elsewhere");
    fs::create_dir_all(outside.join("handmade")).unwrap();
    fs::write(outside.join("handmade/keepsake.md"), "somebody else's").unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    std::os::unix::fs::symlink(&outside, project.join(".agents/skills")).unwrap();
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(project.join(".claude/skills/handmade/SKILL.md"), "mine").unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(outside.join("handmade/keepsake.md").is_file());
    assert!(project.join(".claude/skills/handmade/SKILL.md").is_file());
    assert!(trash_is_empty(&env));
}

/// A namespaced name whose plugin half is already a package here would be
/// stored inside that package, and every later render of it would carry
/// the captured files as its own content.
#[test]
fn a_namespaced_name_under_an_existing_package_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let parent = project.join(".kendex-local/skills/data-science");
    fs::create_dir_all(&parent).unwrap();
    fs::write(parent.join("SKILL.md"), "a package of its own").unwrap();
    fs::create_dir_all(project.join(".claude/skills/data-science__eda")).unwrap();
    fs::write(
        project.join(".claude/skills/data-science__eda/SKILL.md"),
        "mine",
    )
    .unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(parent.join("SKILL.md")).unwrap(),
        "a package of its own"
    );
    assert!(!parent.join("eda").exists());
    assert!(trash_is_empty(&env));
}

/// A refused name is printed, not run. The name reaches stderr through
/// the CLI's `Error: {e}`, so a control sequence inside it would clear
/// the reader's screen while telling them the name was refused.
#[test]
fn a_refusal_prints_the_escape_sequences_it_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project {
        root: tmp.path().join("app"),
    };

    let said = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "keep\u{1b}[2J",
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string();

    assert!(!said.contains('\u{1b}'), "{said:?}");
    assert!(said.contains("\\u{1b}"), "{said:?}");
}

/// An agent's item is a file, so a plain `plugin` and a namespaced
/// `plugin/item` are siblings — `agents/plugin.md` beside
/// `agents/plugin/item.md` — and the local source lists both. Neither
/// nests inside the other, so neither refuses the other's adoption.
#[test]
fn a_plain_agent_and_a_namespaced_agent_both_adopt() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let agents = project.join(".claude/agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(agents.join("data-science.md"), "the plain one").unwrap();
    fs::write(agents.join("data-science__eda.md"), "the namespaced one").unwrap();

    for name in ["data-science", "data-science/eda"] {
        assert!(
            can_keep_for(&env, &scope, ItemKind::Agent, name, HarnessId::Claude),
            "{name} should be offered"
        );
        let plan = adopt(&env, &scope, ItemKind::Agent, name, &[HarnessId::Claude]).unwrap();
        crate::apply::execute(&env, &plan).unwrap();
    }

    let local = project.join(".kendex-local/agents");
    assert_eq!(
        fs::read_to_string(local.join("data-science.md")).unwrap(),
        "the plain one"
    );
    assert_eq!(
        fs::read_to_string(local.join("data-science/eda.md")).unwrap(),
        "the namespaced one"
    );
}

/// The offer reads the destination rule the capture reads. A slot behind
/// a symlink, and one nesting inside a package the local source already
/// holds, both refuse the verb — so neither may be drawn as a Keep.
#[test]
fn a_destination_the_capture_refuses_is_never_offered() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    // Both symlink halves need a symlink a test may make, so they run
    // where the platform hands them out without a privilege.
    #[cfg(unix)]
    {
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let outside = tmp.path().join("elsewhere");
        fs::create_dir_all(outside.join("handmade")).unwrap();
        fs::create_dir_all(project.join(".agents")).unwrap();
        std::os::unix::fs::symlink(&outside, project.join(".agents/skills")).unwrap();
        fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
        fs::write(project.join(".claude/skills/handmade/SKILL.md"), "mine").unwrap();

        assert!(!can_keep_for(
            &env,
            &scope,
            ItemKind::Skill,
            "handmade",
            HarnessId::Claude
        ));

        // The shared-folder offer reads it too. A row for a hand-made
        // sharing layout takes its Keep from `link_target`, not from
        // `can_keep_for`, so the rule has to reach that answer as well.
        let shared = tmp.path().join("shared/browser");
        fs::create_dir_all(&shared).unwrap();
        fs::write(shared.join("SKILL.md"), "shared content").unwrap();
        let link = project.join(".claude/skills/browser");
        std::os::unix::fs::symlink(&shared, &link).unwrap();
        assert!(link_target(&env, &scope, ItemKind::Skill, "browser", &link).is_none());
    }

    // The package-nesting half, in a scope whose local source is a plain
    // directory.
    let other = tmp.path().join("app2");
    let scope = Scope::Project {
        root: other.clone(),
    };
    let parent = other.join(".kendex-local/skills/data-science");
    fs::create_dir_all(&parent).unwrap();
    fs::write(parent.join("SKILL.md"), "a package of its own").unwrap();
    fs::create_dir_all(other.join(".claude/skills/data-science__eda")).unwrap();
    fs::write(
        other.join(".claude/skills/data-science__eda/SKILL.md"),
        "mine",
    )
    .unwrap();

    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        HarnessId::Claude
    ));
}

/// The nesting refusal compares two paths, and the sealed reader hands
/// back a canonicalized root while the slot carries the spelling the
/// caller built it from. With a symlink anywhere above the local source —
/// which is macOS by default, where a temporary directory sits under
/// `/var` fronted by `/private/var` — comparing them raw is comparing two
/// names for one directory, and the guard silently stops guarding.
///
/// The case it describes is a Unix one, and a test can make its symlink
/// there without a privilege.
#[cfg(unix)]
#[test]
fn the_nesting_refusal_holds_under_a_symlinked_ancestor() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    fs::create_dir_all(tmp.path().join("real")).unwrap();
    std::os::unix::fs::symlink(tmp.path().join("real"), tmp.path().join("front")).unwrap();
    let project = tmp.path().join("front/app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let parent = project.join(".kendex-local/skills/data-science");
    fs::create_dir_all(&parent).unwrap();
    fs::write(parent.join("SKILL.md"), "a package of its own").unwrap();
    fs::create_dir_all(project.join(".claude/skills/data-science__eda")).unwrap();
    fs::write(
        project.join(".claude/skills/data-science__eda/SKILL.md"),
        "mine",
    )
    .unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(!parent.join("eda").exists());
    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        HarnessId::Claude
    ));
}

/// Every adopt refusal that names a position spells it with `/`, whatever
/// the platform builds the path with. The three below are the ones that
/// print a position rather than an item name: the read that found nothing
/// anywhere, the in-place arm that found the home but no content to move
/// into it, and the folder wearing a skill's name without its marker.
///
/// The assertion is a tail spelled `/` in this source and never through
/// `paths::slashed`, so the two sides only agree where the value really
/// goes through that rule. On a host where `/` already separates, nothing
/// here can fail; the lane this holds is Windows, where the unfixed sites
/// read `app\.claude\skills\ghost`.
#[test]
fn an_adopt_refusal_spells_the_position_it_names_with_slashes() {
    let tail = "app/.claude/skills/ghost";

    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(&project).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let nowhere = adopt(&env, &scope, ItemKind::Skill, "ghost", &[HarnessId::Claude]).unwrap_err();
    assert!(nowhere.to_string().contains(tail), "{nowhere}");

    // The shared tree already holds the name, so the read gets past the
    // first refusal and the in-place arm makes the same complaint.
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(project.join(".agents/skills/ghost")).unwrap();
    fs::write(project.join(".agents/skills/ghost/SKILL.md"), "mine").unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let no_content =
        adopt(&env, &scope, ItemKind::Skill, "ghost", &[HarnessId::Claude]).unwrap_err();
    assert!(no_content.to_string().contains(tail), "{no_content}");

    // A directory under the name with no marker in it: content to move,
    // and nothing that reads back as a skill.
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(project.join(".claude/skills/ghost")).unwrap();
    fs::write(project.join(".claude/skills/ghost/notes.md"), "mine").unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let unmarked = adopt(&env, &scope, ItemKind::Skill, "ghost", &[HarnessId::Claude]).unwrap_err();
    assert!(unmarked.to_string().contains(tail), "{unmarked}");
}
