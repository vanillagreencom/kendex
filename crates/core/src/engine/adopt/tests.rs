use super::*;
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

    // Content lives in the local source; the original is trashed.
    assert!(
        project
            .join(".kendex-local/skills/handmade/SKILL.md")
            .is_file()
    );
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

/// The local source already had a copy: it is trashed, never overwritten
/// in place, so nothing adoption replaces is gone for good.
#[test]
fn an_earlier_local_copy_goes_to_the_trash_not_under_the_new_one() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let earlier = project.join(".kendex-local/skills/handmade");
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

/// The shared-folder case this path exists for: two tools read one
/// folder through links. Adopting captures the folder's content, and
/// after the follow-up apply every tool still resolves to real files —
/// the sharing survives with kendex's copy as canonical.
#[test]
fn a_shared_skill_folder_adopts_the_target_and_keeps_every_tool_reading() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let shared = tmp.path().join("shared/browser");
    fs::create_dir_all(&shared).unwrap();
    fs::write(
        shared.join("SKILL.md"),
        "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    fs::create_dir_all(project.join(".agents/skills")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".agents/skills/browser")).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "browser",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    // Content captured; the folder and every link that read it cleared.
    assert!(
        project
            .join(".kendex-local/skills/browser/SKILL.md")
            .is_file()
    );
    assert!(!shared.exists());
    assert!(!project.join(".claude/skills/browser").is_symlink());
    assert!(!project.join(".agents/skills/browser").is_symlink());

    // The follow-up apply restores the sharing from kendex's copy.
    let report = crate::engine::audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
    let through_claude =
        fs::read_to_string(project.join(".claude/skills/browser/SKILL.md")).unwrap();
    assert!(through_claude.contains("Shared content."));
    let through_agents =
        fs::read_to_string(project.join(".agents/skills/browser/SKILL.md")).unwrap();
    assert!(through_agents.contains("Shared content."));
    let after = crate::engine::audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// "Somewhere kendex has no business touching": a folder that is not a
/// skill at all. The marker is the boundary — no SKILL.md, no adopt.
#[test]
fn a_link_at_a_folder_without_the_marker_still_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let elsewhere = tmp.path().join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("notes.txt"), "private").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/documents")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "documents",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(project.join(".claude/skills/documents").is_symlink());
    assert!(elsewhere.join("notes.txt").is_file());
}

/// A link the user repointed into kendex's own store is not theirs to
/// adopt: capturing a managed tree under another name would steal it.
#[test]
fn a_link_into_kendexs_own_trees_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let managed = env.rendered_skills_dir().join("other");
    fs::create_dir_all(&managed).unwrap();
    fs::write(
        managed.join("SKILL.md"),
        "---\nname: other\ndescription: managed elsewhere\n---\nManaged.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&managed, project.join(".claude/skills/stolen")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "stolen",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(managed.join("SKILL.md").is_file());
}

/// The folder changing between the plan and the apply aborts the whole
/// transaction: the trash op is bound to the bytes that were captured,
/// so a stale snapshot can never become "the backup".
#[test]
fn a_target_that_changed_after_planning_fails_the_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let shared = tmp.path().join("shared/browser");
    fs::create_dir_all(&shared).unwrap();
    fs::write(
        shared.join("SKILL.md"),
        "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "browser",
        &[HarnessId::Claude],
    )
    .unwrap();
    fs::write(shared.join("SKILL.md"), "changed under the plan").unwrap();

    assert!(crate::apply::execute(&env, &plan, None).is_err());
    assert!(
        shared.join("SKILL.md").is_file(),
        "the folder stays where it was"
    );
    assert!(project.join(".claude/skills/browser").is_symlink());
}

/// An absolute name is not a name. `PathBuf::join` throws away the root it
/// is joined onto, so the position adoption reads becomes the absolute
/// path itself — a directory outside every kendex root, captured into the
/// local source and then trashed. Refused before a path is derived.
#[test]
fn an_absolute_name_captures_and_trashes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let outside = tmp.path().join("elsewhere/notes");
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("SKILL.md"), "somebody else's files").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        outside.to_str().unwrap(),
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(outside.join("SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(trash_is_empty(&env));
    // The offer a surface would draw says the same thing.
    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        outside.to_str().unwrap(),
        HarnessId::Claude
    ));
}

/// A `..`-shaped name climbs out of the tool's skills directory: the old
/// join put the position at `.claude/notes`, one step above where skills
/// live, and the capture would have moved and trashed it.
#[test]
fn a_traversal_name_captures_and_trashes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let climbed = project.join(".claude/notes");
    fs::create_dir_all(&climbed).unwrap();
    fs::write(climbed.join("SKILL.md"), "not an item kendex was given").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "../notes",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(climbed.join("SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(trash_is_empty(&env));
    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "../notes",
        HarnessId::Claude
    ));
}

/// A namespaced skill sits at the tool's rendered spelling — one directory
/// called `plugin__item`, never nested directories — while the logical
/// name stays the manifest's and the local source's. Looking under
/// `.claude/skills/data-science/eda` would find nothing and report a skill
/// that is plainly there as absent.
#[test]
fn a_namespaced_skill_is_adopted_at_its_rendered_position() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let rendered = project.join(".claude/skills/data-science__eda");
    fs::create_dir_all(&rendered).unwrap();
    fs::write(
        rendered.join("SKILL.md"),
        "---\nname: eda\ndescription: explore data\n---\nMy content.\n",
    )
    .unwrap();

    assert!(can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        HarnessId::Claude
    ));
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    // The namespace is a directory only in the local source.
    assert!(
        project
            .join(".kendex-local/skills/data-science/eda/SKILL.md")
            .is_file()
    );
    assert!(!rendered.exists());
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("data-science/eda"), "{manifest}");

    // The follow-up apply puts it back where the tool reads it, and the
    // scope is drift-clean.
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
    assert!(rendered.exists(), "the tool reads it at its rendered name");
    assert!(!project.join(".claude/skills/data-science").exists());
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// Nothing has been moved into the trash. Its directory is created on
/// demand, so an absent one counts.
fn trash_is_empty(env: &Env) -> bool {
    fs::read_dir(env.trash_dir()).is_ok_and(|mut d| d.next().is_none()) || !env.trash_dir().exists()
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

/// A legal name still spells a path. With `.kendex-local/skills` a link
/// at somebody else's folder, the destination sits outside the sealed
/// source, and the capture's trash-then-write pair would land on a tree
/// adoption was never pointed at.
#[test]
fn a_symlinked_local_source_directory_refuses_the_capture() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let outside = tmp.path().join("elsewhere");
    fs::create_dir_all(outside.join("handmade")).unwrap();
    fs::write(outside.join("handmade/keepsake.md"), "somebody else's").unwrap();
    fs::create_dir_all(project.join(".kendex-local")).unwrap();
    std::os::unix::fs::symlink(&outside, project.join(".kendex-local/skills")).unwrap();
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
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let outside = tmp.path().join("elsewhere");
    fs::create_dir_all(outside.join("handmade")).unwrap();
    fs::create_dir_all(project.join(".kendex-local")).unwrap();
    std::os::unix::fs::symlink(&outside, project.join(".kendex-local/skills")).unwrap();
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
