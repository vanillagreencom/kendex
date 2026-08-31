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

/// A name that folds onto a neighbour of the local source's slot is the
/// same slot: a volume handing `Data-Science` and `data-science` back as
/// one directory keeps the stored item where the fork is asking to write,
/// and the planner would refuse both names and sweep the one that was
/// there. Fork-beside and rename ask the one occupancy rule, so both
/// refuse it.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_and_rename_refuse_names_that_fold_onto_a_neighbour() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(skill_file(&w), "edited").unwrap();

    let local = w.home.join("app/.kendex-local/skills/Data-Science");
    fs::create_dir_all(&local).unwrap();
    fs::write(
        local.join("SKILL.md"),
        "---\nname: Data-Science\n---\nTheirs.\n",
    )
    .unwrap();

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "data-science",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let renamed =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "data-science").unwrap_err();
    assert!(
        matches!(renamed, CoreError::SourceCollision { .. }),
        "{renamed:?}"
    );
    assert_eq!(
        fs::read_to_string(local.join("SKILL.md")).unwrap(),
        "---\nname: Data-Science\n---\nTheirs.\n"
    );
}
