use std::fs;

use super::*;

mod links;

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
    crate::apply::execute(&env, &plan, None).unwrap();

    // The real directory moved into the shared tree — the content of
    // record, not a copy of it — and nothing was left where it was.
    assert!(project.join(".agents/skills/handmade/SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(!project.join(".claude/skills/handmade").exists());

    // Follow-up apply renders the managed replacement, drift-clean.
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
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
    crate::apply::execute(&env, &plan, None).unwrap();

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
    crate::apply::execute(&env, &plan, None).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.handmade]"));
    assert!(
        manifest.contains("harnesses = [\"claude\"]"),
        "the declaration must pin to the adopted harness alone:\n{manifest}"
    );

    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
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

/// The same nesting from the other side, and the direction that used to
/// delete. `data-science/eda` is stored at `<local>/skills/data-science`,
/// so the slot a plain `data-science` asks for is the directory holding
/// it — and the slot existing is not an earlier copy of `data-science`,
/// a name the local source lists nowhere. A project's plain skill is its
/// own source in `.agents`, so the local source is a plain skill's
/// destination only at the global scope.
#[test]
fn a_plain_skill_over_the_namespaced_one_stored_there_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Global;
    let held = tmp.path().join(".claude/skills");
    fs::create_dir_all(held.join("data-science__eda")).unwrap();
    fs::write(
        held.join("data-science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string();

    assert!(refused.contains("data-science/eda"), "{refused:?}");
    // The local source still offers the namespaced skill under its own
    // name, and the declaration still resolves to content that is there.
    let root = crate::source::local_source_root(&env, &scope);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    assert_eq!(
        crate::source::list_items(&sealed, &config, ItemKind::Skill),
        ["data-science/eda"]
    );
    let manifest =
        crate::manifest::load_for_mutation(&crate::manifest::manifest_path(&env, &scope))
            .unwrap()
            .unwrap();
    assert_eq!(
        manifest.declared(ItemKind::Skill)["data-science/eda"].source,
        LOCAL_SOURCE_NAME
    );
    assert_eq!(
        crate::source::find_item(&sealed, &config, ItemKind::Skill, "data-science/eda"),
        Some(root.join("skills/data-science/eda"))
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/data-science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);

    // The refusal is the collision's, not a refusal of every plain name:
    // one whose slot holds nothing is still kept.
    fs::create_dir_all(held.join("handmade")).unwrap();
    fs::write(held.join("handmade/SKILL.md"), "mine").unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();
    assert!(root.join("skills/handmade/SKILL.md").is_file());
}

/// The spelling half of the same collision. A macOS or Windows volume
/// hands `Data-Science` and `data-science` to one directory, so the stored
/// `Data-Science/eda` sits in the slot a plain `data-science` asks for even
/// though the two names differ character by character. The refusal reads
/// both sides under `names::fold`, which is a fact about the names rather
/// than about the host running the test, so it holds here too.
#[test]
fn a_plain_skill_over_a_differently_cased_namespaced_one_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Global;
    let held = tmp.path().join(".claude/skills");
    fs::create_dir_all(held.join("Data-Science__eda")).unwrap();
    fs::write(
        held.join("Data-Science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "Data-Science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string();

    assert!(refused.contains("Data-Science/eda"), "{refused:?}");
    let root = crate::source::local_source_root(&env, &scope);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    assert_eq!(
        crate::source::list_items(&sealed, &config, ItemKind::Skill),
        ["Data-Science/eda"]
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/Data-Science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);
}

/// The occupancy read is a read, and a read that fails is not an answer of
/// "the slot is free". Here the directory holding `data-science/eda` is
/// past the bound the sealed reader lists within, so the listing the guard
/// asks for cannot be made — and adoption refuses instead of trashing what
/// the plain name would land on top of. A local source that declares its
/// own layout is the shape that reaches this: without a control file the
/// search table walks the same directory first and refuses there.
#[test]
fn a_plain_skill_over_a_slot_whose_listing_fails_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Global;
    let held = tmp.path().join(".claude/skills");
    fs::create_dir_all(held.join("data-science__eda")).unwrap();
    fs::write(
        held.join("data-science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    let root = crate::source::local_source_root(&env, &scope);
    fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    let stored = root.join("skills/data-science");
    for n in 0..4_096 {
        fs::create_dir(stored.join(format!("filler-{n:04}"))).unwrap();
    }

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::SourceEscape { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/data-science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);
}

/// A skill written straight into the global scope's local source. These
/// controls ask what the slot HOLDS, and how it came to hold it is not part
/// of that question.
fn store_local_skill(env: &Env, rel: &str, body: &str) -> PathBuf {
    let dir = crate::source::local_source_root(env, &Scope::Global)
        .join("skills")
        .join(rel);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), body).unwrap();
    dir
}

/// The refusal a plain `name` gets at the global scope, with Claude holding
/// a skill of that name for the capture to take.
fn refuse_plain_skill(env: &Env, home: &Path, name: &str) -> String {
    let held = home.join(".claude/skills").join(name);
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    adopt(
        env,
        &Scope::Global,
        ItemKind::Skill,
        name,
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string()
}

/// A local source whose own config will not parse offers nothing at all —
/// every listing of it is empty, and an empty listing is not an empty
/// directory. The skill stored in the slot is stored there either way.
#[test]
fn a_plain_skill_over_a_slot_in_an_unreadable_local_source_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/eda", "the namespaced one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(root.join("kendex.toml"), "schema = [").unwrap();

    let refused = refuse_plain_skill(&env, tmp.path(), "data-science");

    assert!(refused.contains("data-science/eda"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// A catalog that declares where its skills live: `skills/data-science` is
/// this source's skill directory, so what it stores is listed as `foo/eda`
/// — a name whose plugin half is not the slot's, and whose path is inside
/// the slot regardless.
#[test]
fn a_plain_skill_over_a_slot_holding_a_differently_named_item_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/foo/eda", "the stored one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(
        root.join("kendex.toml"),
        "[catalog]\nskills = [\"skills/data-science\"]\n",
    )
    .unwrap();

    let refused = refuse_plain_skill(&env, tmp.path(), "data-science");

    assert!(refused.contains("data-science/foo"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the stored one"
    );
    assert!(trash_is_empty(&env));
}

/// A listing skips a `tests` directory wherever it finds one — the support
/// vocabulary a browse row is drawn through, since files there are about the
/// items rather than items. A legal `tests/foo` is therefore a skill no
/// listing names, and it occupies the plain `tests` slot all the same.
#[test]
fn a_plain_skill_over_a_slot_no_listing_names_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let stored = store_local_skill(&env, "tests/foo", "the namespaced one");

    let refused = refuse_plain_skill(&env, tmp.path(), "tests");

    assert!(refused.contains("tests/foo"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// A slot holding this very name is not a collision. The plain item stored
/// there is an earlier copy of the name being kept, and replacing it is
/// what a capture over it is for — the refusal above is the collision's,
/// not a refusal of every plain name whose slot exists.
#[test]
fn a_plain_skill_over_an_earlier_copy_of_itself_lands() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let stored = store_local_skill(&env, "handmade", "the earlier one");
    let held = tmp.path().join(".claude/skills/handmade");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the newer one").unwrap();

    let plan = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the newer one"
    );
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
        crate::apply::execute(&env, &plan, None).unwrap();
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
